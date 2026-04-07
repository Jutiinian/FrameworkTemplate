--[[
	DataServiceServer

	Server-side service that manages player data loading, saving, and replication using ProfileStore.
	Provides helper methods for reading, writing, and observing player data safely.

	@author Jutiinian
	@version February 11, 2026
]]

--!optimize 2
--!strict

-- || Services || --
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- || Dependencies || --
local Observers = require(ReplicatedStorage.Packages.Observers)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)
local Signal = require(ReplicatedStorage.Packages.Signal)

local ProfileStore = require(ServerScriptService.ServerPackages.ProfileStore)

local DataProfile = require(ReplicatedStorage.Services.DataService.DataProfile)
local DataServiceTypes = require(ReplicatedStorage.Services.DataService.DataServiceTypes)
local DataTemplate = require(ReplicatedStorage.Services.DataService.DataTemplate)

-- || Variables || --
local DATA_PREFIX = "PLAYER_"
local DEFAULT_PROFILE_STORE_INDEX = "Default"

type IndexPath = DataServiceTypes.IndexPath
type Disconnect = DataServiceTypes.Disconnect
type Profile = ProfileStore.Profile<DataTemplate.Data>

-- || Public API || --
type profileStore = ProfileStore.ProfileStore<DataTemplate.Data>
type dataProfile = DataProfile.DataProfile<DataTemplate.Data>
type DataServiceNetwork = typeof(require(script.Parent.NetworkServer))

type MessageData = {
	key: string,
	data: { any },
}

local DataServiceServer = {
	_network = (nil :: any) :: DataServiceNetwork,
	_dataProfiles = {} :: { [Player]: dataProfile },
	_activeProfiles = {} :: { [Player]: Profile },
	_waitSignals = {} :: { [Player]: Signal.ClassicSignal<any> },
	_globalCallbacks = {} :: { [string]: (player: Player, { any }) -> boolean? },
	_globalCallbackAdded = Signal.new() :: Signal.ClassicSignal<string>,
	_removalFunctions = {} :: { (player: Player, data: DataTemplate.Data) -> () },

	options = {} :: dataOptions,
	playerStore = nil :: profileStore?,
}

export type DataServiceServer = typeof(DataServiceServer)

type dataOptions = {
	useMock: boolean?, -- Use mock data store (for testing)
	overridenUserId: number?, -- Override the UserId for data keys (for testing)
	dontSave: boolean?, -- Don't save data (read-only mode)
	profileStoreIndex: string?, -- Custom ProfileStore index name
	profileStoreDataPrefix: string?, -- Custom prefix for data keys
	replicationIgnoreList: { string }?, -- List of data keys to not replicate to clients
}

--[[
	Initializes the DataService on the server.
	
	@param options dataOptions Configuration table to control behavior
	
	Examples:
	```lua
	-- Production setup
	local DataServiceServer = require(ServerScriptService.Services.DataService.DataServiceServer)
	DataServiceServer:Init({
		profileStoreIndex = "Production_V1",
		replicationIgnoreList = {"AdminFlags", "BannedUntil"} -- Don't send to client
	})
	
	-- Testing setup with mock data
	DataServiceServer:Init({
		useMock = true,
		dontSave = true
	})
	
	-- Development setup with custom prefix
	DataServiceServer:Init({
		profileStoreIndex = "Development",
		profileStoreDataPrefix = "DEV_PLAYER_"
	})
	```
]]
function DataServiceServer.Init(self: DataServiceServer, options: dataOptions)
	self._network = require(script.Parent.NetworkServer)

	self.options = options
	self.playerStore = ProfileStore.New(options.profileStoreIndex or DEFAULT_PROFILE_STORE_INDEX, DataTemplate)

	Observers.observePlayer(function(player: Player)
		self:_playerAdded(player)
		return function()
			task.defer(self._playerRemoving, self, player)
		end
	end)
end

