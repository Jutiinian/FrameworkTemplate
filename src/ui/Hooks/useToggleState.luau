--!optimize 2
--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local React = require(ReplicatedStorage.Packages.React)

-- || Types || --
export type Toggle = {
	toggle: () -> (),
	on: () -> (),
	off: () -> (),
}

-- || Hook || --
local function useToggleState(default: boolean?): (boolean, Toggle)
	local value, setValue = React.useState(default == true)

	local toggle = React.useMemo(function()
		return {
			toggle = function()
				setValue(function(prev: boolean)
					return not prev
				end)
			end,

			on = function()
				setValue(true)
			end,

			off = function()
				setValue(false)
			end,
		}
	end)

	return value, toggle
end

return useToggleState
