module predictplay::predictplay {
    // === Imports ===
    // Standard library modules
    use std::ascii::{Self, String};
    use std::u64;

    // Sui core modules
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::sui::SUI;
    use sui::table::{Self, Table};
    use sui::vec_map::{Self, VecMap};

    // === Errors ===
    const EMarketNotFound: u64 = 0;
    const EMarketAlreadyClosed: u64 = 1;
    const EMarketAlreadyResolved: u64 = 2;
    const EInsufficientFunds: u64 = 3;
    const EUnauthorized: u64 = 5;
    const EMarketNotClosed: u64 = 6;
    const EInvalidTimestamp: u64 = 7;
    const EPositionNotFound: u64 = 8; // Error for user position lookup failure
    const ECalculationError: u64 = 9; // Error for mathematical calculation issues

    // === Market Status ===
    const MARKET_STATUS_ACTIVE: u8 = 0;
    const MARKET_STATUS_RESOLVED: u8 = 2;
    // Virtual Liquidity
    const VIRTUAL_LIQUIDITY: u64 = 1_000_000_000; // 1 SUI in MIST
    // Basis points constants
    const BASIS_POINTS: u64 = 10000; // 100% in basis points
    const INITIAL_PRICE: u64 = 5000; // 50% in basis points

    // === Structs ===

    // New struct to hold user's shares per market
    public struct UserPosition has store, drop {
        yes_shares: u64,
        no_shares: u64
    }

    /// Represents a single prediction market
    public struct Market has key, store {
        id: UID,
        game_id: u64,
        name: String,
        end_time: u64, // Timestamp in milliseconds
        // Prices are stored directly, where P_yes + P_no = 1
        yes_price: u64, // Price in basis points (10000 = 100%)
        no_price: u64,  // Price in basis points (10000 = 100%)
        status: u8, // Using constants: 0: Active, 1: Closed, 2: Resolved
        resolved_outcome: std::option::Option<bool>, // Some(true) for YES, Some(false) for NO, None if not resolved
        // Liquidity will be managed via dedicated pools or balances associated with the market
        yes_shares: Balance<SUI>, // Shares representing YES outcome (acts like liquidity)
        no_shares: Balance<SUI>,  // Shares representing NO outcome (acts like liquidity)
        total_liquidity: u64, // Total SUI value locked in the market according to shares
        creator: address
    }

    /// Capability required to manage the PredictPlay protocol
    public struct AdminCap has key {
        id: UID
    }

    /// Shared object holding market data (using Tables)
    public struct Markets has key {
        id: UID,
        // Store Market objects directly, keyed by a simple counter ID for lookup
        next_market_id_counter: u64,
        markets: Table<u64, Market>,
        // Store user positions: User Address -> Market ID -> UserPosition
        // Updated value type to UserPosition
        positions: Table<address, VecMap<u64, UserPosition>>
        // market_creators: Table<u64, address>, // Creator stored within Market struct
        // total_liquidity: Balance<SUI> // Total liquidity managed across all markets
    }

    // === Test-only functions ===

    /// Create a Markets object for testing
    #[test_only]
    public fun create_markets_test_only(ctx: &mut TxContext) {
        let markets_obj = Markets {
            id: object::new(ctx),
            next_market_id_counter: 0,
            markets: table::new<u64, Market>(ctx),
            positions: table::new<address, VecMap<u64, UserPosition>>(ctx),
        };
        // Share the object immediately after creation
        transfer::share_object(markets_obj);
    }

