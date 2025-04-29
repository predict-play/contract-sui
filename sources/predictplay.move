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
        // Prices are implicit based on liquidity pool in AMM, not stored directly
        // yes_price: u64,
        // no_price: u64,
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

    fun init(ctx: &mut TxContext) {
        // Create and transfer the Admin Capability to the publisher
        transfer::transfer(AdminCap { id: object::new(ctx) }, tx_context::sender(ctx));

        // Create the shared Markets object
        transfer::share_object(Markets {
            id: object::new(ctx),
            next_market_id_counter: 0,
            markets: table::new<u64, Market>(ctx),
            // Updated value type in table creation
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
        let y_balance = balance::value(&market.yes_shares);
        let n_balance = balance::value(&market.no_shares);

        // 3. Elevate to u128 for calculation
        let amount_u128 = sui_amount as u128;
        let y_u128 = y_balance as u128;
        let n_u128 = n_balance as u128;
        let v_u128 = VIRTUAL_LIQUIDITY as u128;

        // 4. Calculate shares bought using the simplified model formula
        let denominator: u128 = y_u128 + n_u128 + (2 * v_u128);
        assert!(denominator > 0, ECalculationError); // Should always be > 0 due to V
        let shares_bought: u64;

        if (is_yes) {
            let numerator_y: u128 = y_u128 + v_u128;
            assert!(numerator_y > 0, ECalculationError); // Should always be > 0
            // shares = amount * (Y+N+2V) / (Y+V)
            let shares_bought_u128 = (amount_u128 * denominator) / numerator_y;
            // Basic overflow check (can be made more robust)
            assert!(shares_bought_u128 <= u64::max_value!() as u128, ECalculationError);
            shares_bought = shares_bought_u128 as u64;

            // 5. Add payment to YES balance
            balance::join(&mut market.yes_shares, coin::into_balance(sui_payment));
        } else {
            let numerator_n: u128 = n_u128 + v_u128;
            assert!(numerator_n > 0, ECalculationError); // Should always be > 0
            // shares = amount * (Y+N+2V) / (N+V)
            let shares_bought_u128 = (amount_u128 * denominator) / numerator_n;
            // Basic overflow check
            assert!(shares_bought_u128 <= u64::max_value!() as u128, ECalculationError);
            shares_bought = shares_bought_u128 as u64;

            // 5. Add payment to NO balance
            balance::join(&mut market.no_shares, coin::into_balance(sui_payment));
        };

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
