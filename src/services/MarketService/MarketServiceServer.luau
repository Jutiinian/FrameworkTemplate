--[[
	MarketServiceServer
	
	Server-side marketplace service that handles gamepass and developer product purchases, ownership tracking, gifting,
	receipt processing, and purchase events. Provides promise-based helpers and signals for reacting to marketplace activity.
	
	@author Justin Dinh
	@version February 11, 2026
]]

--!optimize 2
--!strict

-- || Services || --
local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- || Dependencies || --
local Observers = require(ReplicatedStorage.Packages.Observers)
local ProfileStore = require(ServerScriptService.ServerPackages.ProfileStore)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Signal = require(ReplicatedStorage.Packages.Signal)

local MarketServiceUtils = require(ReplicatedStorage.Services.MarketService.MarketServiceUtils)
local ProductRegistry = require(ReplicatedStorage.Services.MarketService.ProductRegistry)

-- || Constants || --
local DEFAULT_RECEIPT_STORE_KEY = "ProcessedReceipts"
local DEFAULT_PROFILE_STORE_INDEX = "DefaultMarketStore"
local DEFAULT_FIRE_OWNED_GAMEPASSES_ON_JOIN = true
local DEFAULT_WARN_ON_MISSING_RECEIPT_HANDLER = true
local DEFAULT_ALLOW_OFFLINE_GIFTING = true
local DEFAULT_GIFT_MESSAGE_KEY = "MarketServiceGift"

-- || Types || --
type marketStore = ProfileStore.ProfileStore<{ [string]: boolean }>
type Profile = ProfileStore.Profile<{ [string]: boolean }>

type InitOptions = {
	receiptStoreKey: string?, -- DataStore key for tracking processed receipts
	profileStoreIndex: string?, -- ProfileStore index for gamepass ownership
	useMock: boolean?, -- Use mock ProfileStore (for testing)
	dontSave: boolean?, -- Don't save data (read-only mode)
	overrideUserId: number?, -- Preferred alias for overridenUserId
	overridenUserId: number?, -- Override UserId for testing
	fireOwnedGamepassesOnJoin: boolean?, -- Fire GamepassPurchased for already-owned passes after load
	warnOnMissingReceiptHandler: boolean?, -- Warn when a dev product receipt has no registered handler
	allowOfflineGifting: boolean?, -- Allow gifts to players who are not currently in the server
	giftMessageKey: string?, -- MarketService profile message key used for offline gift delivery
}

type ResolvedInitOptions = {
	receiptStoreKey: string,
	profileStoreIndex: string,
	useMock: boolean,
	dontSave: boolean,
	overrideUserId: number?,
	fireOwnedGamepassesOnJoin: boolean,
	warnOnMissingReceiptHandler: boolean,
	allowOfflineGifting: boolean,
	giftMessageKey: string,
}

type ReceiptInfo = {
	PlayerId: number, -- UserId who made the purchase
	ProductId: number, -- The product ID purchased
	PurchaseId: string, -- Unique ID for this transaction
	[string]: any, -- Additional Roblox receipt data
}

type ReceiptContext = {
	recipient: Player?,
	recipientUserId: number,
	purchaser: Player?,
	purchaserUserId: number,
	productKey: string,
	productId: number,
	purchaseId: string,
	isGift: boolean,
	isGamepassGift: boolean,
	receiptInfo: ReceiptInfo,
}

type ReceiptHandler = (receiptContext: ReceiptContext) -> boolean

type ProductIdentifier = string | number

type GiftRecipient = Player | number

type GiftData = {
	PurchaserID: number, -- Who is buying the gift
	RecipientID: number, -- Who receives it
	ProductID: number, -- What product is being gifted
	IsGamepassGift: boolean?, -- True if it's a gamepass gift
}

type OfflineGiftMessageData = {
	RecipientID: number,
	ProductID: number,
	ProductKey: string,
	PurchaseID: string,
	PurchaserID: number,
	IsGamepassGift: boolean,
}

-- || Private Functions || --
local function getPassIDKey(passID: number): string
	return tostring(passID)
end

local function getProfileKeyForUserId(userId: number, options: ResolvedInitOptions): string
	return `{options.overrideUserId or userId}`
end

local function getMessageStore(store: marketStore, options: ResolvedInitOptions): any
	return if options.useMock then (store :: any).Mock else store
end

