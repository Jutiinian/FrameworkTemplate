--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- || Dependencies || --
local Janitor = require(ReplicatedStorage.Packages.Janitor)
local Signal = require(ReplicatedStorage.Packages.Signal)

-- || Constants/Variables || --
local SCAN_COLOR = Color3.fromRGB(200, 0, 0)
local IDLE_COLOR = Color3.fromRGB(0, 200, 0)

-- || Types || --
export type HitResult = {
	Character: Model,
	Humanoid: Humanoid,
	HumanoidRootPart: BasePart,
}

-- || Private Functions || --
local function resolveCharacter(part: BasePart): (Model?, Humanoid?, BasePart?)
	local character = part:FindFirstAncestorOfClass("Model")
	if not character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	return character, humanoid, hrp
end

local function queryOverlap(part: BasePart, overlapParams: OverlapParams): { HitResult }
	local results: { HitResult } = {}
	local seen: { [Model]: true } = {}

	for _, hitPart in workspace:GetPartsInPart(part, overlapParams) do
		local character, humanoid, hrp = resolveCharacter(hitPart)
		if character and humanoid and hrp and not seen[character] then
			seen[character] = true
			table.insert(results, {
				Character = character,
				Humanoid = humanoid,
				HumanoidRootPart = hrp,
			})
		end
	end

	return results
end

-- || Public API || --
local Hitbox = {}
Hitbox.__index = Hitbox

export type Hitbox = typeof(setmetatable(
	{} :: {
		_janitor: Janitor.Janitor,
		_queryJanitor: Janitor.Janitor,

		_part: BasePart,

		_overlapParams: OverlapParams,
		_hitBuffer: { [Model]: true },

		_isDebugMode: boolean,
		_isActive: boolean,

		Hit: Signal.ClassicSignal<HitResult>,
	},
	Hitbox
))

Hitbox.new = function(debugMode: boolean?): Hitbox
	local self = setmetatable({}, Hitbox) :: Hitbox

	self._janitor = Janitor.new()
	self._queryJanitor = self._janitor:AddObject(Janitor, "Destroy", "QueryJanitor") :: Janitor.Janitor

	self.Hit = self._janitor:AddObject(Signal, "Destroy", "HitSignal")

	self._isDebugMode = debugMode == true
	self._hitBuffer = {}
	self._isActive = false

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = {}
	self._overlapParams = overlapParams

	local hitboxPart = self._janitor:Add(Instance.new("Part"), "Destroy") :: BasePart
	hitboxPart.CanCollide = false
	hitboxPart.CastShadow = false
	hitboxPart.CanQuery = true
	hitboxPart.Anchored = true
	hitboxPart.Material = Enum.Material.ForceField
	hitboxPart.Transparency = self._isDebugMode and 0.7 or 1
	hitboxPart.Color = IDLE_COLOR
	hitboxPart.Size = Vector3.one
	hitboxPart.Name = "Hitbox"
	hitboxPart.Parent = workspace
	self._part = hitboxPart

	return self
end

function Hitbox.SetSize(self: Hitbox, size: Vector3)
	self._part.Size = size
end

function Hitbox.GetSize(self: Hitbox): Vector3
	return self._part.Size
end

function Hitbox.SetCFrame(self: Hitbox, cframe: CFrame)
	self._part.CFrame = cframe
end

function Hitbox.GetCFrame(self: Hitbox): CFrame
	return self._part.CFrame
end

function Hitbox.AttachTo(self: Hitbox, part: BasePart, offset: CFrame?)
	-- TODO: Possibly switch to weld
	self._queryJanitor:Add(
		RunService.Heartbeat:Connect(function()
			self._part.CFrame = part.CFrame * (offset or CFrame.identity)
		end),
		"Disconnect",
		"AttachConnection"
	)
end

function Hitbox.AddToFilter(self: Hitbox, instances: { Instance } | Instance)
	if typeof(instances) == "Instance" then
		self._overlapParams:AddToFilter({ instances } :: { Instance })
	else
		self._overlapParams:AddToFilter(instances :: { Instance })
	end
end

function Hitbox.SetFilter(self: Hitbox, instances: { Instance })
	self._overlapParams.FilterDescendantsInstances = instances
end

function Hitbox.ClearFilter(self: Hitbox)
	self._overlapParams.FilterDescendantsInstances = {}
end

function Hitbox.BindToCharacter(self: Hitbox, character: Model)
	self._overlapParams:AddToFilter(character)
end

function Hitbox.Cast(self: Hitbox): { HitResult }
	return queryOverlap(self._part, self._overlapParams)
end

function Hitbox.Start(self: Hitbox)
	if self._isActive then
		return
	end

	self._isActive = true
	self._hitBuffer = {}

	if self._isDebugMode then
		self._part.Color = SCAN_COLOR
	end

	self._queryJanitor:Add(
		RunService.Heartbeat:Connect(function()
			for _, result in queryOverlap(self._part, self._overlapParams) do
				if not self._hitBuffer[result.Character] then
					self._hitBuffer[result.Character] = true
					self.Hit:Fire(result)
				end
			end
		end),
		"Disconnect",
		"QueryConnection"
	)
end

function Hitbox.Stop(self: Hitbox)
	if not self._isActive then
		return
	end

	self._isActive = false
	self._hitBuffer = {}

	if self._isDebugMode then
		self._part.Color = IDLE_COLOR
	end

	self._queryJanitor:Remove("QueryConnection")
end

function Hitbox.GetClosestTarget(self: Hitbox, relativePosition: Vector3?): HitResult?
	local origin = relativePosition or self._part.Position
	local closest: HitResult? = nil
	local closestDist = math.huge

	for _, result in self:Cast() do
		local dist = (result.HumanoidRootPart.Position - origin).Magnitude
		if dist < closestDist then
			closestDist = dist
			closest = result
		end
	end

	return closest
end

function Hitbox.Destroy(self: Hitbox)
	self._janitor:Cleanup()
end

return Hitbox
