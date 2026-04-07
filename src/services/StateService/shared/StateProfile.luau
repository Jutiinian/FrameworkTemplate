--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local Janitor = require(ReplicatedStorage.Packages.Janitor)
local Signal = require(ReplicatedStorage.Packages.Signal)

local HeapManager = require(script.Parent.Utils.HeapManager)

local StateServiceTypes = require(script.Parent.StateServiceTypes)

-- || Constants/Variables || --
local _nextID = 0
local _registry: { [number]: StateProfile } = setmetatable({}, { __mode = "v" }) :: any

local sharedHeap: HeapManager.HeapManager = HeapManager.new(function(rawEntry)
	local entry = rawEntry :: HeapManager.HeapEntry

	local self = _registry[entry.ID]
	if not self then
		return
	end

	if self._destroyed then
		return
	end

	local state = self._states[entry.Key]
	if state ~= entry.StateRef then
		return
	end

	if state.Paused then
		return
	end

	self._states[entry.Key] = nil
	self:_fireSignals(entry.Key, false)
end)

-- || Types || --
type StateData = StateServiceTypes.StateData
type HeapManager = HeapManager.HeapManager

type GlobalSignal = Signal.ClassicSignal<boolean, number?, number?>
type ActivatedSignal = Signal.ClassicSignal<number?, number?>
type DeactivatedSignal = Signal.ClassicSignal<>

-- || Private Helper Functions || --
local function _getRemaining(state: StateData): number?
	if not state.ExpiresAt then
		return nil
	end
	local r = state.ExpiresAt - os.clock()
	return if r > 0 then r else 0
end

-- || Public API || --
local StateProfile = {}
StateProfile.__index = StateProfile

export type StateProfile = typeof(setmetatable(
	{} :: {
		_ID: number,
		_states: { [string]: StateData },
		_signals: {
			activated: { [string]: ActivatedSignal },
			deactivated: { [string]: DeactivatedSignal },
			global: { [string]: GlobalSignal },
		},
		_janitor: Janitor.Janitor,
		_nextObserveID: number,
		_destroyed: boolean,
	},
	StateProfile
))

function StateProfile.new(): StateProfile
	_nextID += 1
	local ID = _nextID

	local self = setmetatable({
		_ID = ID,
		_states = {},
		_signals = {
			activated = {},
			deactivated = {},
			global = {},
		},
		_janitor = Janitor.new(),
		_nextObserveID = 0,
		_destroyed = false,
	}, StateProfile)

	self.Changed = Signal.new(self._janitor)

	_registry[ID] = self

	return self
end

function StateProfile.Add(self: StateProfile, stateKey: string, duration: number?)
	local state: StateData = {
		ExpiresAt = if duration then os.clock() + duration else nil,
		Duration = duration,
	}

	self._states[stateKey] = state

	if duration then
		sharedHeap:Push({
			ExpiresAt = state.ExpiresAt :: number,
			ID = self._ID,
			Key = stateKey,
			StateRef = state,
		})

		local root = sharedHeap:Peek()
		if root and (root :: any).StateRef == state then
			sharedHeap:ScheduleNext()
		end
	end

	self:_fireSignals(stateKey, true)
end

function StateProfile.AddMany(self: StateProfile, map: { [string]: number | boolean })
	for stateKey, value in map do
		if value == false then
			continue
		end
		self:Add(stateKey, if type(value) == "number" then value else nil)
	end
end

function StateProfile.Remove(self: StateProfile, stateKey: string)
	if not self._states[stateKey] then
		return
	end

	self._states[stateKey] = nil

	self:_fireSignals(stateKey, false)
end

function StateProfile.RemoveMany(self: StateProfile, keys: { string })
	for _, key in keys do
		self:Remove(key)
	end
end

function StateProfile.IsActive(self: StateProfile, stateKey: string): boolean
	return self._states[stateKey] ~= nil
end

function StateProfile.IsAnyActive(self: StateProfile, ...: string): boolean
	local states = self._states
	for i = 1, select("#", ...) do
		if states[(select(i, ...))] then
			return true
		end
	end
	return false
end

function StateProfile.IsAllActive(self: StateProfile, ...: string): boolean
	local states = self._states
	for i = 1, select("#", ...) do
		if not states[(select(i, ...))] then
			return false
		end
	end
	return true
end

function StateProfile.IsNoneActive(self: StateProfile, ...: string): boolean
	local states = self._states
	for i = 1, select("#", ...) do
		if states[(select(i, ...))] then
			return false
		end
	end
	return true
end

function StateProfile.GetRemaining(self: StateProfile, stateKey: string): number?
	local status = self._states[stateKey]
	return if status then _getRemaining(status) else nil
end

function StateProfile.GetActive(self: StateProfile): { string }
	local active = {}
	for key in self._states do
		table.insert(active, key)
	end
	return active
end

function StateProfile.Pause(self: StateProfile, stateKey: string)
	local status = self._states[stateKey]
	if not status or not status.ExpiresAt or status.Paused then
		return
	end

	status.PausedRemaining = status.ExpiresAt - os.clock()
	status.ExpiresAt = nil
	status.Paused = true
end