local function resolveInitOptions(options: InitOptions?): ResolvedInitOptions
	local overrideUserId = if options and options.overrideUserId ~= nil
		then options.overrideUserId
		elseif options then options.overridenUserId
		else nil

	return {
		receiptStoreKey = if options and options.receiptStoreKey ~= nil then options.receiptStoreKey else DEFAULT_RECEIPT_STORE_KEY,
		profileStoreIndex = if options and options.profileStoreIndex ~= nil then options.profileStoreIndex else DEFAULT_PROFILE_STORE_INDEX,
		useMock = if options and options.useMock ~= nil then options.useMock else false,
		dontSave = if options and options.dontSave ~= nil then options.dontSave else false,
		overrideUserId = overrideUserId,
		fireOwnedGamepassesOnJoin = if options and options.fireOwnedGamepassesOnJoin ~= nil
			then options.fireOwnedGamepassesOnJoin
			else DEFAULT_FIRE_OWNED_GAMEPASSES_ON_JOIN,
		warnOnMissingReceiptHandler = if options and options.warnOnMissingReceiptHandler ~= nil
			then options.warnOnMissingReceiptHandler
			else DEFAULT_WARN_ON_MISSING_RECEIPT_HANDLER,
		allowOfflineGifting = if options and options.allowOfflineGifting ~= nil
			then options.allowOfflineGifting
			else DEFAULT_ALLOW_OFFLINE_GIFTING,
		giftMessageKey = if options and options.giftMessageKey ~= nil then options.giftMessageKey else DEFAULT_GIFT_MESSAGE_KEY,
	}
end

local function isRegisteredProduct(productName: string): boolean
	return ProductRegistry.GamePasses[productName] ~= nil or ProductRegistry.DevProducts[productName] ~= nil
end

local function resolveRecipientUserId(recipient: GiftRecipient): number?
	if typeof(recipient) == "Instance" then
		local player = recipient :: Player
		return player.UserId
	end

	if type(recipient) == "number" then
		return recipient
	end

	return nil
end

-- || Public API || --
type MarketServiceNetwork = typeof(require(script.Parent.NetworkServer))

local MarketServiceServer = {
	marketStore = (nil :: any) :: marketStore,

	GamepassPurchased = (nil :: any) :: Signal.ClassicSignal<Player, string>, -- Fires when a player purchases a gamepass
	DevProductPurchased = (nil :: any) :: Signal.ClassicSignal<Player, string>, -- Fires when a player purchases a dev product
	GiftDelivered = (nil :: any) :: Signal.ClassicSignal<Player, string, number>, -- Fires when a gift is delivered to a recipient
	GiftQueued = (nil :: any) :: Signal.ClassicSignal<number, string, number>, -- Fires when an offline gift is queued

	_initialized = false :: boolean,
	_initOptions = nil :: ResolvedInitOptions?,
	_network = nil :: MarketServiceNetwork?,
	_receiptHandlers = {} :: { [string]: ReceiptHandler },
	_receiptStore = (nil :: any) :: DataStore,

	_activeGifts = {} :: { [number]: GiftData },
	_activeProfiles = {} :: { [Player]: Profile },
	_waitSignals = {} :: { [Player]: Signal.ClassicSignal<Profile> },
}

export type MarketServiceServer = typeof(MarketServiceServer)

--[[
	Initializes the MarketService on the server.
	
	@param options InitOptions? Optional configuration table
	
	Examples:
	```lua
	local MarketServiceServer = require(ServerScriptService.Services.MarketService.MarketServiceServer)

	MarketServiceServer:Init({
		receiptStoreKey = "ProductionReceipts_V2",
		profileStoreIndex = "ProductionMarket_V2",
		fireOwnedGamepassesOnJoin = false,
		warnOnMissingReceiptHandler = true,
		allowOfflineGifting = true,
		useMock = true,
		dontSave = true
	})
	```
	
	Register receipt handlers before players can purchase products.
]]
function MarketServiceServer.Init(self: MarketServiceServer, options: InitOptions?)
	if self._initialized then
		warn("MarketServiceServer already initialized")
		return
	end

	self._initialized = true
	self._initOptions = resolveInitOptions(options)

	self._network = require(script.Parent.NetworkServer)

	self.GamepassPurchased = Signal.new()
	self.DevProductPurchased = Signal.new()
	self.GiftDelivered = Signal.new()
	self.GiftQueued = Signal.new()

	local initOptions = self._initOptions
	assert(initOptions, "[MarketServiceServer] Failed to resolve init options.")

	self.marketStore = ProfileStore.New(initOptions.profileStoreIndex)
	self._receiptStore = DataStoreService:GetDataStore(initOptions.receiptStoreKey)

	self:_BindMarketEvents()
	self:_BindNetworkEvents()

	Observers.observePlayer(function(player: Player)
		task.spawn(function()
			self:_OnPlayerAdded(player, initOptions)

			if not player:IsDescendantOf(Players) then
				return
			end

			if initOptions.fireOwnedGamepassesOnJoin then
				for key, passData in pairs(ProductRegistry.GamePasses) do
					local passID = passData.ID
					if passID and self:PlayerOwnsGamepass(player, passID) then
						self.GamepassPurchased:FireDeferred(player, key)
					end
				end
			end
		end)

		return function()
			self:_OnPlayerRemoved(player)
		end
	end)
end

