--[[
	SettingsServer
	
	Server-side settings service that manages player preferences with validation and persistence.
	Validates all changes against a template, persists to DataService, and replicates to clients.
	
	@author Jutiinian
	@version February 20, 2026
]]

--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- || Dependencies || --
local Observers = require(ReplicatedStorage.Packages.Observers)
local Sift = require(ReplicatedStorage.Packages.Sift)
local Signal = require(ReplicatedStorage.Packages.Signal)

local SettingsProfile = require(ReplicatedStorage.Services.SettingsService.SettingsProfile)
local SettingsTemplate = require(ReplicatedStorage.Services.SettingsService.SettingsTemplate)

local DataService = require(ServerScriptService.Services.DataService.DataServiceServer)

-- || Types || --
type Path = SettingsProfile.Path
type Network = typeof(require(script.Parent.NetworkServer))

-- || Constants/Variables || --
local DATA_KEY = "Settings"

-- || Private Helpers || --
-- Validate that a path exists in the template
local function validatePath(path: Path): (boolean, any)
	local parts = if type(path) == "string" then string.split(path, ".") else path
	local current = SettingsTemplate

	for _, key in parts :: {} do
		current = current[key]
		if current == nil then
			return false, nil
		end
	end

	return true, current
end

-- Validate that a value matches the template type
local function validateValue(templateValue: any, value: any): boolean
	local templateType = typeof(templateValue)
	local valueType = typeof(value)

	if templateType == valueType then
		return true
	end

	-- Allow number -> number (int/float)
	if templateType == "number" and valueType == "number" then
		return true
	end

	return false
end

-- || Public API || --
local SettingsServiceServer = {
	_network = (nil :: Network?) :: Network,
	_profiles = {} :: { [Player]: SettingsProfile.SettingsProfile? },
}

export type SettingsServiceServer = typeof(SettingsServiceServer)

--[[
	Initializes the Settings service on the server.
	
	This should be called once when the server starts, after DataService is initialized.
	It sets up network listeners to handle save requests from clients and observes player join/leave.
	
	@return void
	
	Example:
	```lua
	local SettingsServiceServer = require(ServerScriptService.Services.SettingsService.SettingServiceServer)
	
	-- Make sure DataService is initialized first
	DataServiceServer:Init()
	SettingsServiceServer:Init()
	```
	
	Note: Settings depends on DataService for persistence, so DataService must be initialized first.
]]
function SettingsServiceServer.Init(self: SettingsServiceServer)
	self._network = require(script.Parent.NetworkServer)

	-- Handle save requests from clients
	self._network.Save.SetCallback(function(player: Player, changes: { [string]: any })
		local profile = self._profiles[player]
		if not profile then
			return
		end

		-- Validate and apply each change
		for path, value in changes do
			local valid, templateValue = validatePath(path)
			if not valid then
				warn(`[Settings] Invalid path from {player.Name}: {path}`)
				continue
			end

			if not validateValue(templateValue, value) then
				warn(`[Settings] Type mismatch from {player.Name}: {path}`)
				continue
			end

			-- Apply change (this saves to DataService automatically)
			self:Set(player, path, value)
		end
	end)

	-- Handle player join/leave
	Observers.observePlayer(function(player)
		self:_onPlayerAdded(player)

		return function()
			self:_onPlayerRemoved(player)
		end
	end)
end

--[[
	Gets a player's setting value.
	
	@param player Player The player whose settings to read
	@param path string | {string}? Path to the setting. Can be:
	                                 - "audio.master" (string)
	                                 - {"audio", "master"} (table)
	                                 - nil (returns all settings)
	@return any The value at the specified path, or nil if not found or player has no profile
	
	Examples:
	```lua
	-- Get a specific setting
	local sensitivity = SettingsServiceServer:Get(player, "controls.sensitivity")
	
	-- Get entire section
	local audioSettings = SettingsServiceServer:Get(player, "audio")
	-- Returns: { master = 0.8, music = 0.6, sfx = 1.0 }
	
	-- Get all settings
	local allSettings = SettingsServiceServer:Get(player)
	
	-- Check if value exists
	local quality = SettingsServiceServer:Get(player, "graphics.quality")
	if quality then
		print(player.Name, "prefers", quality, "graphics")
	end
	```
	
	Note: Returns nil if player has no profile yet (still loading). Use HasPlayer() to check first.
	Warning: This is a synchronous read. Settings are cached in memory, so this is very fast.
]]
function SettingsServiceServer.Get(self: SettingsServiceServer, player: Player, path: Path?): any
	local profile = self._profiles[player]
	if not profile then
		warn(`[Settings] No profile for {player.Name}`)
		return nil
	end

	return profile:Get(path)
end

