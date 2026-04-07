--[[
	SettingsClient
	
	Client-side settings service that manages player preferences and configuration.
	Automatically saves changes to the server with debouncing and provides reactive
	signals for observing setting changes locally.
	
	@author Jutiinian
	@version February 20, 2026
]]

--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- || Dependencies || --
local Promise = require(ReplicatedStorage.Packages.Promise)
local Signal = require(ReplicatedStorage.Packages.Signal)

local SettingsProfile = require(script.Parent.SettingsProfile)
local SettingsTemplate = require(script.Parent.SettingsTemplate)

type Path = SettingsProfile.Path
type Network = typeof(require(script.Parent.NetworkClient))

-- || Constants/Variables || --
-- Debounce saves - batch multiple changes together
local SAVE_DEBOUNCE = 0.5 -- seconds

local SettingsServiceClient = {
	_network = (nil :: Network?) :: Network,
	_profile = nil :: SettingsProfile.SettingsProfile?,
	_ready = Signal.new(),
	_pendingSaves = {} :: { [string]: any },
	_saveScheduled = false,
}

export type SettingsServiceClient = typeof(SettingsServiceClient)

--[[
	Initializes the Settings service on the client.
	
	This should be called once when the game starts, typically in a client-side initialization script.
	It sets up network listeners to receive settings from the server and handle updates.
	
	@return void
	
	Example:
	```lua
	local SettingServiceClient = require(ReplicatedStorage.Services.SettingsService.SettingServiceClient)
	SettingServiceClient:Init()
	```
	
	Note: In Studio edit mode, this will immediately initialize with the template for testing.
]]
function SettingsServiceClient.Init(self: SettingsServiceClient)
	self._network = require(script.Parent.NetworkClient)

	-- Receive initial data from server
	self._network.Sync.SetCallback(function(data)
		if self._profile then
			warn("[Settings] Already initialized")
			return
		end

		self._profile = SettingsProfile.new(data)
		self._ready:Fire()
	end)

	-- Receive updates from server
	self._network.Update.SetCallback(function(data)
		if not self._profile then
			return
		end

		self._profile:Set(data.Key, data.Value)
	end)

	-- Studio mode: use template immediately
	if not RunService:IsRunning() then
		self._profile = SettingsProfile.new(SettingsTemplate)
		self._ready:Fire()
	end
end

--[[
	Gets a setting value (synchronous, yields until ready).
	
	@param path string | {string}? Path to the setting. Can be:
	                                 - "audio.master" (string)
	                                 - {"audio", "master"} (table)
	                                 - nil (returns all settings)
	@return any The value at the specified path, or nil if not found
	
	Examples:
	```lua
	-- Get a specific setting
	local volume = SettingsServiceClient:Get("audio.master") -- 0.8
	
	-- Get nested setting
	local invertY = SettingsServiceClient:Get("controls.invertY") -- false
	
	-- Get entire section
	local audioSettings = SettingsServiceClient:Get("audio")
	-- Returns: { master = 0.8, music = 0.6, sfx = 1.0 }
	
	-- Get all settings
	local allSettings = SettingsServiceClient:Get()
	-- Returns entire settings table
	```
	
	Note: This is a read from local cache. Changes are applied instantly, then saved to server.
]]
function SettingsServiceClient.Get(self: SettingsServiceClient, path: Path?): any
	return (self._profile :: SettingsProfile.SettingsProfile):Get(path)
end

--[[
	Gets a setting value asynchronously (returns a Promise).
	
	This is the preferred way to get settings as it doesn't block and integrates well with promise chains.
	
	@param path string | {string}? Path to the setting
	@return Promise<any> Promise that resolves with the setting value
	
	Examples:
	```lua
	SettingsServiceClient:GetAsync("audio.master"):andThen(function(volume)
		print("Volume is", volume)
		SoundService.Volume = volume
	end)
	```
	
	Benefits over Get():
	- Non-blocking, returns immediately with a promise
	- Can be chained with other async operations
	- Better error handling with catch()
	- Can be canceled or timed out
]]
function SettingsServiceClient.GetAsync(self: SettingsServiceClient, path: Path?): Promise.TypedPromise<any>
	if self._profile then
		return Promise.resolve(self._profile:Get(path))
	end

	return Promise.fromEvent(self._ready):andThen(function()
		return (self._profile :: any):Get(path)
	end)
end

