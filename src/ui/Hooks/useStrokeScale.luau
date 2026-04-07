--!optimize 2
--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local React = require(ReplicatedStorage.Packages.React)
local useViewportSize = require(script.Parent.useViewportSize)

-- || Hook || --

--[[
    relativeSize is relative size of the screen; defaults to 985
]]
local function useStrokeScale(pixelThickness: number | React.Binding<number>, relativeSize: number?)
	local trueRelativeSize = if relativeSize then relativeSize else 985

	local thicknessBinding: React.Binding<number>
	if typeof(pixelThickness) == "number" then
		thicknessBinding = React.useBinding(pixelThickness :: number)
	else
		thicknessBinding = pixelThickness :: React.Binding<number>
	end

	local viewportSizeBinding = useViewportSize()

	return React.joinBindings({
		thickness = thicknessBinding :: React.Binding<number>,
		viewportSize = viewportSizeBinding :: React.Binding<Vector2>,
	}):map(function(values: { thickness: number, viewportSize: Vector2 })
		--[[local ratio = values.thickness / trueRelativeSize
		return values.viewportSize.X * values.thickness * ratio]]
		return values.viewportSize.X * values.thickness / trueRelativeSize
	end)
end

return useStrokeScale
