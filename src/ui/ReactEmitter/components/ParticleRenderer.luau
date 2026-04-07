-- IMPLEMENTATION NODE:
-- Flipbook particles on random mode will need two images per particle to fade between

-- IMPLEMENTATION NOTE:
-- Brightness will be multiplied to the current color

--!strict

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
-- Modules
local Emitter = require(script.Parent.Parent.core.Emitter)
local EmitterType = require(script.Parent.Parent.core.EmitterType)
local React = require(ReplicatedStorage.Packages.React)

local e = React.createElement

local function yoink(thunk: () -> ()): (...any) -> ...any
	local yoinked
	xpcall(thunk, function()
		yoinked = debug.info(2, "f")
	end)
	return yoinked
end

-- Directly set the properties on the particle instances for performance
local set: (Instance, string, any) -> () = yoink(function()
	(game :: any)["not_a_real_property"] = nil
end)

local create = Instance.new
local destroy = game.Destroy

export type props = {
	Emitter: EmitterType._Emitter,
	LocalTransparencyModifier: number?, -- Additive modifier for particle transparency from this renderer
	ResampleMode: Enum.ResamplerMode?, -- Resample mode used for the particles
	ZOffset: number?, -- ZOffset of particles
	native: { [any]: any }?,
	children: React.ReactNode?,
}

local registry = {} :: {
	[Frame]: {
		props: props,
		instances: { [number]: { ImageLabel } },
		-- Instances are stored per-renderer, per-particle (lookup by particle _id)
		-- There is usually one instance per particle, but flipbook random mode requires two
	},
}

local function step()
	for frame, renderer in registry do
		local props = renderer.props
		local instances = renderer.instances
		local emitter = props.Emitter
		local particles: { EmitterType.Particle } = Emitter.Particles[emitter._seed] or {}

		local dimensions = emitter.ShapeDimensions
		local XBigger = dimensions.X > dimensions.Y

		local seen = {}

		for _, particle in particles do
			local id = particle._id
			seen[id] = true
			local existing, new = instances[id], false

			if not existing then
				-- Create new instance(s)
				local img1 = create("ImageLabel")
				set(img1, "BackgroundTransparency", 1)
				set(img1, "AnchorPoint", Vector2.new(0.5, 0.5))
				local img2
				if particle.FlipbookFrameTarget then
					img2 = create("ImageLabel")
					set(img2, "BackgroundTransparency", 1)
					set(img2, "AnchorPoint", Vector2.new(0.5, 0.5))
				end

				existing = { img1, img2 }
				instances[id] = existing
				new = true
			end

			-- Update instance(s)
			local ranOnce = false
			for _, v in existing do
				local position = particle.Position
				set(v, "Position", UDim2.fromOffset(position.X, position.Y))
				local size = particle.Size
				local squash = particle.Squash

				-- X shrinks when squash > 0, grows when squash < 0.
				-- Y grows when squash > 0, shrinks when squash < 0.
				local scaleX = size * (1 - squash)
				local scaleY = size * (1 + squash)

				set(v, "Size", UDim2.fromScale(scaleX, scaleY))
				set(v, "SizeConstraint", XBigger and Enum.SizeConstraint.RelativeXX or Enum.SizeConstraint.RelativeYY)
				set(v, "Rotation", particle.Rotation)
				set(v, "ImageColor3", particle.Color)
				set(v, "ImageTransparency", math.clamp(particle.Transparency + (props.LocalTransparencyModifier or 0), 0, 1))
				set(v, "ImageContent", emitter.Texture)
				set(v, "ZIndex", props.ZOffset or 1)
				set(v, "ResampleMode", props.ResampleMode or Enum.ResamplerMode.Default)

				-- Flipbook Particles
				local fb = particle.FlipbookFrame
				local cache = emitter._frameCache
				if fb and cache then
					-- emitter may have been changed during the lifetime of this particle so we are setting defaults to prevent errors

					set(v, "ImageRectOffset", cache[fb] or Vector2.zero)
					set(v, "ImageRectSize", emitter._frameSize or Vector2.zero)

					if ranOnce then
						local ft = particle.FlipbookFrameTarget
						local fa = particle.FlipbookFrameAlpha

						local img1, img2 = instances[id][1], instances[id][2]

						set(img2, "ImageRectOffset", cache[ft] or Vector2.zero)

						-- Crossfade
						set(
							img1,
							"ImageTransparency",
							math.clamp(particle.Transparency + fa + (props.LocalTransparencyModifier or 0), 0, 1)
						)
						set(
							img2,
							"ImageTransparency",
							math.clamp(particle.Transparency + fa + (props.LocalTransparencyModifier or 0), 0, 1)
						)
					end
				else
					set(v, "ImageRectOffset", Vector2.zero)
					set(v, "ImageRectSize", Vector2.zero)
				end
				ranOnce = true
			end

			if new then
				for _, v in existing do
					set(v, "Parent", frame)
				end
			end
		end

		for id, existing in instances do
			if not seen[id] then
				for _, v in existing do
					destroy(v)
				end
				instances[id] = nil
			end
		end
	end
end

local isEdit = not RunService:IsRunning()

-- When using tools like UI_Labs, we want to avoid multiple bindings.
RunService:UnbindFromRenderStep("ReactEmitterRenderer")
RunService:BindToRenderStep("ReactEmitterRenderer", Enum.RenderPriority.Last.Value, function()
	if isEdit then
		local success, err = pcall(step :: any)
		if not success then
			RunService:UnbindFromRenderStep("ReactEmitterRenderer")
			error(err)
		end
	else
		step()
	end
end)

--[=[
	@function ParticleRenderer
	@within ReactEmitter
	@param props { Emitter: Emitter, LocalTransparencyModifier: number?, ResampleMode: ResamplerMode?, ZOffset: number?, native: { [any]: any }? }
	@return ReactElement
]=]
return function(props: props)
	local container = React.useRef(nil :: Frame?)

	React.useEffect(function()
		if not container.current then
			return
		end

		registry[container.current] = { props = props, instances = {} }
		return function()
			for _, v in registry[container.current].instances do
				for _, instance in v do
					destroy(instance)
				end
			end
			registry[container.current] = nil
		end
	end, { props.Emitter, container.current } :: { unknown })

	local native = {}
	native.ref = container
	local size = props.Emitter.ShapeDimensions
	native.Size = UDim2.fromOffset(size.X, size.Y)
	native.BackgroundTransparency = 1
	for k, v in (props.native or {} :: any) do
		native[k] = v
	end

	return e("Frame", native, props.children)
end
