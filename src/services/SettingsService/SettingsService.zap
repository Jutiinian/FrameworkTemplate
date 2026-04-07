opt server_output = "./network/Server.luau"
opt client_output = "./network/Client.luau"

opt remote_scope = "SettingsService"
opt casing = "PascalCase"

opt yield_type = "promise"
opt async_lib = "require(game:GetService('ReplicatedStorage').Packages.Promise)"

opt disable_fire_all = true

type Value = (
	f64
	| boolean
	| string.utf8
	| unknown
)

event Sync = {
	from: Server,
	type: Reliable,
	call: SingleAsync,
	data: map { [string.utf8]: Value },
}

type indexPath = enum "Type" {
    String { value: string.utf8 },
    Table { value: string.utf8[] },
}

event Update = {
	from: Server,
	type: Reliable,
	call: SingleAsync,
	data: struct {
		Key: string.utf8,
		Value: Value
	}
}

event Save = {
    from: Client,
    type: Reliable,
    call: SingleAsync,
    data: map { [string.utf8]: Value }
}