module predictplay::predictplay;

use predictplay::no_coin::NO_COIN;
use predictplay::yes_coin::YES_COIN;
use std::ascii::{Self, String};
use std::u64;
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::event;
use sui::package;
use sui::sui::SUI;
use sui::table::{Self, Table};
use sui::types;
use sui::vec_map::{Self, VecMap};

const VERSION: u64 = 3;

public fun package_version(): u64 { VERSION }

// === Coin Types ===
/// One-time witness for the module
public struct PREDICTPLAY has drop {}

// === Errors ===
const EMarketNotFound: u64 = 100;
const EMarketAlreadyClosed: u64 = 101;
const EMarketAlreadyResolved: u64 = 102;
const EInsufficientFunds: u64 = 103;
const EMarketNotClosed: u64 = 104;
const EPositionNotFound: u64 = 105; // Error for user position lookup failure
const ECalculationError: u64 = 106; // Error for mathematical calculation issues
const EPeriodTooSmall: u64 = 107; // Error for period too small
const EOutcomeError: u64 = 108;

// Debug error codes
const EDebugPriceCalculation: u64 = 201;
const EDebugSharesUpdate: u64 = 202;
const EDebugPriceChange: u64 = 203;
const EDebugPriceAdjustment: u64 = 204;
const EDebugLiquiditySplit: u64 = 205;
const EDebugInsufficientLiquidity: u64 = 206;

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
public struct UserPosition has drop, store {
    yes_shares: u64,
    no_shares: u64,
}

/// Shared object holding market data (using Tables)
public struct Markets has key {
    id: UID,
    // Store Market objects directly, keyed by a simple counter ID for lookup
    next_market_id_counter: u64,
    markets: Table<u64, Market>,
    // Store user positions: User Address -> Market ID -> UserPosition
    // Updated value type to UserPosition
    positions: Table<address, VecMap<u64, UserPosition>>,
    // Global treasury caps for YES and NO coins
    yes_treasury_cap: Option<TreasuryCap<YES_COIN>>,
    no_treasury_cap: Option<TreasuryCap<NO_COIN>>,
    // market_creators: Table<u64, address>, // Creator stored within Market struct
    // total_liquidity: Balance<SUI> // Total liquidity managed across all markets
}

/// Represents a single prediction market
public struct Market has key, store {
    id: UID,
    game_id: u64,
    name: String,
    end_time: u64, // Timestamp in milliseconds
    // Prices are stored directly, where P_yes + P_no = 1
    yes_price: u64, // Price in basis points (10000 = 100%)
    no_price: u64, // Price in basis points (10000 = 100%)
    status: u8, // Using constants: 0: Active, 1: Closed, 2: Resolved
    resolved_outcome: u8, // 1 for YES, 2 for NO, 0 if not resolved
    yes_shares: u64,
    no_shares: u64,
    // Liquidity will be managed via dedicated pools or balances associated with the market
    yes_liquidity: Balance<SUI>, // Shares representing YES outcome (acts like liquidity)
    no_liquidity: Balance<SUI>, // Shares representing NO outcome (acts like liquidity)
    total_liquidity: u64, // Total SUI value locked in the market according to shares
    creator: address,
}

/// Capability required to manage the PredictPlay protocol
public struct AdminCap has key {
    id: UID,
}

// === Events ===

public struct MarketCreated has copy, drop {
    market_id: u64, // Using the counter ID for simplicity in events
    game_id: u64,
    name_bytes: vector<u8>, // Store bytes instead of String
    end_time: u64,
    creator: address,
}

public struct PositionOpened has copy, drop {
    market_id: u64,
    user: address,
    is_yes: bool, // True if bought YES shares, False if bought NO shares
    sui_amount: u64, // Amount of SUI spent
    shares_bought: u64, // Amount of shares received (renamed from shares_minted)
}

// Event emitted when a user sells shares
public struct PositionClosed has copy, drop {
    market_id: u64,
    user: address,
    is_yes: bool, // True if sold YES shares, False if sold NO shares
    sui_amount: u64, // Amount of SUI received
    shares_sold: u64, // Amount of shares sold
}

public struct MarketResolved has copy, drop {
    market_id: u64,
    outcome: u8, // 1 for YES, 2 for NO
}

// Define a struct to hold the information returned by get_markets_list
// Make sure all fields are copy, drop, store if the struct itself needs these abilities
public struct MarketInfo has copy, drop, store {
    market_id: u64,
    game_id: u64,
    name: String, // Be mindful of string copying costs/semantics
    end_time: u64,
    yes_price: u64,
    no_price: u64,
    yes_liquidity: u64,
    no_liquidity: u64,
    status: u8,
    total_liquidity: u64,
    creator: address,
    resolved_outcome: u8,
}