--[[
	Registers a gamepass and syncs it to connected clients.

	@param productName string Product key
	@param productId number Gamepass ID
	@param giftProductId number? Gift developer product ID

	Examples:
	```lua
	MarketServiceServer:AddGamePass("VIP", 123456, 654321)
	```
]]
function MarketServiceServer.AddGamePass(self: MarketServiceServer, productName: string, productId: number, giftProductId: number?)
	ProductRegistry:RegisterGamePass(productName, {
		ID = productId,
		GiftID = giftProductId,
	})

	if self._initialized and self._network then
		self._network.AddGamePass.FireAll(productName, { ID = productId, GiftID = giftProductId })
	end
end

--[[
	Registers multiple gamepasses and syncs them to connected clients.

	@param gamePasses { [string]: { ID: number, GiftID: number? } } Gamepass definitions

	Examples:
	```lua
	MarketServiceServer:AddGamePasses({
		VIP = { ID = 123456, GiftID = 654321 },
		DoubleXP = { ID = 222333 },
	})
	```
]]
function MarketServiceServer.AddGamePasses(self: MarketServiceServer, gamePasses: { [string]: { ID: number, GiftID: number? } })
	for productName, data in pairs(gamePasses) do
		self:AddGamePass(productName, data.ID, data.GiftID)
	end
end

--[[
	Registers a developer product and syncs it to connected clients.

	@param productName string Product key
	@param productId number Developer product ID

	Examples:
	```lua
	MarketServiceServer:AddDevProduct("Coins100", 123456789)
	```
]]
function MarketServiceServer.AddDevProduct(self: MarketServiceServer, productName: string, productId: number)
	ProductRegistry:RegisterDevProduct(productName, productId)

	if self._initialized and self._network then
		self._network.AddDevProduct.FireAll(productName, productId)
	end
end

--[[
	Registers multiple developer products and syncs them to connected clients.

	@param devProducts { [string]: number } Developer product definitions

	Examples:
	```lua
	MarketServiceServer:AddDevProducts({
		Coins100 = 123456789,
		Coins500 = 987654321,
	})
	```
]]
function MarketServiceServer.AddDevProducts(self: MarketServiceServer, devProducts: { [string]: number })
	for productName, productId in pairs(devProducts) do
		self:AddDevProduct(productName, productId)
	end
end

-- || Gamepass Methods || --

--[[
	Checks if a player owns a specific gamepass.
	
	Checks cached ownership data first, then queries Roblox API if not cached.
	The result is cached for future checks.
	
	@param player Player The player to check
	@param passID number The gamepass ID
	@return boolean True if the player owns the gamepass
	
	Examples:
	```lua
	local VIP_PASS_ID = MarketServiceServer:GetProductID("VIP_Pass")
	
	if MarketServiceServer:PlayerOwnsGamepass(player, VIP_PASS_ID) then
		grantVIPPerks(player)
	end
	```
	
	Note: Makes a web request on first check. Use PlayerOwnsGamepassAsync() for
	promise-based async checking with better error handling.
]]
function MarketServiceServer.PlayerOwnsGamepass(self: MarketServiceServer, player: Player, passID: number): boolean
	local passIDKey = getPassIDKey(passID)

	-- Check cached data first
	local profile = self._activeProfiles[player]
	if profile and profile.Data and (profile.Data :: any)[passIDKey] == true then
		return true
	end

	-- Query Roblox API
	local success, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passID)
	end)

	if not success then
		warn(`Failed to check gamepass ownership for {player.Name}: {owns}`)
		return false
	end

	-- Cache the result if owned
	if owns and profile and profile.Data then
		(profile.Data :: any)[passIDKey] = true
		if self._network then
			self._network.SetMarketData.Fire(player, passIDKey, true)
		end
	end

	return owns
end

--[[
	Returns a promise that resolves with the player's gamepass ownership status.
	
	@param player Player The player to check
	@param passID number The gamepass ID
	@return Promise<boolean> Promise that resolves with true if owned, false if not
	
	Examples:
	```lua
	MarketServiceServer:PlayerOwnsGamepassAsync(player, VIP_PASS):andThen(function(owns)
		print("Owns VIP:", owns)
	end)
	```
]]
function MarketServiceServer.PlayerOwnsGamepassAsync(
	self: MarketServiceServer,
	player: Player,
	passID: number
): Promise.TypedPromise<boolean>
	return self:WaitForDataAsync(player):andThen(function()
		return self:PlayerOwnsGamepass(player, passID)
	end)
end

-- || Product Methods || --

