--[[
	MarketServiceClient
	
	Client-side marketplace service that handles gamepass and developer product purchases, ownership tracking, gifting,
	and purchase events. Provides promise-based helpers and signals for reacting to marketplace activity.
	
	@author Jutiinian
	@version February 11, 2026
]]

--!optimize 2
--!strict

-- || Services || --
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local MarketServiceUtils = require(script.Parent.MarketServiceUtils)
local ProductRegistry = require(script.Parent.ProductRegistry)

local Promise = require(ReplicatedStorage.Packages.Promise)
local Signal = require(ReplicatedStorage.Packages.Signal)

-- || Variables || --
local DEFAULT_OWNERSHIP_TIMEOUT = 10

local Player = Players.LocalPlayer

local function resolveRecipientUserId(recipient: Player | number): number?
	if typeof(recipient) == "Instance" then
		return (recipient :: Player).UserId
	end

	if type(recipient) == "number" then
		return recipient
	end

	return nil
end

-- || Types || --
type InitOptions = {
	ownershipTimeout: number?, -- Default timeout in seconds for ownership sync waits
}

type ProductIdentifier = string | number

type GamePassDefinition = {
	ID: number,
	GiftID: number?,
}

type MarketServiceNetwork = typeof(require(script.Parent.NetworkClient))

-- || Public API || --
local MarketServiceClient = {
	_network = nil :: MarketServiceNetwork?,
	_ownershipCache = {} :: { [string]: boolean },

	GamepassPurchased = (nil :: any) :: Signal.ClassicSignal<string>, -- Fires when a gamepass is purchased
	DevProductPurchased = (nil :: any) :: Signal.ClassicSignal<string>, -- Fires when a dev product is purchased
	GamepassOwnershipChanged = (nil :: any) :: Signal.ClassicSignal<string, boolean>, -- Fires when ownership status changes
	GiftPurchaseCompleted = (nil :: any) :: Signal.ClassicSignal<number, string>, -- Fires when the local player completes a gift purchase

	_initStarted = false :: boolean,
	_initialized = false :: boolean,
	_ownershipTimeout = DEFAULT_OWNERSHIP_TIMEOUT :: number,
	_initializedSignal = (nil :: any) :: Signal.ClassicSignal<>,
}

export type MarketServiceClient = typeof(MarketServiceClient)

-- || Initialization || --

--[[
	Initializes the MarketService on the client.
	
	Examples:
	```lua
	local MarketServiceClient = require(ReplicatedStorage.Services.MarketService.MarketServiceClient)
	MarketServiceClient:Init({
		ownershipTimeout = 10,
	})
	
	-- Now you can use MarketServiceClient methods
	```
]]
function MarketServiceClient.Init(self: MarketServiceClient, options: InitOptions?)
	if self._initStarted then
		warn("MarketServiceClient already initialized")
		return
	end

	self._initStarted = true
	self._ownershipTimeout = if options and options.ownershipTimeout ~= nil then options.ownershipTimeout else DEFAULT_OWNERSHIP_TIMEOUT

	self._network = require(script.Parent.NetworkClient)
	self._initializedSignal = Signal.new()

	self.GamepassPurchased = Signal.new()
	self.DevProductPurchased = Signal.new()
	self.GamepassOwnershipChanged = Signal.new()
	self.GiftPurchaseCompleted = Signal.new()

	self:_BindNetworkEvents()
	self:_BindProductRegistrySync()
	self:_BindMarketEvents()
end

--[[
	Registers a gamepass in the local product registry.

	Most games should register products on the server and let MarketService sync them.

	@param productName string Product key
	@param productId number Gamepass ID
	@param giftProductId number? Gift developer product ID

	Examples:
	```lua
	MarketServiceClient:AddGamePass("VIP", 123456, 654321)
	```
]]
function MarketServiceClient.AddGamePass(_self: MarketServiceClient, productName: string, productId: number, giftProductId: number?)
	ProductRegistry:RegisterGamePass(productName, {
		ID = productId,
		GiftID = giftProductId,
	})
end

--[[
	Registers a developer product in the local product registry.

	Most games should register products on the server and let MarketService sync them.

	@param productName string Product key
	@param productId number Developer product ID

	Examples:
	```lua
	MarketServiceClient:AddDevProduct("Coins100", 123456789)
	```
]]
function MarketServiceClient.AddDevProduct(_self: MarketServiceClient, productName: string, productId: number)
	ProductRegistry:RegisterDevProduct(productName, productId)
