opt server_output = "./network/Server.luau"
opt client_output = "./network/Client.luau"

opt remote_scope = "MarketService"
opt casing = "PascalCase"

opt yield_type = "promise"
opt async_lib = "require(game:GetService('ReplicatedStorage').Promise)"

opt disable_fire_all = false

event InitializeMarketData = {
    from: Server,
    type: Reliable,
    call: SingleAsync,
    data: map { [string.utf8]: boolean }
}

event SetMarketData = {
    from: Server,
    type: Reliable,
    call: SingleAsync,
    data: (Index: string.utf8, Value: boolean)
}

event AddGamePass = {
    from: Server,
    type: Reliable,
    call: SingleAsync,
    data: (Name: string.utf8, idData: struct {
        ID: f64,
        GiftID: f64?,
    })
}

event AddDevProduct = {
    from: Server,
    type: Reliable,
    call: SingleAsync,
    data: (Name: string.utf8, ID: f64)
}

funct RequestGiftPurchase = {
    call: Async,
    args: (Recipient: string.utf8, ProductID: string.utf8),
    rets: boolean
}