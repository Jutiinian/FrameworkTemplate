--[[
	StateServiceServer

	Server-side service for managing object state. Handles creating and destroying
	state profiles per object, applying timed or permanent states, and replicating
	state changes to clients.

	Objects must be explicitly initialized before any state can be applied to them.
	Players are automatically initialized and deinitialized via observePlayer.

	@author Jutiinian
	@version March 5, 2026
]]

--!strict

-- || Services || --
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local Observers = require(ReplicatedStorage.Packages.Observers)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Signal = require(ReplicatedStorage.Packages.Signal)

local StateProfile = require(ReplicatedStorage.Services.StateService.StateProfile)
local StateServiceTypes = require(ReplicatedStorage.Services.StateService.StateServiceTypes)

-- || Types || --
type profile = StateProfile.StateProfile
type Networker = typeof(require(script.Parent.NetworkServer))

export type ReplicationTarget = "All" | "Self" | { Player } | nil

-- || Constants/Variables || --
local errorMessages = {
	AlreadyCreated = "[StateServiceServer] Object '%s' is already initialized",
	NotInitialized = "[StateServiceServer] Object '%s' has not yet been initialized",
}

-- || Private Functions || --
local function getPlayerFromObject(object: StateServiceTypes.Object): Player?
	if typeof(object) == "Instance" then
		if object:IsA("Player") then
			return object
		end

		return Players:GetPlayerFromCharacter(object :: any)
	end

	return nil
end

-- || Public API || --
local StateServiceServer = {
	_network = (nil :: Networker?) :: Networker,
	_waitSignals = {} :: { [StateServiceTypes.Object]: Signal.ClassicSignal<> },
	_profiles = {} :: { [StateServiceTypes.Object]: profile? },
}

export type StateServiceServer = typeof(StateServiceServer)

--[[
	Initializes the StateService on the server.

	Sets up network handlers and automatically initializes/deinitializes
	state profiles for players as they join and leave.

	This should be called once during server startup.

	@return void

	Example:
	```lua
	local StateServiceServer = require(ServerScriptService.Services.StateService.StateServiceServer)
	StateServiceServer:Init()
	```
]]
function StateServiceServer.Init(self: StateServiceServer)
	self._network = require(script.Parent.NetworkServer)

	Observers.observePlayer(function(player: Player)
		self:InitializeObject(player)

		return function()
			self:DeinitializeObject(player)
		end
	end)
end

--[[
	Creates a state profile for the given object.

	Must be called before any state can be added or removed from the object.
	Players are initialized automatically — only call this manually for
	non-player objects like NPCs or interactable models.

	Fires any pending AwaitObjectInitialization promises for this object.
	Non-player objects are automatically deinitialized when destroyed.

	@param object Instance The object to initialize

	Example:
	```lua
	StateServiceServer:InitializeObject(npc)
	StateServiceServer:Add(npc, "Enraged", 10, "All")
	```

	Note: Errors if the object is already initialized.
]]
function StateServiceServer.InitializeObject(self: StateServiceServer, object: StateServiceTypes.Object)
	assert(self._profiles[object] == nil, errorMessages.AlreadyCreated:format(tostring(object)))

	local profile = StateProfile.new()
	self._profiles[object] = profile

	if self._waitSignals[object] then
		self._waitSignals[object]:Fire()
	end

	if not object:IsA("Player") then
		profile._janitor:Add(
			object.Destroying:Connect(function()
				self:DeinitializeObject(object)
			end),
			"Disconnect",
			"DestroyingConn"
		)
	end
end

--[[
	Destroys the state profile for the given object and clears all active states.

	Called automatically for players on PlayerRemoving and for non-player objects
	on Destroying. You can call this manually if you need to clean up earlier.

	@param object Instance The object to deinitialize

	Example:
	```lua
	StateServiceServer:DeinitializeObject(npc)
	```
]]
function StateServiceServer.DeinitializeObject(self: StateServiceServer, object: StateServiceTypes.Object)
	local profile = self._profiles[object]
	if not profile then
		return
	end

	profile:Destroy()
	self._profiles[object] = nil
end

