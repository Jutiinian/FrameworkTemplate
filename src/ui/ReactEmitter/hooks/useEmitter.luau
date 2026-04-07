local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EmitterType = require(script.Parent.Parent.core.EmitterType)
local React = require(ReplicatedStorage.Packages.React)
local useEmitters = require(script.Parent.useEmitters)

--[=[
	@function useEmitter
	@within ReactEmitter
	@param props EmitterProps | () -> EmitterProps -- Using a function will enable the Imperative API
	@return Emitter
	@return { emit: (number) -> () }? -- Imperative API if props was a function
]=]
local function useEmitter(props: useEmitters.props, deps: { unknown }?): (EmitterType._Emitter, { emit: (number) -> () })
	local emitters, parentApi = (useEmitters :: any)(1, props, deps)

	local api = React.useMemo(function(): { emit: (number) -> () }?
		if parentApi then
			return {
				emit = function(numToEmit: number)
					parentApi.emit(function()
						return numToEmit
					end)
				end,
			}
		end
		return
	end, deps or {})

	return emitters[1], api :: any
end

return (
	useEmitter :: any
) :: ((props: { EmitterType.EmitterPublic }, deps: { unknown }?) -> EmitterType._Emitter) & ((props: () -> EmitterType.EmitterPublic) -> (EmitterType._Emitter, { emit: (number) -> () }))