end

-- || Gamepass Ownership Methods || --

--[[
	Checks if the local player owns a specific gamepass (synchronous).
	
	@param passID number The gamepass ID to check
	@return boolean True if the player owns the gamepass
	
	Examples:
	```lua
	if MarketServiceClient:PlayerOwnsGamepass(123456789) then
		print("Player has VIP!")
	end
	```
]]
function MarketServiceClient.PlayerOwnsGamepass(self: MarketServiceClient, passID: number): boolean
	local key = tostring(passID)

	local cached = self._ownershipCache[key]
	if cached ~= nil then
		return cached
	end

	local success, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(Player.UserId, passID)
	end)

	if not success then
		warn(`Failed to check gamepass ownership: {owns}`)
		return false
	end

	self._ownershipCache[key] = owns
	return owns
end

--[[
	Returns a promise that resolves with the player's gamepass ownership status.
	
	@param passID number The gamepass ID to check
	@param timeout number? Timeout in seconds (default: 10)
	@return Promise<boolean> Promise that resolves with true if owned, false if not
	
	Examples:
	```lua
	MarketServiceClient:PlayerOwnsGamepassAsync(123456789):andThen(function(owns)
		if owns then
			print("Player owns VIP pass!")
		else
			print("Player doesn't own VIP pass")
		end
	end):catch(function(err)
		warn("Failed to check ownership:", err)
	end)
	```
]]
function MarketServiceClient.PlayerOwnsGamepassAsync(
	self: MarketServiceClient,
	passID: number,
	timeout: number?
): Promise.TypedPromise<boolean>
	assert(self._initStarted, "[MarketServiceClient] Please initialize the market service by running MarketServiceClient:Init().")

	local key = tostring(passID)

	return Promise.try(function()
		if not self._initialized then
			return Promise.fromEvent(self._initializedSignal)
		end

		return true :: any
	end):andThen(function()
		local cached = self._ownershipCache[key]
		if cached ~= nil then
			return Promise.resolve(cached)
		end

		return Promise.race({
			Promise.fromEvent(self.GamepassOwnershipChanged :: any, function(id)
				return id == key
			end):andThen(function(_, owns)
				return owns
			end),

			Promise.delay(timeout or self._ownershipTimeout):andThen(function()
				return Promise.reject("Timed out waiting for gamepass ownership")
			end),
		})
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
	MarketServiceClient:GetProductPriceAsync("VIP_Pass"):andThen(function(price)
		print("VIP Pass costs", price, "Robux")
	end)
	
	MarketServiceClient:GetProductPriceAsync("Coins100"):andThen(function(price)
		print("Coin Pack costs", price, "Robux")
	end)
	```
]]
function MarketServiceClient.GetProductPriceAsync(
	_self: MarketServiceClient,
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
	Waits for a registered product key to become available in the local registry.

	@param productName string Registered product key to wait for
	@param timeout number? Optional timeout in seconds
	@return Promise<number> Promise that resolves with the registered product ID

	Examples:
	```lua
	MarketServiceClient:AwaitProductRegistrationAsync("Coins_100"):andThen(function(productId)
		return MarketServiceClient:GetProductPriceAsync("Coins_100")
	end):andThen(function(price)
		print("Coins_100 costs", price)
	end):catch(warn)
	```
]]
function MarketServiceClient.AwaitProductRegistrationAsync(
	_self: MarketServiceClient,
	productName: string,
	timeout: number?
): Promise.TypedPromise<number>
	return MarketServiceUtils:AwaitProductRegistrationAsync(productName, timeout):andThen(function(registeredProduct)
		return registeredProduct.ID
	end)
end

--[[
	Prompts the player to purchase a gamepass.
	
	@param passID string | number Registered gamepass key or raw gamepass ID to prompt
	@return Promise<boolean> Promise that resolves with true if purchased, false if declined
	
	Examples:
	```lua
	MarketServiceClient:PromptGamePassAsync("VIP"):andThen(function(purchased)
		if purchased then
			print("Thanks for purchasing VIP!")
		else
			print("Purchase was declined or failed")
		end
	end):catch(function(err)
		warn("Error prompting gamepass:", err)
	end)
	```
	
	Note: The promise resolves true ONLY if the purchase completed successfully.
	It resolves false if declined, and rejects if there's an error.
]]
function MarketServiceClient.PromptGamePassAsync(_self: MarketServiceClient, passID: ProductIdentifier): Promise.TypedPromise<boolean>
	local resolvedPassID = MarketServiceUtils:ResolveGamePassID(passID)
	if not resolvedPassID then
		return Promise.reject(`Unknown gamepass: {tostring(passID)}`)
	end

	return MarketServiceUtils.PromptAsync(Player, resolvedPassID, true)
end

--[[
	Prompts the player to purchase a developer product.
	
	@param productID string | number Registered developer product key or raw product ID to prompt
	@return Promise<boolean> Promise that resolves with true if purchased, false if declined
	
	Examples:
	```lua
	MarketServiceClient:PromptDevProductAsync("100_Coins"):andThen(function(purchased)
		if purchased then
			print("Thanks for purchasing 100 coins!")
			-- Actual grant happens server-side in ProcessReceipt
		end
	end)
	```
	
	Note: The server's ProcessReceipt callback handles actually granting the product.
	This just initiates the purchase flow.
]]
function MarketServiceClient.PromptDevProductAsync(_self: MarketServiceClient, productID: ProductIdentifier): Promise.TypedPromise<boolean>
	local resolvedProductID = MarketServiceUtils:ResolveDevProductID(productID)
	if not resolvedProductID then
		return Promise.reject(`Unknown developer product: {tostring(productID)}`)
	end

	return MarketServiceUtils.PromptAsync(Player, resolvedProductID, false)
end

-- || Gift Methods || --

--[[
	Prompts the local player to gift a developer product to another player.
	
	@param recipient Player | number Player instance or UserId of the gift recipient
	@param productID string | number Registered developer product key or raw product ID to gift
	@return Promise<boolean> Promise that resolves with true if purchase completed
	
	Examples:
	```lua
	MarketServiceClient:PromptGiftDevProductAsync(targetPlayer, "100_Coins")
		:andThen(function(success)
			if success then
				print("Gift sent to", targetPlayer.Name)
			end
		end)
		:catch(function(err)
			print("Gift failed:", err)
		end)
	```
]]
function MarketServiceClient.PromptGiftDevProductAsync(
	self: MarketServiceClient,
	recipient: Player | number,
	productID: ProductIdentifier
): Promise.TypedPromise<boolean>
	local recipientUserId = resolveRecipientUserId(recipient)
	if not recipientUserId or recipientUserId <= 0 then
		return Promise.reject("Recipient must be a valid Player or UserId")
	end

	local resolvedProductID = MarketServiceUtils:ResolveDevProductID(productID)
	if not resolvedProductID then
		return Promise.reject(`Unknown developer product: {tostring(productID)}`)
	end

	if not self._network then
		return Promise.reject("MarketService not initialized")
	end

	return self._network.RequestGiftPurchase.Call(tostring(recipientUserId), tostring(resolvedProductID)):andThen(function(accepted)
		if not accepted then
			return Promise.reject("Server rejected gift request")
		end
		return MarketServiceUtils.PromptAsync(Player, resolvedProductID, false):andThen(function(purchased)
			if purchased and self.GiftPurchaseCompleted then
				local productKey = ProductRegistry:GetDevProductKeyFromId(resolvedProductID)
				if productKey then
					self.GiftPurchaseCompleted:Fire(recipientUserId, productKey)
				end
			end
			return purchased
		end)
	end)
end

--[[
	Prompts the local player to gift a gamepass to another player.
	
	@param recipient Player | number Player instance or UserId of the gift recipient
	@param passID string | number Registered gamepass key or raw gamepass ID to gift
	@return Promise<boolean> Promise that resolves with true if purchase completed
	
	Examples:
	```lua
	MarketServiceClient:PromptGiftGamepassAsync(targetPlayer, "VIP_Pass")
		:andThen(function(success)
			if success then
				print("VIP gifted to", selectedPlayer.Name)
			end
		end)
		:catch(function(err)
			warn("Gift failed:", err)
		end)
	```
]]
function MarketServiceClient.PromptGiftGamepassAsync(
	self: MarketServiceClient,
	recipient: Player | number,
	passID: ProductIdentifier
): Promise.TypedPromise<boolean>
	local recipientUserId = resolveRecipientUserId(recipient)
	if not recipientUserId or recipientUserId <= 0 then
		return Promise.reject("Recipient must be a valid Player or UserId")
	end

	local resolvedPassID = MarketServiceUtils:ResolveGamePassID(passID)
	if not resolvedPassID then
		return Promise.reject(`Unknown gamepass: {tostring(passID)}`)
	end

	local passKey = ProductRegistry:GetGamePassKeyFromId(resolvedPassID)
	if not passKey then
		return Promise.reject("Invalid gamepass ID")
	end

	local giftProductID = ProductRegistry.GamePasses[passKey].GiftID
	if not giftProductID then
		return Promise.reject("Gamepass has no gift Dev Product")
	end

	if not self._network then
		return Promise.reject("MarketService not initialized")
	end

	return self._network.RequestGiftPurchase.Call(tostring(recipientUserId), tostring(resolvedPassID)):andThen(function(accepted)
		if not accepted then
			return Promise.reject("Server rejected gift request")
		end
		return MarketServiceUtils.PromptAsync(Player, giftProductID, false):andThen(function(purchased)
			if purchased and self.GiftPurchaseCompleted then
				self.GiftPurchaseCompleted:Fire(recipientUserId, passKey)
			end
			return purchased
		end)
	end)
end

-- || Utility Methods || --

--[[
	Gets the product ID from a product name.
	
	Looks up the product in ProductRegistry by its key name.
	
	@param productName string The product key name from ProductRegistry
	@return number The Roblox product/gamepass ID
	
	Examples:
	```lua
	local productName = "SpeedBoost"
	local productId = MarketServiceClient:GetProductID(productName)
	MarketServiceClient:PromptGamePassAsync(productId)
	```
]]
MarketServiceClient.GetProductID = MarketServiceUtils.GetProductID :: (self: MarketServiceClient, productName: string) -> number?

-------------------------------------------------------------------------------------------------------------------------------
-- Private Methods

function MarketServiceClient._SetOwnership(self: MarketServiceClient, passKey: string, owns: boolean)
	local current = self._ownershipCache[passKey]
	if current == owns then
		return
	end

	self._ownershipCache[passKey] = owns

	if self.GamepassOwnershipChanged then
		self.GamepassOwnershipChanged:Fire(passKey, owns)
	end

	if owns and self.GamepassPurchased then
		self.GamepassPurchased:FireDeferred(passKey)
	end
end

function MarketServiceClient._BindNetworkEvents(self: MarketServiceClient)
	if not self._network then
		warn("Network not initialized")
		return
	end

	-- Initial ownership data from server
	self._network.InitializeMarketData.SetCallback(function(data)
		for passKey, owns in pairs(data) do
			self:_SetOwnership(passKey, owns)
		end

		if not self._initialized then
			self._initialized = true
			if self._initializedSignal then
				self._initializedSignal:Fire()
			end
		end
	end)

	-- Ownership updates from server
	self._network.SetMarketData.SetCallback(function(passKey, owns)
		self:_SetOwnership(passKey, owns)
	end)
end

function MarketServiceClient._BindProductRegistrySync(self: MarketServiceClient)
	local network = self._network
	if not network then
		return
	end

	network.AddGamePass.SetCallback(function(
		productName: string,
		idData: {
			ID: number,
			GiftID: number?,
		}
	)
		self:AddGamePass(productName, idData.ID, idData.GiftID)
	end)

	network.AddDevProduct.SetCallback(function(productName: string, productId: number)
		self:AddDevProduct(productName, productId)
	end)
end

function MarketServiceClient._BindMarketEvents(self: MarketServiceClient)
	-- Listen for gamepass purchases
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, passID: number, wasPurchased: boolean)
		if player ~= Player then
			return
		end

		if wasPurchased then
			self:_SetOwnership(tostring(passID), true)
		end
	end)

	-- Listen for dev product purchases
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userID: number, productID: number, wasPurchased: boolean)
		if userID ~= Player.UserId then
			return
		end

		if wasPurchased then
			local key = ProductRegistry:GetDevProductKeyFromId(productID)
			if key and self.DevProductPurchased then
				self.DevProductPurchased:FireDeferred(key)
			end
		end
	end)
end

return MarketServiceClient