    #[test_only]
    /// Helper for creating a market in tests
    public fun create_market_test_only(
        markets_obj: &mut Markets,
        game_id: u64,
        name: String,
        end_time: u64,
        _clock: &Clock,
        ctx: &mut TxContext
    ) {
        let market_id_counter = markets_obj.next_market_id_counter;
        markets_obj.next_market_id_counter = market_id_counter + 1;

        let sender = tx_context::sender(ctx);
        let name_bytes = *ascii::as_bytes(&name);

        let new_market = Market {
            id: object::new(ctx),
            game_id: game_id,
            name: name,
            end_time: end_time,
            yes_price: INITIAL_PRICE, // Initial price of 0.5 (50%) for YES
            no_price: INITIAL_PRICE,  // Initial price of 0.5 (50%) for NO
            status: MARKET_STATUS_ACTIVE,
            resolved_outcome: std::option::none<bool>(),
            yes_shares: balance::zero<SUI>(),
            no_shares: balance::zero<SUI>(),
            total_liquidity: 0,
            creator: sender
        };

        // Add the market to the table
        table::add(&mut markets_obj.markets, market_id_counter, new_market);

        // Emit an event
        event::emit(MarketCreated {
            market_id: market_id_counter,
            game_id: game_id,
            name_bytes: name_bytes,
            end_time: end_time,
            creator: sender
        });
    }

    #[test_only]
    /// Get the prices of a market for testing
    public fun get_market_prices_test_only(markets_obj: &Markets, market_id: u64): (u64, u64, u64) {
        let market = table::borrow(&markets_obj.markets, market_id);
        (market.yes_price, market.no_price, market.total_liquidity)
    }

    #[test_only]
    /// Get market state including status and resolved outcome for testing
    public fun get_market_state_test_only(markets_obj: &Markets, market_id: u64): (u64, u64, u8, bool) {
        let market = table::borrow(&markets_obj.markets, market_id);
        let outcome = if (std::option::is_some(&market.resolved_outcome)) {
            *std::option::borrow(&market.resolved_outcome)
        } else {
            false // Default value if not resolved
        };
        (market.yes_price, market.no_price, market.status, outcome)
    }

    #[test_only]
    /// Helper function to resolve a market in tests
    public fun resolve_market_test_only(
        markets_obj: &mut Markets,
        market_id: u64,
        outcome: bool,
        _ctx: &mut TxContext
    ) {
        let market = table::borrow_mut(&mut markets_obj.markets, market_id);

        // Set market status to resolved
        market.status = MARKET_STATUS_RESOLVED;
        market.resolved_outcome = std::option::some(outcome);

        // Emit event
        event::emit(MarketResolved {
            market_id: market_id,
            outcome: outcome
        });
    }

    #[test_only]
    /// Buy shares in a market for testing
    public fun buy_shares_test_only(
        markets_obj: &mut Markets,
        market_id: u64,
        is_yes: bool,
        sui_payment: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Delegate to the main implementation
        buy_shares(markets_obj, market_id, is_yes, sui_payment, clock, ctx)
    }

    // === Events ===

    public struct MarketCreated has copy, drop {
        market_id: u64, // Using the counter ID for simplicity in events
        game_id: u64,
        name_bytes: vector<u8>, // Store bytes instead of String
        end_time: u64,
        creator: address
    }

    public struct PositionOpened has copy, drop {
        market_id: u64,
        user: address,
        is_yes: bool, // True if bought YES shares, False if bought NO shares
        sui_amount: u64, // Amount of SUI spent
        shares_bought: u64 // Amount of shares received (renamed from shares_minted)
    }

     public struct MarketResolved has copy, drop {
        market_id: u64,
        outcome: bool // true for YES, false for NO
    }

    // === Init ===
    /// Helper function to calculate price change based on bet size relative to market liquidity
    fun calculate_price_change(bet_amount: u64, total_liquidity: u64): u64 {
        // If there is no liquidity, use the default price change value
        if (total_liquidity == 0) {
            500 // 5% change in basis points
        } else {
            // Calculate impact - larger bets relative to liquidity have a greater impact
            let bet_u128 = bet_amount as u128;
            let liquidity_u128 = (total_liquidity + VIRTUAL_LIQUIDITY) as u128;

            // Impact formula: bet_amount * scale_factor / (total_liquidity + virtual_liquidity)
            // Scaling factor (1000) controls the magnitude of price change per bet
            let price_change_u128 = (bet_u128 * 1000) / liquidity_u128;

            // Limit the maximum price change per transaction
            if (price_change_u128 > 2000) {
                2000 // Maximum 20% change
            } else {
                price_change_u128 as u64
            }
        }
    }

