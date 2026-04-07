-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local Signal = require(ReplicatedStorage.Packages.Signal)

export type StateData = {
	ExpiresAt: number?,
	Duration: number?,
	Paused: boolean?,
	PausedRemaining: number?,
}

export type Object = Player | Instance

export type Disconnect = () -> ()
export type ObserveCallback = (active: boolean, remaining: number?, totalDuration: number?) -> Disconnect?
export type ObserveManyCallback = (stateKey: string, active: boolean, remaining: number?, totalDuration: number?) -> Disconnect?

export type ReadOnlySignal<T...> = {
	Connect: (self: ReadOnlySignal<T...>, callback: (T...) -> ()) -> Signal.Connection,
	Once: (self: ReadOnlySignal<T...>, callback: (T...) -> ()) -> Signal.Connection,
	Wait: (self: ReadOnlySignal<T...>) -> T...,
}

export type OnActivatedSignal = ReadOnlySignal<number?, number?>
export type OnDeactivatedSignal = ReadOnlySignal<>

return {}
