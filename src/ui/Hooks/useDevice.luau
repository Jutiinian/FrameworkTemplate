-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

-- || Dependencies || --
local React = require(ReplicatedStorage.Packages.React)

-- || Variables || --
local useState = React.useState
local useEffect = React.useEffect

-- || Helper Functions || --
local function getDeviceType()
	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		return "Mobile"
	elseif UserInputService.GamepadEnabled then
		return "Console"
	else
		return "Desktop"
	end
end

local function getDeviceInfo()
	local deviceType = getDeviceType()
	return {
		deviceType = deviceType,
		platform = UserInputService:GetPlatform(),
		touchEnabled = UserInputService.TouchEnabled,
		mouseEnabled = UserInputService.MouseEnabled,
		keyboardEnabled = UserInputService.KeyboardEnabled,
		gamepadEnabled = UserInputService.GamepadEnabled,
		isMobile = deviceType == "Mobile",
		isDesktop = deviceType == "Desktop",
		isConsole = deviceType == "Console",
	}
end

-- || Hook || --
local function useDevice()
	local device, setDevice = useState(getDeviceInfo())

	useEffect(function()
		local gamepadChanged = UserInputService.GamepadConnected:Connect(function()
			setDevice(getDeviceInfo())
		end)

		local gamepadDisconnected = UserInputService.GamepadDisconnected:Connect(function()
			setDevice(getDeviceInfo())
		end)

		return function()
			gamepadChanged:Disconnect()
			gamepadDisconnected:Disconnect()
		end
	end, {})

	return device
end

return useDevice