// === Init ===
/// Helper function to calculate price change based on bet size relative to market liquidity
fun calculate_price_change(bet_amount: u64, total_liquidity: u64): u64 {
    // Special handling: If the bet amount is extremely large (considering SUI precision: 1 SUI = 10^9 MIST)
    // When the bet exceeds 30 SUI, it is considered a large bet amount
    if (bet_amount > 30_000_000_000) {
        // 30 SUI
        // For large bets, we use a more significant price impact
        // Return different price changes based on the bet amount
        if (bet_amount > 100_000_000_000) {
            // Over 100 SUI large bet
            return 1500 // 15% price change
        } else if (bet_amount > 50_000_000_000) {
            // 50-100 SUI bet
            return 1000 // 10% price change
        } else {
            // 30-50 SUI bet
            return 700 // 7% price change
        }
    };

    // If there is no liquidity, use the default price change value
    if (total_liquidity == 0) {
        500 // 5% change in basis points
    } else {
        // Calculate impact - the ratio of bet amount to liquidity determines price impact
        let bet_u128 = bet_amount as u128;
        let liquidity_u128 = (total_liquidity + VIRTUAL_LIQUIDITY) as u128;

        // Impact formula: bet_amount * scale_factor / (total_liquidity + virtual_liquidity)
        // Scale factor controls the price change per bet
        let price_change_u128 = (bet_u128 * 1200) / liquidity_u128;

        // Limit the maximum price change per transaction
        if (price_change_u128 > 1500) {
            1500 // Maximum 15% change
        } else {
            price_change_u128 as u64
        }
    }
}

/// Initialize the PredictPlay protocol
fun init(otw: PREDICTPLAY, ctx: &mut TxContext) {
    // Confirmation is a true one-time witness
    assert!(types::is_one_time_witness(&otw), 0);

    // Declare publisher
    let publisher = package::claim(otw, ctx);

    // Transfer admin permission to publisher
    transfer::transfer(AdminCap { id: object::new(ctx) }, tx_context::sender(ctx));

    // Create and share Markets object, subsequent events will get the TreasuryCap of the coin
    transfer::share_object(Markets {
        id: object::new(ctx),
        next_market_id_counter: 0,
        markets: table::new<u64, Market>(ctx),
        positions: table::new<address, VecMap<u64, UserPosition>>(ctx),
        yes_treasury_cap: option::none(),
        no_treasury_cap: option::none(),
    });

    // Destroy publisher
    package::burn_publisher(publisher);
}

// === Functions (Entry points and helpers will be added here) ===

/// Set treasury caps for YES and NO coins (called after deployment)
public entry fun set_treasury_caps(
    _: &AdminCap,
    markets_obj: &mut Markets,
    yes_treasury_cap: TreasuryCap<YES_COIN>,
    no_treasury_cap: TreasuryCap<NO_COIN>,
) {
    // Set the treasury caps
    option::fill(&mut markets_obj.yes_treasury_cap, yes_treasury_cap);
    option::fill(&mut markets_obj.no_treasury_cap, no_treasury_cap);
}

/// Creates a new prediction market.
/// Only requires game_id and market name, market_id is auto-incremented and end_time is calculated automatically.
public entry fun create_market(
    _: &AdminCap,
    markets_obj: &mut Markets,
    game_id: u64,
    name: String, // Function receives ownership of name
    clock: &Clock, // Need Clock object to get current time
    period_minutes: u64,
    ctx: &mut TxContext,
) {
    create_market_base(markets_obj, game_id, name, clock, period_minutes, ctx);
}

public entry fun create_market_without_admin(
    markets_obj: &mut Markets,
    game_id: u64,
    name: String, // Function receives ownership of name
    clock: &Clock, // Need Clock object to get current time
    period_minutes: u64,
    ctx: &mut TxContext,
) {
    create_market_base(markets_obj, game_id, name, clock, period_minutes, ctx);
}

public fun create_market_base(
    markets_obj: &mut Markets,
    game_id: u64,
    name: String, // Function receives ownership of name
    clock: &Clock, // Need Clock object to get current time
    period_minutes: u64,
    ctx: &mut TxContext,
) {
    // Set market end time to period minutes from now
    let current_timestamp = clock::timestamp_ms(clock);
    assert!(period_minutes >= 1, EPeriodTooSmall);
    let end_time = current_timestamp + period_minutes * 60 * 1000; // period minutes later

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
        no_price: INITIAL_PRICE, // Initial price of 0.5 (50%) for NO
        status: MARKET_STATUS_ACTIVE,
        // resolved_outcome is initially None
        resolved_outcome: 0,
        yes_shares: 0,
        no_shares: 0,
        yes_liquidity: balance::zero<SUI>(),
        no_liquidity: balance::zero<SUI>(),
        total_liquidity: 0, // Starts with zero actual liquidity
        creator: sender,
    };

    // Add the market to the shared table
    table::add(&mut markets_obj.markets, market_id_counter, new_market);

    // Emit an event using the cloned bytes
    event::emit(MarketCreated {
        market_id: market_id_counter,
        game_id: game_id,
        name_bytes: name_bytes, // Use the cloned bytes here
        end_time: end_time,
        creator: sender,
    });
}

/// Returns a user's position in a specific market
/// Returns (yes_shares, no_shares)
/// Returns (0, 0) if the user has no position in the market
public fun get_user_position(markets_obj: &Markets, market_id: u64, user: address): (u64, u64) {
    // Check if the user has any positions
    if (!table::contains(&markets_obj.positions, user)) {
        return (0, 0)
    };

    // Get the user's positions map
    let positions_map = table::borrow(&markets_obj.positions, user);

    // Check if the user has a position in this market
    if (!vec_map::contains(positions_map, &market_id)) {
        return (0, 0)
    };

    // Get the user's position in this market
    let position = vec_map::get(positions_map, &market_id);
    (position.yes_shares, position.no_shares)
}