--[[
	Gets the price of a product or gamepass.
	
	@param productId string | number Registered product key or raw product ID
	@param isGamepass boolean? Required only when productId is a raw number
	@return Promise<number> Promise that resolves with the price in Robux
	
	Examples:
	```lua
	MarketServiceServer:GetProductPriceAsync("VIP_Pass"):andThen(function(price)
		print("VIP costs", price, "Robux")
	end)
	```
]]
function MarketServiceServer.GetProductPriceAsync(
	_self: MarketServiceServer,
	productId: ProductIdentifier,
	isGamepass: boolean?
): Promise.TypedPromise<number>
	local resolvedProductID, infoType, resolveError = MarketServiceUtils:ResolveProductPriceTarget(productId, isGamepass)
	if not resolvedProductID or not infoType then
		return Promise.reject(resolveError or "Failed to resolve product price target")
	end

	return MarketServiceUtils.FetchProductPriceAsync(resolvedProductID, infoType)
end

--[[
	Waits for a registered product key to become available in the server registry.

	@param productName string Registered product key to wait for
	@param timeout number? Optional timeout in seconds
	@return Promise<number> Promise that resolves with the registered product ID

	Examples:
	```lua
	MarketServiceServer:AwaitProductRegistrationAsync("VIP_Pass"):andThen(function(productId)
		print("Registered VIP gamepass id:", productId)
	end):catch(warn)
	```
]]
function MarketServiceServer.AwaitProductRegistrationAsync(
	_self: MarketServiceServer,
	productName: string,
	timeout: number?
): Promise.TypedPromise<number>
	return MarketServiceUtils:AwaitProductRegistrationAsync(productName, timeout):andThen(function(registeredProduct)
		return registeredProduct.ID
	end)
end

--[[
	Prompts a player to purchase a gamepass.
	
	@param player Player The player to show the purchase prompt
	@param passID string | number Registered gamepass key or raw gamepass ID
	@return Promise<boolean> Promise that resolves with true if purchased, false if declined
	
	Examples:
	```lua
	MarketServiceServer:PromptGamePassAsync(player, "VIP_Pass"):andThen(function(purchased)
		if purchased then
			print(player.Name, "bought VIP!")
		end
	end):catch(warn)
	```
]]
function MarketServiceServer.PromptGamePassAsync(
	_self: MarketServiceServer,
	player: Player,
	passID: ProductIdentifier
): Promise.TypedPromise<boolean>
	local resolvedPassID = MarketServiceUtils:ResolveGamePassID(passID)
	if not resolvedPassID then
		return Promise.reject(`Unknown gamepass: {tostring(passID)}`)
	end

	return MarketServiceUtils.PromptAsync(player, resolvedPassID, true)
end

--[[
	Prompts a player to purchase a developer product.
	
	@param player Player The player to show the purchase prompt
	@param productID string | number Registered developer product key or raw product ID
	@return Promise<boolean> Promise that resolves with true if purchased, false if declined
	
	Examples:
	```lua
	MarketServiceServer:PromptDevProductAsync(player, "100_Coins"):andThen(function(purchased)
		if purchased then
			print(player.Name, "bought 100 coins!")
		end
	end):catch(warn)
	```
]]
function MarketServiceServer.PromptDevProductAsync(
	_self: MarketServiceServer,
	player: Player,
	productID: ProductIdentifier
): Promise.TypedPromise<boolean>
	local resolvedProductID = MarketServiceUtils:ResolveDevProductID(productID)
	if not resolvedProductID then
		return Promise.reject(`Unknown developer product: {tostring(productID)}`)
	end

	return MarketServiceUtils.PromptAsync(player, resolvedProductID, false)
end

function MarketServiceServer._GetGiftPromptProduct(_self: MarketServiceServer, requestedProductId: number): (number?, boolean, string?)
	local gamepassKey = ProductRegistry:GetGamePassKeyFromId(requestedProductId)
	if not gamepassKey then
		return requestedProductId, false, nil
	end

	local giftDevProductID = ProductRegistry.GamePasses[gamepassKey].GiftID
	if not giftDevProductID then
		return nil, true, "No gift Dev Product associated with this gamepass"
	end

	return giftDevProductID, true, nil
end

function MarketServiceServer._ValidateGiftRecipient(self: MarketServiceServer, purchaser: Player, recipientUserId: number): string?
	local initOptions = self._initOptions
	assert(initOptions, "[MarketServiceServer] Missing init options.")

	if recipientUserId <= 0 then
		return "Recipient UserId must be a positive number"
	end

	if recipientUserId == purchaser.UserId then
		return "Players cannot gift items to themselves"
	end

	if not initOptions.allowOfflineGifting and not Players:GetPlayerByUserId(recipientUserId) then
		return "Recipient is not in the game"
	end

	return nil
end

function MarketServiceServer._PromptGiftPurchaseAsync(
	self: MarketServiceServer,
	purchaser: Player,
	recipientUserId: number,
	promptProductId: number,
	isGamepassGift: boolean
): Promise.TypedPromise<boolean>
	self._activeGifts[purchaser.UserId] = {
		PurchaserID = purchaser.UserId,
		RecipientID = recipientUserId,
		ProductID = promptProductId,
		IsGamepassGift = isGamepassGift,
	}

	return MarketServiceUtils.PromptAsync(purchaser, promptProductId, false):catch(function(err)
		self._activeGifts[purchaser.UserId] = nil
		return Promise.reject(err)
	end)
