--[[
	StateServiceClient
	
	Client-side service for reading, reacting to, and setting object state. Receives
	replicated state changes from the server and provides a unified API for both
	server-replicated and client-local states.
	
	Profiles are auto-initialized on first contact - calling Initialized (done on the
	server) is not needed. 
	
	@author Jutiinian
	@version March 5, 2026
]]

--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local StateProfile = require(ReplicatedStorage.Services.StateService.StateProfile)
local StateServiceTypes = require(ReplicatedStorage.Services.StateService.StateServiceTypes)

-- || Types || --
type profile = StateProfile.StateProfile

-- || Constants/Variables || --
type Networker = typeof(require(script.Parent.NetworkClient))

-- || Public API || --
local StateServiceClient = {
	_network = (nil :: Networker?) :: Networker,
	_profiles = {} :: { [StateServiceTypes.Object]: profile? },
}

type StateServiceClient = typeof(StateServiceClient)

--[[
	Initializes the StateService on the client.

	Sets up network listeners to receive and apply state changes replicated
	from the server. Should be called once during client startup.

	@return void

	Example:
	```lua
	local StateServiceClient = require(ReplicatedStorage.Services.StateService.StateServiceClient)
	StateServiceClient:Init()
	```
]]
function StateServiceClient.Init(self: StateServiceClient)
	self._network = require(script.Parent.NetworkClient)

	self._network.AddState.SetCallback(function(value)
		if value.type == "Single" then
			self:Add(value.object, value.stateKey, value.duration)
		elseif value.type == "Many" then
			self:AddMany(value.object, value.map)
		end
	end)

	self._network.RemoveState.SetCallback(function(value)
		if value.type == "Single" then
			self:Remove(value.object, value.stateKey)
		elseif value.type == "Many" then
			self:RemoveMany(value.object, value.keys)
		end
	end)
end

--[[
	Adds a client-local state to an object.

	This state exists only on the client and is never sent to the server.
	Be careful of any states that should require server authority.

	@param object Instance The target object
	@param stateKey string Identifier for the state
	@param duration number? How long the state lasts in seconds. nil = permanent

	Examples:
	```lua
	StateServiceClient:Add(player, "MenuOpen")
	
	StateServiceClient:Add(player, "Stunned", 3)
	```
]]
function StateServiceClient.Add(self: StateServiceClient, object: StateServiceTypes.Object, stateKey: string, duration: number?)
	self:_retrieveProfile(object):Add(stateKey, duration)
end

--[[
	Adds multiple client-local states to an object at once.

	Map values can be a duration number or true for a permanent state.
	False values are skipped entirely.

	@param object Instance The target object
	@param map { [string]: number | boolean } Map of stateKey to duration or boolean

	Example:
	```lua
	StateServiceClient:AddMany(player, {
		MenuOpen    = true,
		InCutscene  = true,
		Transitioning = 1.5,
	})
	```
]]
function StateServiceClient.AddMany(self: StateServiceClient, object: StateServiceTypes.Object, map: { [string]: number | boolean })
	self:_retrieveProfile(object):AddMany(map)
end

--[[
	Removes a state from an object.

	Works for both client-local states and states set by incoming server
	replication. Do nothing if the state is not active.

	@param object Instance The target object
	@param stateKey string The state to remove

	Example:
	```lua
	StateServiceClient:Remove(player, "MenuOpen")
	```
]]
function StateServiceClient.Remove(self: StateServiceClient, object: StateServiceTypes.Object, stateKey: string)
	self:_retrieveProfile(object):Remove(stateKey)
end

--[[
	Removes multiple states from an object at once.

	@param object Instance The target object
	@param keys { string } List of state keys to remove

	Example:
	```lua
	StateServiceClient:RemoveMany(player, { "MenuOpen", "InCutscene" })
	```
]]
function StateServiceClient.RemoveMany(self: StateServiceClient, object: StateServiceTypes.Object, keys: { string })
	self:_retrieveProfile(object):RemoveMany(keys)
end

--[[
	Returns whether a single state is currently active on an object.

	Covers both server-replicated and client-local states.
	Returns false if the object has no profile.

	@param object Instance The target object
	@param stateKey string The state to check
	@return boolean

	Example:
	```lua
	if StateServiceClient:IsActive(player, "Stunned") then
		disableInput()
	end
	```
]]
function StateServiceClient.IsActive(self: StateServiceClient, object: StateServiceTypes.Object, stateKey: string): boolean
	local profile = self._profiles[object]
	return profile ~= nil and profile:IsActive(stateKey)
end

--[[
	Returns whether ANY of the given states are currently active on an object.

	@param object Instance The target object
	@param ... string One or more state keys to check
	@return boolean

	Example:
	```lua
	if StateServiceClient:IsAnyActive(player, "Stunned", "Frozen", "MenuOpen") then
		lockCamera()
	end
	```
]]
function StateServiceClient.IsAnyActive(self: StateServiceClient, object: StateServiceTypes.Object, ...: string): boolean
	local profile = self._profiles[object]
	return profile ~= nil and profile:IsAnyActive(...)
end

--[[
	Returns whether ALL of the given states are currently active on an object.

	@param object Instance The target object
	@param ... string State keys that must all be active
	@return boolean

	Example:
	```lua
	if StateServiceClient:IsAllActive(player, "Aiming", "Crouching") then
		enableScopeOverlay()
	end
	```
]]
function StateServiceClient.IsAllActive(self: StateServiceClient, object: StateServiceTypes.Object, ...: string): boolean
	local profile = self._profiles[object]
	return profile ~= nil and profile:IsAllActive(...)
end

