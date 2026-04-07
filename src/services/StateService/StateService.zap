opt server_output = "./network/Server.luau"
opt client_output = "./network/Client.luau"

opt remote_scope = "StateService"
opt casing = "PascalCase"

opt yield_type = "promise"
opt async_lib = "require(game:GetService('ReplicatedStorage').Packages.Promise)"

type addStateData = enum "type" {
    Single {
        object: Instance,
        stateKey: string.utf8,
        duration: f32(0..)?,
    },

    Many {
        object: Instance,
        map: map { [string.utf8]: (f32(0..) | boolean) }
    },
}

event AddState = {
    from: Server,
    type: Reliable,
    call: SingleAsync,
    data: addStateData
}

type removeStateData = enum "type" {
    Single {
        object: Instance,
        stateKey: string.utf8,
    },

    Many {
        object: Instance,
        keys: string.utf8[], 
    },
}

event RemoveState = {
    from: Server,
    type: Reliable,
    call: SingleAsync,
    data: removeStateData
}