end

-- || Gift Methods || --

--[[
	Prompts a player to purchase a developer product as a gift for another player.
	
	@param purchaser Player The player who will pay for the gift
	@param recipient Player | number Player instance or UserId of the gift recipient
	@param productID string | number Registered developer product key or raw product ID to gift
	@return Promise<boolean> Promise that resolves with true if purchased
	
	Examples:
	```lua
	MarketServiceServer:PromptGiftDevProductAsync(purchaser, recipient, "100_Coins")
		:andThen(function(success)
			if success then
				print(purchaser.Name, "gifted item to", recipient.Name)
			end
		end)
		:catch(function(err)
			warn("Gift failed:", err)
		end)
	```
]]
function MarketServiceServer.PromptGiftDevProductAsync(
	self: MarketServiceServer,
	purchaser: Player,
	recipient: GiftRecipient,
	productID: ProductIdentifier
): Promise.TypedPromise<boolean>
	local recipientUserId = resolveRecipientUserId(recipient)
	if not recipientUserId then
		return Promise.reject("Recipient must be a Player or UserId")
	end

	local resolvedProductID = MarketServiceUtils:ResolveDevProductID(productID)
	if not resolvedProductID then
		return Promise.reject(`Unknown developer product: {tostring(productID)}`)
	end

	local validationError = self:_ValidateGiftRecipient(purchaser, recipientUserId)
	if validationError then
		return Promise.reject(validationError)
	end

	return self:_PromptGiftPurchaseAsync(purchaser, recipientUserId, resolvedProductID, false)
end

--[[
	Prompts a player to purchase a gamepass as a gift for another player.
	
	@param purchaser Player The player who will pay for the gift
	@param recipient Player | number Player instance or UserId of the gift recipient
	@param passID string | number Registered gamepass key or raw gamepass ID to gift
	@return Promise<boolean> Promise that resolves with true if purchased
	
	Examples:
	```lua
	MarketServiceServer:PromptGiftGamepassAsync(purchaser, recipient, "VIP_Pass")
		:andThen(function(success)
			if success then
				print(purchaser.Name, "gifted VIP to", recipient.Name)
			end
		end)
		:catch(function(err)
			sendError(purchaser, "Gift failed: " .. tostring(err))
		end)
	```
]]
function MarketServiceServer.PromptGiftGamepassAsync(
	self: MarketServiceServer,
	purchaser: Player,
	recipient: GiftRecipient,
	passID: ProductIdentifier
): Promise.TypedPromise<boolean>
	local recipientUserId = resolveRecipientUserId(recipient)
	if not recipientUserId then
		return Promise.reject("Recipient must be a Player or UserId")
	end

	local resolvedPassID = MarketServiceUtils:ResolveGamePassID(passID)
	if not resolvedPassID then
		return Promise.reject(`Unknown gamepass: {tostring(passID)}`)
	end

	local validationError = self:_ValidateGiftRecipient(purchaser, recipientUserId)
	if validationError then
		return Promise.reject(validationError)
	end

	local giftDevProductID, isGamepassGift, resolveError = self:_GetGiftPromptProduct(resolvedPassID)
	if not giftDevProductID then
		return Promise.reject(resolveError or "Invalid gamepass ID")
	end

	return self:_PromptGiftPurchaseAsync(purchaser, recipientUserId, giftDevProductID, isGamepassGift)
end

-- || Data Methods || --

--[[
	Returns a promise that resolves when a player's market data is loaded.
	
	@param player Player The player whose data to wait for
	@return Promise<Profile> Promise that resolves with the ProfileStore profile
	
	Examples:
	```lua
	MarketServiceServer:WaitForDataAsync(player):andThen(function(profile)
		local hasVIP = MarketServiceServer:PlayerOwnsGamepass(player, VIP_PASS_ID)
		print(hasVIP)
	end):catch(function(err)
		player:Kick("Failed to load market data")
	end)
	```
]]
function MarketServiceServer.WaitForDataAsync(self: MarketServiceServer, player: Player): Promise.TypedPromise<Profile>
	local profile = self._activeProfiles[player]
	if profile then
		return Promise.resolve(profile)
	end

	local waitSignal = self._waitSignals[player]
	if not waitSignal then
		waitSignal = Signal.new()
		self._waitSignals[player] = waitSignal
	end

	return Promise.race({
		Promise.fromEvent(waitSignal, function(receivedProfile)
			return receivedProfile ~= nil
		end),

		Promise.fromEvent(Players.PlayerRemoving, function(leavingPlayer)
			return leavingPlayer == player
		end):andThen(function()
			return Promise.reject("Player left before data loaded")
		end),
	})
