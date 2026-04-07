--[[
	InputService

	Client-side service that manages input binding, context filtering, and action signals.
	Supports standard, hold, double-tap, and chord action types, a priority-based
	input consumption model, and a reference-counted context stack.

    @authoer Jutiinian
	@version January 12, 2026
]]

--!optimize 2

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

-- || Client-only guard || --
if not RunService:IsClient() then
	return {} :: InputService
end

-- || Dependencies || --
local Labels = require(script.Labels)
local Signal = require(ReplicatedStorage.Packages.Signal)

-- || Types || --
export type Input = Enum.KeyCode | Enum.UserInputType
export type ActionType = "Default" | "Hold" | "DoubleTap" | "Chord"

--[[
	Options table passed as the third argument to BindAction.

	- context:          Context group this action belongs to. Defaults to "Gameplay".
	- priority:         Input consumption priority. Higher values block lower ones sharing a key. Defaults to 0.
	- type:             Action behavior model. Defaults to "Default".
	- holdDuration:     Seconds the key must be held before "Hold" actions fire Began. Defaults to 0.5.
	- doubleTapWindow:  Maximum seconds between two taps for "DoubleTap" actions to fire. Defaults to 0.3.
]]
export type ActionOptions = {
	context: string?,
	priority: number?,
	type: ActionType?,
	holdDuration: number?,
	doubleTapWindow: number?,
}

export type ActionConfig = {
	keys: { Input },
	context: string,
	priority: number,
	actionType: ActionType,
	holdDuration: number,
	doubleTapWindow: number,
}

--[[
	Signal bundle for a single action.

	Standard (Default / DoubleTap / Chord):
	  Began     — fires when the action activates
	  Ended     — fires when the action deactivates

	Hold-specific (in addition to Began / Ended):
	  HoldPressed   — fires immediately when the key is first pressed, before the
	                  hold duration elapses. Use this to start fill animations or
	                  progress bars.
	  HoldCancelled — fires when the key is released before the hold duration
	                  elapses. Use this to cancel / reverse any animation started
	                  by HoldPressed.
	  (Began fires only once the hold duration is fully satisfied.)
	  (Ended fires when the key is released after Began has fired.)

	Triggered — fires for both Began and Ended with the phase as the first argument.
	            HoldPressed and HoldCancelled are not routed through Triggered.
]]
export type ActionSignals = {
	Began: Signal.ClassicSignal<Input>,
	Ended: Signal.ClassicSignal<Input>,
	Triggered: Signal.ClassicSignal<"Began" | "Ended", Input>,
	HoldPressed: Signal.ClassicSignal<Input>,
	HoldCancelled: Signal.ClassicSignal<Input>,
}

-- || Public API || --
local InputService = {
	_initialized = false,
	_actions = {} :: { [string]: ActionConfig },
	_keyActions = {} :: { [Input]: { string } },
	_signals = {} :: { [string]: ActionSignals },
	_heldKeys = {} :: { [Input]: boolean },
	_heldActions = {} :: { [string]: boolean },
	_heldSince = {} :: { [string]: number },
	_holdTimers = {} :: { [string]: thread },
	_lastTapTime = {} :: { [string]: number },
	-- Context stack: context name → number of active pushes
	_contextStack = { Gameplay = 1 } :: { [string]: number },
}

export type InputService = typeof(InputService)

-- || Private Functions || --
local function _isContextActive(self: InputService, context: string): boolean
	return (self._contextStack[context] or 0) > 0
end

local function _getOrCreateSignals(self: InputService, actionName: string): ActionSignals
	if not self._signals[actionName] then
		self._signals[actionName] = {
			Began = Signal.new(),
			Ended = Signal.new(),
			Triggered = Signal.new() :: Signal.ClassicSignal<"Began" | "Ended", Input>,
			HoldPressed = Signal.new(),
			HoldCancelled = Signal.new(),
		}
	end
	return self._signals[actionName]
end

local function _sortKeyActions(self: InputService, key: Input)
	local list = self._keyActions[key]
	if not list then
		return
	end
	table.sort(list, function(a, b)
		local pa = self._actions[a] and self._actions[a].priority or 0
		local pb = self._actions[b] and self._actions[b].priority or 0
		return pa > pb
	end)
end

local function _bindKeyToAction(self: InputService, actionName: string, key: Input)
	if not self._keyActions[key] then
		self._keyActions[key] = {}
	end
	table.insert(self._keyActions[key], actionName)
	_sortKeyActions(self, key)