--[[
	Saves profile data for a specific player, or all players if none is provided.
	
	@param player Player? The Player to save. If nil, saves all players.
	
	Examples:
	```lua
	DataServiceServer:SaveData(player)
	```
]]
function DataServiceServer.SaveData(self: DataServiceServer, player: Player?)
	local function saveProfile(p: Player): ()
		local profile = self._activeProfiles[p]
		if profile then
			profile:Save()
		end
	end

	if player then
		saveProfile(player)
	else
		for _, p in ipairs(Players:GetPlayers()) do
			saveProfile(p)
		end
	end
end

--[[
	Sends a global message to the specified user's profile.

	@param key string
	@param userId number | string
	@param data { any }
	@return boolean

	Example:
	```lua
	DataServiceServer:SendGlobalMessage("SendGift", userId, { currency = 100, from = "Friend" })
	```
]]
function DataServiceServer.SendGlobalMessage(self: DataServiceServer, key: string, userId: number | string, data: { any }): boolean
	assert(self.playerStore, "[DataServiceServer] playerStore not yet initialized. Please run DataServiceServer:Init()")
	local messageData: MessageData = { key = key, data = data }
	return self.playerStore:MessageAsync(self:_getProfileKey(userId), messageData)
end

--[[
	Adds a global callback function for handling messages with the specified key.

	@param key string
	@param callback (player: Player, data: { any }) -> boolean?

	Example:
	```lua
	DataService:AddGlobalCallback("SendGift", function(player: Player, data: { any }): boolean?
		print("Received gift for", player.Name, "with data:", data)
		-- Process the gift here
	end)
	```
]]
function DataServiceServer.AddGlobalCallback(self: DataServiceServer, key: string, callback: (player: Player, { any }) -> boolean?): ()
	assert(self._globalCallbacks[key] == nil, "Global callback already exists for key: " .. key)
	self._globalCallbacks[key] = callback
	self._globalCallbackAdded:Fire(key)
end

--[=[
	Adds a callback that runs when a player is removed.
	
	@param fn (player: Player, data: any) -> ()

	Example:
	```lua
	DataService:AddPlayerRemovingCallback(function(player: Player, data: any): ()
		print(player.Name .. " is leaving with data:", data)
		-- Perform any cleanup or save operations here
	end)
	```

	```lua
	local disconnect = DataService:AddPlayerRemovingCallback(function(player: Player, data: any): ()
		data.currency = 0
	end)

	-- Later, you can disconnect this function if needed
	disconnect()
	```
]=]
function DataServiceServer.AddPlayerRemovingCallback(self: DataServiceServer, fn: (player: Player, data: DataTemplate.Data) -> ()): () -> ()
	table.insert(self._removalFunctions, fn)
	return function()
		local index = table.find(self._removalFunctions, fn)
		if index then
			table.remove(self._removalFunctions, index)
		end
	end
end

--[[
	Gets the currently loaded ProfileStore profile for a player.
	
	Returns the raw ProfileStore profile, which contains the data and additional metadata.
	Usually you'll want to use Get(), Set(), etc. instead of accessing the profile directly.
	
	@param player Player The player whose profile to get
	@return Profile? The ProfileStore profile, or nil if not loaded yet
	
	Example:
	```lua
	local profile = DataServiceServer:GetProfile(player)
	if profile then
		print("Profile loaded for:", player.Name)
		print("Last save:", profile.LastSavedTime)
	end
	```
	
	Note: Prefer using Get() and other methods over directly accessing profile.Data
]]
function DataServiceServer.GetProfile(self: DataServiceServer, player: Player): Profile?
	return self._activeProfiles[player]
end

--[[
	Waits for the player's data to be ready and returns it (synchronous).
	
	⚠️ Warning: This yields the current thread. Consider using WaitForDataAsync() instead.
	
	@param player Player The player whose data to wait for
	@return DataProfile The player's data profile
	
	Example:
	```lua
	-- In a coroutine or thread that can yield
	Players.PlayerAdded:Connect(function(player)
		local data = DataServiceServer:WaitForData(player)
		
		print(DataServiceServer:Get(player, "isVip"))
	end)
	```
	
	Note: Generally prefer WaitForDataAsync() for better async handling.
]]
function DataServiceServer.WaitForData(self: DataServiceServer, player: Player): dataProfile
	local data = self._dataProfiles[player]
	if data then
		return data
	end

	local waitSignal = self._waitSignals[player]
	if not waitSignal then
		waitSignal = Signal.new()
		self._waitSignals[player] = waitSignal
	end

	waitSignal:Wait()
	return self._dataProfiles[player]
