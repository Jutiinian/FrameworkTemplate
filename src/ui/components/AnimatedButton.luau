--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local React = require(ReplicatedStorage.Packages.React)
local React_Flow = require(ReplicatedStorage.Packages["React-Flow"])
local getDependencies = require(ReplicatedStorage.UI.utils.getDependencies)

-- || Variables || --
local Spring = React_Flow.Spring
local useAnimation = React_Flow.useAnimation
local useGroupAnimation = React_Flow.useGroupAnimation

local e = React.createElement

-- || Types || --
export type SpringConfigSingle = {
	speed: number?,
	damping: number?,
}

export type SpringConfigMulti = {
	Default: SpringConfigSingle?,
	Hover: SpringConfigSingle?,
	Press: SpringConfigSingle?,
}

export type props = {
	-- Animation
	HoverMultiplier: Vector2?,
	PressedMultiplier: Vector2?,
	SpringConfig: (SpringConfigSingle | SpringConfigMulti)?,

	-- Layout
	Size: UDim2,
	Position: UDim2? | React.Binding<UDim2>?,
	AnchorPoint: Vector2?,
	LayoutOrder: number?,
	ZIndex: number?,

	-- Appearance
	BackgroundColor3: Color3?,
	BackgroundTransparency: number?,
	AutoButtonColor: boolean?,
	ClipsDescendants: boolean?,

	-- State
	Disabled: boolean?,

	-- Callbacks
	onHover: ((isHovering: boolean) -> ())?,
	onPressed: ((isPressed: boolean) -> ())?,
	onActivated: (() -> ())?,

	-- Children
	children: React.ReactNode?,
}

-- || Constants || --
local DEFAULT_SPRING = { speed = 20, damping = 1 }
local DEFAULT_HOVER_MULTIPLIER = Vector2.new(1.05, 1.05)
local DEFAULT_PRESSED_MULTIPLIER = Vector2.new(0.95, 0.95)

-- || Helpers || --
local function scaleUDim2(size: UDim2, mul: Vector2): UDim2
	return UDim2.new(size.X.Scale * mul.X, size.X.Offset * mul.X, size.Y.Scale * mul.Y, size.Y.Offset * mul.Y)
end

local function parseSpringConfig(
	config: (SpringConfigSingle | SpringConfigMulti)?
): (SpringConfigSingle, SpringConfigSingle, SpringConfigSingle)
	if not config then
		return DEFAULT_SPRING, DEFAULT_SPRING, DEFAULT_SPRING
	end

	local isMultiConfig = (config :: SpringConfigMulti).Default ~= nil
		or (config :: SpringConfigMulti).Hover ~= nil
		or (config :: SpringConfigMulti).Press ~= nil

	if isMultiConfig then
		local multiConfig = config :: SpringConfigMulti
		local defaultConfig = multiConfig.Default or DEFAULT_SPRING
		return defaultConfig, multiConfig.Hover or defaultConfig, multiConfig.Press or defaultConfig
	else
		local singleConfig = config :: SpringConfigSingle
		return singleConfig, singleConfig, singleConfig
	end
end

-- || Component || --
return React.forwardRef(function(props: props, ref: React.Ref<TextButton?>)
	local isHovering, setIsHovering = React.useState(false)
	local isPressed, setIsPressed = React.useState(false)

	local isDisabled = props.Disabled or false

	-- Memoize multipliers and offsets
	local hoverMultiplier = props.HoverMultiplier or DEFAULT_HOVER_MULTIPLIER
	local pressedMultiplier = props.PressedMultiplier or DEFAULT_PRESSED_MULTIPLIER

	-- Parse spring configs
	local configDefault, configHover, configPress = React.useMemo(function()
		return parseSpringConfig(props.SpringConfig)
	end, { props.SpringConfig })

	-- Memoize animation targets to prevent recreation
	local animationTargets = React.useMemo(function()
		return {
			default = {
				size = props.Size,
			},
			hover = {
				size = scaleUDim2(props.Size, hoverMultiplier),
			},
			press = {
				size = scaleUDim2(props.Size, pressedMultiplier),
			},
		}
	end, getDependencies(props.Size, props.Position, hoverMultiplier, pressedMultiplier))

	-- Setup animations with individual configs
	local animations, playAnimation = useGroupAnimation({
		Default = useAnimation({
			size = Spring({
				target = animationTargets.default.size,
				speed = configDefault.speed,
				damper = configDefault.damping,
			}),
		}),

		Hover = useAnimation({
			size = Spring({
				target = animationTargets.hover.size,
				speed = configHover.speed,
				damper = configHover.damping,
			}),
		}),

		Press = useAnimation({
			size = Spring({
				target = animationTargets.press.size,
				speed = configPress.speed,
				damper = configPress.damping,
			}),
		}),
	}, animationTargets.default)

	-- Determine animation state
	local animationState = React.useMemo(function()
		if isDisabled then
			return "Default"
		end
		return isPressed and "Press" or isHovering and "Hover" or "Default"
	end, { isPressed, isHovering, isDisabled })

	-- Play animation when state changes
	React.useEffect(function()
		playAnimation(animationState)
	end, { animationState })

	-- Notify hover state changes
	React.useEffect(function()
		if props.onHover then
			props.onHover(isHovering)
		end
	end, { isHovering })

	-- Notify pressed state changes
	React.useEffect(function()
		if props.onPressed then
			props.onPressed(isPressed)
		end
	end, { isPressed })

	-- Event handlers
	local handleMouseEnter = React.useCallback(function()
		if not isDisabled then
			setIsHovering(true)
		end
	end, { isDisabled })

	local handleMouseLeave = React.useCallback(function()
		setIsHovering(false)
		setIsPressed(false)
	end, {})

	local handleMouseButton1Down = React.useCallback(function()
		if not isDisabled then
			setIsPressed(true)
		end
	end, { isDisabled })

	local handleMouseButton1Up = React.useCallback(function()
		if isPressed and not isDisabled then
			setIsPressed(false)
			if props.onActivated then
				props.onActivated()
			end
		end
	end, getDependencies(isPressed, isDisabled, props.onActivated))

	return e("TextButton", {
		Text = "",
		TextTransparency = 1,

		Size = animations.size,
		Position = props.Position,

		BorderSizePixel = 0,

		AnchorPoint = props.AnchorPoint or Vector2.new(0, 0),
		BackgroundColor3 = props.BackgroundColor3 or Color3.fromRGB(255, 255, 255),
		BackgroundTransparency = props.BackgroundTransparency or 0,
		ZIndex = props.ZIndex,
		AutoButtonColor = props.AutoButtonColor or false,
		ClipsDescendants = props.ClipsDescendants,
		LayoutOrder = props.LayoutOrder,

		[React.Event.MouseEnter] = handleMouseEnter,
		[React.Event.MouseLeave] = handleMouseLeave,
		[React.Event.MouseButton1Down] = handleMouseButton1Down,
		[React.Event.MouseButton1Up] = handleMouseButton1Up,

		ref = ref,
	}, props.children)
end)