end

local function _unbindKeyFromAction(self: InputService, actionName: string, key: Input)
	local list = self._keyActions[key]
	if not list then
		return
	end
	for i = #list, 1, -1 do
		if list[i] == actionName then
			table.remove(list, i)
		end
	end
	if #list == 0 then
		self._keyActions[key] = nil
	end
end

local function _resolveInput(input: InputObject): Input
	if input.UserInputType == Enum.UserInputType.Keyboard then
		return input.KeyCode
	end
	return input.UserInputType
end

local function _cancelHoldTimer(self: InputService, actionName: string)
	local thread = self._holdTimers[actionName]
	if thread then
		task.cancel(thread)
		self._holdTimers[actionName] = nil
	end
end

local function _isChordSatisfied(self: InputService, keys: { Input }): boolean
	for _, key in ipairs(keys) do
		if not self._heldKeys[key] then
			return false
		end
	end
	return true
end

local function _beginAction(self: InputService, actionName: string, key: Input)
	self._heldActions[actionName] = true
	self._heldSince[actionName] = os.clock()
	local bundle = self._signals[actionName]
	if bundle then
		bundle.Began:Fire(key)
		bundle.Triggered:Fire("Began", key)
	end
end

local function _endAction(self: InputService, actionName: string, key: Input)
	if not self._heldActions[actionName] then
		return
	end
	self._heldActions[actionName] = nil
	self._heldSince[actionName] = nil
	local bundle = self._signals[actionName]
	if bundle then
		bundle.Ended:Fire(key)
		bundle.Triggered:Fire("Ended", key)
	end
end

local function _processInputBegan(self: InputService, key: Input)
	local list = self._keyActions[key]
	if not list then
		return
	end

	for _, actionName in ipairs(list) do
		local action = self._actions[actionName]
		if not action then
			continue
		end
		if not _isContextActive(self, action.context) then
			continue
		end

		if action.actionType == "Default" then
			_beginAction(self, actionName, key)
		elseif action.actionType == "Hold" then
			-- Fire HoldPressed immediately so callers can start animations right away
			local bundle = self._signals[actionName]
			if bundle then
				bundle.HoldPressed:Fire(key)
			end

			self._holdTimers[actionName] = task.delay(action.holdDuration, function()
				self._holdTimers[actionName] = nil
				-- Only complete if the key is still physically held
				if self._heldKeys[key] and _isContextActive(self, action.context) then
					_beginAction(self, actionName, key)
				end
			end)
		elseif action.actionType == "DoubleTap" then
			local now = os.clock()
			local last = self._lastTapTime[actionName]
			if last and (now - last) <= action.doubleTapWindow then
				self._lastTapTime[actionName] = nil
				_beginAction(self, actionName, key)
			else
				self._lastTapTime[actionName] = now
			end
		elseif action.actionType == "Chord" then
			if _isChordSatisfied(self, action.keys) then
				_beginAction(self, actionName, key)
			end
		end

		if action.priority > 0 then
			break
		end
	end
end

local function _processInputEnded(self: InputService, key: Input)
	local list = self._keyActions[key]
	if not list then
		return
	end

	for _, actionName in ipairs(list) do
		local action = self._actions[actionName]
		if not action then
			continue
		end

		if action.actionType == "Hold" then
			local timerWasRunning = self._holdTimers[actionName] ~= nil
			_cancelHoldTimer(self, actionName)

			if timerWasRunning then
				-- Key released before the duration elapsed — fire HoldCancelled
				local bundle = self._signals[actionName]
				if bundle then
					bundle.HoldCancelled:Fire(key)
				end
			else
				-- Duration had already elapsed and Began fired — fire Ended normally
				_endAction(self, actionName, key)
			end
		elseif action.actionType == "Default" or action.actionType == "DoubleTap" or action.actionType == "Chord" then
			_endAction(self, actionName, key)
		end
	end
end

--[[
	Initializes the InputService by connecting input events.

	This should be called once when the client starts. Subsequent calls are no-ops.
	Listens to InputBegan and InputEnded, ignoring held-key repeat fires and inputs
	already consumed by Roblox's UI layer.

	Examples:
	```lua
	InputService:Init()
	```

	Note: Must be called before any bindings, queries, or context operations.
]]
function InputService.Init(self: InputService)
	if self._initialized then
		return
	end
	self._initialized = true

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		local key = _resolveInput(input)
		if self._heldKeys[key] then
			return
		end -- suppress repeat fires from held keys
		self._heldKeys[key] = true
		_processInputBegan(self, key)
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		local key = _resolveInput(input)
		self._heldKeys[key] = nil
		_processInputEnded(self, key)
	end)
