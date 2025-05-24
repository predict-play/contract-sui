module predictplay::no_coin {
    use sui::coin;
    use sui::transfer;
    use sui::tx_context::TxContext;
    use std::option;

    /// A one-time witness to NO tokens
    /// Must match the module name (uppercase) and only has drop ability
    public struct NO_COIN has drop {}

    /// Initialize, create NO coin
    fun init(witness: NO_COIN, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency<NO_COIN>(
            witness,
            9, // 9 decimals like SUI
            b"NO",
            b"NO Outcome Token",
            b"Global prediction market NO outcome token",
            option::none(),
            ctx
        );

        // Transfer treasury cap to sender
        transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
        // Freeze metadata object
        transfer::public_freeze_object(metadata);
    }

    #[test_only]
    /// Create treasury cap for testing
    public fun create_treasury_cap_for_testing(ctx: &mut TxContext): coin::TreasuryCap<NO_COIN> {
        let (treasury_cap, metadata) = coin::create_currency<NO_COIN>(
            NO_COIN {},
            9,
            b"NO",
            b"NO Outcome Token",
            b"Global prediction market NO outcome token",
            option::none(),
            ctx
        );

        transfer::public_freeze_object(metadata);
        treasury_cap
    }
}
