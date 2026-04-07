--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local Signal = require(ReplicatedStorage.Packages.Signal)

-- || Public API || --
local ProductRegistry = {
	GamePasses = {
		-- Example:
		-- TEMPLATE = {
		--     ID = 123123123,      -- Normal Gamepass ID
		--     GiftID = 456456456,  -- Dev Product for gifting
		-- }
	},

	DevProducts = {
		-- Example:
		-- TEMPLATE = 789789789,
	},
}

type GamePassDefinition = {
	ID: number,
	GiftID: number?,
}

type ProductRegistrySnapshot = {
	GamePasses: { [string]: GamePassDefinition },
	DevProducts: { [string]: number },
}

export type RegisteredProductInfo = {
	Name: string,
	ID: number,
	IsGamePass: boolean,
	GiftID: number?,
}

-- Lookup tables
local lookups = {
	GamePassesByID = {}, -- ID -> key
	GamePassesByGiftID = {}, -- GiftID -> key
	DevProductsByID = {}, -- DevProduct ID -> key
}

local productRegisteredSignal = Signal.new()

local function createRegisteredProductInfo(name: string, id: number, isGamePass: boolean, giftId: number?): RegisteredProductInfo
	return {
		Name = name,
		ID = id,
		IsGamePass = isGamePass,
		GiftID = giftId,
	}
end

local function assertUniqueLookup(lookupTable: { [number]: string }, id: number, key: string, label: string)
	local existingKey = lookupTable[id]
	assert(existingKey == nil or existingKey == key, `{label} {id} is already registered to {existingKey}`)
end

local function registerGamePassInternal(key: string, data: GamePassDefinition)
	assert(type(key) == "string" and key ~= "", "GamePass key must be a non-empty string")
	assert(type(data) == "table", `GamePass definition for {key} must be a table`)
	assert(type(data.ID) == "number", `GamePass {key} must define a numeric ID`)
	assert(data.GiftID == nil or type(data.GiftID) == "number", `GamePass {key} GiftID must be a number when provided`)

	local existingDefinition = ProductRegistry.GamePasses[key]
	if existingDefinition then
		assert(existingDefinition.ID == data.ID, `GamePass {key} is already registered with a different ID`)
		assert(existingDefinition.GiftID == data.GiftID, `GamePass {key} is already registered with a different GiftID`)
	end

	assertUniqueLookup(lookups.GamePassesByID, data.ID, key, "GamePass ID")
	if data.GiftID ~= nil then
		assertUniqueLookup(lookups.GamePassesByGiftID, data.GiftID, key, "GamePass GiftID")
	end

	ProductRegistry.GamePasses[key] = data
	lookups.GamePassesByID[data.ID] = key
	if data.GiftID ~= nil then
		lookups.GamePassesByGiftID[data.GiftID] = key
	end

	productRegisteredSignal:Fire(createRegisteredProductInfo(key, data.ID, true, data.GiftID))
end

local function registerDevProductInternal(key: string, id: number)
	assert(type(key) == "string" and key ~= "", "DevProduct key must be a non-empty string")
	assert(type(id) == "number", `DevProduct {key} must define a numeric ID`)

	local existingId = ProductRegistry.DevProducts[key]
	if existingId ~= nil then
		assert(existingId == id, `DevProduct {key} is already registered with a different ID`)
	end

	assertUniqueLookup(lookups.DevProductsByID, id, key, "DevProduct ID")

	ProductRegistry.DevProducts[key] = id
	lookups.DevProductsByID[id] = key

	productRegisteredSignal:Fire(createRegisteredProductInfo(key, id, false, nil))
end

function ProductRegistry:RegisterGamePass(key: string, data: GamePassDefinition)
	registerGamePassInternal(key, data)
end

function ProductRegistry:RegisterGamePasses(gamePasses: { [string]: GamePassDefinition })
	for key, data in pairs(gamePasses) do
		registerGamePassInternal(key, data)
	end
end

function ProductRegistry:RegisterDevProduct(key: string, id: number)
	registerDevProductInternal(key, id)
end

function ProductRegistry:RegisterDevProducts(devProducts: { [string]: number })
	for key, id in pairs(devProducts) do
		registerDevProductInternal(key, id)
	end
end

function ProductRegistry:GetSnapshot(): ProductRegistrySnapshot
	local gamePasses = {} :: { [string]: GamePassDefinition }
	for key, data in pairs(self.GamePasses) do
		gamePasses[key] = {
			ID = data.ID,
			GiftID = data.GiftID,
		}
	end

	local devProducts = {} :: { [string]: number }
	for key, id in pairs(self.DevProducts) do
		devProducts[key] = id
	end

	return {
		GamePasses = gamePasses,
		DevProducts = devProducts,
	}
end

ProductRegistry:RegisterGamePasses(ProductRegistry.GamePasses)
ProductRegistry:RegisterDevProducts(ProductRegistry.DevProducts)

function ProductRegistry:GetGamePassKeyFromId(id: number): string?
	return lookups.GamePassesByID[id]
end

function ProductRegistry:GetGamePassKeyFromGiftId(giftId: number): string?
	return lookups.GamePassesByGiftID[giftId]
end

function ProductRegistry:GetDevProductKeyFromId(id: number): string?
	return lookups.DevProductsByID[id]
end

function ProductRegistry:GetRegisteredProductInfo(productName: string): RegisteredProductInfo?
	local gamePass = self.GamePasses[productName]
	if gamePass ~= nil then
		return createRegisteredProductInfo(productName, gamePass.ID, true, gamePass.GiftID)
	end

	local devProductId = self.DevProducts[productName]
	if devProductId ~= nil then
		return createRegisteredProductInfo(productName, devProductId, false, nil)
	end

	return nil
end

function ProductRegistry:GetProductRegisteredSignal(): Signal.ClassicSignal<RegisteredProductInfo>
	return productRegisteredSignal
end

return ProductRegistry