    #[test_only]
    /// Initialize the PredictPlay protocol
    fun init(ctx: &mut TxContext) { 
        // Create and transfer the Admin Capability to the publisher
        transfer::transfer(AdminCap { id: object::new(ctx) }, tx_context::sender(ctx));

        // Create the shared Markets object
        transfer::share_object(Markets {
            id: object::new(ctx),
            next_market_id_counter: 0,
            markets: table::new<u64, Market>(ctx),
            positions: table::new<address, VecMap<u64, UserPosition>>(ctx)
            // total_liquidity: balance::zero<SUI>()
        });
    }

    // === Functions (Entry points and helpers will be added here) ===

    /// Creates a new prediction market.
    public entry fun create_market(
        markets_obj: &mut Markets,
        game_id: u64,
        name: String, // Function receives ownership of name
        end_time: u64, // Betting end timestamp in milliseconds
        clock: &Clock, // Need Clock object to get current time
        ctx: &mut TxContext
    ) {
        let current_timestamp = clock::timestamp_ms(clock);
        assert!(end_time > current_timestamp, EInvalidTimestamp);

        let market_id_counter = markets_obj.next_market_id_counter;
        markets_obj.next_market_id_counter = market_id_counter + 1;

        let sender = tx_context::sender(ctx);

        // Get name bytes for the event before moving the original name
        let name_bytes = *ascii::as_bytes(&name); // Copy the bytes vector with the dereference operator *

        let new_market = Market {
            id: object::new(ctx),
            game_id: game_id,
            name: name, // Original name is moved here
            end_time: end_time,
            yes_price: INITIAL_PRICE, // Initial price of 0.5 (50%) for YES
            no_price: INITIAL_PRICE,  // Initial price of 0.5 (50%) for NO
            status: MARKET_STATUS_ACTIVE,
            // resolved_outcome is initially None
            resolved_outcome: std::option::none<bool>(),
            yes_shares: balance::zero<SUI>(),
            no_shares: balance::zero<SUI>(),
            total_liquidity: 0, // Starts with zero actual liquidity
            creator: sender
        };

        // Add the market to the shared table
        table::add(&mut markets_obj.markets, market_id_counter, new_market);

        // Emit an event using the cloned bytes
        event::emit(MarketCreated {
            market_id: market_id_counter,
            game_id: game_id,
            name_bytes: name_bytes, // Use the cloned bytes here
            end_time: end_time,
            creator: sender
        });
    }