--[[
	Adds a single state to an object, optionally with a duration.

	If duration is provided, the state will automatically be removed after
	that many seconds. If omitted, the state is permanent until manually removed.

	@param object Instance The target object
	@param stateKey string Identifier for the state (e.g. "Stunned", "Burning")
	@param duration number? How long the state lasts in seconds. nil = permanent
	@param replication ReplicationTarget Who to replicate this state to

	Examples:
	```lua
	-- Timed state replicated to everyone
	StateServiceServer:Add(player, "Stunned", 2, "All")

	-- Permanent state replicated only to the player
	StateServiceServer:Add(player, "Muted", nil, "Self")

	-- Timed state replicated to a specific list
	StateServiceServer:Add(player, "MarkedForParty", 5, partyMembers)

	-- Server-only state, no replication
	StateServiceServer:Add(npc, "InCombat", nil, nil)
	```
]]
function StateServiceServer.Add(
	self: StateServiceServer,
	object: StateServiceTypes.Object,
	stateKey: string,
	duration: number?,
	replication: ReplicationTarget
)
	self:_requireProfile(object):Add(stateKey, duration)
	self:_fireReplication("Add", replication, object, {
		type = "Single",
		stateKey = stateKey,
		duration = duration,
		object = object :: Instance,
	})
end

--[[
	Adds multiple states to an object at once from a map.

	Map values can be a duration number or true for a permanent state.
	False values are skipped entirely.

	All states in the map are replicated with the same target.

	@param object Instance The target object
	@param map { [string]: number | boolean } Map of stateKey to duration or boolean
	@param replication ReplicationTarget Who to replicate these states to

	Examples:
	```lua
	-- Mix of timed and permanent states
	StateServiceServer:AddMany(player, {
		Stunned = 2,
		Rooted  = 3,
		Marked  = true,  -- permanent
		Ignored = false, -- skipped
	}, "All")
	```
]]
function StateServiceServer.AddMany(
	self: StateServiceServer,
	object: StateServiceTypes.Object,
	map: { [string]: number | boolean },
	replication: ReplicationTarget
)
	self:_requireProfile(object):AddMany(map)
	self:_fireReplication("Add", replication, object, {
		type = "Many",
		map = map,
		object = object :: Instance,
	})
end

--[[
	Removes a single state from an object.

	No-ops silently if the state is not currently active.

	@param object Instance The target object
	@param stateKey string The state to remove
	@param replication ReplicationTarget Who to notify of the removal

	Example:
	```lua
	StateServiceServer:Remove(player, "Stunned", "All")
	```
]]
function StateServiceServer.Remove(
	self: StateServiceServer,
	object: StateServiceTypes.Object,
	stateKey: string,
	replication: ReplicationTarget
)
	self:_requireProfile(object):Remove(stateKey)
	self:_fireReplication("Remove", replication, object, {
		type = "Single",
		stateKey = stateKey,
		object = object :: Instance,
	})
end

--[[
	Removes multiple states from an object at once.

	@param object Instance The target object
	@param keys { string } List of state keys to remove
	@param replication ReplicationTarget Who to notify of the removals

	Example:
	```lua
	StateServiceServer:RemoveMany(player, { "Stunned", "Rooted", "Burning" }, "All")
	```
]]
function StateServiceServer.RemoveMany(
	self: StateServiceServer,
	object: StateServiceTypes.Object,
	keys: { string },
	replication: ReplicationTarget
)
	self:_requireProfile(object):RemoveMany(keys)
	self:_fireReplication("Remove", replication, object, {
		type = "Many",
		keys = keys,
		object = object :: Instance,
	})
end

--[[
	Returns whether a single state is currently active on an object.

	Returns false if the object has not been initialized.

	@param object Instance The target object
	@param stateKey string The state to check
	@return boolean

	Example:
	```lua
	if StateServiceServer:IsActive(player, "Stunned") then
		-- prevent movement
	end
	```
]]
function StateServiceServer.IsActive(self: StateServiceServer, object: StateServiceTypes.Object, stateKey: string): boolean
	local profile = self._profiles[object]
	return profile ~= nil and profile:IsActive(stateKey)
end

