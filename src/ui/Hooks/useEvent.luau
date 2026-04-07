--!optimize 2
--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local React = require(ReplicatedStorage.Packages.React)

-- || Variables || --
local useEffect = React.useEffect
local useCallback = React.useCallback

-- || Hook || --
local function useEvent<T...>(event: RBXScriptSignal<T...>, fn: (T...) -> (), dependencies: { any })
	local memoizedFn = useCallback(fn, dependencies)

	useEffect(function()
		local connection = event:Connect(memoizedFn)
		return function()
			connection:Disconnect()
		end
	end, { event, memoizedFn :: any })
end

return useEvent
