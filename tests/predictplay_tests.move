#[test_only]
module predictplay::predictplay_tests {
    use sui::clock::{Self, Clock};
    use sui::test_scenario::{Self};
    // tx_context is already provided by default
    use sui::coin::{Self};
    use std::ascii;
    use sui::sui::SUI;
    // tx_context is already imported by default
    use predictplay::predictplay::{Self, Markets};

    // === Constants ===
    const ADMIN: address = @0x1;
    const USER1: address = @0x2;
    const USER2: address = @0x3;

    const BASIS_POINTS: u64 = 10000;
    const INITIAL_PRICE: u64 = 5000;

    #[test]
    fun test_market_creation() {
        let mut scenario = test_scenario::begin(ADMIN);
        {
            // First transaction: create Clock and Markets objects
            let ctx = test_scenario::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            clock::share_for_testing(clock);
            predictplay::create_markets_test_only(ctx);
        };

        // Move to the next transaction
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            // Now we can take the shared objects
            let clock_ref = test_scenario::take_shared<Clock>(&scenario);
            let mut markets = test_scenario::take_shared<Markets>(&scenario);

            let ctx = test_scenario::ctx(&mut scenario);

            let game_id = 1;
            let name = ascii::string(b"Will BTC reach $100,000 by 2025?");
            let end_time = sui::clock::timestamp_ms(&clock_ref) + 10000;
            let market_id = 0;

            predictplay::create_market_test_only(
                &mut markets, game_id, name, end_time, &clock_ref, ctx
            );

            let (yes_price, no_price, _) = predictplay::get_market_prices_test_only(
                &markets, market_id
            );
            assert!(yes_price == INITIAL_PRICE, 0);
            assert!(no_price == INITIAL_PRICE, 1);
            assert!(yes_price + no_price == BASIS_POINTS, 2);

            // Return shared objects before ending the transaction
            test_scenario::return_shared(markets);
            test_scenario::return_shared(clock_ref);
        };
        test_scenario::end(scenario);
    }

    #[test]
    fun test_buy_shares_price_update() {
        let mut scenario = test_scenario::begin(ADMIN);
        {
            // First transaction: create Clock and Markets objects
            let ctx = test_scenario::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            clock::share_for_testing(clock);
            predictplay::create_markets_test_only(ctx);
        };

        // Market creation transaction
        let market_id; // Define market_id here to use across transactions
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            // Take shared objects
            let clock_ref = test_scenario::take_shared<Clock>(&scenario);
            let mut markets = test_scenario::take_shared<Markets>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);

            let game_id = 1;
            let name = ascii::string(b"Will BTC reach $100,000 by 2025?");
            let end_time = sui::clock::timestamp_ms(&clock_ref) + 10000;
            market_id = 0;

            predictplay::create_market_test_only(
                &mut markets, game_id, name, end_time, &clock_ref, ctx
            );

            // Return shared objects
            test_scenario::return_shared(markets);
            test_scenario::return_shared(clock_ref);
        };

        // Buying shares transaction
        test_scenario::next_tx(&mut scenario, USER1);
        {
            // Take shared objects again
            let clock_ref = test_scenario::take_shared<Clock>(&scenario);
            let mut markets = test_scenario::take_shared<Markets>(&scenario);

            let ctx = test_scenario::ctx(&mut scenario);
            let sui_coin = coin::mint_for_testing<SUI>(1_000_000_000, ctx);

            predictplay::buy_shares_test_only(
                &mut markets, market_id, true, sui_coin, &clock_ref, ctx
            );

            let (yes_price_after, no_price_after, _) = predictplay::get_market_prices_test_only(
                &markets, market_id
            );

            assert!(yes_price_after > INITIAL_PRICE, 3);
            assert!(no_price_after < INITIAL_PRICE, 4);
            assert!(yes_price_after + no_price_after == BASIS_POINTS, 5);

            // Return shared objects
            test_scenario::return_shared(markets);
            test_scenario::return_shared(clock_ref);
        };
        test_scenario::end(scenario);
    }

    #[test]
    fun test_market_resolution() {
        let mut scenario = test_scenario::begin(ADMIN);
        {
            // First transaction: create Clock and Markets objects
            let ctx = test_scenario::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            clock::share_for_testing(clock);
            predictplay::create_markets_test_only(ctx);
        };

        // Market creation transaction
        let market_id;
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            // Take shared objects
            let clock_ref = test_scenario::take_shared<Clock>(&scenario);
            let mut markets = test_scenario::take_shared<Markets>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);

            let game_id = 1;
            let name = ascii::string(b"Will BTC reach $100,000 by 2025?");
            let end_time = sui::clock::timestamp_ms(&clock_ref) + 10000;
            market_id = 0;

            predictplay::create_market_test_only(
                &mut markets, game_id, name, end_time, &clock_ref, ctx
            );

            // Return shared objects
            test_scenario::return_shared(markets);
            test_scenario::return_shared(clock_ref);
        };

        // Simulate passing time to reach market end
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut clock_ref = test_scenario::take_shared<Clock>(&scenario);
            // Add extra time to ensure we're past the market end time
            let current_time = clock::timestamp_ms(&clock_ref);
            // Update clock time to be well past the end time
            clock::set_for_testing(&mut clock_ref, current_time + 20000);
            test_scenario::return_shared(clock_ref);
        };

        // Market resolution transaction
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            // Take shared objects again
            let clock_ref = test_scenario::take_shared<Clock>(&scenario);
            let mut markets = test_scenario::take_shared<Markets>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);

            predictplay::resolve_market(
                &mut markets,
                market_id,
                true,
                &clock_ref,
                ctx
            );

            // Return shared objects
            test_scenario::return_shared(markets);
            test_scenario::return_shared(clock_ref);
        };
        test_scenario::end(scenario);
    }

    #[test]
    fun test_extreme_price_changes() {
        let mut scenario = test_scenario::begin(ADMIN);
        {
            // First transaction: create Clock and Markets objects
            let ctx = test_scenario::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            clock::share_for_testing(clock);
            predictplay::create_markets_test_only(ctx);
        };

        // Market creation transaction
        let market_id;
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            // Take shared objects
            let clock_ref = test_scenario::take_shared<Clock>(&scenario);
            let mut markets = test_scenario::take_shared<Markets>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);

            let game_id = 1;
            let name = ascii::string(b"Will BTC reach $100,000 by 2025?");
            let end_time = sui::clock::timestamp_ms(&clock_ref) + 10000;
            market_id = 0;

            predictplay::create_market_test_only(
                &mut markets, game_id, name, end_time, &clock_ref, ctx
            );

            // Return shared objects
            test_scenario::return_shared(markets);
            test_scenario::return_shared(clock_ref);
        };

        // First user buys YES shares
        test_scenario::next_tx(&mut scenario, USER1);
        {
            // Take shared objects again
            let clock_ref = test_scenario::take_shared<Clock>(&scenario);
            let mut markets = test_scenario::take_shared<Markets>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);

            let sui_coin = coin::mint_for_testing<SUI>(1_000_000, ctx);

            let (yes_price_before, _no_price_before, _) = predictplay::get_market_prices_test_only(
                &markets, market_id
            );

            predictplay::buy_shares_test_only(
                &mut markets, market_id, true, sui_coin, &clock_ref, ctx
            );

            let (yes_price_after, no_price_after, _) = predictplay::get_market_prices_test_only(
                &markets, market_id
            );

            assert!(yes_price_after > yes_price_before, 1);
            assert!(yes_price_after + no_price_after == BASIS_POINTS, 2);

            // Return shared objects
            test_scenario::return_shared(markets);
            test_scenario::return_shared(clock_ref);
        };

        // Second user buys NO shares
        test_scenario::next_tx(&mut scenario, USER2);
        {
            // Take shared objects again
            let clock_ref = test_scenario::take_shared<Clock>(&scenario);
            let mut markets = test_scenario::take_shared<Markets>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);

            let sui_coin = coin::mint_for_testing<SUI>(10_000_000_000, ctx);

            let (yes_price_before, no_price_before, _) = predictplay::get_market_prices_test_only(
                &markets, market_id
            );

            predictplay::buy_shares_test_only(
                &mut markets, market_id, false, sui_coin, &clock_ref, ctx
            );

            let (yes_price_after, no_price_after, _) = predictplay::get_market_prices_test_only(
                &markets, market_id
            );

            assert!(yes_price_after < yes_price_before, 3);
            assert!(no_price_after > no_price_before, 4);
            assert!(yes_price_after + no_price_after == BASIS_POINTS, 5);

            // Return shared objects
            test_scenario::return_shared(markets);
            test_scenario::return_shared(clock_ref);
        };
        test_scenario::end(scenario);
    }

    #[test]
    fun test_multiple_markets() {
        let mut scenario = test_scenario::begin(ADMIN);
        {
            // First transaction: create Clock and Markets objects
            let ctx = test_scenario::ctx(&mut scenario);
            let clock = clock::create_for_testing(ctx);
            clock::share_for_testing(clock);
            predictplay::create_markets_test_only(ctx);
        };

        test_scenario::next_tx(&mut scenario, ADMIN);
        let clock_ref = test_scenario::take_shared<Clock>(&scenario);
        let mut markets = test_scenario::take_shared<Markets>(&scenario);
        {
            let ctx = test_scenario::ctx(&mut scenario);
            predictplay::create_markets_test_only(ctx);

            let game_id_1 = 1;
            let name_1 = ascii::string(b"Will BTC reach $100,000 by 2025?");
            let end_time_1 = sui::clock::timestamp_ms(&clock_ref) + 10000;
            let market_id_1 = 0;

            predictplay::create_market_test_only(
                &mut markets, game_id_1, name_1, end_time_1, &clock_ref, ctx
            );

            let game_id_2 = 2;
            let name_2 = ascii::string(b"Will ETH reach $10,000 by 2025?");
            let end_time_2 = sui::clock::timestamp_ms(&clock_ref) + 15000;
            let market_id_2 = 1;

            predictplay::create_market_test_only(
                &mut markets, game_id_2, name_2, end_time_2, &clock_ref, ctx
            );

            let (yes_price_1, no_price_1, _) = predictplay::get_market_prices_test_only(
                &markets, market_id_1
            );
            let (yes_price_2, no_price_2, _) = predictplay::get_market_prices_test_only(
                &markets, market_id_2
            );
            assert!(yes_price_1 == INITIAL_PRICE, 1);
            assert!(no_price_1 == INITIAL_PRICE, 1);
            assert!(yes_price_2 == INITIAL_PRICE, 2);
            assert!(no_price_2 == INITIAL_PRICE, 3);

            test_scenario::next_tx(&mut scenario, USER1);
            let ctx = test_scenario::ctx(&mut scenario);
            let sui_coin_1 = coin::mint_for_testing<SUI>(2_000_000_000, ctx);
            predictplay::buy_shares_test_only(
                &mut markets, market_id_1, true, sui_coin_1, &clock_ref, ctx
            );

            test_scenario::next_tx(&mut scenario, USER2);
            let ctx = test_scenario::ctx(&mut scenario);
            let sui_coin_2 = coin::mint_for_testing<SUI>(3_000_000_000, ctx);
            predictplay::buy_shares_test_only(
                &mut markets, market_id_2, false, sui_coin_2, &clock_ref, ctx
            );

            test_scenario::next_tx(&mut scenario, ADMIN);
            let _ctx = test_scenario::ctx(&mut scenario);
            // Need to take our own reference to markets, not a new copy

            let (yes_price_1_after, no_price_1_after, _) = predictplay::get_market_prices_test_only(
                &markets, market_id_1
            );
            let (yes_price_2_after, no_price_2_after, _) = predictplay::get_market_prices_test_only(
                &markets, market_id_2
            );

            assert!(yes_price_1_after > INITIAL_PRICE, 6);
            assert!(no_price_2_after > INITIAL_PRICE, 7);
            assert!(yes_price_1_after + no_price_1_after == BASIS_POINTS, 8);
            assert!(yes_price_2_after + no_price_2_after == BASIS_POINTS, 9);

            // First end the current transaction and return all shared objects
            test_scenario::return_shared(markets);
            test_scenario::return_shared(clock_ref);

            // Start a new transaction, set the time
            test_scenario::next_tx(&mut scenario, ADMIN);
            {
                let mut clock_update = test_scenario::take_shared<Clock>(&scenario);
                let current_time = 100000; // Use a large explicit time value
                clock::set_for_testing(&mut clock_update, current_time);
                test_scenario::return_shared(clock_update);
            };

            // Market resolution transaction
            test_scenario::next_tx(&mut scenario, ADMIN);
            {
                let clock_resolve = test_scenario::take_shared<Clock>(&scenario);
                let mut markets_resolve = test_scenario::take_shared<Markets>(&scenario);
                let ctx = test_scenario::ctx(&mut scenario);
                predictplay::resolve_market(
                    &mut markets_resolve,
                    market_id_1,
                    true,
                    &clock_resolve,
                    ctx
                );
                test_scenario::return_shared(markets_resolve);
                test_scenario::return_shared(clock_resolve);
            };
        };
        test_scenario::end(scenario);
    }
}