end

-- || Receipt Handling || --

--[[
	Registers a receipt handler for a single product key.

	@param productName string Product key from ProductRegistry
	@param handler (receiptContext: ReceiptContext) -> boolean

	Examples:
	```lua
	MarketServiceServer:RegisterReceiptHandler("Coins100", function(context)
		local recipient = context.recipient
		if not recipient then
			return false
		end

		print("Grant product to", recipient.Name)
		return true
	end)
	```
]]
function MarketServiceServer.RegisterReceiptHandler(self: MarketServiceServer, productName: string, handler: ReceiptHandler)
	assert(isRegisteredProduct(productName), `[MarketServiceServer] Unknown product key: {productName}`)
	self._receiptHandlers[productName] = handler
end

--[[
	Registers multiple receipt handlers at once.

	@param handlers { [string]: ReceiptHandler } Map of product keys to handlers

	Examples:
	```lua
	MarketServiceServer:RegisterReceiptHandlers({
		Coins100 = function(context)
			return context.recipient ~= nil
		end,
		Coins500 = function(context)
			return context.recipient ~= nil
		end,
	})
	```
]]
function MarketServiceServer.RegisterReceiptHandlers(self: MarketServiceServer, handlers: { [string]: ReceiptHandler })
	for productName, handler in pairs(handlers) do
		self:RegisterReceiptHandler(productName, handler)
	end
end

--[[
	Gets the product ID from a product name.
	
	Looks up the product in ProductRegistry by its key name.
	
	@param productName string The product key from ProductRegistry
	@return number The Roblox product/gamepass ID
	
	Examples:
	```lua
	local productName = "SpeedBoost"
	local productId = MarketServiceServer:GetProductID(productName)
	MarketServiceServer:PromptGamePassAsync(player, productId)
	```
]]
MarketServiceServer.GetProductID = MarketServiceUtils.GetProductID :: (self: MarketServiceServer, productName: string) -> number?

-------------------------------------------------------------------------------------------------------------------------------
-- Private Service Functions

function MarketServiceServer._RunReceiptHandler(self: MarketServiceServer, receiptContext: ReceiptContext): boolean
	local receiptHandler = self._receiptHandlers[receiptContext.productKey]
	if not receiptHandler then
		local initOptions = self._initOptions
		if initOptions and initOptions.warnOnMissingReceiptHandler then
			warn(`No receipt handler registered for product {receiptContext.productKey} ({receiptContext.productId})`)
		end

		return false
	end

	local receiptHandlerSuccess, receiptHandlerResult = pcall(receiptHandler, receiptContext)
	if not receiptHandlerSuccess then
		warn(`Receipt handler errored for {receiptContext.productKey} ({receiptContext.productId}): {receiptHandlerResult}`)
		return false
	end

	return receiptHandlerResult == true
end

function MarketServiceServer._SyncProductRegistry(self: MarketServiceServer, player: Player)
	local network = self._network
	if not network then
		return
	end

	for productName, data in pairs(ProductRegistry.GamePasses) do
		network.AddGamePass.Fire(player, productName, { ID = data.ID, GiftID = data.GiftID })
	end

	for productName, productId in pairs(ProductRegistry.DevProducts) do
		network.AddDevProduct.Fire(player, productName, productId)
	end
end

function MarketServiceServer._GrantReceiptContext(self: MarketServiceServer, receiptContext: ReceiptContext): boolean
	if receiptContext.isGamepassGift then
		local recipient = receiptContext.recipient
		if not recipient then
			warn(
				`Cannot grant gamepass gift {receiptContext.productKey} because recipient {receiptContext.recipientUserId} is not available`
			)
			return false
		end

		local gamepassID = ProductRegistry.GamePasses[receiptContext.productKey].ID
		self:_GrantGamepass(recipient, gamepassID)
		if receiptContext.isGift and self.GiftDelivered then
			self.GiftDelivered:Fire(recipient, receiptContext.productKey, receiptContext.purchaserUserId)
		end
		return true
	end

	if not self:_RunReceiptHandler(receiptContext) then
		return false
	end

	if receiptContext.recipient and self.DevProductPurchased then
		self.DevProductPurchased:Fire(receiptContext.recipient, receiptContext.productKey)
	end

	if receiptContext.isGift and receiptContext.recipient and self.GiftDelivered then
		self.GiftDelivered:Fire(receiptContext.recipient, receiptContext.productKey, receiptContext.purchaserUserId)
	end

	return true
end

