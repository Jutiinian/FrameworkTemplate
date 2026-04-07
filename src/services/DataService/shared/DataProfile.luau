-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local DataServiceTypes = require(script.Parent.DataServiceTypes)
local PathUtils = require(script.Parent.PathUtils)

local Signal = require(ReplicatedStorage.Packages.Signal)

-- || Variables || --
type Disconnect = DataServiceTypes.Disconnect
type IndexPath = DataServiceTypes.IndexPath
type WeakValueTable<T> = typeof(setmetatable({} :: { [string]: T }, { __mode = "v" }))

-- || Public API || --
local DataProfile = {}
DataProfile.__index = DataProfile

export type DataProfile<T> = typeof(setmetatable(
	{} :: {
		_data: T,
		_signals: {
			ValueChanged: { [string]: Signal.ClassicSignal<any, any?> },
			IndexChanged: { [string]: Signal.ClassicSignal<any, any?> },
			ArrayInserted: { [string]: Signal.ClassicSignal<number, any> },
			ArrayRemoved: { [string]: Signal.ClassicSignal<number, any> },
		},
		_weakSignals: {
			ValueChanged: WeakValueTable<Signal.ClassicSignal<any, any?>>,
			IndexChanged: WeakValueTable<Signal.ClassicSignal<any, any?>>,
			ArrayInserted: WeakValueTable<Signal.ClassicSignal<number, any>>,
			ArrayRemoved: WeakValueTable<Signal.ClassicSignal<number, any>>,
		},
	},
	DataProfile
))

function DataProfile.new<T>(data: T): DataProfile<T>
	local self = {
		_data = data,
		_signals = {
			ValueChanged = {},
			IndexChanged = {},
			ArrayInserted = {},
			ArrayRemoved = {},
		},
		_weakSignals = {
			ValueChanged = setmetatable({}, { __mode = "v" }),
			IndexChanged = setmetatable({}, { __mode = "v" }),
			ArrayInserted = setmetatable({}, { __mode = "v" }),
			ArrayRemoved = setmetatable({}, { __mode = "v" }),
		},
	}

	setmetatable(self, DataProfile)

	return self
end

-- Usable Functions
function DataProfile.Get<T>(self: DataProfile<T>, indexPath: IndexPath?): T | any
	if indexPath == nil then
		return self._data
	end

	local normalized, isSplit = PathUtils.normalizePath(indexPath)

	if not isSplit then
		return (self._data :: any)[normalized]
	end

	local current = self._data
	for _, key in ipairs(normalized :: { string }) do
		if type(current) ~= "table" then
			return nil
		end

		current = (current :: any)[key]
		if current == nil then
			return nil
		end
	end

	return current
end