--- Restores a paused status' frozen remaining time.
function StateProfile.Resume(self: StateProfile, stateKey: string)
	local state = self._states[stateKey]
	if not state or not state.Paused then
		return
	end

	local remaining = state.PausedRemaining or 0
	state.ExpiresAt = os.clock() + remaining
	state.PausedRemaining = nil
	state.Paused = false

	sharedHeap:Push({
		ExpiresAt = state.ExpiresAt :: number,
		ID = self._ID,
		Key = stateKey,
		StateRef = state,
	})
	sharedHeap:ScheduleNext()
end

function StateProfile.Observe(
	self: StateProfile,
	stateKey: string,
	callback: StateServiceTypes.ObserveCallback
): StateServiceTypes.Disconnect
	local cleanUp: StateServiceTypes.Disconnect? = nil

	task.spawn(function()
		if self._destroyed then
			return
		end

		local state = self._states[stateKey]
		local active = state ~= nil

		local stateDuration = if active and state then state.Duration else nil
		local timeRemaining = if active and state then _getRemaining(state) else nil

		local result = callback(active, timeRemaining, stateDuration)
		if type(result) == "function" then
			cleanUp = result
		end
	end)

	local signalConnection = self:_retrieveGlobalSignal(stateKey):Connect(function(active, remaining, totalDuration)
		if cleanUp then
			cleanUp()
			cleanUp = nil
		end

		local result = callback(active, remaining, totalDuration)
		if type(result) == "function" then
			cleanUp = result
		end
	end)

	self._nextObserveID += 1
	local observeKey = "observe_" .. self._nextObserveID

	local function disconnect()
		if not self._destroyed then
			self._janitor:RemoveNoClean(observeKey)
		end

		signalConnection:Disconnect()
		if cleanUp then
			cleanUp()
			cleanUp = nil
		end
	end

	self._janitor:Add(disconnect, true, observeKey)
	return disconnect
end

function StateProfile.ObserveMany(
	self: StateProfile,
	stateKeys: { string },
	callback: StateServiceTypes.ObserveManyCallback
): StateServiceTypes.Disconnect
	local signalsJanitor = Janitor.new()
	local cleanUps: { [string]: StateServiceTypes.Disconnect } = {}

	for _, stateKey in stateKeys do
		task.spawn(function()
			if self._destroyed then
				return
			end

			local state = self._states[stateKey]
			local active = state ~= nil

			local stateDuration = if active and state then state.Duration else nil
			local timeRemaining = if active and state then _getRemaining(state) else nil

			local result = callback(stateKey, active, timeRemaining, stateDuration)
			if type(result) == "function" then
				cleanUps[stateKey] = result
			end
		end)

		signalsJanitor:Add(
			self:_retrieveGlobalSignal(stateKey):Connect(function(active, remaining, totalDuration)
				if cleanUps[stateKey] then
					cleanUps[stateKey]()
					cleanUps[stateKey] = nil
				end

				local result = callback(stateKey, active, remaining, totalDuration)
				if type(result) == "function" then
					cleanUps[stateKey] = result
				end
			end),
			"Disconnect",
			stateKey
		)
	end

	self._nextObserveID += 1
	local observeKey = "observe_" .. self._nextObserveID

	local function disconnect()
		if not self._destroyed then
			self._janitor:RemoveNoClean(observeKey)
		end

		signalsJanitor:Destroy()

		for _, cleanUp in cleanUps do
			cleanUp()
		end

		table.clear(cleanUps)
	end

	self._janitor:Add(disconnect, true, observeKey)
	return disconnect
end

function StateProfile.OnActivated(self: StateProfile, stateKey: string): StateServiceTypes.OnActivatedSignal
	local activatedSignals = self._signals.activated
	if not activatedSignals[stateKey] then
		local newSignal = Signal.new(self._janitor)
		activatedSignals[stateKey] = newSignal
	end

	return activatedSignals[stateKey] :: any
end

function StateProfile.OnDeactivated(self: StateProfile, stateKey: string): StateServiceTypes.OnDeactivatedSignal
	local deactivatedSignals = self._signals.deactivated
	if not deactivatedSignals[stateKey] then
		local newSignal = Signal.new(self._janitor)
		deactivatedSignals[stateKey] = newSignal
	end

	return deactivatedSignals[stateKey] :: any
end

function StateProfile.Destroy(self: StateProfile)
	self._destroyed = true

	self._states = nil :: any
	self._signals = nil :: any
	self._janitor:Destroy()

	table.clear(self :: any)
	setmetatable(self :: any, nil)
end

function StateProfile._fireSignals(self: StateProfile, stateKey: string, active: boolean)
	local state = self._states[stateKey]
	local duration = if active and state then state.Duration else nil
	local timeRemaining = if active and state then _getRemaining(state) else nil

	if self._signals.global[stateKey] then
		self._signals.global[stateKey]:Fire(active, timeRemaining, duration)
	end

	if active and self._signals.activated[stateKey] then
		self._signals.activated[stateKey]:Fire(timeRemaining, duration)
	elseif not active and self._signals.deactivated[stateKey] then
		self._signals.deactivated[stateKey]:Fire()
	end
end

function StateProfile._retrieveGlobalSignal(self: StateProfile, stateKey: string): GlobalSignal
	local globalSignals = self._signals.global
	if not globalSignals[stateKey] then
		local newSignal = Signal.new(self._janitor)
		globalSignals[stateKey] = newSignal
	end

	return globalSignals[stateKey]
end

return StateProfile
