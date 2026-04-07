--!optimize 2
--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local Signal = require(ReplicatedStorage.Packages.Signal)

-- || Types || --
export type Path = string | { string }

-- || Constants/Variables || --
local strFind = string.find
local strSplit = string.split
local tblConcat = table.concat

local pathCache: { [string]: { string } } = {}
local pathKeyCache: { [string]: string } = {}

-- || Private Functions || --
local function parsePath(path: Path): { string }
	if type(path) == "table" then
		return path
	end

	local cached = pathCache[path]
	if cached then
		return cached
	end

	if not strFind(path, ".", 1, true) then
		local result = table.freeze({ path })
		pathCache[path] = result
		return result
	end

	local result = table.freeze(strSplit(path, "."))
	pathCache[path] = result
	return result
end

local function pathToKey(path: Path): string
	if type(path) == "string" then
		return path
	end

	local cacheKey = tblConcat(path, "\0")
	local cached = pathKeyCache[cacheKey]
	if cached then
		return cached
	end

	local result = tblConcat(path, ".")
	pathKeyCache[cacheKey] = result
	return result
end

-- || Public API || --
local SettingsProfile = {}
SettingsProfile.__index = SettingsProfile

export type SettingsProfile = typeof(setmetatable(
	{} :: {
		_data: { [string]: any },
		_signals: { [string]: Signal.ClassicSignal<any> },
	},
	SettingsProfile
))

function SettingsProfile.new(data: { [string]: any }): SettingsProfile
	local self = setmetatable({
		_data = data,
		_signals = {},
	}, SettingsProfile)

	return self
end

function SettingsProfile.Get(self: SettingsProfile, path: Path?): any
	if not path then
		return self._data
	end

	local parts = parsePath(path)
	local current = self._data

	if #parts == 1 then
		return current[parts[1]]
	end

	for _, key in parts do
		current = current[key]
		if current == nil then
			return nil
		end
	end

	return current
end

function SettingsProfile.Set(self: SettingsProfile, path: Path, value: any)
	local parts = parsePath(path)
	local partsLen = #parts

	if partsLen == 1 then
		local key = parts[1]
		local oldValue = self._data[key]

		if oldValue == value then
			return -- No change
		end

		self._data[key] = value

		local signal = self._signals[key]
		if signal then
			signal:Fire(value)
		end
		return
	end

	local current = self._data

	-- Navigate to parent
	for i = 1, partsLen - 1 do
		local key = parts[i]
		local next = current[key]
		if next == nil then
			next = {}
			current[key] = next
		end
		current = next
	end

	local lastKey = parts[partsLen]
	local oldValue = current[lastKey]

	if oldValue == value then
		return -- No change
	end

	current[lastKey] = value

	if next(self._signals) then
		self:_fireSignals(parts, value)
	end
end

function SettingsProfile.Changed(self: SettingsProfile, path: Path): Signal.ClassicSignal<any>
	local key = pathToKey(path)

	local signal = self._signals[key]
	if signal then
		return signal
	end

	local newSignal = Signal.new()
	self._signals[key] = newSignal

	return newSignal
end

function SettingsProfile._fireSignals(self: SettingsProfile, parts: { string }, finalValue: any)
	local partsLen = #parts

	local buffer = table.create(partsLen * 2 - 1)
	local current = self._data

	for i, key in parts do
		current = current[key]

		if i == 1 then
			buffer[1] = key
		else
			buffer[i * 2 - 2] = "."
			buffer[i * 2 - 1] = key
		end

		local pathStr = tblConcat(buffer, "", 1, i * 2 - 1)
		local signal = self._signals[pathStr]

		if signal then
			local value = if i == partsLen then finalValue else current
			signal:Fire(value)
		end
	end
end

function SettingsProfile.Destroy(self: SettingsProfile)
	for _, signal in self._signals do
		signal:Destroy()
	end

	table.clear(self :: any)
	setmetatable(self :: any, nil)
end

return SettingsProfile