--[[
	Returns whether any of the given states are currently active on an object.

	Returns false if the object has not been initialized.

	@param object Instance The target object
	@param ... string One or more state keys to check
	@return boolean

	Example:
	```lua
	if StateServiceServer:IsAnyActive(player, "Stunned", "Frozen", "Sleeping") then
		-- player cannot act
	end
	```
]]
function StateServiceServer.IsAnyActive(self: StateServiceServer, object: StateServiceTypes.Object, ...: string): boolean
	local profile = self._profiles[object]
	return profile ~= nil and profile:IsAnyActive(...)
end

--[[
	Returns whether all of the given states are currently active on an object.

	Returns false if the object has not been initialized.

	@param object Instance The target object
	@param ... string State keys that must all be active
	@return boolean

	Example:
	```lua
	if StateServiceServer:IsAllActive(player, "Enraged", "Empowered") then
		-- apply bonus effects
	end
	```
]]
function StateServiceServer.IsAllActive(self: StateServiceServer, object: StateServiceTypes.Object, ...: string): boolean
	local profile = self._profiles[object]
	return profile ~= nil and profile:IsAllActive(...)
end

--[[
	Returns whether none of the given states are currently active on an object.

	Returns true if the object has not been initialized (nothing is active).

	@param object Instance The target object
	@param ... string State keys to check
	@return boolean

	Example:
	```lua
	if StateServiceServer:NoneActive(player, "Stunned", "Rooted") then
		-- player can move freely
	end
	```
]]
function StateServiceServer.NoneActive(self: StateServiceServer, object: StateServiceTypes.Object, ...: string): boolean
	local profile = self._profiles[object]
	return profile ~= nil and profile:IsNoneActive(...)
end

--[[
	Returns how many seconds remain on a timed state.

	Returns nil if the state is not active, or if the state is permanent (no duration).

	@param object Instance The target object
	@param stateKey string The state to check
	@return number? Remaining seconds, or nil

	Example:
	```lua
	local remaining = StateServiceServer:GetRemaining(player, "Stunned")
	if remaining then
		print(("Stun expires in %.1f seconds"):format(remaining))
	end
	```
]]
function StateServiceServer.GetRemaining(self: StateServiceServer, object: StateServiceTypes.Object, stateKey: string): number?
	local profile = self._profiles[object]
	return if profile ~= nil then profile:GetRemaining(stateKey) else nil
end

--[[
	Returns a list of all currently active state keys on an object.

	Returns an empty table if the object has not been initialized.

	@param object Instance The target object
	@return { string } List of active state keys

	Example:
	```lua
	for _, stateKey in StateServiceServer:GetActive(player) do
		print(player.Name, "has state:", stateKey)
	end
	```
]]
function StateServiceServer.GetActive(self: StateServiceServer, object: StateServiceTypes.Object): { string }
	local profile = self._profiles[object]
	return if profile then profile:GetActive() else {}
end

--[[
	Returns a signal that fires whenever the given state becomes active on an object.

	The signal fires with (remaining: number?) — the duration remaining, or nil
	if the state is permanent.

	Multiple callers can connect to the same signal independently without
	creating duplicate internal listeners.

	@param object Instance The target object
	@param stateKey string The state to listen for
	@return OnActivatedSignal ReadOnly signal: fires (remaining: number?)

	Example:
	```lua
	StateServiceServer:OnActivated(npc, "Enraged"):Connect(function(remaining)
		npc.Humanoid.WalkSpeed = 32
	end)
	```

	Note: Errors if the object has not been initialized.
]]
function StateServiceServer.OnActivated(
	self: StateServiceServer,
	object: StateServiceTypes.Object,
	stateKey: string
): StateServiceTypes.OnActivatedSignal
	return self:_requireProfile(object):OnActivated(stateKey)
end

--[[
	Returns a signal that fires whenever the given state is removed from an object.

	The signal fires with no arguments.

	@param object Instance The target object
	@param stateKey string The state to listen for
	@return OnDeactivatedSignal ReadOnly signal: fires ()

	Example:
	```lua
	StateServiceServer:OnDeactivated(npc, "Enraged"):Connect(function()
		npc.Humanoid.WalkSpeed = 16
	end)
	```

	Note: Errors if the object has not been initialized.
]]
function StateServiceServer.OnDeactivated(
	self: StateServiceServer,
	object: StateServiceTypes.Object,
	stateKey: string
): StateServiceTypes.OnDeactivatedSignal
	return self:_requireProfile(object):OnDeactivated(stateKey)
