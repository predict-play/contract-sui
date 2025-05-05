# PredictPlay: Decentralized Prediction Markets on Sui

PredictPlay is a decentralized prediction market platform built on the Sui blockchain. It allows users to create markets for predicting outcomes of various events, trade shares representing those outcomes, and earn rewards for correct predictions.

## Overview

This platform implements a prediction market mechanism where:
- Users can create markets for specific events or games
- Users can buy shares in YES or NO outcomes
- Market prices are automatically adjusted based on trading activity
- Markets are resolved when outcomes are determined
- Users who predicted correctly can claim rewards

The platform uses an automated market maker model with a CFMM (Constant Function Market Maker) approach to ensure liquidity and determine fair prices based on market activity.

## Key Features

- **Market Creation**: Create prediction markets for various events with customizable duration
- **Share Trading**: Buy and sell YES/NO shares in markets
- **Dynamic Pricing**: Prices automatically adjust based on market activity
- **Market Resolution**: Markets are officially resolved when outcomes are determined
- **Reward Distribution**: Winners can claim rewards proportional to their share ownership

## Core Functions

### Market Management

- `create_market()`: Creates a new prediction market with specified parameters
- `get_markets_list()`: Returns a list of available markets with their details
- `get_market_prices()`: Returns current prices and liquidity for a specific market
- `resolve_market()`: Resolves a market with the final outcome (YES or NO)

### User Interactions

- `buy_shares()`: Purchase YES or NO shares in a market
- `sell_shares()`: Sell previously purchased shares
- `get_user_position()`: Returns a user's current position in a specific market
- `claim_winnings()`: Allows winners to claim their rewards after market resolution

### Price Mechanism

- `calculate_sui_needed_for_shares()`: Calculates the amount of SUI required to purchase a specified number of shares
- Price adjustments are made automatically according to the CFMM model, ensuring that:
  - Prices always sum to 100%
  - Price impact is limited per transaction
  - Liquidity is maintained for both outcomes

## Technical Details

The platform is built using Sui Move and leverages:
- Sui's object model for market data storage
- Tables for efficient data access
- Events for tracking market activities
- Balance management for handling SUI tokens

## Getting Started

To interact with PredictPlay, you need to:
1. Connect to the Sui network
2. Access the PredictPlay module
3. Create or participate in prediction markets through the provided functions

## Security Features

- Market time constraints ensure fair participation
- Price impact limitations prevent market manipulation
- Balance validation ensures proper fund management
- Role-based access controls for administrative functions
