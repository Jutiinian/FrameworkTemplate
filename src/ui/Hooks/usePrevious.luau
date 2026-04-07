--!optimize 2
--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local React = require(ReplicatedStorage.Packages.React)
local getDependencies = require(ReplicatedStorage.UI.utils.getDependencies)

-- || Variables || --
local useRef = React.useRef
local useEffect = React.useEffect

-- || Hooks || --
local function usePrevious<T>(value: T): T
	local ref = useRef(nil :: T?)

	useEffect(function()
		ref.current = value
	end, getDependencies(value))

	return ref.current :: T
end

return usePrevious