end

--[[
	Observes a state on an object, firing immediately with the current state
	and again on every subsequent change.

	The callback receives (active: boolean, remaining: number?, maxDuration: number?).
	When active is true, the callback may return a cleanup function that runs
	before the next fire or when the observer is disconnected.

	@param object Instance The target object
	@param stateKey string The state to observe
	@param callback ObserveCallback Called with current and future state
	@return Disconnect Call to stop observing

	Example:
	```lua
	local unobserve = StateServiceServer:Observe(npc, "Burning", function(active, remaining, maxDuration)
		if not active then return end

		startDamageTick(npc)
		return function()
			stopDamageTick(npc)
		end
	end)

	-- Later: stop observing
	unobserve()
	```

	Note: Errors if the object has not been initialized.
]]
function StateServiceServer.Observe(
	self: StateServiceServer,
	object: StateServiceTypes.Object,
	stateKey: string,
	callback: StateServiceTypes.ObserveCallback
): StateServiceTypes.Disconnect
	return self:_requireProfile(object):Observe(stateKey, callback)
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
	local unobserve = StateServiceServer:ObserveMany(npc, { "Stunned", "Rooted", "Frozen" }, function(stateKey, active, remaining, maxDuration)
		if not active then return end

		triggerDebuff(npc, stateKey)
		return function()
			removeDebuff(npc, stateKey)
		end
	end)
	```

	Note: Errors if the object has not been initialized.
]]
function StateServiceServer.ObserveMany(
	self: StateServiceServer,
	object: StateServiceTypes.Object,
	stateKeys: { string },
	callback: StateServiceTypes.ObserveManyCallback
): StateServiceTypes.Disconnect
	return self:_requireProfile(object):ObserveMany(stateKeys, callback)
end

--[[
	Returns a promise that resolves when the object has been initialized.

	Resolves immediately if already initialized. Rejects if the object is
	destroyed before initialization completes.

	Useful when you need to react to or query an object's state but cannot
	guarantee that InitializeObject has already been called.

	@param object Instance The object to wait for
	@return Promise Resolves when initialized, rejects if object is destroyed first

	Example:
	```lua
	StateServiceServer:AwaitObjectInitialization(npc):andThen(function()
		StateServiceServer:Add(npc, "Patrolling", nil, "All")
	end):catch(function(err)
		warn("NPC destroyed before initialization:", err)
	end)
	```
]]
function StateServiceServer.AwaitObjectInitialization(self: StateServiceServer, object: StateServiceTypes.Object): Promise.Promise
	local profile = self._profiles[object]
	if profile then
		return Promise.resolve()
	end

	local waitSignal = self._waitSignals[object]
	if not waitSignal then
		waitSignal = Signal.new()
		self._waitSignals[object] = waitSignal
	end

	return Promise.race({
		Promise.fromEvent(waitSignal :: any, function()
			return self._profiles[object] ~= nil
		end),

		Promise.fromEvent(object.Destroying):andThen(function()
			return Promise.reject("Object destroyed before data loaded")
		end),
	}):finally(function()
		waitSignal:Destroy()
		self._waitSignals[object] = nil
	end)
end

function StateServiceServer._requireProfile(self: StateServiceServer, object: StateServiceTypes.Object): profile
	local profile = self._profiles[object]
	assert(profile, errorMessages.NotInitialized:format(tostring(object)))
	return profile
end

function StateServiceServer._fireReplication(
	self: StateServiceServer,
	actionType: "Add" | "Remove",
	replication: ReplicationTarget,
	object: StateServiceTypes.Object,
	payload: any
)
	if not replication then
		return
	end

	local networkEvent: typeof(self._network.AddState) | typeof(self._network.RemoveState) = if actionType == "Add"
		then self._network.AddState
		else self._network.RemoveState

	if replication == "All" then
		(networkEvent :: any).FireAll(payload)
	elseif replication == "Self" then
		local player = getPlayerFromObject(object)
		if player then
			(networkEvent :: any).Fire(player, payload)
		end
	else
		(networkEvent :: any).FireList(replication, payload)
	end
end

return StateServiceServer