--[[
	Sets a player's setting value with validation, persistence, and replication.
	
	Changes are validated against the template, saved to DataService, and replicated to the client.
	Invalid changes (wrong type or non-existent path) are rejected with a warning.
	
	@param player Player The player whose settings to modify
	@param path string | {string} Path to the setting
	@param value any New value to set
	@return boolean true if successful, false if failed validation or no profile
	
	Examples:
	```lua
	-- Set a value
	local success = SettingsServiceServer:Set(player, "graphics.quality", "High")
	if success then
		print("Updated graphics quality")
	end
	
	-- Invalid changes are rejected
	SettingsServiceServer:Set(player, "audio.master", "loud") -- false (type mismatch)
	SettingsServiceServer:Set(player, "fake.setting", 123)    -- false (path doesn't exist)
	```
	
	Validation:
	- Path must exist in SettingsTemplate
	- Type must match template type
	- Profile must be loaded
	
	Note: This always replicates to the client. There is no skipReplication option.
	Warning: Validation warnings are logged to server console when changes are rejected.
]]
function SettingsServiceServer.Set(self: SettingsServiceServer, player: Player, path: Path, value: any): boolean
	local profile = self._profiles[player]
	if not profile then
		warn(`[Settings] No profile for {player.Name}`)
		return false
	end

	-- Validate
	local valid, templateValue = validatePath(path)
	if not valid then
		warn(`[Settings] Invalid path: {path}`)
		return false
	end

	if not validateValue(templateValue, value) then
		warn(`[Settings] Type mismatch: {path}`)
		return false
	end

	-- Update profile
	profile:Set(path, value)

	-- Save to DataService
	local data = profile:Get()
	DataService:Set(player, DATA_KEY, data)

	-- Replicate to client
	local pathStr = if type(path) == "string" then path else table.concat(path, ".")
	self._network.Update.Fire(player, {
		Key = pathStr,
		Value = value,
	})

	return true
end

--[[
	Gets a signal that fires whenever a player's setting changes.
	
	Useful for server-side logic that needs to react to setting changes, such as analytics,
	admin monitoring, or game mechanics that depend on player preferences.
	
	@param player Player The player whose settings to observe
	@param path string | {string} Path to observe for changes
	@return Signal<any>? Signal that fires with the new value, or nil if player has no profile
	
	Examples:
	```lua
	-- Listen to specific setting
	SettingsServiceClient:GetChangedSignal(player, "audio.master"):Connect(function(volume)
		print("Volume changed to", volume)
		SoundService.Volume = volume
	end)
	
	-- Listen to entire section
	SettingsServiceClient:GetChangedSignal(player, "audio"):Connect(function(audioSettings)
		print("Audio settings changed:", audioSettings)
		-- audioSettings = { master = 0.8, music = 0.6, sfx = 1.0 }
	end)
	
	-- Clean up when done
	local connection = SettingsServiceClient:GetChangedSignal(player, "audio.master"):Connect(...)
	-- Later:
	connection:Disconnect()
	```
	
	Note: Returns nil if player has no profile. Always check the return value.
]]
function SettingsServiceServer.GetChangedSignal(self: SettingsServiceServer, player: Player, path: Path): Signal.ClassicSignal<any>?
	local profile = self._profiles[player]
	if not profile then
		warn(`[Settings] No profile for {player.Name}`)
		return nil
	end

	return profile:Changed(path)
end

--[[
	Checks if a player has a loaded settings profile.
	
	@param player Player The player to check
	@return boolean true if player's settings are loaded, false otherwise
	
	Examples:
	```lua
	-- Check before accessing
	if SettingsServiceServer:HasPlayer(player) then
		local fov = Settings.GetPlayer(player, "graphics.fov")
	else
		print(player.Name, "settings not loaded yet")
	end
	```
	
	Note: This is the non-blocking way to check if settings are ready for a player.
	Use this before calling GetPlayer() or SetPlayer() if timing is uncertain.
]]
function SettingsServiceServer.HasPlayer(self: SettingsServiceServer, player: Player): boolean
	return self._profiles[player] ~= nil
end

function SettingsServiceServer._onPlayerAdded(self: SettingsServiceServer, player: Player)
	DataService:WaitForDataAsync(player)
		:andThen(function()
			-- Load or create settings
			local savedData = DataService:Get(player, DATA_KEY)
			local data = if savedData then savedData else Sift.Dictionary.copyDeep(SettingsTemplate)

			-- Create profile
			local profile = SettingsProfile.new(data)
			self._profiles[player] = profile

			-- Save to DataService (in case new player)
			DataService:Set(player, DATA_KEY, data)

			-- Send to client
			self._network.Sync.Fire(player, data)
		end)
		:catch(function(err)
			warn(`[Settings] Failed to load for {player.Name}: {err}`)
		end)
end

function SettingsServiceServer._onPlayerRemoved(self: SettingsServiceServer, player: Player)
	local profile = self._profiles[player]
	if profile then
		profile:Destroy()
		self._profiles[player] = nil
	end
end

return SettingsServiceServer
