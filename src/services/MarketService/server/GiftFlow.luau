--!strict

-- || Services || --
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local Promise = require(ReplicatedStorage.Packages.Promise)

local MarketServiceUtils = require(ReplicatedStorage.Services.MarketService.MarketServiceUtils)
local ProductRegistry = require(ReplicatedStorage.Services.MarketService.ProductRegistry)

-- || Types || --
type ProductIdentifier = string | number
type GiftRecipient = Player | number

type GiftData = {
	PurchaserID: number,
	RecipientID: number,
	ProductID: number,
	IsGamepassGift: boolean?,
}

type ResolvedInitOptions = {
	allowOfflineGifting: boolean,
	[string]: any,
}

type ServiceState = {
	_activeGifts: { [number]: GiftData },
	_initOptions: ResolvedInitOptions?,
}

-- || Private Functions || --
local function resolveRecipientUserId(recipient: GiftRecipient): number?
	if typeof(recipient) == "Instance" then
		return (recipient :: Player).UserId
	end

	if type(recipient) == "number" then
		return recipient
	end

	return nil
end

-- || Public API || --
local GiftFlow = {}

function GiftFlow.ResolveGiftPromptProduct(requestedProductId: number): (number?, boolean, string?)
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

function GiftFlow.ValidateRecipient(service: ServiceState, purchaser: Player, recipientUserId: number): string?
	local initOptions = service._initOptions
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

function GiftFlow.BeginGiftPurchase(
	service: ServiceState,
	purchaser: Player,
	recipientUserId: number,
	promptProductId: number,
	isGamepassGift: boolean
): Promise.TypedPromise<boolean>
	service._activeGifts[purchaser.UserId] = {
		PurchaserID = purchaser.UserId,
		RecipientID = recipientUserId,
		ProductID = promptProductId,
		IsGamepassGift = isGamepassGift,
	}

	return MarketServiceUtils.PromptAsync(purchaser, promptProductId, false):catch(function(err)
		service._activeGifts[purchaser.UserId] = nil
		return Promise.reject(err)
	end)
end

function GiftFlow.PromptGiftDevProductAsync(
	service: ServiceState,
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

	local validationError = GiftFlow.ValidateRecipient(service, purchaser, recipientUserId)
	if validationError then
		return Promise.reject(validationError)
	end

	return GiftFlow.BeginGiftPurchase(service, purchaser, recipientUserId, resolvedProductID, false)
end

function GiftFlow.PromptGiftGamepassAsync(
	service: ServiceState,
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

	local validationError = GiftFlow.ValidateRecipient(service, purchaser, recipientUserId)
	if validationError then
		return Promise.reject(validationError)
	end

	local giftDevProductID, isGamepassGift, resolveError = GiftFlow.ResolveGiftPromptProduct(resolvedPassID)
	if not giftDevProductID then
		return Promise.reject(resolveError or "Invalid gamepass ID")
	end

	return GiftFlow.BeginGiftPurchase(service, purchaser, recipientUserId, giftDevProductID, isGamepassGift)
end

return table.freeze(GiftFlow)