end

--[[
	Returns a promise that resolves with the player's profile data once ready.
	
	This is the preferred way to wait for data. The promise rejects if the player leaves before data loads.
	
	@param player Player The player whose data to wait for
	@return Promise<DataProfile> Promise that resolves with the data profile
	
	Examples:
	```lua
	DataServiceServer:WaitForDataAsync(player):andThen(function(data)
		local coins = data:Get("Currency.Coins")
		print(player.Name, "has", coins, "coins")
	end):catch(function(err)
		warn("Failed to load data for", player.Name, ":", err)
	end)
	```
	
	Benefits:
	- Automatically rejects if player leaves (prevents errors)
	- Non-blocking, returns immediately
	- Can be chained with other operations
	- Better error handling
]]
function DataServiceServer.WaitForDataAsync(self: DataServiceServer, player: Player): Promise.TypedPromise<dataProfile>
	local profile = self._dataProfiles[player]
	if profile then
		return Promise.resolve(profile)
	end

	local waitSignal = self._waitSignals[player]
	if not waitSignal then
		waitSignal = Signal.new()
		self._waitSignals[player] = waitSignal
	end

	return Promise.race({
		Promise.fromEvent(waitSignal, function()
			return (self._dataProfiles[player] :: any) ~= nil
		end):andThenReturn(self._dataProfiles[player]),

		Promise.fromEvent(Players.PlayerRemoving, function(leavingPlayer)
			return leavingPlayer == player
		end):andThen(function()
			error("Player left before data loaded")
		end),
	})
end

--[[
	Gets a value from a player's profile data.
	
	@param player Player The player whose data to read
	@param indexPath string | {string}? Path to the data (nil returns entire profile)
	@return any The value at the specified path
	
	Examples:
	```lua
	-- Get entire data
	local allData = DataServiceServer:Get(player)
	
	-- Get nested value with string path
	local volume = DataServiceServer:Get(player, "Settings.Audio.Volume")
	
	-- Get nested value with table path
	local volume = DataServiceServer:Get(player, {"Settings", "Audio", "Volume"})
	
	-- Get object
	local inventory = DataServiceServer:Get(player, "Inventory")
	
	-- Get array
	local friends = DataServiceServer:Get(player, "Social.Friends")
	```
]]
function DataServiceServer.Get(self: DataServiceServer, player: Player, indexPath: IndexPath?): any
	assert(self._dataProfiles[player], "[DataServiceServer] Player data not loaded yet. Possibly wait for initialization.")
	return self._dataProfiles[player]:Get(indexPath)
end

--[[
	Sets a value in the player's profile data.
	
	The change is automatically saved to the data store and replicated to the client (unless NoReplication is true).
	
	@param player Player The player whose data to modify
	@param indexPath string | {string} Path to the value to set
	@param value any The new value
	@param NoReplication boolean? If true, don't send update to client (default: false)
	
	Examples:
	```lua
	-- Set simple values
	DataServiceServer:Set(player, "Stats.Level", 5)
	DataServiceServer:Set(player, "Settings.Audio.Volume", 0.8)
	
	-- Set entire objects
	DataServiceServer:Set(player, "Settings.Graphics", {
		Quality = "High",
		Shadows = true,
		ParticleEffects = true
	})
	
	-- Set without replicating to client (server-only data)
	DataServiceServer:Set(player, "AdminData.BannedUntil", os.time() + 86400, true)
	
	-- Use table path
	DataServiceServer:Set(player, {"Currency", "Coins"}, 100)
	
	-- Set nested value in table
	local inventory = DataServiceServer:Get(player, "Inventory")
	inventory.MaxSlots = 50
	DataServiceServer:Set(player, "Inventory", inventory)
	```
	
	Note: For arrays, use ArrayInsert() and ArrayRemove() instead.
]]
function DataServiceServer.Set(self: DataServiceServer, player: Player, indexPath: IndexPath, value: any, NoReplication: boolean?): ()
	assert(self._network, "[DataServiceServer] Networker has not been loaded yet. Please run DataServiceServer:Init().")
	assert(self._dataProfiles[player], "[DataServiceServer] Player data not loaded yet. Possibly wait for initialization.")

	if not NoReplication then
		self._network.DataUpdate.Fire(
			player,
			{
				Type = type(indexPath) == "table" and "Table" or "String",
				value = indexPath,
			} :: any,
			value
		)
	end

	self._dataProfiles[player]:Set(indexPath, value)
