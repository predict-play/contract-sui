module predictplay::yes_coin;

use sui::coin;

/// A one-time witness to YES tokens
/// Must match the module name (uppercase) and only has drop ability
public struct YES_COIN has drop {}

/// Initialize, create YES coin
fun init(witness: YES_COIN, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency<YES_COIN>(
        witness,
        9, // 9 decimals like SUI
        b"YES",
        b"YES Outcome Token",
        b"Global prediction market YES outcome token",
        option::none(),
        ctx,
    );

    // Transfer treasury cap to sender
    transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
    // Freeze metadata object
    transfer::public_freeze_object(metadata);
}

#[test_only]
/// Create treasury cap for testing
public fun create_treasury_cap_for_testing(ctx: &mut TxContext): coin::TreasuryCap<YES_COIN> {
    let (treasury_cap, metadata) = coin::create_currency<YES_COIN>(
        YES_COIN {},
        9,
        b"YES",
        b"YES Outcome Token",
        b"Global prediction market YES outcome token",
        option::none(),
        ctx,
    );

    transfer::public_freeze_object(metadata);
    treasury_cap
}
