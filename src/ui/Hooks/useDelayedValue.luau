--!optimize 2
--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local React = require(ReplicatedStorage.Packages.React)
local getDependencies = require(ReplicatedStorage.UI.utils.getDependencies)

-- || Types || --
type IIncomingUpdate = {
	ResolveTime: number,
	Thread: thread,
}

-- || Private Functions || --
local function clearUpdates(updates: { IIncomingUpdate }, laterThen: number?)
	for id, update in updates do
		if laterThen == nil or update.ResolveTime > laterThen then
			updates[id] = nil
			task.cancel(update.Thread)
		end
	end
end

-- || Variables || --
local nextId = 0

local useState = React.useState

-- || Hook || --
local function useDelayedValue<T>(value: T, delayInSeconds: number)
	local delayedValue, setDelayedValue = useState(value)
	local updates = React.useMemo(function()
		local values: { IIncomingUpdate } = {}
		return values
	end)

	React.useEffect(function()
		local id = nextId
		nextId += 1

		local update: IIncomingUpdate = {
			ResolveTime = os.clock() + delayInSeconds,
			Thread = task.delay(delayInSeconds, function()
				setDelayedValue(value)
				updates[id] = nil
			end),
		}

		clearUpdates(updates, update.ResolveTime)
		updates[id] = update
	end, getDependencies(delayInSeconds, value))

	React.useEffect(function()
		return function()
			clearUpdates(updates)
		end
	end, {})

	return delayedValue
end

return useDelayedValue