/// Returns a list of markets with basic details, supporting pagination.
/// `start` is the market ID to start from (inclusive).
/// `limit` is the maximum number of markets to return.
public fun get_markets_list(markets_obj: &Markets, start: u64, limit: u64): vector<MarketInfo> {
    let mut market_infos = vector::empty<MarketInfo>();
    let mut cursor = start;
    let mut count = 0;
    let max_id = markets_obj.next_market_id_counter; // Get the upper bound

    // Iterate while we have markets and haven't reached the limit
    while (cursor < max_id && count < limit) {
        // Check if a market exists at the current cursor ID
        if (table::contains(&markets_obj.markets, cursor)) {
            let market = table::borrow(&markets_obj.markets, cursor);
            vector::push_back(
                &mut market_infos,
                MarketInfo {
                    market_id: cursor, // Use the key as the ID
                    game_id: market.game_id,
                    name: market.name, // Cloning the string might be necessary depending on usage
                    end_time: market.end_time,
                    yes_price: market.yes_price,
                    no_price: market.no_price,
                    yes_liquidity: balance::value(&market.yes_liquidity),
                    no_liquidity: balance::value(&market.no_liquidity),
                    status: market.status,
                    total_liquidity: market.total_liquidity,
                    creator: market.creator,
                    resolved_outcome: market.resolved_outcome,
                },
            );
            count = count + 1;
        };
        cursor = cursor + 1;
    };
    market_infos
}

/// Returns markets by game_id
public fun get_markets_by_game_id(markets_obj: &Markets, game_id: u64): vector<MarketInfo> {
    let mut market_infos = vector::empty<MarketInfo>();
    let mut cursor = 0;
    let max_id = markets_obj.next_market_id_counter;

    // Iterate through all markets to find matching game_id
    while (cursor < max_id) {
        if (table::contains(&markets_obj.markets, cursor)) {
            let market = table::borrow(&markets_obj.markets, cursor);
            if (market.game_id == game_id) {
                vector::push_back(
                    &mut market_infos,
                    MarketInfo {
                        market_id: cursor,
                        game_id: market.game_id,
                        name: market.name,
                        end_time: market.end_time,
                        yes_price: market.yes_price,
                        no_price: market.no_price,
                        yes_liquidity: balance::value(&market.yes_liquidity),
                        no_liquidity: balance::value(&market.no_liquidity),
                        status: market.status,
                        total_liquidity: market.total_liquidity,
                        creator: market.creator,
                        resolved_outcome: market.resolved_outcome,
                    },
                );
            }
        };
        cursor = cursor + 1;
    };
    market_infos
}

/// Returns the current prices of a market (yes price, no price, total liquidity)
public fun get_market_prices(markets_obj: &Markets, market_id: u64): (u64, u64, u64) {
    assert!(table::contains(&markets_obj.markets, market_id), EMarketNotFound);
    let market = table::borrow(&markets_obj.markets, market_id);
    (market.yes_price, market.no_price, market.total_liquidity)
}

/// Calculates how many SUI tokens are needed to buy a specific amount of shares
/// Returns the required SUI amount in MIST (1 SUI = 10^9 MIST)
public fun calculate_sui_needed_for_shares(
    markets_obj: &Markets,
    market_id: u64,
    is_yes: bool,
    shares_amount: u64,
): u64 {
    assert!(table::contains(&markets_obj.markets, market_id), EMarketNotFound);
    let market = table::borrow(&markets_obj.markets, market_id);

    // Calculate required SUI based on current price
    if (is_yes) {
        // For YES shares: amount = shares * price
        // Convert price from basis points (10000 = 100%) to decimal
        let price_decimal = (market.yes_price as u128) * 100 / (BASIS_POINTS as u128); // Convert to decimal (0-100)
        // Calculate required amount (price is per share)
        // price_decimal is in percentage format (0-100), so we divide by 100 to get actual multiplier
        let sui_amount = (shares_amount as u128) * price_decimal / 100;
        (sui_amount as u64)
    } else {
        // For NO shares: similar calculation with NO price
        let price_decimal = (market.no_price as u128) * 100 / (BASIS_POINTS as u128);
        let sui_amount = (shares_amount as u128) * price_decimal / 100;
        (sui_amount as u64)
    }
}

/// Mint YES coins for a user based on their shares
public fun mint_yes_coins(
    markets_obj: &mut Markets,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    // Check if Treasury exists
    assert!(option::is_some(&markets_obj.yes_treasury_cap), ECalculationError);
    // Use option::borrow_mut to get mutable reference
    let yes_cap = option::borrow_mut(&mut markets_obj.yes_treasury_cap);
    // Mint YES coins
    let yes_coin = coin::mint(yes_cap, amount, ctx);
    transfer::public_transfer(yes_coin, recipient);
}

/// Mint NO coins for a user based on their shares
public fun mint_no_coins(
    markets_obj: &mut Markets,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    // Check if Treasury exists
    assert!(option::is_some(&markets_obj.no_treasury_cap), ECalculationError);
    // Use option::borrow_mut to get mutable reference
    let no_cap = option::borrow_mut(&mut markets_obj.no_treasury_cap);
    // Mint NO coins
    let no_coin = coin::mint(no_cap, amount, ctx);
    transfer::public_transfer(no_coin, recipient);
}

/// Burn YES coins
public fun burn_yes_coins(markets_obj: &mut Markets, coins: Coin<YES_COIN>) {
    // Check if Treasury exists
    assert!(option::is_some(&markets_obj.yes_treasury_cap), ECalculationError);
    // Use option::borrow_mut to get mutable reference
    let yes_cap = option::borrow_mut(&mut markets_obj.yes_treasury_cap);
    // Burn YES coins
    coin::burn(yes_cap, coins);
}

