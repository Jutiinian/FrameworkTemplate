--!strict

local DEFAULT_SAMPLE_COUNT = 16

type OffsetMode = "wrap" | "clamp"
type SampleMethod = "linear" | "nearest"
type Direction = "forward" | "backward"

export type OffsetColorSequenceOptions = {
	sampleCount: number?,
	offsetMode: OffsetMode?,
	sampleMethod: SampleMethod?,
	direction: Direction?,
}

local function normalizeTime(time: number, mode: OffsetMode): number
	if mode == "clamp" then
		return math.clamp(time, 0, 1)
	end

	return time % 1
end

local function getNearestColor(sequence: ColorSequence, time: number): Color3
	local keypoints = sequence.Keypoints
	local nearest = keypoints[1]
	local nearestDistance = math.abs(time - nearest.Time)

	for i = 2, #keypoints do
		local keypoint = keypoints[i]
		local distance = math.abs(time - keypoint.Time)
		if distance < nearestDistance then
			nearest = keypoint
			nearestDistance = distance
		end
	end

	return nearest.Value
end

--- Linearly interpolate a ColorSequence at an arbitrary time (0–1).
local function sampleColorSequence(sequence: ColorSequence, time: number, sampleMethod: SampleMethod): Color3
	if sampleMethod == "nearest" then
		return getNearestColor(sequence, time)
	end

	local keypoints = sequence.Keypoints

	if time <= keypoints[1].Time then
		return keypoints[1].Value
	end
	if time >= keypoints[#keypoints].Time then
		return keypoints[#keypoints].Value
	end

	for i = 1, #keypoints - 1 do
		local curr = keypoints[i]
		local next = keypoints[i + 1]
		if time >= curr.Time and time <= next.Time then
			local alpha = (time - curr.Time) / (next.Time - curr.Time)
			return curr.Value:Lerp(next.Value, alpha)
		end
	end

	return keypoints[#keypoints].Value
end

local function offsetColorSequence(sequence: ColorSequence, offset: number, options: OffsetColorSequenceOptions?): ColorSequence
	local sampleCount = if options and options.sampleCount ~= nil
		then math.max(1, math.floor(options.sampleCount))
		else DEFAULT_SAMPLE_COUNT
	local offsetMode: OffsetMode = if options and options.offsetMode ~= nil then options.offsetMode else "wrap"
	local sampleMethod: SampleMethod = if options and options.sampleMethod ~= nil then options.sampleMethod else "linear"
	local direction: Direction = if options and options.direction ~= nil then options.direction else "backward"

	local keypoints = table.create(sampleCount + 1)

	for i = 0, sampleCount do
		local t = i / sampleCount
		local shiftedTime = if direction == "forward" then t + offset else t - offset
		local sampleT = normalizeTime(shiftedTime, offsetMode)
		local color = sampleColorSequence(sequence, sampleT, sampleMethod)
		keypoints[i + 1] = ColorSequenceKeypoint.new(t, color)
	end

	return ColorSequence.new(keypoints)
end

return offsetColorSequence