end

--[[
	Updates a value in a player's profile data using a callback function and returns the new value.
	
	The callback receives the current value and must return the new value. This is useful for
	incrementing, decrementing, or transforming values based on their current state.
	
	@param player Player The player whose data to modify
	@param indexPath string | {string} Path to the value to update
	@param callback (currentValue: any) -> any Function that transforms the current value
	@param NoReplication boolean? If true, don't send update to client (default: false)
	@return any The new value after the update
	
	Examples:
	```lua
	-- Increment coins
	local newCoins = DataServiceServer:Update(player, "Currency.Coins", function(coins)
		return coins + 100
	end)
	print("Player now has", newCoins, "coins")
	
	-- Increment with maximum
	DataServiceServer:Update(player, "Stats.Experience", function(exp)
		return math.min(exp + 50, 1000) -- Cap at 1000
	end)
	
	-- Toggle boolean
	DataServiceServer:Update(player, "Settings.MusicEnabled", function(enabled)
		return not enabled
	end)
	
	-- Modify table properties
	DataServiceServer:Update(player, "Stats", function(stats)
		stats.Kills = stats.Kills + 1
		stats.KDR = stats.Kills / math.max(stats.Deaths, 1)
		return stats
	end)
	
	-- Add to a count without replication
	DataServiceServer:Update(player, "Analytics.SessionsPlayed", function(count)
		return count + 1
	end, true) -- No replication
	```
	
	Benefits over Get() + Set():
	- Atomic operation (no race conditions)
	- Cleaner code for transformations
	- Returns the new value immediately
]]
function DataServiceServer.Update(
	self: DataServiceServer,
	player: Player,
	indexPath: IndexPath,
	callback: (any) -> any,
	NoReplication: boolean?
): any
	assert(self._network, "[DataServiceServer] Networker has not been loaded yet. Please run DataServiceServer:Init().")
	assert(self._dataProfiles[player], "[DataServiceServer] Player data not loaded yet. Possibly wait for initialization.")

	local newValue = self._dataProfiles[player]:Update(indexPath, callback)

	if not NoReplication then
		self._network.DataUpdate.Fire(
			player,
			{
				Type = type(indexPath) == "table" and "Table" or "String",
				value = indexPath,
			} :: any,
			newValue
		)
	end

	return newValue
end

