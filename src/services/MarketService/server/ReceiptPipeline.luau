--!strict

-- || Services || --
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local ProductRegistry = require(ReplicatedStorage.Services.MarketService.ProductRegistry)
local ProfileStore = require(game:GetService("ServerScriptService").ServerPackages.ProfileStore)
local Promise = require(ReplicatedStorage.Packages.Promise)

-- || Types || --
type Profile = ProfileStore.Profile<{ [string]: boolean }>

type ReceiptInfo = {
	PlayerId: number,
	ProductId: number,
	PurchaseId: string,
	[string]: any,
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

type GiftData = {
	PurchaserID: number,
	RecipientID: number,
	ProductID: number,
	IsGamepassGift: boolean?,
}

type OfflineGiftMessageData = {
	RecipientID: number,
	ProductID: number,
	ProductKey: string,
	PurchaseID: string,
	PurchaserID: number,
	IsGamepassGift: boolean,
}

type ResolvedInitOptions = {
	warnOnMissingReceiptHandler: boolean,
	useMock: boolean,
	overrideUserId: number?,
	giftMessageKey: string,
	[string]: any,
}

type ServiceState = {
	marketStore: any,
	_initOptions: ResolvedInitOptions?,
	_receiptHandlers: { [string]: ReceiptHandler },
	_receiptStore: DataStore,
	_activeProfiles: { [Player]: any },
	_activeGifts: { [number]: GiftData },
	_network: any?,
	DevProductPurchased: any?,
	GiftDelivered: any?,
	GiftQueued: any?,
	_GrantGamepass: (self: any, player: Player, passID: number) -> (),
	WaitForDataAsync: (self: any, player: Player) -> Promise.TypedPromise<Profile>,
}

-- || Private Functions || --
local function getProfileKeyForUserId(userId: number, options: ResolvedInitOptions): string
	return `{options.overrideUserId or userId}`
end

local function getMessageStore(store: any, options: ResolvedInitOptions): any
	return if options.useMock then store.Mock else store
end

local function runReceiptHandler(service: ServiceState, receiptContext: ReceiptContext): boolean
	local receiptHandler = service._receiptHandlers[receiptContext.productKey]
	if not receiptHandler then
		local initOptions = service._initOptions
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

local function grantReceiptContext(service: ServiceState, receiptContext: ReceiptContext): boolean
	if receiptContext.isGamepassGift then
		local recipient = receiptContext.recipient
		if not recipient then
			warn(
				`Cannot grant gamepass gift {receiptContext.productKey} because recipient {receiptContext.recipientUserId} is not available`
			)
			return false
		end

		local gamepassID = ProductRegistry.GamePasses[receiptContext.productKey].ID
		service:_GrantGamepass(recipient, gamepassID)
		if receiptContext.isGift and service.GiftDelivered then
			service.GiftDelivered:Fire(recipient, receiptContext.productKey, receiptContext.purchaserUserId)
		end
		return true
	end

	if not runReceiptHandler(service, receiptContext) then
		return false
	end

	if receiptContext.recipient and service.DevProductPurchased then
		service.DevProductPurchased:Fire(receiptContext.recipient, receiptContext.productKey)
	end

	if receiptContext.isGift and receiptContext.recipient and service.GiftDelivered then
		service.GiftDelivered:Fire(receiptContext.recipient, receiptContext.productKey, receiptContext.purchaserUserId)
	end

	return true
end

local function queueOfflineGiftMessage(service: ServiceState, receiptContext: ReceiptContext): boolean
	local initOptions = service._initOptions
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
	local messageStore = getMessageStore(service.marketStore, initOptions)
	local success = messageStore:MessageAsync(profileKey, message)

	if not success then
		warn(`Failed to queue offline gift for recipient {receiptContext.recipientUserId} product {receiptContext.productKey}`)
	elseif service.GiftQueued then
		service.GiftQueued:Fire(receiptContext.recipientUserId, receiptContext.productKey, receiptContext.purchaserUserId)
	end

	return success
end

local function processOfflineGiftMessage(service: ServiceState, player: Player, messageData: OfflineGiftMessageData): boolean?
	if player.UserId ~= messageData.RecipientID then
		warn(`Received offline gift message for recipient {messageData.RecipientID} on player {player.UserId}`)
		return false
	end

	if not service._activeProfiles[player] then
		local status = service:WaitForDataAsync(player):awaitStatus()
		if status ~= Promise.Status.Resolved then
			return false
		end

		if not service._activeProfiles[player] then
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

	return grantReceiptContext(service, receiptContext)
end

-- || Public API || --
local ReceiptPipeline = {}

function ReceiptPipeline.GetProfileKeyForUserId(userId: number, options: ResolvedInitOptions): string
	return getProfileKeyForUserId(userId, options)
end

function ReceiptPipeline.BindOfflineGiftMessageHandler(
	service: ServiceState,
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

		if processOfflineGiftMessage(service, player, payload :: OfflineGiftMessageData) ~= false then
			processed()
		end
	end)
end

function ReceiptPipeline.ProcessReceipt(service: ServiceState, receiptInfo: ReceiptInfo): Enum.ProductPurchaseDecision
	assert(
		service._receiptStore,
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

	local giftData = service._activeGifts[player.UserId]
	local recipient: Player? = player
	local recipientUserId = player.UserId
	local isGamepassGift = false

	if giftData and giftData.ProductID == receiptInfo.ProductId then
		recipientUserId = giftData.RecipientID
		recipient = Players:GetPlayerByUserId(giftData.RecipientID)
		isGamepassGift = giftData.IsGamepassGift or false
	end

	local success, result = pcall(function()
		return service._receiptStore:UpdateAsync(receiptInfo.PurchaseId, function(isPurchased)
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
				if not queueOfflineGiftMessage(service, receiptContext) then
					return nil
				end
				return true
			end

			if not grantReceiptContext(service, receiptContext) then
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
		service._activeGifts[player.UserId] = nil
	end

	return if result == true then Enum.ProductPurchaseDecision.PurchaseGranted else Enum.ProductPurchaseDecision.NotProcessedYet
end

return table.freeze(ReceiptPipeline)
