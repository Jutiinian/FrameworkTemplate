--!optimize 2
--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local React = require(ReplicatedStorage.Packages.React)

-- || Hook || --
local function useToggleState(fn: () -> ()?)
	local onUnmount = React.useRef(nil :: () -> ()?)

	onUnmount.current = fn

	React.useEffect(function()
		return function()
			if onUnmount.current then
				onUnmount.current()
			end
		end
	end)
end

return useToggleState