--[[
	Inserts a value into an array in a player's profile data.
	
	@param player Player The player whose data to modify
	@param indexPath string | {string} Path to the array
	@param value any The value to insert
	@param index number? Position to insert at (nil = append to end)
	@param NoReplication boolean? If true, don't send update to client (default: false)
	
	Examples:
	```lua
	-- Append to array
	DataServiceServer:ArrayInsert(player, "Inventory.Items", {
		Id = "sword_legendary",
		Damage = 50
	})
	
	-- Insert at specific position
	DataServiceServer:ArrayInsert(player, "Inventory.Items", newItem, 1) -- Insert at start
	
	-- Add friend to list
	DataServiceServer:ArrayInsert(player, "Social.Friends", friendUserId)
	
	-- Add quest to active quests
	DataServiceServer:ArrayInsert(player, "Quests.Active", {
		QuestId = "main_001",
		Progress = 0,
		StartTime = os.time()
	})
	
	-- Insert without client notification
	DataServiceServer:ArrayInsert(player, "ServerData.LoginHistory", os.time(), nil, true)
	```
	
	Note: The array must already exist at the specified path.
]]
function DataServiceServer.ArrayInsert(
	self: DataServiceServer,
	player: Player,
	indexPath: IndexPath,
	value: any,
	index: number?,
	NoReplication: boolean?
)
	assert(self._network, "[DataServiceServer] Networker has not been loaded yet. Please run DataServiceServer:Init().")
	assert(self._dataProfiles[player], "[DataServiceServer] Player data not loaded yet. Possibly wait for initialization.")

	if not NoReplication then
		self._network.ArrayInsert.Fire(
			player,
			{
				Type = type(indexPath) == "table" and "Table" or "String",
				value = indexPath,
			} :: any,
			value,
			index
		)
	end

	self._dataProfiles[player]:ArrayInsert(indexPath, value, index)
end

--[[
	Removes an element from an array in a player's profile data.
	
	@param player Player The player whose data to modify
	@param indexPath string | {string} Path to the array
	@param index number Position of the element to remove (1-indexed)
	@param NoReplication boolean? If true, don't send update to client (default: false)
	@return any The value that was removed
	
	Examples:
	```lua
	-- Remove item by index
	local removedItem = DataServiceServer:ArrayRemove(player, "Inventory.Items", 3)
	print("Removed:", removedItem.Id)
	
	-- Remove first element
	DataServiceServer:ArrayRemove(player, "Notifications", 1)
	
	-- Remove friend from list
	local items = DataServiceServer:Get(player, "Inventory.Items")
	for i, itemData in ipairs(items) do
		if itemData.ID == targetItemID then
			DataServiceServer:ArrayRemove(player, "Inventory.Items", i)
			break
		end
	end
	```
	
	Returns: The removed value, useful for moving items between arrays.
]]
function DataServiceServer.ArrayRemove(
	self: DataServiceServer,
	player: Player,
	indexPath: IndexPath,
	index: number,
	NoReplication: boolean?
): any
	assert(self._network, "[DataServiceServer] Networker has not been loaded yet. Please run DataServiceServer:Init().")
	assert(self._dataProfiles[player], "[DataServiceServer] Player data not loaded yet. Possibly wait for initialization.")

	if not NoReplication then
		self._network.ArrayRemove.Fire(
			player,
			{
				Type = type(indexPath) == "table" and "Table" or "String",
				value = indexPath,
			} :: any,
			index
		)
	end

	return self._dataProfiles[player]:ArrayRemove(indexPath, index)
end

--[[
	Gets a signal that fires whenever a value changes at the specified path.
	
	@param player Player The player whose data to observe
	@param indexPath string | {string} Path to observe
	@return Signal<any> Signal that fires with the new value
	
	Examples:
	```lua
	DataServiceServer:GetValueChangedSignal(player, "Stats.Level"):Connect(function(newLevel)
		print(player.Name, "reached level", newLevel)
	end)
	```
]]
function DataServiceServer.GetValueChangedSignal(self: DataServiceServer, player: Player, indexPath: IndexPath): Signal.Signal<any>
	assert(self._dataProfiles[player], "[DataServiceServer] Player data not loaded yet. Possibly wait for initialization.")
	return self._dataProfiles[player]:GetValueChangedSignal(indexPath)
end

--[[
	Gets a signal that fires whenever a value is inserted into an array.
	
	@param player Player The player whose data to observe
	@param indexPath string | {string} Path to the array
	@return Signal<number, any> Signal that fires with (index, value)
	
	Example:
	```lua
	DataServiceServer:GetArrayInsertedSignal(player, "Inventory.Items"):Connect(function(index, item)
		print(player, "New item acquired:", item)
	end)
	```
]]
function DataServiceServer.GetArrayInsertedSignal(self: DataServiceServer, player: Player, indexPath: IndexPath): Signal.Signal<any>
	assert(self._dataProfiles[player], "[DataServiceServer] Player data not loaded yet. Possibly wait for initialization.")
	return self._dataProfiles[player]:GetArrayInsertedSignal(indexPath)