end

--[[
	Pushes a context onto the stack, enabling it.

	The context is reference-counted: multiple systems can push the same context
	independently, and the context only deactivates once every push has been matched
	by a corresponding PopContext call. This prevents one system accidentally
	re-enabling a context that another system intentionally disabled.

	@param context string The name of the context to push

	Examples:
	```lua
	-- Suppress gameplay input while a menu is open
	InputService:PopContext("Gameplay")
	InputService:PushContext("Menu")

	-- Restore on close
	InputService:PopContext("Menu")
	InputService:PushContext("Gameplay")
	```
]]
function InputService.PushContext(self: InputService, context: string)
	self._contextStack[context] = (self._contextStack[context] or 0) + 1
end

--[[
	Pops one reference to a context from the stack.

	The context deactivates only when its reference count reaches zero.
	No-op if the context is not currently pushed.

	@param context string The name of the context to pop

	Examples:
	```lua
	InputService:PopContext("Gameplay")
	```
]]
function InputService.PopContext(self: InputService, context: string)
	local count = self._contextStack[context]
	if not count then
		return
	end

	if count <= 1 then
		self._contextStack[context] = nil
	else
		self._contextStack[context] = count - 1
	end
end

--[[
	Returns whether the given context is currently active.

	A context is active when it has been pushed at least once without a matching pop.

	@param context string The name of the context to check
	@return boolean True if the context has at least one active push

	Examples:
	```lua
	if InputService:IsContextActive("Menu") then
		print("Menu input context is active")
	end
	```
]]
function InputService.IsContextActive(self: InputService, context: string): boolean
	return _isContextActive(self, context)
end

--[[
	Returns a list of all currently active context names.

	@return { string } Array of context names with at least one active push

	Examples:
	```lua
	for _, context in ipairs(InputService:GetActiveContexts()) do
		print(context, "is active")
	end
	```
]]
function InputService.GetActiveContexts(self: InputService): { string }
	local result = {}
	for context, count in pairs(self._contextStack) do
		if count > 0 then
			table.insert(result, context)
		end
	end
	return result
end