/// Burn NO coins
public fun burn_no_coins(markets_obj: &mut Markets, coins: Coin<NO_COIN>) {
    // Check if Treasury exists
    assert!(option::is_some(&markets_obj.no_treasury_cap), ECalculationError);
    // Use option::borrow_mut to get mutable reference
    let no_cap = option::borrow_mut(&mut markets_obj.no_treasury_cap);
    // Burn NO coins
    coin::burn(no_cap, coins);
}

/// Allows a user to buy YES or NO shares (outcome tokens) in a market.
public entry fun buy_shares(
    markets_obj: &mut Markets,
    market_id: u64,
    is_yes: bool,
    sui_payment: Coin<SUI>,
    clock: &Clock,
    _slip: u64,
    ctx: &mut TxContext,
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
        balance::join(&mut market.yes_liquidity, coin::into_balance(sui_payment));

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
            market.no_price = 100; // 1%
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
        balance::join(&mut market.no_liquidity, coin::into_balance(sui_payment));

        // Update market prices - increase NO price, decrease YES price
        let price_change = calculate_price_change(sui_amount, market.total_liquidity);

        // Ensure we don't exceed 100% or go below 0%
        if (price_change < market.yes_price) {
            market.no_price = market.no_price + price_change;
            market.yes_price = market.yes_price - price_change;
        } else {
            // Cap at 99% probability to avoid extreme prices
            market.no_price = 9900; // 99%
            market.yes_price = 100; // 1%
        }
    };

    // Ensure prices always sum to 100%
    assert!(market.yes_price + market.no_price == BASIS_POINTS, ECalculationError);

    // 6. Update market total liquidity tracking (simple sum of actual balances)
    // Recalculate based on balances *after* adding the payment
    market.total_liquidity =
        balance::value(&market.yes_liquidity) + balance::value(&market.no_liquidity);

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
        vec_map::insert(
            user_positions_map,
            market_id,
            UserPosition { yes_shares: 0, no_shares: 0 },
        );
        vec_map::get_mut(user_positions_map, &market_id)
    };

    // Add the bought shares to the user's position
    if (is_yes) {
        user_market_position.yes_shares = user_market_position.yes_shares + shares_bought;
        market.yes_shares = market.yes_shares + shares_bought;
    } else {
        user_market_position.no_shares = user_market_position.no_shares + shares_bought;
        market.no_shares = market.no_shares + shares_bought;
    };

    // 8. Emit event
    event::emit(PositionOpened {
        market_id: market_id,
        user: sender,
        is_yes: is_yes,
        sui_amount: sui_amount,
        shares_bought: shares_bought,
    });

    // 9. Mint outcome coins for the user
    if (is_yes) {
        mint_yes_coins(markets_obj, shares_bought, sender, ctx);
    } else {
        mint_no_coins(markets_obj, shares_bought, sender, ctx);
    }
}