--[[
	Sets a setting value and automatically saves to server after debounce.
	
	Changes are applied locally immediately, then saved to the server after 0.5 seconds.
	Multiple rapid changes are batched into a single network call for efficiency.
	
	@param path string | {string} Path to the setting
	@param value any New value to set
	@return void
	
	Examples:
	```lua
	-- Set a single value
	SettingsServiceClient:Set("audio.master", 0.5)
	-- Applied instantly locally, saves to server after 0.5s
	
	-- Rapid changes are batched
	SettingsServiceClient:Set("audio.master", 0.6) -- 0.5s timer starts
	SettingsServiceClient:Set("audio.music", 0.4)  -- Same batch
	SettingsServiceClient:Set("audio.sfx", 0.8)    -- Same batch
	-- All 3 sent to server in one call after 0.5s
	```
	
	Note: The server validates type and path before saving. Invalid changes are rejected.
	Warning: Calling Set() before settings are ready will warn and ignore the change.
]]
function SettingsServiceClient.Set(self: SettingsServiceClient, path: Path, value: any)
	if not self._profile then
		warn("[Settings] Cannot set before ready")
		return
	end

	-- Update locally immediately
	self._profile:Set(path, value)

	-- Schedule save to server
	self:_scheduleSave(path, value)
end

--[[
	Gets a signal that fires whenever a setting changes.
	
	Fires when the setting is updated either locally (via Set) or from the server (via replication).
	Parent paths fire when any child changes.
	
	@param path string | {string} Path to observe for changes
	@return Signal<any> Signal that fires with the new value
	
	Examples:
	```lua
	-- Listen to specific setting
	SettingsServiceClient:GetChangedSignal("audio.master"):Connect(function(volume)
		print("Volume changed to", volume)
		SoundService.Volume = volume
	end)
	
	-- Listen to entire section
	SettingsServiceClient:GetChangedSignal("audio"):Connect(function(audioSettings)
		print("Audio settings changed:", audioSettings)
		-- audioSettings = { master = 0.8, music = 0.6, sfx = 1.0 }
	end)
	
	-- Clean up when done
	local connection = SettingsServiceClient:GetChangedSignal("audio.master"):Connect(...)
	-- Later:
	connection:Disconnect()
	```
	
	Note: Remember to disconnect signals when no longer needed to avoid memory leaks.
	Error: Throws if called before settings are ready. Use WaitUntilReady() first if needed.
]]
function SettingsServiceClient.GetChangedSignal(self: SettingsServiceClient, path: Path): Signal.ClassicSignal<any>
	if not self._profile then
		error("[Settings] Cannot listen before ready")
	end

	return self._profile:Changed(path)
end

--[[
	Checks if settings are loaded and ready to use (non-blocking).
	
	@return boolean true if settings are ready, false otherwise
	
	Examples:
	```lua
	if SettingsServiceClient:IsReady() then
		local volume = Settings.Get("audio.master")
	else
		print("Settings not loaded yet")
	end
	```
	
	Note: This is the non-blocking way to check readiness. Use this instead of pcall(Get).
]]
function SettingsServiceClient.IsReady(self: SettingsServiceClient): boolean
	return self._profile ~= nil
end

--[[
	Waits for settings to be ready (synchronous, yields).
	
	⚠️ Warning: This yields the current thread. Consider using WaitUntilReadyAsync() for better control.
	
	@return void
	
	Examples:
	```lua
	-- In a script that can yield
	SettingsServiceClient:WaitUntilReady()
	local volume = SettingsServiceClient:Get("audio.master")
	print("Volume is", volume)
	```
	
	Note: Generally prefer WaitUntilReadyAsync() for more robust async handling.
]]
function SettingsServiceClient.WaitUntilReady(self: SettingsServiceClient)
	if self._profile then
		return
	end

	self._ready:Wait()
end

--[[
	Returns a promise that resolves when settings are ready (async).
	
	This is the preferred way to wait for settings as it integrates well with promise chains.
	
	@return Promise<void> Promise that resolves when ready
	
	Examples:
	```lua
	SettingsServiceClient:WaitUntilReadyAsync():andThen(function()
		local volume = SettingsServiceClient:Get("audio.master")
		SoundService.Volume = volume
	end)
	```
	
	Benefits over WaitUntilReady():
	- Non-blocking, returns immediately with a promise
	- Can be chained with other async operations
	- Better error handling with catch()
	- Can be canceled or timed out
]]
function SettingsServiceClient.WaitUntilReadyAsync(self: SettingsServiceClient): Promise.Promise
	if self._profile then
		return Promise.resolve()
	end

	return Promise.fromEvent(self._ready)
end

function SettingsServiceClient._scheduleSave(self: SettingsServiceClient, path: Path, value: any)
	local pathStr = if type(path) == "string" then path else table.concat(path, ".")
	self._pendingSaves[pathStr] = value

	if self._saveScheduled then
		return
	end

	self._saveScheduled = true
	task.delay(SAVE_DEBOUNCE, function()
		self:_flushSaves()
	end)
end

function SettingsServiceClient._flushSaves(self: SettingsServiceClient)
	self._saveScheduled = false

	if next(self._pendingSaves) == nil then
		return
	end

	-- Send all pending saves to server
	self._network.Save.Fire(self._pendingSaves)
	table.clear(self._pendingSaves)
end

return SettingsServiceClient
