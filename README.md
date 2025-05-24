# PredictPlay - Prediction Market Platform on Sui Blockchain

<p align="center">
  <img src="predictplay_logo.png" alt="PredictPlay Logo" width="200">
</p>

<div align="center">
  <strong>Decentralized Prediction Market Protocol Built on Sui Move</strong>
</div>

<div align="center">
  <sub>Create Markets · Buy Shares · Predict Outcomes · Earn Rewards</sub>
</div>

<br />

## 📖 Project Overview

PredictPlay is a decentralized prediction market platform running on the Sui blockchain, allowing users to create prediction markets for various events, buy and sell shares of different outcomes, and claim rewards after market resolution.

The protocol leverages Automated Market Maker (AMM) mechanisms and liquidity pools to ensure efficient market operations while providing a fair and transparent trading environment for participants.

## ✨ Core Features

- **Create Prediction Markets**: Anyone can create prediction markets for future events
- **YES/NO Share Trading**: Users can buy or sell shares representing possible event outcomes
- **Dynamic Pricing Mechanism**: Prices automatically adjust based on market liquidity and trading volume
- **Outcome Settlement**: Users holding shares of the winning outcome can claim rewards after market closure
- **Virtual Liquidity**: Uses virtual liquidity to ensure smooth market operations

## 🔧 Technical Architecture

### Main Modules

- **predictplay.move**: Core protocol logic containing market creation, trading, and settlement functionality
- **yes_coin.move**: Definition and management of YES outcome tokens
- **no_coin.move**: Definition and management of NO outcome tokens

### Key Structures

- **Markets**: Shared object storing all market data
- **Market**: Represents a single prediction market, containing name, end time, price, and liquidity information
- **UserPosition**: Stores a user's share holdings in a specific market

## 🚀 How to Use

### Prerequisites

- Install [Sui CLI](https://docs.sui.io/build/install)
- Have some SUI tokens for transactions

### Deploy Contract

```bash
sui client publish --gas-budget 100000000
```

### Create Prediction Market

```bash
sui client call --package <PACKAGE_ID> --module predictplay --function create_market --args <ADMIN_CAP> <MARKETS_OBJ> <GAME_ID> <NAME> <CLOCK_OBJ> <PERIOD_MINUTES> --gas-budget 10000000
```

### Buy Shares

```bash
sui client call --package <PACKAGE_ID> --module predictplay --function buy_shares --args <MARKETS_OBJ> <MARKET_ID> <IS_YES> <SHARES_AMOUNT> <SUI_COIN> <CLOCK_OBJ> <SLIPPAGE_BP> --gas-budget 10000000
```

### Sell Shares

```bash
sui client call --package <PACKAGE_ID> --module predictplay --function sell_shares --args <MARKETS_OBJ> <MARKET_ID> <IS_YES> <SHARES_AMOUNT> <YES_COINS> <NO_COINS> <CLOCK_OBJ> <SLIPPAGE_BP> --gas-budget 10000000
```

### Claim Rewards

```bash
sui client call --package <PACKAGE_ID> --module predictplay --function claim_winnings --args <MARKETS_OBJ> <MARKET_ID> <YES_COINS> <NO_COINS> --gas-budget 10000000
```

## 📊 Market Mechanism

### Price Calculation

PredictPlay uses a liquidity-based dynamic pricing mechanism:

- Each market has YES and NO outcomes, with prices always summing to 100%
- Initial prices are set at 50%/50%
- The ratio of transaction amount to market liquidity determines price impact
- Maximum price change limits prevent excessive price impact from large trades

### Virtual Liquidity

To ensure smooth market operations, the system introduces the concept of virtual liquidity:

- Initial virtual liquidity is set at 1 SUI (10^9 MIST)
- Virtual liquidity is not actual funds, only used for price calculations
- Helps reduce the excessive impact of small trades on prices

## 📜 Project Status

Current version: v3

## 🔮 Future Plans

- Add more market types
- Implement fee sharing for market creators
- Introduce liquidity provider incentives
- Develop a user-friendly frontend interface

## 👥 Contribution Guidelines

Contributions are welcome! Please fork this repository and submit a pull request.

## 📄 License

[MIT](LICENSE)