/// Allows a user to sell YES or NO shares they previously bought in a market.
public entry fun sell_shares(
    markets_obj: &mut Markets,
    market_id: u64,
    is_yes: bool,
    shares_amount: u64,
    yes_coins: Coin<YES_COIN>,
    no_coins: Coin<NO_COIN>,
    clock: &Clock,
    _slip: u64,
    ctx: &mut TxContext,
) {
    assert!(shares_amount > 0, EInsufficientFunds);
    assert!(
        coin::value(&yes_coins) == (if (is_yes) { shares_amount } else { 0 }),
        EInsufficientFunds,
    );
    assert!(
        coin::value(&no_coins) == (if (!is_yes) { shares_amount } else { 0 }),
        EInsufficientFunds,
    );

    // 1. Get market and check status/time
    assert!(table::contains(&markets_obj.markets, market_id), EMarketNotFound);
    let market = table::borrow_mut(&mut markets_obj.markets, market_id);
    assert!(market.status == MARKET_STATUS_ACTIVE, EMarketAlreadyClosed);

    let current_timestamp = clock::timestamp_ms(clock);
    assert!(current_timestamp < market.end_time, EMarketAlreadyClosed);

    // 2. Check that the user has sufficient shares to sell
    let sender = tx_context::sender(ctx);
    assert!(table::contains(&markets_obj.positions, sender), EPositionNotFound);

    let user_positions_map = table::borrow_mut(&mut markets_obj.positions, sender);
    assert!(vec_map::contains(user_positions_map, &market_id), EPositionNotFound);

    let user_market_position = vec_map::get_mut(user_positions_map, &market_id);

    // Verify the user has enough shares and the correct amount of coins
    if (is_yes) {
        assert!(user_market_position.yes_shares >= shares_amount, EInsufficientFunds);
        // Check if the user has provided the correct amount of YES coins
        assert!(coin::value(&yes_coins) == shares_amount, EInsufficientFunds);
    } else {
        assert!(user_market_position.no_shares >= shares_amount, EInsufficientFunds);
        // Check if the user has provided the correct amount of NO coins
        assert!(coin::value(&no_coins) == shares_amount, EInsufficientFunds);
    };

    // We need to handle the coins differently to avoid borrowing issues
    // We'll burn the coins at the end of the function

    // 3. Calculate SUI amount to return based on current price and execute the trade
    let sui_return_amount: u64; // Define the return amount outside both branches

    if (is_yes) {
        // Calculate SUI to return: shares * price / 100 (price is in percentage)
        assert!(market.yes_price > 0, EDebugPriceCalculation);
        let price_decimal = (market.yes_price as u128) * 100 / (BASIS_POINTS as u128); // Convert to decimal (0-100)
        let sui_amount_u128 = (shares_amount as u128) * price_decimal / 100;
        sui_return_amount = (sui_amount_u128 as u64);
        assert!(sui_return_amount > 0, EDebugPriceCalculation);

        // 4. Update user position
        assert!(user_market_position.yes_shares >= shares_amount, EDebugSharesUpdate);
        user_market_position.yes_shares = user_market_position.yes_shares - shares_amount;
        assert!(market.yes_shares >= shares_amount, EDebugSharesUpdate);
        market.yes_shares = market.yes_shares - shares_amount;

        // 5. Update market prices - decrease YES price, increase NO price
        assert!(market.total_liquidity > 0, EDebugPriceChange);
        let price_change = calculate_price_change(sui_return_amount, market.total_liquidity);
        assert!(price_change > 0, EDebugPriceChange);

        // Ensure we don't exceed 100% or go below 0%
        if (price_change < market.yes_price) {
            assert!(price_change <= market.yes_price, EDebugPriceAdjustment);
            market.yes_price = market.yes_price - price_change;
            market.no_price = market.no_price + price_change;
            assert!(market.yes_price + market.no_price == BASIS_POINTS, EDebugPriceAdjustment);
        } else {
            // Cap at 99% probability to avoid extreme prices
            market.yes_price = 100; // 1%
            market.no_price = 9900; // 99%
        };

        // 6. Take SUI from YES balance and return to user
        // Create a coin from the split balance and transfer to the user
        assert!(balance::value(&market.yes_liquidity) > 0, EDebugLiquiditySplit);
        assert!(
            balance::value(&market.yes_liquidity) >= sui_return_amount,
            EDebugInsufficientLiquidity,
        );
        let balance_split = balance::split(&mut market.yes_liquidity, sui_return_amount);
        let coin_to_return = coin::from_balance(balance_split, ctx);
        sui::transfer::public_transfer(coin_to_return, sender);

        // We'll burn the coins at the end of the function
    } else {
        // Calculate SUI to return: shares * price / 100 (price is in percentage)
        assert!(market.no_price > 0, EDebugPriceCalculation);
        let price_decimal = (market.no_price as u128) * 100 / (BASIS_POINTS as u128); // Convert to decimal (0-100)
        let sui_amount_u128 = (shares_amount as u128) * price_decimal / 100;
        sui_return_amount = (sui_amount_u128 as u64);
        assert!(sui_return_amount > 0, EDebugPriceCalculation);

        // 4. Update user position
        assert!(user_market_position.no_shares >= shares_amount, EDebugSharesUpdate);
        user_market_position.no_shares = user_market_position.no_shares - shares_amount;
        assert!(market.no_shares >= shares_amount, EDebugSharesUpdate);
        market.no_shares = market.no_shares - shares_amount;

        // 5. Update market prices - decrease NO price, increase YES price
        assert!(market.total_liquidity > 0, EDebugPriceChange);
        let price_change = calculate_price_change(sui_return_amount, market.total_liquidity);
        assert!(price_change > 0, EDebugPriceChange);

        // Ensure we don't exceed 100% or go below 0%
        if (price_change < market.no_price) {
            assert!(price_change <= market.no_price, EDebugPriceAdjustment);
            market.no_price = market.no_price - price_change;
            market.yes_price = market.yes_price + price_change;
            assert!(market.yes_price + market.no_price == BASIS_POINTS, EDebugPriceAdjustment);
        } else {
            // Cap at 99% probability to avoid extreme prices
            market.no_price = 100; // 1%
            market.yes_price = 9900; // 99%
        };

        // 6. Take SUI from NO balance and return to user
        // Create a coin from the split balance and transfer to the user
        assert!(balance::value(&market.no_liquidity) > 0, EDebugLiquiditySplit);
        assert!(
            balance::value(&market.no_liquidity) >= sui_return_amount,
            EDebugInsufficientLiquidity,
        );
        let balance_split = balance::split(&mut market.no_liquidity, sui_return_amount);
        let coin_to_return = coin::from_balance(balance_split, ctx);
        sui::transfer::public_transfer(coin_to_return, sender);

        // We'll burn the coins at the end of the function
    };

    // Ensure prices always sum to 100%
    assert!(market.yes_price + market.no_price == BASIS_POINTS, ECalculationError);

    // 7. Update market total liquidity
    market.total_liquidity =
        balance::value(&market.yes_liquidity) + balance::value(&market.no_liquidity);

    // 8. Check if position is now empty and clean up if needed
    if (user_market_position.yes_shares == 0 && user_market_position.no_shares == 0) {
        vec_map::remove(user_positions_map, &market_id);

        // Clean up user's position map if it becomes empty
        if (vec_map::is_empty(user_positions_map)) {
            table::remove(&mut markets_obj.positions, sender);
        }
    };

    // 9. Now that we're done with all operations that borrow markets_obj, we can burn the coins
    // Only burn the coins that correspond to the shares being sold
    // The other coins should be zero and will be destroyed with destroy_zero
    if (is_yes) {
        burn_yes_coins(markets_obj, yes_coins);
        coin::destroy_zero(no_coins);
    } else {
        burn_no_coins(markets_obj, no_coins);
        coin::destroy_zero(yes_coins);
    };

    // 10. Emit event for position close
    let event = PositionClosed {
        market_id,
        user: sender,
        is_yes,
        sui_amount: sui_return_amount,
        shares_sold: shares_amount,
    };
    event::emit(event);
}