end

--[[
	Gets a signal that fires whenever a value is removed from an array.
	
	@param player Player The player whose data to observe
	@param indexPath string | {string} Path to the array
	@return Signal<number, any> Signal that fires with (index, removedValue)
	
	Example:
	```lua
	DataServiceServer:GetArrayRemovedSignal(player, "Inventory.Items"):Connect(function(index, item)
		print(player, "Item removed:", item)
	end)
	```
]]
function DataServiceServer.GetArrayRemovedSignal(self: DataServiceServer, player: Player, indexPath: IndexPath): Signal.Signal<number, any>
	assert(self._dataProfiles[player], "[DataServiceServer] Player data not loaded yet. Possibly wait for initialization.")
	return self._dataProfiles[player]:GetArrayRemovedSignal(indexPath)
end

--[[
	Gets a signal that fires whenever any child index under the specified path changes.
	
	@param player Player The player whose data to observe
	@param indexPath string | {string} Path to the parent object
	@return Signal<string, any> Signal that fires with (childKey, newValue)
	
	Example:
	```lua
	DataServiceServer:GetIndexChangedSignal(player, "Currency"):Connect(function(currencyType, newAmount)
		print(player, currencyType, newAmount)
	end)
	```
]]
function DataServiceServer.GetIndexChangedSignal(self: DataServiceServer, player: Player, indexPath: IndexPath): Signal.Signal<any>
	assert(self._dataProfiles[player], "[DataServiceServer] Player data not loaded yet. Possibly wait for initialization.")
	return self._dataProfiles[player]:GetChildChangedSignal(indexPath)
end

--[[
	Observes a single value at a path for a specific player.
	
	Calls the factory function whenever the value changes. The factory should return a cleanup function.
	This is useful for setting up reactive behavior based on data changes.
	
	@param player Player The player whose data to observe
	@param indexPath string | {string} Path to observe
	@param factory (value: any) -> Disconnect Function called with value, returns cleanup function
	@return Disconnect Function to stop observing
	
	Examples:
	```lua
	local disconnect = DataServiceServer:ObserveData(player, "Stats.Level", function(level)
		print("Level is now:", level)
		
		-- Cleanup when level changes again
		return function()
			print("Level changed, old value was:", level)
		end
	end)

	-- Later: stop observing
	disconnect()
	```
]]
function DataServiceServer.ObserveData(
	self: DataServiceServer,
	player: Player,
	indexPath: IndexPath,
	factory: (value: any) -> Disconnect
): Disconnect
	assert(self._dataProfiles[player], "[DataServiceServer] Player data not loaded yet. Possibly wait for initialization.")
	return self._dataProfiles[player]:ObserveData(indexPath, factory)
end

--[[
	Observes a table at a path for a specific player.
	
	Calls the factory function for each key/value pair in the table, and whenever they change.
	The factory should return a cleanup function for each entry.
	
	@param player Player The player whose data to observe
	@param indexPath string | {string} Path to the table
	@param factory (key: K, value: V) -> Disconnect? Function called for each entry
	@param monitorLastValue boolean? If true, factory is called when values change (not just keys)
	@return Disconnect Function to stop observing
	
	Examples:
	```lua
	local disconnect = DataServiceServer:ObserveTableData(player, "Quests.Active", function(questId, questData)
		print("Tracking quest:", questId, questData)
		
		-- Return cleanup
		return function()
			print("No longer tracking quest:", questID, questData)
			questUI:Destroy()
		end
	end, true) -- Monitor value changes too

	DataServiceServer:ObserveTableData(player, "Character.Equipped", function(slot, itemId)
		-- Equip the item visually
		
		-- Cleanup function
		return function()
			-- unequip item
		end
	end)
	
	-- Later: stop observing
	disconnect()
	```
]]
function DataServiceServer.ObserveTableData<K, V>(
	self: DataServiceServer,
	player: Player,
	indexPath: IndexPath,
	factory: (key: K, value: V) -> Disconnect?,
	monitorLastValue: boolean?
): Disconnect
	assert(self._dataProfiles[player], "[DataServiceServer] Player data not loaded yet. Possibly wait for initialization.")
	return self._dataProfiles[player]:ObserveTableData(indexPath, factory, monitorLastValue)