    /// Allows a user to buy YES or NO shares (outcome tokens) in a market.
    public entry fun buy_shares(
        markets_obj: &mut Markets,
        market_id: u64,
        is_yes: bool,
        sui_payment: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // 1. Get market and check status/time
        assert!(table::contains(&markets_obj.markets, market_id), EMarketNotFound);
        let market = table::borrow_mut(&mut markets_obj.markets, market_id);
        assert!(market.status == MARKET_STATUS_ACTIVE, EMarketAlreadyClosed);

        let current_timestamp = clock::timestamp_ms(clock);
        assert!(current_timestamp < market.end_time, EMarketAlreadyClosed);

        // 2. Get payment amount and current balances
        let sui_amount = coin::value(&sui_payment);
        assert!(sui_amount > 0, EInsufficientFunds);
        // We no longer need these variables, as the price is now stored directly in the market structure
        // let y_balance = balance::value(&market.yes_shares);
        // let n_balance = balance::value(&market.no_shares);

        // 3. Elevate to u128 for calculation
        let amount_u128 = sui_amount as u128;
        // Remove unused variables
        // let y_u128 = y_balance as u128;
        // let n_u128 = n_balance as u128;
        // let v_u128 = VIRTUAL_LIQUIDITY as u128;

        // 4. Calculate shares based on current price (which is the probability)
        let shares_bought: u64;

        if (is_yes) {
            // Shares = amount / price (higher price = fewer shares per SUI)
            let price_decimal = (market.yes_price as u128) * 100 / (BASIS_POINTS as u128); // Convert to decimal (0-100)
            assert!(price_decimal > 0, ECalculationError); // Ensure price isn't zero
            // Calculate shares: amount * 100 / price (normalized to percentage)
            let shares_bought_u128 = (amount_u128 * 100) / price_decimal;
            assert!(shares_bought_u128 <= u64::max_value!() as u128, ECalculationError);
            shares_bought = shares_bought_u128 as u64;

            // 5. Add payment to YES balance
            balance::join(&mut market.yes_shares, coin::into_balance(sui_payment));

            // Update market prices - increase YES price, decrease NO price
            // The price change is proportional to the amount being added relative to existing liquidity
            let price_change = calculate_price_change(sui_amount, market.total_liquidity);

            // Ensure we don't exceed 100% or go below 0%
            if (price_change < market.no_price) {
                market.yes_price = market.yes_price + price_change;
                market.no_price = market.no_price - price_change;
            } else {
                // Cap at 99% probability to avoid extreme prices
                market.yes_price = 9900; // 99%
                market.no_price = 100;   // 1%
            }
        } else {
            // Shares = amount / price (higher price = fewer shares per SUI)
            let price_decimal = (market.no_price as u128) * 100 / (BASIS_POINTS as u128); // Convert to decimal (0-100)
            assert!(price_decimal > 0, ECalculationError); // Ensure price isn't zero
            // Calculate shares: amount * 100 / price (normalized to percentage)
            let shares_bought_u128 = (amount_u128 * 100) / price_decimal;
            assert!(shares_bought_u128 <= u64::max_value!() as u128, ECalculationError);
            shares_bought = shares_bought_u128 as u64;

            // 5. Add payment to NO balance
            balance::join(&mut market.no_shares, coin::into_balance(sui_payment));

            // Update market prices - increase NO price, decrease YES price
            let price_change = calculate_price_change(sui_amount, market.total_liquidity);

            // Ensure we don't exceed 100% or go below 0%
            if (price_change < market.yes_price) {
                market.no_price = market.no_price + price_change;
                market.yes_price = market.yes_price - price_change;
            } else {
                // Cap at 99% probability to avoid extreme prices
                market.no_price = 9900; // 99%
                market.yes_price = 100;  // 1%
            }
        };

        // Ensure prices always sum to 100%
        assert!(market.yes_price + market.no_price == BASIS_POINTS, ECalculationError);

        // 6. Update market total liquidity tracking (simple sum of actual balances)
        // Recalculate based on balances *after* adding the payment
        market.total_liquidity = balance::value(&market.yes_shares) + balance::value(&market.no_shares);

        // 7. Update user position in the positions table
        let sender = tx_context::sender(ctx);
        let user_positions_map = if (table::contains(&markets_obj.positions, sender)) {
            table::borrow_mut(&mut markets_obj.positions, sender)
        } else {
            // First time this user interacts with the contract
            table::add(&mut markets_obj.positions, sender, vec_map::empty<u64, UserPosition>());
            table::borrow_mut(&mut markets_obj.positions, sender)
        };

        let user_market_position = if (vec_map::contains(user_positions_map, &market_id)) {
            vec_map::get_mut(user_positions_map, &market_id)
        } else {
            // First time this user interacts with THIS market
            vec_map::insert(user_positions_map, market_id, UserPosition { yes_shares: 0, no_shares: 0 });
            vec_map::get_mut(user_positions_map, &market_id)
        };

        // Add the bought shares to the user's position
        if (is_yes) {
            user_market_position.yes_shares = user_market_position.yes_shares + shares_bought;
        } else {
            user_market_position.no_shares = user_market_position.no_shares + shares_bought;
        };

        // 8. Emit event
        event::emit(PositionOpened {
            market_id: market_id,
            user: sender,
            is_yes: is_yes,
            sui_amount: sui_amount,
            shares_bought: shares_bought
        });
    }

