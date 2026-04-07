--!optimize 2
--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local DataServiceClient = require(ReplicatedStorage.Services.DataService.DataServiceClient)
local Promise = require(ReplicatedStorage.Packages.Promise)
local React = require(ReplicatedStorage.Packages.React)

-- || Variables || --
local useState = React.useState
local useEffect = React.useEffect

-- || Hook || --
return function(key: string | { string }, initialValue: any?)
	local value, setValue = useState(initialValue)

	useEffect(function()
		local signalConnection

		local dataPromise = DataServiceClient:WaitForDataAsync()
			:andThen(function()
				local currentValue = DataServiceClient:Get(key)
				setValue(currentValue)

				signalConnection = DataServiceClient:GetValueChangedSignal(key):Connect(function(newValue)
					setValue(newValue)
				end)
			end)
			:catch(warn)

		return function()
			if dataPromise:getStatus() == Promise.Status.Started then
				dataPromise:cancel()
			end

			if signalConnection then
				signalConnection:Disconnect()
			end
		end
	end, { key })

	return value
end
