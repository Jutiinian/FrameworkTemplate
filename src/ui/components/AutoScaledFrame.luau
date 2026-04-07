--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local React = require(ReplicatedStorage.Packages.React)
local getDependencies = require(ReplicatedStorage.UI.utils.getDependencies)
local useScale = require(ReplicatedStorage.UI.hooks.useScale)

local UIConfigurations = require(ReplicatedStorage.UI.Configurations)
local joinDicts = require(ReplicatedStorage.UI.utils.joinDicts)

-- || Constants/Variables || --
local STUDIO_SIZE = UIConfigurations.STUDIO_SIZE

local e = React.createElement

-- || Types || --
export type props = {
	ScaleFactor: number?,
	MinSize: Vector2?,
	Size: UDim2,
	native: {
		Size: nil,
		[string]: any,
	}?,
	children: React.ReactNode?,
}

-- || Component || --
return React.forwardRef(function(props: props, ref: React.Ref<any>)
	local minSize = props.MinSize or Vector2.zero
	local scaleFactor = props.ScaleFactor or 1

	local minScale = React.useMemo(function()
		return math.max(minSize.X / props.Size.X.Offset, minSize.Y / props.Size.Y.Offset)
	end, getDependencies(minSize, props.Size))

	local scaleBinding = useScale(scaleFactor, STUDIO_SIZE)

	return e(
		"Frame",
		joinDicts({
			Size = props.Size,
			BackgroundTransparency = 1,
			ref = ref,
		}, props.native),
		{
			e("UIScale", {
				Scale = scaleBinding:map(function(scaleNumber)
					return math.max(scaleNumber, minScale)
				end),
			}),
			props.children :: any,
		}
	)
end)