    /// Resolves a market with the final outcome (YES or NO)
    /// Only the market creator can call this function
    /// Market must be active and its end time must have passed
    public entry fun resolve_market(
        markets_obj: &mut Markets,
        market_id: u64,
        outcome: bool, // true for YES, false for NO
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // 1. Check that market exists and get mutable reference
        assert!(table::contains(&markets_obj.markets, market_id), EMarketNotFound);
        let market = table::borrow_mut(&mut markets_obj.markets, market_id);

        // 2. Check that caller is the market creator
        let sender = tx_context::sender(ctx);
        assert!(sender == market.creator, EUnauthorized);

        // 3. Check that market is active and not already resolved
        assert!(market.status == MARKET_STATUS_ACTIVE, EMarketAlreadyResolved);

        // 4. Check that market end time has passed
        let current_timestamp = clock::timestamp_ms(clock);
        assert!(current_timestamp >= market.end_time, EMarketNotClosed);

        // 5. Update market status and set resolved outcome
        market.status = MARKET_STATUS_RESOLVED;
        market.resolved_outcome = std::option::some(outcome);

        // 6. Emit a market resolved event
        event::emit(MarketResolved {
            market_id: market_id,
            outcome: outcome
        });
    }

    /// Allows a user to claim their winnings from a resolved market
    /// The market must be resolved before claiming
    /// Only users who bet on the winning outcome can claim rewards
    public entry fun claim_winnings(
        markets_obj: &mut Markets,
        market_id: u64,
        ctx: &mut TxContext
    ) {
        // 1. Check that market exists and is resolved
        assert!(table::contains(&markets_obj.markets, market_id), EMarketNotFound);
        let market = table::borrow_mut(&mut markets_obj.markets, market_id);
        assert!(market.status == MARKET_STATUS_RESOLVED, EMarketNotClosed);

        // 2. Get resolved outcome (should be Some since market is resolved)
        let resolved_outcome = *std::option::borrow(&market.resolved_outcome);

        // 3. Check if user has a position in this market
        let sender = tx_context::sender(ctx);
        assert!(table::contains(&markets_obj.positions, sender), EPositionNotFound);

        let positions_map = table::borrow_mut(&mut markets_obj.positions, sender);
        assert!(vec_map::contains(positions_map, &market_id), EPositionNotFound);

        // 4. Get user position and check if they have shares in the winning outcome
        // vec_map::remove returns a tuple (K, V) where K is the key (market_id) and V is the value (UserPosition)
        let (_, user_position) = vec_map::remove(positions_map, &market_id);

        let winning_shares = if (resolved_outcome) {
            // YES outcome won
            user_position.yes_shares
        } else {
            // NO outcome won
            user_position.no_shares
        };

        // 5. Ensure user has winning shares
        assert!(winning_shares > 0, EInsufficientFunds);

        // 6. Calculate winnings (proportional to share of winning pool)
        let total_winning_pool_size = if (resolved_outcome) {
            // YES outcome won, total winning pool is all YES shares
            balance::value(&market.yes_shares)
        } else {
            // NO outcome won, total winning pool is all NO shares
            balance::value(&market.no_shares)
        };

        // Calculate user's share of the total winning pool
        let total_liquidity = market.total_liquidity;
        // Avoid division by zero if the winning pool somehow has zero balance (shouldn't happen if winning_shares > 0)
        assert!(total_winning_pool_size > 0, ECalculationError);
        // Use u128 for intermediate calculation to prevent overflow
        let user_share_percentage_numerator = (winning_shares as u128) * 10000;
        let user_share_percentage = user_share_percentage_numerator / (total_winning_pool_size as u128);

        // Calculate winnings as proportion of total liquidity
        let user_winnings_numerator = (total_liquidity as u128) * user_share_percentage;
        let user_winnings = (user_winnings_numerator / 10000) as u64;

        // 7. Transfer winnings to user
        let winning_pool_balance = if (resolved_outcome) {
            &mut market.yes_shares
        } else {
            &mut market.no_shares
        };

        // Ensure we don't try to split more than available in the pool
        assert!(user_winnings <= balance::value(winning_pool_balance), ECalculationError);

        let reward_balance = balance::split(winning_pool_balance, user_winnings);
        let reward_coin = coin::from_balance(reward_balance, ctx);
        transfer::public_transfer(reward_coin, sender);

        // 8. Update market total liquidity
        market.total_liquidity = market.total_liquidity - user_winnings;

        // Optional: Clean up user's position map if it becomes empty
        if (vec_map::is_empty(positions_map)) {
            table::remove(&mut markets_obj.positions, sender);
        }
    }
}
