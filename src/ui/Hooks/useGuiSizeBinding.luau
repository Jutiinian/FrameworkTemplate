--!optimize 2
--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local React = require(ReplicatedStorage.Packages.React)

-- || Variables || --
local useBinding = React.useBinding
local useRef = React.useRef
local useEffect = React.useEffect

-- || Hook || --
local function useGuiSizeBinding(): (React.Ref<GuiObject>, React.Binding<Vector2>)
	local ref = useRef(nil :: GuiObject?)
	local binding, setBinding = useBinding(Vector2.zero)

	local current = ref.current

	useEffect(function()
		if current == nil or not current:IsA("GuiBase2d") then
			setBinding(Vector2.zero)
			return
		end

		local currentGuiObject = current :: GuiObject

		local connection = currentGuiObject:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			setBinding(currentGuiObject.AbsoluteSize)
		end)

		return function()
			connection:Disconnect()
		end
	end, { current })

	return ref, binding
end

return useGuiSizeBinding
