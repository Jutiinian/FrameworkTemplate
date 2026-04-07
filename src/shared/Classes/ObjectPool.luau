-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local Signal = require(ReplicatedStorage.Packages.Signal)

-- || Public API || --
local ObjectPool = {}
ObjectPool.__index = ObjectPool

export type ObjectPool<T> = typeof(setmetatable(
	{} :: {
		_createFunc: () -> T,
		_pool: { T },
		_active: { T },
		_indexMap: { [T]: boolean },

		OnObjectReturned: Signal.ClassicSignal<T>,
		OnObjectCheckedOut: Signal.ClassicSignal<T>,
	},
	ObjectPool
))

--[[
    Creates a new object pool.
    - `createFunc` = function that returns a new instance (e.g., Instance.new("Part")).
    - `initialSize` = number of objects to preallocate.
]]
function ObjectPool.new<T>(createFunc: () -> T, initialSize: number?): ObjectPool<T>
	local self = setmetatable({
		_createFunc = createFunc,
		_pool = {},
		_active = {},
		_indexMap = {},

		OnObjectReturned = Signal.new(),
		OnObjectCheckedOut = Signal.new(),
	}, ObjectPool)

	local size = initialSize or 25
	for _ = 1, size do
		local object = createFunc()
		table.insert(self._pool, object)
		self._indexMap[object] = false
	end

	return self
end

--[[
    Gets an object from the pool.
    - If none are available, creates a new one automatically.
    - Fires OnObjectCheckedOut, passing the object.
]]
function ObjectPool.Get<T>(self: ObjectPool<T>): T
	local object

	if #self._pool > 0 then
		object = table.remove(self._pool)
	else
		object = self._createFunc()
	end

	table.insert(self._active, object)
	self._indexMap[object] = true

	self.OnObjectCheckedOut:Fire(object)

	return object
end

--[[
    Returns an object back to the pool.
    - Automatically removes from active list and marks as available.
    - Ignores if object is already returned.
    - Fires OnObjectReturned, passing the object.
]]
function ObjectPool.Return<T>(self: ObjectPool<T>, object: T)
	if not self._indexMap[object] then
		if self._indexMap[object] == nil then
			warn("ObjectPool: Return called on object not from this pool")
		end

		return
	end

	self._indexMap[object] = false

	for i = #self._active, 1, -1 do
		if self._active[i] == object then
			table.remove(self._active, i)
			break
		end
	end

	table.insert(self._pool, object)

	self.OnObjectReturned:Fire(object)
end

--[[
    Returns the number of objects currently available in the pool.
]]
function ObjectPool.GetAvailableCount<T>(self: ObjectPool<T>): number
	return #self._pool
end

--[[
    Returns the number of objects currently active (checked out).
]]
function ObjectPool.GetActiveCount<T>(self: ObjectPool<T>): number
	return #self._active
end

--[[
    Clears the pool completely. Optionally destroys all instances if they have a :Destroy() method.
    - Pool can still be used after clearing.
]]
function ObjectPool.Clear<T>(self: ObjectPool<T>, destroyInstances: boolean?)
	destroyInstances = destroyInstances or false

	if destroyInstances then
		for _, object in ipairs(self._pool) do
			if object.Destroy then
				object:Destroy()
			end
		end

		for _, object in ipairs(self._active) do
			if object.Destroy then
				object:Destroy()
			end
		end
	end

	self._pool = {}
	self._active = {}
	self._indexMap = {}
end

--[[
    Destroys all instances and completely destroys the pool.
    - Pool can not be used after destroying.
]]
function ObjectPool.Destroy<T>(self: ObjectPool<T>)
	self:Clear(true)

	self.OnObjectReturned:Destroy()
	self.OnObjectCheckedOut:Destroy()

	table.clear(self :: any)
	setmetatable(self :: any, nil)
end

return ObjectPool