/// Resolves a market with the final outcome (YES or NO)
/// Only the market creator can call this function
/// Market must be active and its end time must have passed
public entry fun resolve_market(
    _: &AdminCap,
    markets_obj: &mut Markets,
    market_id: u64,
    outcome: u8, // true for YES, false for NO
    clock: &Clock,
    _: &mut TxContext,
) {
    assert!(outcome > 0, EOutcomeError);

    // 1. Check that market exists and get mutable reference
    assert!(table::contains(&markets_obj.markets, market_id), EMarketNotFound);
    let market = table::borrow_mut(&mut markets_obj.markets, market_id);

    // 2. Check that caller is the market creator
    // let sender = tx_context::sender(ctx);
    // assert!(sender == market.creator, EUnauthorized);

    // 3. Check that market is active and not already resolved
    assert!(market.status == MARKET_STATUS_ACTIVE, EMarketAlreadyResolved);

    // 4. Check that market end time has passed
    let current_timestamp = clock::timestamp_ms(clock);
    assert!(current_timestamp >= market.end_time, EMarketNotClosed);

    // 5. Update market status and set resolved outcome
    market.status = MARKET_STATUS_RESOLVED;
    market.resolved_outcome = outcome;

    if (outcome == 1) {
        let no_balance = balance::withdraw_all(&mut market.no_liquidity);
        balance::join(&mut market.yes_liquidity, no_balance);
    } else {
        let yes_balance = balance::withdraw_all(&mut market.yes_liquidity);
        balance::join(&mut market.no_liquidity, yes_balance);
    };

    event::emit(MarketResolved {
        market_id: market_id,
        outcome: outcome,
    });
}

/// Allows a user to claim their winnings from a resolved market
/// The market must be resolved before claiming
/// Only users who bet on the winning outcome can claim rewards
public entry fun claim_winnings(
    markets_obj: &mut Markets,
    market_id: u64,
    yes_coins: Coin<YES_COIN>,
    no_coins: Coin<NO_COIN>,
    ctx: &mut TxContext,
) {
    // 1. Check that market exists and is resolved
    assert!(table::contains(&markets_obj.markets, market_id), EMarketNotFound);
    let market = table::borrow_mut(&mut markets_obj.markets, market_id);
    assert!(market.status == MARKET_STATUS_RESOLVED, EMarketNotClosed);

    // 2. Get resolved outcome (should be Some since market is resolved)
    let resolved_outcome = if (&market.resolved_outcome == 1) {
        true
    } else {
        false
    };

    // 3. Check if user has a position in this market
    let sender = tx_context::sender(ctx);
    assert!(table::contains(&markets_obj.positions, sender), EPositionNotFound);

    let positions_map = table::borrow_mut(&mut markets_obj.positions, sender);
    assert!(vec_map::contains(positions_map, &market_id), EPositionNotFound);

    // 4. Get user position and check if they have shares in the winning outcome
    let (_, user_position) = vec_map::remove(positions_map, &market_id);

    let winning_shares = if (resolved_outcome) {
        user_position.yes_shares
    } else {
        user_position.no_shares
    };

    // 5. Ensure user has winning shares
    assert!(winning_shares > 0, EInsufficientFunds);

    // 6. Calculate winnings (proportional to share of winning pool)
    let total_winning_pool_size = if (resolved_outcome) {
        balance::value(&market.yes_liquidity)
    } else {
        balance::value(&market.no_liquidity)
    };

    let total_winning_shares = if (resolved_outcome) {
        market.yes_shares
    } else {
        market.no_shares
    };

    // Calculate user's share of the total winning pool
    let total_liquidity = market.total_liquidity;
    assert!(total_winning_pool_size > 0, ECalculationError);

    let user_share_percentage_numerator = (winning_shares as u128) * 10000;
    let user_share_percentage = user_share_percentage_numerator / (total_winning_shares as u128);

    let user_winnings_numerator = (total_liquidity as u128) * user_share_percentage;
    let mut user_winnings = (user_winnings_numerator / 10000) as u64;

    // 7. Transfer winnings to user
    let winning_pool_balance = if (resolved_outcome) {
        &mut market.yes_liquidity
    } else {
        &mut market.no_liquidity
    };

    // Ensure we don't try to split more than available in the pool
    if (user_winnings > balance::value(winning_pool_balance)) {
        user_winnings = balance::value(winning_pool_balance);
    };

    let reward_balance = balance::split(winning_pool_balance, user_winnings);
    let reward_coin = coin::from_balance(reward_balance, ctx);
    transfer::public_transfer(reward_coin, sender);

    // 8. Update market total liquidity
    market.total_liquidity = market.total_liquidity - user_winnings;

    // Optional: Clean up user's position map if it becomes empty
    if (vec_map::is_empty(positions_map)) {
        table::remove(&mut markets_obj.positions, sender);
    };

    // Now that we're done with all operations that borrow markets_obj, we can burn the coins
    // Burn both YES and NO coins to consume the parameters regardless of outcome
    burn_yes_coins(markets_obj, yes_coins);
    burn_no_coins(markets_obj, no_coins);
}

// === Test-only functions ===