function MarketServiceServer._QueueOfflineGiftMessage(self: MarketServiceServer, receiptContext: ReceiptContext): boolean
	local initOptions = self._initOptions
	assert(initOptions, "[MarketServiceServer] Missing init options.")

	local messageData: OfflineGiftMessageData = {
		RecipientID = receiptContext.recipientUserId,
		ProductID = receiptContext.productId,
		ProductKey = receiptContext.productKey,
		PurchaseID = receiptContext.purchaseId,
		PurchaserID = receiptContext.purchaserUserId,
		IsGamepassGift = receiptContext.isGamepassGift,
	}

	local message = {
		Key = initOptions.giftMessageKey,
		Payload = messageData,
	}

	local profileKey = getProfileKeyForUserId(receiptContext.recipientUserId, initOptions)
	local messageStore = getMessageStore(self.marketStore, initOptions)

	local success = messageStore:MessageAsync(profileKey, message)

	if not success then
		warn(`Failed to queue offline gift for recipient {receiptContext.recipientUserId} product {receiptContext.productKey}`)
	elseif self.GiftQueued then
		self.GiftQueued:Fire(receiptContext.recipientUserId, receiptContext.productKey, receiptContext.purchaserUserId)
	end

	return success
end

function MarketServiceServer._ProcessOfflineGiftMessage(
	self: MarketServiceServer,
	player: Player,
	messageData: OfflineGiftMessageData
): boolean?
	if player.UserId ~= messageData.RecipientID then
		warn(`Received offline gift message for recipient {messageData.RecipientID} on player {player.UserId}`)
		return false
	end

	if not self._activeProfiles[player] then
		local waitSignal = self._waitSignals[player]
		if not waitSignal then
			return false
		end

		waitSignal:Wait()
		if not self._activeProfiles[player] then
			return false
		end
	end

	local receiptContext: ReceiptContext = {
		recipient = player,
		recipientUserId = player.UserId,
		purchaser = Players:GetPlayerByUserId(messageData.PurchaserID),
		purchaserUserId = messageData.PurchaserID,
		productKey = messageData.ProductKey,
		productId = messageData.ProductID,
		purchaseId = messageData.PurchaseID,
		isGift = true,
		isGamepassGift = messageData.IsGamepassGift,
		receiptInfo = {
			PlayerId = messageData.PurchaserID,
			ProductId = messageData.ProductID,
			PurchaseId = messageData.PurchaseID,
		},
	}

	return self:_GrantReceiptContext(receiptContext)
end

function MarketServiceServer._BindOfflineGiftMessageHandler(
	self: MarketServiceServer,
	player: Player,
	profile: Profile,
	options: ResolvedInitOptions
)
	profile:MessageHandler(function(message, processed: () -> ())
		if type(message) ~= "table" then
			return
		end

		local typedMessage = message :: { [string]: any }
		if typedMessage.Key ~= options.giftMessageKey then
			return
		end

		local payload = typedMessage.Payload
		if type(payload) ~= "table" then
			warn(`[MarketServiceServer] Received malformed offline gift payload for {player.UserId}`)
			return
		end

		if self:_ProcessOfflineGiftMessage(player, payload :: OfflineGiftMessageData) ~= false then
			processed()
		end
	end)
end

function MarketServiceServer._ProcessReceipt(self: MarketServiceServer, receiptInfo: ReceiptInfo): Enum.ProductPurchaseDecision
	assert(
		self._receiptStore,
		"[MarketServiceServer] Attempting to process receipt but seems that _receiptStore does not exist. Please run MarketServiceServer:Init()."
	)

	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local key = ProductRegistry:GetDevProductKeyFromId(receiptInfo.ProductId)
		or ProductRegistry:GetGamePassKeyFromGiftId(receiptInfo.ProductId)

	if not key then
		warn(`Unknown product: {receiptInfo.ProductId}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local giftData = self._activeGifts[player.UserId]
	local recipient: Player? = player
	local recipientUserId = player.UserId
	local isGamepassGift = false

	if giftData and giftData.ProductID == receiptInfo.ProductId then
		recipientUserId = giftData.RecipientID
		recipient = Players:GetPlayerByUserId(giftData.RecipientID)
		isGamepassGift = giftData.IsGamepassGift or false
	end

	local success, result = pcall(function()
		return self._receiptStore:UpdateAsync(receiptInfo.PurchaseId, function(isPurchased)
			if isPurchased then
				return true
			end

			local receiptContext: ReceiptContext = {
				recipient = recipient,
				recipientUserId = recipientUserId,
				purchaser = player,
				purchaserUserId = player.UserId,
				productKey = key,
				productId = receiptInfo.ProductId,
				purchaseId = receiptInfo.PurchaseId,
				isGift = giftData ~= nil and giftData.ProductID == receiptInfo.ProductId,
				isGamepassGift = isGamepassGift,
				receiptInfo = receiptInfo,
			}

			if receiptContext.isGift and receiptContext.recipient == nil then
				if not self:_QueueOfflineGiftMessage(receiptContext) then
					return nil
				end
				return true
			end

			if not self:_GrantReceiptContext(receiptContext) then
				return nil
			end

			return true
		end)
	end)

	if not success then
		warn(`Failed to process receipt due to data store error: {result}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if result == true and giftData and giftData.ProductID == receiptInfo.ProductId then
		self._activeGifts[player.UserId] = nil
	end

	return if result == true then Enum.ProductPurchaseDecision.PurchaseGranted else Enum.ProductPurchaseDecision.NotProcessedYet
end

function MarketServiceServer._GrantGamepass(self: MarketServiceServer, player: Player, passID: number)
	local profile = self._activeProfiles[player]
	if profile and profile.Data then
		local passIDKey = getPassIDKey(passID)
		local data = profile.Data :: { [string]: boolean }
		data[passIDKey] = true

		if self._network then
			self._network.SetMarketData.Fire(player, passIDKey, true)
		else
			warn(
				"[MarketServiceServer] Attempted to sync client data but _network does not yet exist. Forget to call MarketServiceServer:Init()?"
			)
		end
	end

	local key = ProductRegistry:GetGamePassKeyFromId(passID)
	if key and self.GamepassPurchased then
		self.GamepassPurchased:Fire(player, key)
	end
end

function MarketServiceServer._BindMarketEvents(self: MarketServiceServer)
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, passID: number, wasPurchased: boolean)
		if wasPurchased then
			self:_GrantGamepass(player, passID)
		end
	end)

	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userID: number, productID: number, wasPurchased: boolean)
		if not wasPurchased then
			local giftData = self._activeGifts[userID]
			if giftData and giftData.ProductID == productID then
				self._activeGifts[userID] = nil
			end
		end
	end)

	MarketplaceService.ProcessReceipt = function(receiptInfo)
		return self:_ProcessReceipt(receiptInfo)
	end
