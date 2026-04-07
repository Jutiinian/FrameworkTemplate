--!optimize 2
--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local React = require(ReplicatedStorage.Packages.React)
local useEvent = require(script.Parent.useEvent)

-- || Hook || --
local function useCurrentCamera(onChange: nil | (currentCamera: Camera) -> ())
	local currentCamera, setCurrentCamera = React.useState(workspace.CurrentCamera)

	useEvent(workspace:GetPropertyChangedSignal("CurrentCamera"), function()
		local newCurrentCamera = workspace.CurrentCamera
		if newCurrentCamera then
			setCurrentCamera(newCurrentCamera)

			if onChange then
				onChange(newCurrentCamera)
			end
		end
	end, { onChange })

	return currentCamera
end

return useCurrentCamera