/// Create a Markets object for testing
#[test_only]
public fun create_markets_test_only(ctx: &mut TxContext) {
    // For testing, we create dummy treasury caps using mint_for_testing
    // This avoids the one-time witness issue in tests
    let yes_treasury = coin::create_treasury_cap_for_testing<YES_COIN>(ctx);
    let no_treasury = coin::create_treasury_cap_for_testing<NO_COIN>(ctx);

    let markets_obj = Markets {
        id: object::new(ctx),
        next_market_id_counter: 0,
        markets: table::new<u64, Market>(ctx),
        positions: table::new<address, VecMap<u64, UserPosition>>(ctx),
        yes_treasury_cap: option::some(yes_treasury),
        no_treasury_cap: option::some(no_treasury),
    };
    // Share the object immediately after creation
    transfer::share_object(markets_obj);

    // Create and transfer AdminCap for testing
    transfer::transfer(AdminCap { id: object::new(ctx) }, tx_context::sender(ctx));
}

#[test_only]
/// Helper for creating a market in tests
public fun create_market_test_only(
    markets_obj: &mut Markets,
    game_id: u64,
    name: String,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Use fixed end time in test environment
    let end_time = 1719735321000; // Set a fixed future timestamp for testing

    let market_id_counter = markets_obj.next_market_id_counter;
    markets_obj.next_market_id_counter = market_id_counter + 1;

    let sender = tx_context::sender(ctx);
    let name_bytes = *ascii::as_bytes(&name);

    // For testing, we skip the treasury creation to avoid one-time witness issues
    // In real environment, treasuries are created in create_market function

    let new_market = Market {
        id: object::new(ctx),
        game_id: game_id,
        name: name,
        end_time: end_time,
        yes_price: INITIAL_PRICE, // Initial price of 0.5 (50%) for YES
        no_price: INITIAL_PRICE, // Initial price of 0.5 (50%) for NO
        status: MARKET_STATUS_ACTIVE,
        // resolved_outcome is initially None
        resolved_outcome: 0,
        yes_shares: 0,
        no_shares: 0,
        yes_liquidity: balance::zero<SUI>(),
        no_liquidity: balance::zero<SUI>(),
        total_liquidity: 0,
        creator: sender,
    };

    // Add the market to the table
    table::add(&mut markets_obj.markets, market_id_counter, new_market);

    // Emit an event
    event::emit(MarketCreated {
        market_id: market_id_counter,
        game_id: game_id,
        name_bytes: name_bytes,
        end_time: end_time,
        creator: sender,
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
    let outcome = if (&market.resolved_outcome == 1) {
        true
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
    outcome: u8,
    _clock: &Clock,
) {
    // Validate the market ID exists
    assert!(table::contains(&markets_obj.markets, market_id), EMarketNotFound);
    let market = table::borrow_mut(&mut markets_obj.markets, market_id);

    // Set market status to resolved
    market.status = MARKET_STATUS_RESOLVED;
    market.resolved_outcome = outcome;

    // Emit event
    event::emit(MarketResolved {
        market_id: market_id,
        outcome: outcome,
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
    ctx: &mut TxContext,
) {
    // For testing, we simulate the buy_shares behavior without creating actual YES/NO tokens
    // 1. Get market and check status/time
    assert!(table::contains(&markets_obj.markets, market_id), EMarketNotFound);
    let market = table::borrow_mut(&mut markets_obj.markets, market_id);
    assert!(market.status == MARKET_STATUS_ACTIVE, EMarketAlreadyClosed);

    let current_timestamp = clock::timestamp_ms(clock);
    assert!(current_timestamp < market.end_time, EMarketAlreadyClosed);

    // 2. Get payment amount and current balances
    let sui_amount = coin::value(&sui_payment);
    assert!(sui_amount > 0, EInsufficientFunds);

    // 3. Calculate shares based on current price (which is the probability)
    let shares_bought: u64;
    let amount_u128 = sui_amount as u128;

    if (is_yes) {
        // Calculate shares
        let price_decimal = (market.yes_price as u128) * 100 / (BASIS_POINTS as u128);
        assert!(price_decimal > 0, ECalculationError);
        let shares_bought_u128 = (amount_u128 * 100) / price_decimal;
        assert!(shares_bought_u128 <= u64::max_value!() as u128, ECalculationError);
        shares_bought = shares_bought_u128 as u64;

        // Add payment to YES balance
        balance::join(&mut market.yes_liquidity, coin::into_balance(sui_payment));

        // Update market prices
        let price_change = calculate_price_change(sui_amount, market.total_liquidity);
        if (price_change < market.no_price) {
            market.yes_price = market.yes_price + price_change;
            market.no_price = market.no_price - price_change;
        } else {
            market.yes_price = 9900;
            market.no_price = 100;
        }
    } else {
        // Calculate shares for NO
        let price_decimal = (market.no_price as u128) * 100 / (BASIS_POINTS as u128);
        assert!(price_decimal > 0, ECalculationError);
        let shares_bought_u128 = (amount_u128 * 100) / price_decimal;
        assert!(shares_bought_u128 <= u64::max_value!() as u128, ECalculationError);
        shares_bought = shares_bought_u128 as u64;

        // Add payment to NO balance
        balance::join(&mut market.no_liquidity, coin::into_balance(sui_payment));

        // Update market prices
        let price_change = calculate_price_change(sui_amount, market.total_liquidity);
        if (price_change < market.yes_price) {
            market.no_price = market.no_price + price_change;
            market.yes_price = market.yes_price - price_change;
        } else {
            market.no_price = 9900;
            market.yes_price = 100;
        }
    };

    // Ensure prices always sum to 100%
    assert!(market.yes_price + market.no_price == BASIS_POINTS, ECalculationError);

    // Update market total liquidity tracking
    market.total_liquidity =
        balance::value(&market.yes_liquidity) + balance::value(&market.no_liquidity);

    // Update user position in the positions table
    let sender = tx_context::sender(ctx);
    let user_positions_map = if (table::contains(&markets_obj.positions, sender)) {
        table::borrow_mut(&mut markets_obj.positions, sender)
    } else {
        table::add(&mut markets_obj.positions, sender, vec_map::empty<u64, UserPosition>());
        table::borrow_mut(&mut markets_obj.positions, sender)
    };

    let user_market_position = if (vec_map::contains(user_positions_map, &market_id)) {
        vec_map::get_mut(user_positions_map, &market_id)
    } else {
        vec_map::insert(
            user_positions_map,
            market_id,
            UserPosition { yes_shares: 0, no_shares: 0 },
        );
        vec_map::get_mut(user_positions_map, &market_id)
    };

    // Add the bought shares to the user's position
    if (is_yes) {
        user_market_position.yes_shares = user_market_position.yes_shares + shares_bought;
        market.yes_shares = market.yes_shares + shares_bought;
    } else {
        user_market_position.no_shares = user_market_position.no_shares + shares_bought;
        market.no_shares = market.no_shares + shares_bought;
    };

    // Emit event
    event::emit(PositionOpened {
        market_id: market_id,
        user: sender,
        is_yes: is_yes,
        sui_amount: sui_amount,
        shares_bought: shares_bought,
    });

    // Note: In testing, we don't create actual YES/NO coins
}

#[test_only]
/// Sell shares in a market for testing
public fun sell_shares_test_only(
    markets_obj: &mut Markets,
    market_id: u64,
    is_yes: bool,
    shares_amount: u64,
    yes_coins: Coin<YES_COIN>,
    no_coins: Coin<NO_COIN>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Delegate to the main implementation
    sell_shares(markets_obj, market_id, is_yes, shares_amount, yes_coins, no_coins, clock, 0, ctx)
}

#[test_only]
/// Claim winnings from a market for testing
public fun claim_winnings_test_only(
    markets_obj: &mut Markets,
    market_id: u64,
    _yes_coins: Coin<YES_COIN>, // Accept coins but don't use them
    _no_coins: Coin<NO_COIN>,
    ctx: &mut TxContext,
) {
    // 1. Check that market exists and is resolved
    assert!(table::contains(&markets_obj.markets, market_id), EMarketNotFound);
    let market = table::borrow_mut(&mut markets_obj.markets, market_id);
    assert!(market.status == MARKET_STATUS_RESOLVED, EMarketNotClosed);

    // 2. Get resolved outcome (should be Some since market is resolved)
    let resolved_outcome = if (&market.resolved_outcome == 1) {
        true
    } else {
        false
    };

    // 3. Check if user has a position in this market
    let sender = tx_context::sender(ctx);
    assert!(table::contains(&markets_obj.positions, sender), EPositionNotFound);

    let positions_map = table::borrow_mut(&mut markets_obj.positions, sender);
    assert!(vec_map::contains(positions_map, &market_id), EPositionNotFound);

    // 4. Get user position and check if they have shares in the winning outcome
    let (_, user_position) = vec_map::remove(positions_map, &market_id);

    let winning_shares = if (resolved_outcome) {
        user_position.yes_shares
    } else {
        user_position.no_shares
    };

    // 5. Ensure user has winning shares
    assert!(winning_shares > 0, EInsufficientFunds);

    // 6. Calculate winnings (simplified for testing)
    let total_winning_pool_size = if (resolved_outcome) {
        balance::value(&market.yes_liquidity)
    } else {
        balance::value(&market.no_liquidity)
    };

    let total_winning_shares = if (resolved_outcome) {
        market.yes_shares
    } else {
        market.no_shares
    };

    // Calculate user's share of the total winning pool
    let total_liquidity = market.total_liquidity;
    assert!(total_winning_pool_size > 0, ECalculationError);

    let user_share_percentage_numerator = (winning_shares as u128) * 10000;
    let user_share_percentage = user_share_percentage_numerator / (total_winning_shares as u128);

    let user_winnings_numerator = (total_liquidity as u128) * user_share_percentage;
    let mut user_winnings = (user_winnings_numerator / 10000) as u64;

    // 7. Transfer winnings to user
    let winning_pool_balance = if (resolved_outcome) {
        &mut market.yes_liquidity
    } else {
        &mut market.no_liquidity
    };

    // Ensure we don't try to split more than available in the pool
    if (user_winnings > balance::value(winning_pool_balance)) {
        user_winnings = balance::value(winning_pool_balance);
    };

    let reward_balance = balance::split(winning_pool_balance, user_winnings);
    let reward_coin = coin::from_balance(reward_balance, ctx);
    transfer::public_transfer(reward_coin, sender);

    // 8. Update market total liquidity
    market.total_liquidity = market.total_liquidity - user_winnings;

    // Optional: Clean up user's position map if it becomes empty
    if (vec_map::is_empty(positions_map)) {
        table::remove(&mut markets_obj.positions, sender);
    };

    // For testing, we simply destroy the input coins instead of burning them
    coin::destroy_zero(_yes_coins);
    coin::destroy_zero(_no_coins);
}
