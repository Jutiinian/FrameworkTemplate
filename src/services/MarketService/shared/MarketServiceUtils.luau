--!strict

-- || Services || --
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local ProductRegistry = require(script.Parent.ProductRegistry)
local Promise = require(ReplicatedStorage.Packages.Promise)

-- || Types || --
type ProductInfo = {
	PriceInRobux: number?,
	[string]: any,
}

type RegisteredProductInfo = ProductRegistry.RegisteredProductInfo

-- || Variables || --
local _priceCache: { [number]: number } = {}

local function resolveRegisteredProductId(productIdentifier: string | number, productMap: { [string]: any }): number?
	if type(productIdentifier) == "number" then
		return productIdentifier
	end

	local productData = productMap[productIdentifier]
	if productData == nil then
		return nil
	end

	return if typeof(productData) == "table" then productData.ID else productData
end

-- || Public API || --
local MarketServiceUtils = {}

function MarketServiceUtils.PromptAsync(player: Player, productID: number, isGamepass: boolean?): Promise.TypedPromise<boolean>
	if not player or not player:IsDescendantOf(Players) then
		return Promise.reject("Player is not in the game")
	end

	local event: RBXScriptSignal<Player, number, boolean> | RBXScriptSignal<number, number, boolean> = if isGamepass
		then MarketplaceService.PromptGamePassPurchaseFinished
		else MarketplaceService.PromptProductPurchaseFinished

	local eventConnection: RBXScriptConnection?

	return Promise.new(function(resolve, reject)
		eventConnection = (event :: RBXScriptSignal):Connect(function(purchaser: Player | number, id: number, wasPurchased: boolean)
			if (purchaser == player or purchaser == player.UserId) and id == productID then
				resolve(wasPurchased)
			end
		end)

		local success, err = pcall(function()
			if isGamepass then
				MarketplaceService:PromptGamePassPurchase(player, productID)
			else
				MarketplaceService:PromptProductPurchase(player, productID)
			end
		end)

		if not success then
			reject(`Failed to prompt purchase: {err}`)
		end
	end):finally(function()
		if eventConnection then
			eventConnection:Disconnect()
			eventConnection = nil
		end
	end)
end

function MarketServiceUtils.GetProductID(_self, productName: string): number?
	local gamepassData = ProductRegistry.GamePasses[productName]
	if gamepassData then
		return if typeof(gamepassData) == "table" then gamepassData.ID else gamepassData
	end

	local devProductData = ProductRegistry.DevProducts[productName]
	if devProductData then
		return if typeof(devProductData) == "table" then devProductData.ID else devProductData
	end

	return nil
end

function MarketServiceUtils.ResolveGamePassID(_self, productIdentifier: string | number): number?
	return resolveRegisteredProductId(productIdentifier, ProductRegistry.GamePasses)
end

function MarketServiceUtils.ResolveDevProductID(_self, productIdentifier: string | number): number?
	return resolveRegisteredProductId(productIdentifier, ProductRegistry.DevProducts)
end

function MarketServiceUtils.GetRegisteredProductInfo(_self, productName: string): RegisteredProductInfo?
	return ProductRegistry:GetRegisteredProductInfo(productName)
end

function MarketServiceUtils.AwaitProductRegistrationAsync(
	_self,
	productName: string,
	timeout: number?
): Promise.TypedPromise<RegisteredProductInfo>
	local registeredProduct = ProductRegistry:GetRegisteredProductInfo(productName)
	if registeredProduct then
		return Promise.resolve(registeredProduct)
	end

	local registrationPromise = Promise.fromEvent(ProductRegistry:GetProductRegisteredSignal(), function(info: RegisteredProductInfo)
		return info.Name == productName
	end)

	if timeout == nil then
		return registrationPromise
	end

	return Promise.race({
		registrationPromise,
		Promise.delay(timeout):andThen(function()
			return Promise.reject(`Timed out waiting for product registration: {productName}`)
		end),
	})
end

function MarketServiceUtils.ResolveProductPriceTarget(
	_self,
	productIdentifier: string | number,
	isGamepass: boolean?
): (number?, Enum.InfoType?, string?)
	if type(productIdentifier) == "string" then
		local registeredProduct = ProductRegistry:GetRegisteredProductInfo(productIdentifier)
		if not registeredProduct then
			return nil, nil, `Unknown product: {productIdentifier}`
		end

		return registeredProduct.ID, if registeredProduct.IsGamePass then Enum.InfoType.GamePass else Enum.InfoType.Product, nil
	end

	if isGamepass == nil then
		return nil, nil, "isGamepass is required when fetching price by raw product ID"
	end

	return productIdentifier, if isGamepass then Enum.InfoType.GamePass else Enum.InfoType.Product, nil
end

function MarketServiceUtils.FetchProductPriceAsync(productId: number, infoType: Enum.InfoType): Promise.TypedPromise<number>
	return Promise.new(function(resolve, reject)
		local cached = _priceCache[productId]
		if cached then
			return resolve(cached)
		end

		local success, result = pcall(function()
			return MarketplaceService:GetProductInfoAsync(productId, infoType)
		end)

		if not success then
			return reject(`Failed to fetch product info for ID {productId}: {result}`)
		end

		local info = result :: ProductInfo
		if not info then
			return reject(`No product info found for ID {productId}`)
		end

		local price = info.PriceInRobux
		if type(price) ~= "number" then
			return reject(`No price found for product ID {productId}`)
		end

		_priceCache[productId] = price

		return resolve(price)
	end)
end

return MarketServiceUtils