end

function MarketServiceServer._BindNetworkEvents(self: MarketServiceServer)
	assert(self._network, "[MarketServiceServer] Attempting to run _BindNetworkEvents while _network does not exist.")

	self._network.RequestGiftPurchase.SetCallback(function(player: Player, recipient: string, productID: string): boolean
		local recipientID = tonumber(recipient)
		local productIDNum = tonumber(productID)

		if not recipientID or not productIDNum then
			warn("Invalid recipient or productID:", recipient, productID)
			return false
		end

		local validationError = self:_ValidateGiftRecipient(player, recipientID)
		if validationError then
			warn(validationError)
			return false
		end

		local giftDevProductID, isGamepassGift, resolveError = self:_GetGiftPromptProduct(productIDNum)
		if not giftDevProductID then
			warn(resolveError or "Failed to resolve gift product")
			return false
		end

		self._activeGifts[player.UserId] = {
			PurchaserID = player.UserId,
			RecipientID = recipientID,
			ProductID = giftDevProductID,
			IsGamepassGift = isGamepassGift,
		}

		return true
	end)
end

function MarketServiceServer._OnPlayerAdded(self: MarketServiceServer, player: Player, options: ResolvedInitOptions)
	self._waitSignals[player] = Signal.new()

	local key = getProfileKeyForUserId(player.UserId, options)

	local params = {
		Cancel = function()
			return player.Parent ~= Players
		end,
	}

	local profile = if options.useMock
		then (self.marketStore :: marketStore).Mock:StartSessionAsync(key, params) :: Profile
		elseif options.dontSave then (self.marketStore :: marketStore):GetAsync(key) :: Profile
		else (self.marketStore :: marketStore):StartSessionAsync(key, params) :: Profile

	if not profile then
		warn(`{player.Name}'s market profile failed to load!`)
		player:Kick("Failed to load market data. Please rejoin.")
		return
	end

	profile:AddUserId(player.UserId)
	profile:Reconcile()
	self:_BindOfflineGiftMessageHandler(player, profile, options)

	profile.OnSessionEnd:Connect(function()
		self._activeProfiles[player] = nil
		if player:IsDescendantOf(Players) then
			player:Kick("Market session closed.\nPlease rejoin!")
		end
	end)

	if not player:IsDescendantOf(Players) then
		profile:EndSession()
		return
	end

	self._activeProfiles[player] = profile
	self:_SyncProductRegistry(player)

	if self._network then
		self._network.InitializeMarketData.Fire(player, profile.Data)
	end

	local waitSignal = self._waitSignals[player]
	if waitSignal then
		waitSignal:Fire(profile)
		waitSignal:Destroy()
		self._waitSignals[player] = nil
	end
end

function MarketServiceServer._OnPlayerRemoved(self: MarketServiceServer, player: Player)
	self._activeGifts[player.UserId] = nil

	local waitSignal = self._waitSignals[player]
	if waitSignal then
		waitSignal:Destroy()
		self._waitSignals[player] = nil
	end

	local profile = self._activeProfiles[player]
	if profile then
		profile:EndSession()
		self._activeProfiles[player] = nil
	end
end

return MarketServiceServer
