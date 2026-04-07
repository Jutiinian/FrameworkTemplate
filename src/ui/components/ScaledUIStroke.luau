--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local React = require(ReplicatedStorage.Packages.React)
local useStrokeScale = require(ReplicatedStorage.UI.hooks.useStrokeScale)

local UIConfigurations = require(ReplicatedStorage.UI.Configurations)

-- || Constants/Variables || --
local STUDIO_SIZE = UIConfigurations.STUDIO_SIZE

local e = React.createElement

-- || Types || --
export type props = {
	Thickness: number | React.Binding<number>,
	Transparency: number | React.Binding<number> | nil,
	Color: Color3 | React.Binding<Color3> | nil,
	BorderOffset: UDim | React.Binding<UDim> | nil,
	ZIndex: number?,
	ApplyStrokeMode: Enum.ApplyStrokeMode?,
	LineJoinMode: Enum.LineJoinMode?,
	BorderStrokePosition: Enum.BorderStrokePosition?,
	Enabled: boolean | React.Binding<boolean> | nil,

	children: React.ReactNode?,
}

-- || Component || --
return function(props: props)
	local trueEnabled = props.Enabled or true
	local scaledThickness = useStrokeScale(props.Thickness, STUDIO_SIZE.X)

	return e("UIStroke", {
		Color = props.Color or Color3.fromRGB(0, 0, 0),
		Transparency = props.Transparency,
		ApplyStrokeMode = props.ApplyStrokeMode,
		LineJoinMode = props.LineJoinMode,
		BorderStrokePosition = props.BorderStrokePosition,
		BorderOffset = props.BorderOffset,
		ZIndex = props.ZIndex,
		Enabled = trueEnabled,

		Thickness = scaledThickness,
	}, props.children)
end