--[[
	Binds one or more keys to a named action.

	Behavior is controlled by the options table:
	- "Default"   — fires Began on press, Ended on release.
	- "Hold"      — fires HoldPressed immediately on key down, then Began once the key
	                has been held for holdDuration seconds. If the key is released before
	                the duration elapses, fires HoldCancelled instead. Ended fires on
	                release only after Began has fired.
	- "DoubleTap" — fires Began on the second press within doubleTapWindow seconds.
	- "Chord"     — fires Began when all keys in the binding are held simultaneously.
	                Ended fires when any key in the chord is released.

	@param actionName string Unique identifier for this action
	@param keys { Input } One or more Enum.KeyCode or Enum.UserInputType values
	@param options ActionOptions? Configuration table (see ActionOptions type)

	Examples:
	```lua
	-- Standard press
	InputService:BindAction("Jump", { Enum.KeyCode.Space })

	-- Proximity prompt style: hold E for 0.8s to interact
	InputService:BindAction("Interact", { Enum.KeyCode.E }, {
		type = "Hold",
		holdDuration = 0.8,
	})

	-- Double-tap W to dash
	InputService:BindAction("Dash", { Enum.KeyCode.W }, {
		type = "DoubleTap",
		doubleTapWindow = 0.25,
	})

	-- Ctrl+Z chord
	InputService:BindAction("Undo", { Enum.KeyCode.LeftControl, Enum.KeyCode.Z }, {
		type = "Chord",
		priority = 5,
	})
	```

	Note: Throws if an action with the same name is already bound. Call UnbindAction first.
]]
function InputService.BindAction(self: InputService, actionName: string, keys: { Input }, options: ActionOptions?)
	assert(self._actions[actionName] == nil, `InputService.BindAction: "{actionName}" is already bound. Call UnbindAction first.`)
	assert(#keys > 0, `InputService.BindAction: "{actionName}" must have at least one key.`)

	local opts = options or {}
	local context = opts.context or "Gameplay"
	local priority = opts.priority or 0
	local aType = opts.type or "Default"
	local holdDur = opts.holdDuration or 0.5
	local tapWindow = opts.doubleTapWindow or 0.3

	self._actions[actionName] = {
		keys = keys,
		context = context,
		priority = priority,
		actionType = aType,
		holdDuration = holdDur,
		doubleTapWindow = tapWindow,
	}

	for _, key in ipairs(keys) do
		_bindKeyToAction(self, actionName, key)
	end
end

--[[
	Removes a bound action and destroys all of its associated signals.

	Also cancels any in-progress hold timers and removes the context reference
	that was pushed when the action was bound.

	No-op if the action does not exist.

	@param actionName string The name of the action to remove

	Examples:
	```lua
	InputService:UnbindAction("Interact")
	InputService:UnbindAction("Jump")
	```
]]
function InputService.UnbindAction(self: InputService, actionName: string)
	local action = self._actions[actionName]
	if not action then
		return
	end

	_cancelHoldTimer(self, actionName)

	for _, key in ipairs(action.keys) do
		_unbindKeyFromAction(self, actionName, key)
	end

	self._heldActions[actionName] = nil
	self._heldSince[actionName] = nil
	self._lastTapTime[actionName] = nil
	self._actions[actionName] = nil

	local bundle = self._signals[actionName]
	if bundle then
		bundle.Began:Destroy()
		bundle.Ended:Destroy()
		bundle.Triggered:Destroy()
		bundle.HoldPressed:Destroy()
		bundle.HoldCancelled:Destroy()
		self._signals[actionName] = nil
	end
end

--[[
	Rebinds an existing action to a new set of keys.

	The action's context, priority, and type are preserved. Existing signal
	connections remain valid and will fire for the new keys going forward.
	Any in-progress hold timer is cancelled.

	@param actionName string The name of the action to rebind
	@param newKeys { Input } The replacement set of keys to bind

	Examples:
	```lua
	-- Player remaps their interact key in settings
	InputService:RebindAction("Interact", { Enum.KeyCode.F })

	-- Add gamepad support to an existing action
	InputService:RebindAction("Interact", { Enum.KeyCode.E, Enum.KeyCode.ButtonX })
	```

	Note: Throws if the action does not exist.
]]
function InputService.RebindAction(self: InputService, actionName: string, newKeys: { Input })
	local action = self._actions[actionName]
	assert(action, `InputService.RebindAction: "{actionName}" does not exist.`)
	assert(#newKeys > 0, `InputService.RebindAction: must provide at least one key.`)

	_cancelHoldTimer(self, actionName)

	for _, key in ipairs(action.keys) do
		_unbindKeyFromAction(self, actionName, key)
	end

	action.keys = newKeys

	for _, key in ipairs(newKeys) do
		_bindKeyToAction(self, actionName, key)
	end
end

--[[
	Returns a Signal that fires when the specified action activates.

	For "Default" / "Chord" actions: fires on key press.
	For "Hold" actions: fires only after the full hold duration elapses, not on initial press.
	                    Use GetHoldPressedSignal to react to the initial press.
	For "DoubleTap" actions: fires on the qualifying second press.

	@param actionName string The name of the action to subscribe to
	@return Signal<Input> Fires with the Input that triggered the action

	Examples:
	```lua
	InputService:GetActionBegan("Jump"):Connect(function()
		character:Jump()
	end)

	-- Fires only after the full hold duration
	InputService:GetActionBegan("Interact"):Connect(function()
		interactSystem:Complete()
	end)
	```

	Note: Throws if the action does not exist.
]]
function InputService.GetActionBegan(self: InputService, actionName: string): Signal.ClassicSignal<Input>
	assert(self._actions[actionName], `InputService.GetActionBegan: "{actionName}" does not exist.`)
	return _getOrCreateSignals(self, actionName).Began
end

--[[
	Returns a Signal that fires when the specified action deactivates.

	For "Hold" actions: only fires if Began had already fired (i.e. the hold was completed).
	                    Releasing before the duration elapses fires HoldCancelled instead.

	@param actionName string The name of the action to subscribe to
	@return Signal<Input> Fires with the Input that ended the action

	Examples:
	```lua
	InputService:GetActionEnded("Sprint"):Connect(function()
		character:StopSprinting()
	end)
	```

	Note: Throws if the action does not exist.
]]
function InputService.GetActionEnded(self: InputService, actionName: string): Signal.ClassicSignal<Input>
	assert(self._actions[actionName], `InputService.GetActionEnded: "{actionName}" does not exist.`)
	return _getOrCreateSignals(self, actionName).Ended
end

--[[
	Returns a unified Signal that fires for both the Began and Ended phases of an action.

	HoldPressed and HoldCancelled are not routed through this signal.

	@param actionName string The name of the action to subscribe to
	@return Signal<"Began" | "Ended", Input> Fires with the phase and triggering Input

	Examples:
	```lua
	InputService:GetActionTriggered("Sprint"):Connect(function(phase, input)
		if phase == "Began" then
			character:StartSprinting()
		else
			character:StopSprinting()
		end
	end)
	```

	Note: Throws if the action does not exist.
]]
function InputService.GetActionTriggered(self: InputService, actionName: string): Signal.ClassicSignal<"Began" | "Ended", Input>
	assert(self._actions[actionName], `InputService.GetActionTriggered: "{actionName}" does not exist.`)
	return _getOrCreateSignals(self, actionName).Triggered
end

--[[
	Returns a Signal that fires immediately when the key for a Hold action is pressed.

	This fires before the hold duration elapses and is intended for starting
	progress animations, fill bars, or any visual feedback that should begin
	on the initial press rather than on completion.

	Only meaningful for actions with type = "Hold". For other action types the
	signal exists but will never fire.

	@param actionName string The name of the Hold action
	@return Signal<Input> Fires with the Input on initial key press

	Examples:
	```lua
	-- Proximity prompt: start fill animation immediately on press
	InputService:GetHoldPressedSignal("Interact"):Connect(function()
		promptUI:PlayFillAnimation(holdDuration)
	end)

	InputService:GetActionBegan("Interact"):Connect(function()
		-- Hold completed — trigger the actual interaction
		interactSystem:Complete()
	end)

	InputService:GetHoldCancelledSignal("Interact"):Connect(function()
		-- Released early — cancel the animation
		promptUI:CancelFillAnimation()
	end)
	```

	Note: Throws if the action does not exist.
]]
function InputService.GetHoldPressedSignal(self: InputService, actionName: string): Signal.ClassicSignal<Input>
	assert(self._actions[actionName], `InputService.GetHoldPressedSignal: "{actionName}" does not exist.`)
	return _getOrCreateSignals(self, actionName).HoldPressed
end

--[[
	Returns a Signal that fires when a Hold action's key is released before the
	hold duration has elapsed.

	Use this to cancel or reverse any animations or UI feedback started by
	GetHoldPressedSignal. This signal will not fire if the hold was completed
	(i.e. if Began has already fired).

	Only meaningful for actions with type = "Hold". For other action types the
	signal exists but will never fire.

	@param actionName string The name of the Hold action
	@return Signal<Input> Fires with the Input when the hold is cancelled early

	Examples:
	```lua
	InputService:GetHoldCancelledSignal("Interact"):Connect(function()
		promptUI:CancelFillAnimation()
	end)
	```

	Note: Throws if the action does not exist.
]]
function InputService.GetHoldCancelledSignal(self: InputService, actionName: string): Signal.ClassicSignal<Input>
	assert(self._actions[actionName], `InputService.GetHoldCancelledSignal: "{actionName}" does not exist.`)
	return _getOrCreateSignals(self, actionName).HoldCancelled
end

--[[
	Returns whether the specified action is currently active.

	For "Hold" actions this is only true after the hold duration has elapsed
	and Began has fired — not while the key is being held but the timer is
	still counting down.

	@param actionName string The name of the action to check
	@return boolean True if the action is currently active

	Examples:
	```lua
	RunService.Heartbeat:Connect(function(dt)
		if InputService:IsActionHeld("Sprint") then
			character:ApplySprintVelocity(dt)
		end
	end)
	```
]]
function InputService.IsActionHeld(self: InputService, actionName: string): boolean
	return self._heldActions[actionName] == true
end

--[[
	Returns whether the specified raw key or button is currently physically held,
	regardless of any action bindings, contexts, or action types.

	@param key Input The Enum.KeyCode or Enum.UserInputType to check
	@return boolean True if the key is held

	Examples:
	```lua
	if InputService:IsKeyHeld(Enum.KeyCode.LeftShift) then
		print("Shift is held")
	end
	```
]]
function InputService.IsKeyHeld(self: InputService, key: Input): boolean
	return self._heldKeys[key] == true
end

--[[
	Returns whether a Hold action's key is currently held but the duration has
	not yet elapsed (i.e. the action is pending, between HoldPressed and Began).

	Useful for driving a progress bar purely from a boolean check rather than
	connecting to signals.

	@param actionName string The name of the Hold action to check
	@return boolean True if the hold timer is actively counting down

	Examples:
	```lua
	RunService.Heartbeat:Connect(function()
		if InputService:IsHoldPending("Interact") then
			local progress = InputService:GetActionHeldDuration("Interact") / holdDuration
			progressBar:SetFill(progress)
		end
	end)
	```
]]
function InputService.IsHoldPending(self: InputService, actionName: string): boolean
	return self._holdTimers[actionName] ~= nil
end

--[[
	Returns how many seconds the specified action has been continuously active.

	For "Hold" actions the timer starts when Began fires (after the hold duration
	elapses), not from the initial key press. Use GetHoldPressDuration for the
	time since the key was first pressed.

	@param actionName string The name of the action to query
	@return number Seconds elapsed since the action began, or 0 if not active

	Examples:
	```lua
	-- Scale damage by how long a charge attack has been held
	local charge = InputService:GetActionHeldDuration("ChargeAttack")
	local damage = math.min(charge / maxChargeTime, 1) * maxDamage
	```
]]
function InputService.GetActionHeldDuration(self: InputService, actionName: string): number
	local since = self._heldSince[actionName]
	if not since then
		return 0
	end
	return os.clock() - since
end

--[[
	Returns a list of all action names that are currently active.

	@return { string } Array of currently active action names

	Examples:
	```lua
	for _, actionName in ipairs(InputService:GetHeldActions()) do
		print(actionName, "has been held for", InputService:GetActionHeldDuration(actionName), "s")
	end
	```
]]
function InputService.GetHeldActions(self: InputService): { string }
	local result = {}
	for actionName in pairs(self._heldActions) do
		table.insert(result, actionName)
	end
	return result
end

--[[
	Returns a human-readable label for the first key bound to an action.

	Useful for UI hints that need to display the current binding, and automatically
	reflects changes made via RebindAction.

	@param actionName string The name of the action to get a label for
	@return string? A friendly label such as "Space", "LMB", or "A",
	                  or nil if the action does not exist

	Examples:
	```lua
	local label = InputService:GetInputLabel("Interact")
	promptLabel.Text = `Press [{label}] to interact`

	-- Automatically updates after a rebind
	InputService:RebindAction("Interact", { Enum.KeyCode.F })
	promptLabel.Text = `Press [{InputService:GetInputLabel("Interact")}] to interact`
	```
]]
function InputService.GetInputLabel(self: InputService, actionName: string): string?
	local action = self._actions[actionName]
	if not action or #action.keys == 0 then
		return nil
	end

	local key = action.keys[1]

	if typeof(key) == "EnumItem" and key.EnumType == Enum.UserInputType then
		return Labels.INPUT_TYPE_LABELS[key :: Enum.UserInputType] or (key :: Enum.UserInputType).Name
	end

	local gamepadLabel = Labels.GAMEPAD_KEY_LABELS[key :: Enum.KeyCode]
	if gamepadLabel then
		return gamepadLabel
	end

	local keyLabel = Labels.KEY_LABELS[key :: Enum.KeyCode]
	if keyLabel then
		return keyLabel
	end

	return (key :: Enum.KeyCode).Name
end

--[[
	Returns the keys currently bound to an action.

	@param actionName string The name of the action to query
	@return { Input }? The bound keys, or nil if the action does not exist

	Examples:
	```lua
	local keys = InputService:GetBoundKeys("Jump")
	if keys then
		for _, key in ipairs(keys) do
			print("Jump is bound to:", key)
		end
	end
	```
]]
function InputService.GetBoundKeys(self: InputService, actionName: string): { Input }?
	local action = self._actions[actionName]
	return action and action.keys or nil
end

--[[
	Returns whether an action with the given name is currently bound.

	@param actionName string The name of the action to check
	@return boolean True if the action exists

	Examples:
	```lua
	if not InputService:ActionExists("Jump") then
		InputService:BindAction("Jump", { Enum.KeyCode.Space })
	end
	```
]]
function InputService.ActionExists(self: InputService, actionName: string): boolean
	return self._actions[actionName] ~= nil
end

return InputService