--[[
	Returns whether none of the given states are currently active on an object.

	Returns true if the object has no profile.

	@param object Instance The target object
	@param ... string State keys to check
	@return boolean

	Example:
	```lua
	if StateServiceClient:NoneActive(player, "Stunned", "Rooted", "MenuOpen") then
		enableMovement()
	end
	```
]]
function StateServiceClient.NoneActive(self: StateServiceClient, object: StateServiceTypes.Object, ...: string): boolean
	local profile = self._profiles[object]
	return profile ~= nil and profile:IsNoneActive(...)
end

--[[
	Returns how many seconds remain on a timed state.

	Returns nil if the state is not active or if it is permanent.

	@param object Instance The target object
	@param stateKey string The state to check
	@return number?

	Example:
	```lua
	local remaining = StateServiceClient:GetRemaining(player, "Stunned")
	if remaining then
		stunBar:SetProgress(remaining / maxDuration)
	end
	```
]]
function StateServiceClient.GetRemaining(self: StateServiceClient, object: StateServiceTypes.Object, stateKey: string): number?
	local profile = self._profiles[object]
	return if profile ~= nil then profile:GetRemaining(stateKey) else nil
end

--[[
	Returns a list of all currently active state keys on an object.

	Includes both server-replicated and client-local states.
	Returns an empty table if the object has no profile.

	@param object Instance The target object
	@return { string }

	Example:
	```lua
	for _, stateKey in StateServiceClient:GetActive(player) do
		print("Active state:", stateKey)
	end
	```
]]
function StateServiceClient.GetActive(self: StateServiceClient, object: StateServiceTypes.Object): { string }
	local profile = self._profiles[object]
	return if profile then profile:GetActive() else {}
end

--[[
	Returns a signal that fires whenever the given state becomes active on an object.

	The signal fires with (remaining: number?, totalDuration: number?) — the remaining duration
	and total duration, or nil for both if the state is permanent.

	The profile is auto-initialized if it does not exist yet.

	@param object Instance The target object
	@param stateKey string The state to listen for
	@return OnActivatedSignal ReadOnly signal: fires (remaining: number?)

	Example:
	```lua
	StateServiceClient:OnActivated(player, "Stunned"):Connect(function(remaining, totalDuration)
		showStunBar(remaining)
	end)
	```
]]
function StateServiceClient.OnActivated(
	self: StateServiceClient,
	object: StateServiceTypes.Object,
	stateKey: string
): StateServiceTypes.OnActivatedSignal
	return self:_retrieveProfile(object):OnActivated(stateKey)
end

--[[
	Returns a signal that fires whenever the given state is removed from an object.

	The signal fires with no arguments.

	The profile is auto-initialized if it does not exist yet.

	@param object Instance The target object
	@param stateKey string The state to listen for
	@return OnDeactivatedSignal ReadOnly signal: fires ()

	Example:
	```lua
	StateServiceClient:OnDeactivated(player, "Stunned"):Connect(function()
		hideStunBar()
	end)
	```
]]
function StateServiceClient.OnDeactivated(
	self: StateServiceClient,
	object: StateServiceTypes.Object,
	stateKey: string
): StateServiceTypes.OnDeactivatedSignal
	return self:_retrieveProfile(object):OnDeactivated(stateKey)
end

--[[
	Observes a state on an object, firing immediately with the current state
	and again on every subsequent change.

	The callback receives (active: boolean, remaining: number?, maxDuration: number?).
	When active is true, the callback may return a cleanup function that runs
	before the next fire or when the observer is disconnected.

	The profile is auto-initialized if it does not exist yet.

	@param object Instance The target object
	@param stateKey string The state to observe
	@param callback ObserveCallback Called with current and future state
	@return Disconnect Call to stop observing

	Example:
	```lua
	local unobserve = StateServiceClient:Observe(player, "Stunned", function(active, remaining, maxDuration)
		if not active then return end

		local bar = showStunBar(remaining, maxDuration)
		return function()
			bar:Destroy()
		end
	end)

	-- Later: stop observing
	unobserve()
	```
]]
function StateServiceClient.Observe(
	self: StateServiceClient,
	object: StateServiceTypes.Object,
	stateKey: string,
	callback: StateServiceTypes.ObserveCallback
): StateServiceTypes.Disconnect
	return self:_retrieveProfile(object):Observe(stateKey, callback)
end

--[[
	Observes multiple states on an object at once.

	Behaves identically to Observe but the callback also receives the stateKey
	as its first argument so you can handle all states in one function.

	@param object Instance The target object
	@param stateKeys { string } The states to observe
	@param callback ObserveManyCallback Called with (stateKey, active, remaining, maxDuration)
	@return Disconnect Call to stop observing all states

	Example:
	```lua
	local unobserve = StateServiceClient:ObserveMany(player, { "Stunned", "Rooted", "Burning" }, function(stateKey, active, remaining, maxDuration)
		if not active then return end

		local vfx = playDebuffVFX(player, stateKey, remaining, maxDuration)
		return function()
			vfx:Destroy()
		end
	end)
	```
]]
function StateServiceClient.ObserveMany(
	self: StateServiceClient,
	object: StateServiceTypes.Object,
	stateKeys: { string },
	callback: StateServiceTypes.ObserveManyCallback
): StateServiceTypes.Disconnect
	return self:_retrieveProfile(object):ObserveMany(stateKeys, callback)
end

function StateServiceClient._retrieveProfile(self: StateServiceClient, object: StateServiceTypes.Object): profile
	if self._profiles[object] ~= nil then
		return self._profiles[object] :: profile
	end

	local profile = StateProfile.new()
	self._profiles[object] = profile

	profile._janitor:Add(
		object.Destroying:Connect(function()
			profile:Destroy()
			self._profiles[object] = nil
		end),
		"Disconnect",
		"DestroyingConn"
	)

	return profile
end

return StateServiceClient
