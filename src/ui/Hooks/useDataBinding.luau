--!optimize 2
--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local DataServiceClient = require(ReplicatedStorage.Services.DataService.DataServiceClient)
local Promise = require(ReplicatedStorage.Packages.Promise)
local React = require(ReplicatedStorage.Packages.React)

-- || Variables || --
local useBinding = React.useBinding
local useEffect = React.useEffect

-- || Hook || --
return function(key: string | { string }, onChange: nil | (value: any) -> (), initialValue: any?)
	local value, setValue = useBinding(initialValue)

	useEffect(function()
		local signalConnection

		local dataPromise = DataServiceClient:WaitForDataAsync()
			:andThen(function()
				setValue(DataServiceClient:Get(key))
				if onChange then
					onChange(DataServiceClient:Get(key))
				end

				signalConnection = DataServiceClient:GetValueChangedSignal(key):Connect(function(newValue)
					setValue(newValue)
					if onChange then
						onChange(newValue)
					end
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