end

function DataServiceServer._playerAdded(self: DataServiceServer, player: Player): ()
	local userId = self.options.overridenUserId or player.UserId
	local key = self:_getProfileKey(userId)

	local params = {
		Cancel = function()
			return (player.Parent ~= Players)
		end,
	}

	local profile: Profile = if self.options.useMock
		then (self.playerStore :: profileStore).Mock:StartSessionAsync(key, params) :: Profile
		elseif self.options.dontSave then (self.playerStore :: profileStore):GetAsync(key) :: Profile
		else (self.playerStore :: profileStore):StartSessionAsync(key, params) :: Profile

	if not profile then
		warn(`{player.Name}'s profile failed to load!`)
		return
	end

	profile:AddUserId(player.UserId)
	profile:Reconcile()

	profile.OnSessionEnd:Connect(function()
		self._activeProfiles[player] = nil
		player:Kick("Session closed.\nPlease rejoin!")
	end)

	profile.OnSave:Connect(function()
		print(`{player.Name}'s data has been saved`)
	end)

	if not player:IsDescendantOf(Players) then
		player:Kick(`Data failed to load.\nPlease rejoin`)
		return
	end

	self._activeProfiles[player] = profile
	self:_initializePlayer(player, profile.Data)

	if not player:IsDescendantOf(Players) then
		player:Kick(`Profile load fail - Please rejoin`)
		return
	end

	profile:MessageHandler(function(messageData, processed: () -> ())
		local messageKey = (messageData :: MessageData).key
		local data = (messageData :: MessageData).data

		local callback = self._globalCallbacks[messageKey]
		if callback then
			if callback(player, data) ~= false then
				processed()
			end

			return
		end

		local waitConnection
		waitConnection = self._globalCallbackAdded:Connect(function(callbackKey: string)
			if callbackKey ~= messageKey then
				return
			end

			if self._globalCallbacks[messageKey](player, data) ~= false then
				processed()
			end

			waitConnection:Disconnect()
		end)
	end)
end

function DataServiceServer._playerRemoving(self: DataServiceServer, player: Player): ()
	local profile = self._activeProfiles[player]

	if not profile then
		return
	end

	for _, fn in self._removalFunctions do
		local success, err: any? = pcall(fn, player, profile.Data)
		if not success then
			warn(err or "Error in removal function for " .. player.Name)
		end
	end

	profile:EndSession()
	self._activeProfiles[player] = nil

	local waitSignal = self._waitSignals[player]
	if waitSignal then
		waitSignal:Destroy()
		self._waitSignals[player] = nil
	end

	local dataProfile = self._dataProfiles[player]
	if dataProfile then
		dataProfile:Destroy()
		self._dataProfiles[player] = nil
	end
end

function DataServiceServer._initializePlayer(self: DataServiceServer, player: Player, data: any): ()
	self._dataProfiles[player] = DataProfile.new(data)

	local replicationData = self.options.replicationIgnoreList == nil and data or Sift.Dictionary.copyDeep(data)
	if self.options.replicationIgnoreList then
		for _, dataName in ipairs(self.options.replicationIgnoreList) do
			replicationData[dataName] = nil
		end
	end
	self._network.InitialDataSync.Fire(player, replicationData)

	local waitSignal = self._waitSignals[player]
	if waitSignal then
		waitSignal:Fire()

		waitSignal:Destroy()
		self._waitSignals[player] = nil
	end
end

function DataServiceServer._getProfileKey(self: DataServiceServer, userId: number | string): string
	return (self.options.profileStoreDataPrefix or DATA_PREFIX) .. tostring(userId)
end

return DataServiceServer
