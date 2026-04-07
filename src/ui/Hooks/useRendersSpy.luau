--!optimize 2
--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local React = require(ReplicatedStorage.Packages.React)

-- || Variables || --
local useRef = React.useRef
local useEffect = React.useEffect

-- || Hook || --

-- Returns the amount of times the component has been rendered since mounting. This is a very useful hook for testing.
local function useRenderSpy(): number
	local count = useRef(0)

	useEffect(function()
		local current = count.current :: number
		count.current = current + 1
	end)

	return count.current
end

return useRenderSpy
