local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Emitter = require(script.Parent.Parent.core.Emitter)
local EmitterType = require(script.Parent.Parent.core.EmitterType)
local React = require(ReplicatedStorage.Packages.React)

export type props = { EmitterType.Emitter } | (index: number) -> EmitterType.Emitter

export type emitters = { EmitterType._Emitter }
export type api = {
	emit: (callback: (index: number) -> number) -> (),
}

local function resolveProps(spec: props, index: number): EmitterType.Emitter?
	if type(spec) == "function" then
		return spec(index)
	else
		-- If spec is a table of props per index, prefer spec[index], otherwise treat spec as the props table
		if type(spec) == "table" and spec[index] ~= nil and type(spec[index]) == "table" then
			return spec[index]
		else
			return spec :: any
		end
	end
end

--[=[
    @function useEmitters
    @within ReactEmitter
    @param count number -- The number of emitters to create
    @param props { EmitterProps } | (index: number) -> EmitterProps -- The properties for each emitter, either as a table or a function that returns a table given the index
    @return { Emitter } -- An array of created emitters
    @return { emit: (callback: (index: number) -> number) -> () }? -- Imperative API created when passing a function as props
    A hook that creates and manages multiple particle emitters. The `props` parameter can be either a table of emitter properties or a function that returns emitter properties based on the index.
]=]
local function useEmitters(count: number, props: props, deps: { unknown }?): ({ EmitterType._Emitter }, api?)
	local isImperative = React.useRef(nil :: boolean?)

	if type(props) == "function" then
		assert(isImperative.current == nil or isImperative.current == true, "Cannot switch between imperative and declarative props.")
		isImperative.current = true
	else
		assert(isImperative.current == nil or isImperative.current == false, "Cannot switch between imperative and declarative props.")
		isImperative.current = false
	end

	-- Rebuild flipbook frame metadata when layout/size changes
	local function rebuildFlipbook(emitter: EmitterType._Emitter)
		local layout = emitter.FlipbookLayout

		if layout == Enum.ParticleFlipbookLayout.None then
			-- No flipbook
			emitter._frames = nil :: any
			emitter._frameCache = nil :: any
			emitter._frameSize = nil :: any
			return
		end

		-- Resolve grid columns and rows from layout enum
		local cols, rows

		if layout == Enum.ParticleFlipbookLayout.Grid2x2 then
			cols, rows = 2, 2
		elseif layout == Enum.ParticleFlipbookLayout.Grid4x4 then
			cols, rows = 4, 4
		elseif layout == Enum.ParticleFlipbookLayout.Grid8x8 then
			cols, rows = 8, 8
		elseif layout == Enum.ParticleFlipbookLayout.Custom then
			cols = emitter.FlipbookSizeX or 0
			rows = emitter.FlipbookSizeY or 0
		end

		local img = emitter.FlipbookImageSize or Vector2.zero

		-- Ensure 1x1 still generates a single frame
		if cols == 1 and rows == 1 then
			emitter._frames = 1
			emitter._frameCache = { Vector2.zero }
			emitter._frameSize = img
			return
		end

		-- Number of frames
		emitter._frames = cols * rows

		-- Build ordered list of frame offsets
		local cache = {}

		local cellW = cols > 0 and img.x / cols or 0
		local cellH = rows > 0 and img.y / rows or 0

		for y = 0, rows - 1 do
			for x = 0, cols - 1 do
				table.insert(cache, Vector2.new(x * cellW, y * cellH))
			end
		end

		emitter._frameCache = cache
		emitter._frameSize = Vector2.new(cellW, cellH)
	end

	local ref = React.useRef(nil :: any)
	if not ref.current then
		local emitters, lastProps = {}, {}

		for i = 1, count do
			local initProps = resolveProps(props, i) or {}
			local emitter = Emitter.new(initProps)
			rebuildFlipbook(emitter)
			emitters[i] = emitter
			lastProps[i] = table.clone(initProps)
		end

		ref.current = {
			emitters = emitters,
			lastProps = lastProps,
		}
	end

	React.useEffect(function()
		local emitters = ref.current.emitters
		local lastProps = ref.current.lastProps

		for i = 1, count do
			local newProps = resolveProps(props, i) or {} :: any
			local emitter = emitters[i]

			local flipbookChanged = false

			for key, newValue in newProps do
				local oldValue = lastProps[i][key]
				if newValue ~= oldValue then
					Emitter.Set(emitter, key, newValue)

					-- Update derived internal properties
					if key == "FlipbookImageSize" or key == "FlipbookLayout" or key == "FlipbookSizeX" or key == "FlipbookSizeY" then
						flipbookChanged = true
					end
					if key == "ShapeDimensions" then
						Emitter.Set(emitter, "_center", (newProps.ShapeDimensions or Vector2.one) * 0.5)
					end
				end
			end

			if flipbookChanged then
				rebuildFlipbook(emitter)
			end

			lastProps[i] = table.clone(newProps)
		end
	end, deps)

	local api = React.useMemo(function(): api?
		if isImperative.current then
			return {
				emit = function(callback: (index: number) -> number)
					local emitters = ref.current.emitters
					for i = 1, count do
						local numToEmit = callback(i)
						for _ = 1, numToEmit do
							Emitter.Emit(emitters[i])
						end
					end
				end,
			}
		end
		return
	end, deps or {})

	-- Handle cleanup
	React.useEffect(function()
		return function()
			for _, emitter in ref.current.emitters do
				Emitter.Destroy(emitter)
			end
		end
	end, {})

	return ref.current.emitters, api
end

return (
	useEmitters :: any
) :: ((count: number, props: { EmitterType.EmitterPublic }, deps: { unknown }?) -> emitters) & ((count: number, props: (index: number) -> EmitterType.EmitterPublic, deps: { unknown }?) -> (emitters, api))
