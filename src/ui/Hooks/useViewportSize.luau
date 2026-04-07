--!optimize 2
--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local React = require(ReplicatedStorage.Packages.React)
local getDependencies = require(ReplicatedStorage.UI.utils.getDependencies)
local useCurrentCamera = require(ReplicatedStorage.UI.hooks.useCurrentCamera)

-- || Hook || --
local function useViewportSize(onChange: nil | (viewportSize: Vector2) -> ())
	local currentCamera = useCurrentCamera()
	local viewportSize, setViewportSize = React.useBinding(currentCamera.ViewportSize)

	React.useEffect(function()
		local newViewportSize = currentCamera.ViewportSize
		setViewportSize(newViewportSize)
		if onChange then
			onChange(newViewportSize)
		end

		local connection = currentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			local newNewViewportSize = currentCamera.ViewportSize
			setViewportSize(newNewViewportSize)
			if onChange then
				onChange(newNewViewportSize)
			end
		end)

		return function()
			connection:Disconnect()
		end
	end, getDependencies(currentCamera))

	return viewportSize
end

return useViewportSize