function DataProfile.Set<T>(self: DataProfile<T>, indexPath: IndexPath, value: any): ()
	assert(indexPath ~= nil, "IndexPath cannot be nil in Set")

	local normalized, isSplit = PathUtils.normalizePath(indexPath)
	local data = self._data :: any

	if not isSplit then
		local key = normalized :: string

		if data[key] == value then
			return
		end

		data[key] = value
		self:_fireChangedSignals(key)
		return
	end

	local path = normalized :: { string }
	for i = 1, #path - 1 do
		data = data[path[i]]
		if data == nil then
			error(`Cannot set value at path {PathUtils.stringifyPath(indexPath)}: parent does not exist`)
		end
	end

	local finalKey = path[#path]

	if data[finalKey] == value then
		return
	end

	data[finalKey] = value
	self:_fireChangedSignals(normalized)
end

function DataProfile.Update<T>(self: DataProfile<T>, indexPath: IndexPath, callback: (any) -> any): any
	local oldValue = self:Get(indexPath)
	local newValue = callback(oldValue)

	self:Set(indexPath, newValue)

	return newValue
end

function DataProfile.ArrayInsert<T>(self: DataProfile<T>, indexPath: IndexPath, value: any, index: number?): ()
	local data = self:Get(indexPath)
	assert(type(data) == "table", "Data at path is not a table")

	if index and index <= #data then
		table.insert(data, index, value)
	else
		data[#data + 1] = value
		index = #data
	end

	local pathString = PathUtils.stringifyPath(indexPath)
	self:_fireChangedSignals(pathString)

	local signal = self._signals.ArrayInserted[pathString]
	if signal then
		signal:Fire(index :: number, value)
	end
end

function DataProfile.ArrayRemove<T>(self: DataProfile<T>, indexPath: IndexPath, index: number): any
	local data = self:Get(indexPath)
	assert(type(data) == "table", "Data at path is not a table")
	assert(index >= 1 and index <= #data, `Index {index} out of bounds`)

	local value = table.remove(data, index)
	local pathString = PathUtils.stringifyPath(indexPath)
	self:_fireChangedSignals(pathString)

	local signal = self._signals.ArrayRemoved[pathString]
	if signal then
		signal:Fire(index, value)
	end

	return value
end

function DataProfile.GetValueChangedSignal<T>(self: DataProfile<T>, indexPath: IndexPath): Signal.Signal<any>
	return self:_retrieveSignal(indexPath, "ValueChanged")
end

function DataProfile.GetChildChangedSignal<T>(self: DataProfile<T>, indexPath: IndexPath): Signal.Signal<string, any>
	return self:_retrieveSignal(indexPath, "IndexChanged")
end

DataProfile.GetIndexChangedSignal = DataProfile.GetChildChangedSignal

function DataProfile.GetArrayInsertedSignal<T>(self: DataProfile<T>, indexPath: IndexPath): Signal.Signal<number, any>
	return self:_retrieveSignal(indexPath, "ArrayInserted")
end

function DataProfile.GetArrayRemovedSignal<T>(self: DataProfile<T>, indexPath: IndexPath): Signal.Signal<number, any>
	return self:_retrieveSignal(indexPath, "ArrayRemoved")
end

function DataProfile.ObserveData<T>(self: DataProfile<T>, indexPath: IndexPath, factory: (value: any) -> Disconnect?): Disconnect
	local cleanupFunction: (() -> ())? = nil

	local function listener(value: any)
		if cleanupFunction then
			task.spawn(cleanupFunction)
			cleanupFunction = nil
		end

		local clean = factory(value)
		cleanupFunction = typeof(clean) == "function" and clean or function() end
	end

	local conn = self:GetValueChangedSignal(indexPath):Connect(listener)

	task.defer(function()
		if not conn.Connected then
			return
		end

		listener(self:Get(indexPath))
	end)

	return function()
		conn:Disconnect()

		if cleanupFunction then
			cleanupFunction()
			cleanupFunction = nil
		end
	end
end

-- TODO: MAYBE make separate observe array function
function DataProfile.ObserveTableData<T, K, V>(
	self: DataProfile<T>,
	indexPath: IndexPath,
	factory: (key: K, value: V) -> Disconnect?,
	monitorLastValue: boolean?
): Disconnect
	local connections: { [K]: { disconnect: Disconnect, lastValue: V? } } = {}

	local function listener(state: { [K]: V })
		state = state or {}

		for key, data in next, connections do
			if state[key] == nil then
				connections[key] = nil
				task.spawn(data.disconnect)
			end
		end

		for key, value in next, state do
			local data = connections[key]

			if not data then
				local clean = factory(key, value)
				connections[key] = {
					disconnect = typeof(clean) == "function" and clean or function() end,
					lastValue = value,
				}
			elseif monitorLastValue and data.lastValue ~= value then
				data.disconnect()
				local clean = factory(key, value)
				connections[key] = {
					disconnect = typeof(clean) == "function" and clean or function() end,
					lastValue = value,
				}
			end
		end
	end

	local conn = self:GetValueChangedSignal(indexPath):Connect(listener)

	task.defer(function()
		if not conn.Connected then
			return
		end
		listener(self:Get(indexPath) :: any)
	end)

	return function()
		conn:Disconnect()
		for _, data in next, connections do
			data.disconnect()
		end
		table.clear(connections)
	end
end

-- Signal Functions
function DataProfile._fireChangedSignals<T>(self: DataProfile<T>, indexPath: IndexPath): string
	local normalized, isSplit = PathUtils.normalizePath(indexPath)

	-- Fast path for single key
	if not isSplit then
		local key = normalized :: string
		self:_fireValueChangedSignal(key, (self._data :: any)[key])
		return key
	end

	-- Navigate and fire signals at each level
	local path = normalized :: { string }
	local value = self._data :: any
	local indexString = ""

	for i, key in ipairs(path) do
		value = value[key]

		if i > 1 then
			local parentPath = indexString
			indexString ..= "."
			self:_fireIndexChangedSignal(parentPath, key, value)
		end

		indexString ..= key
		self:_fireValueChangedSignal(indexString, value)
	end

	return indexString
end

function DataProfile._fireValueChangedSignal<T>(self: DataProfile<T>, indexPath: string, value: any): ()
	local signal = self._signals.ValueChanged[indexPath]
	if signal then
		signal:Fire(value)
	end
end

function DataProfile._fireIndexChangedSignal<T>(self: DataProfile<T>, indexPath: string, index: string | number, value: any): ()
	local signal = self._signals.IndexChanged[indexPath]
	if signal then
		signal:Fire(index, value)
	end
end

function DataProfile._retrieveSignal<T>(self: DataProfile<T>, indexPath: IndexPath, signalType: string): Signal.Signal<any, any>
	local pathString = PathUtils.stringifyPath(indexPath)
	local weakSignals = self._weakSignals[signalType]
	local strongSignals = self._signals[signalType]

	-- Return existing signal if found
	local existingSignal = weakSignals[pathString]
	if existingSignal then
		return existingSignal
	end

	-- Create new signal with connection tracking
	local signal = Signal.new()
	weakSignals[pathString] = signal

	local connectionCount = 0
	local isDestroyed = false

	-- Helper to promote signal to strong reference
	local function promoteToStrong()
		if connectionCount > 0 and not isDestroyed then
			strongSignals[pathString] = signal
		end
	end

	-- Helper to demote signal from strong reference
	local function demoteFromStrong()
		if connectionCount <= 0 then
			strongSignals[pathString] = nil
		end
	end

	-- Override connection methods to track active connections
	local originalConnect = signal.Connect
	local originalOnce = signal.Once

	local function wrapConnectionMethod(originalMethod)
		return function(_, handler: (...any?) -> ())
			if isDestroyed then
				warn("Attempting to connect to destroyed signal at path: " .. pathString)
				return
			end

			local connection = originalMethod(signal, handler)
			connectionCount += 1
			promoteToStrong()

			-- Wrap disconnect to track connection count
			local originalDisconnect = connection.Disconnect
			local hasDisconnected = false

			local function disconnect()
				if hasDisconnected then
					return
				end

				hasDisconnected = true
				if connection.Connected then
					connectionCount -= 1
					demoteFromStrong()
				end
				originalDisconnect(connection)
			end

			connection.Disconnect = disconnect
			connection.Destroy = disconnect

			return connection
		end
	end

	signal.Connect = wrapConnectionMethod(originalConnect)
	signal.Once = wrapConnectionMethod(originalOnce)

	-- Override DisconnectAll
	local originalDisconnectAll = signal.DisconnectAll
	signal.DisconnectAll = function()
		connectionCount = 0
		strongSignals[pathString] = nil
		originalDisconnectAll(signal)
	end

	-- Override Destroy
	local originalDestroy = signal.Destroy
	signal.Destroy = function()
		if isDestroyed then
			return
		end

		isDestroyed = true
		connectionCount = 0
		strongSignals[pathString] = nil
		weakSignals[pathString] = nil
		originalDestroy(signal)
	end

	return signal
end

-- Destroy Function
function DataProfile.Destroy<T>(self: DataProfile<T>): ()
	for _, signals in self._signals do
		for _, signal in signals do
			signal:Destroy()
		end
	end

	self._signals = nil :: any

	table.clear(self :: any)
	setmetatable(self :: any, nil)
end

return DataProfile
