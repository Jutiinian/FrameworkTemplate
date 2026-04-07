--!optimize 2
--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local React = require(ReplicatedStorage.Packages.React)

-- || Variables || --
local useRef = React.useRef

-- || Hook || --
local function useConstant<T>(create: () -> T): T
	local ref = useRef(nil :: { value: T }?)

	if ref.current == nil then
		ref.current = {
			value = create(),
		}
	end

	return (ref.current :: any).value
end

return useConstant
