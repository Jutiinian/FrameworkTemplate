--!optimize 2
--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local React = require(ReplicatedStorage.Packages.React)

-- || Types || --
type ICurrentValue<T> = {
	Dependencies: { unknown },
	MemoizedValue: T,
}

local function useMemoWithCleanup<T>(createValue: () -> T, cleanupValue: (value: T) -> (), dependencies: { unknown }?)
	local trueDependencies: { unknown } = if dependencies then dependencies else {}
	local currentValue = React.useRef(nil :: ICurrentValue<T>?)
	local needsToRecalculate = false

	if not currentValue.current then
		needsToRecalculate = true
	else
		for index, dependency in trueDependencies do
			if dependency ~= currentValue.current.Dependencies[index] then
				needsToRecalculate = true
				break
			end
		end
	end

	if needsToRecalculate then
		local currentValueValue = currentValue.current
		if currentValueValue then
			cleanupValue(currentValueValue.MemoizedValue)
		end

		currentValue.current = {
			Dependencies = trueDependencies,
			MemoizedValue = createValue(),
		}
	end

	React.useEffect(function()
		return function()
			local currentValueValue = currentValue.current
			if currentValueValue then
				cleanupValue(currentValueValue.MemoizedValue)
			end

			currentValue.current = nil
		end
	end, {})

	return (currentValue.current :: ICurrentValue<T>).MemoizedValue
end

return useMemoWithCleanup
