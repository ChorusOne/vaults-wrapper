# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository is dedicated to developing **MorphoLoopStrategy** - a custom looped staking strategy contract that integrates Morpho Blue lending markets with Lido V3 staking vaults via the DeFi Wrapper system. Built with Foundry and Solidity 0.8.30.

The single contract `src/strategy/MorphoLoopStrategy.sol` is the focus of this repository. It implements leveraged staking by looping deposits through Morpho lending markets to amplify staking yields.

## Essential Commands

### Building and Testing

```bash
# Build contracts
forge build

# Format code
forge fmt
```

### Testing the Morpho Strategy

Testing is a **two-step process**:

**Step 1: Start test environment (run by developer as background task)**
```bash
bash testenv-anvil.sh
```
This starts a local Anvil fork on port 9123 with the necessary Lido core contracts deployed and configured. **This must be running before tests can execute.**

**Step 2: Run Morpho strategy tests (can be run by AI)**
```bash
FOUNDRY_PROFILE=test CORE_LOCATOR_ADDRESS=0x84eA74d481Ee0A5332c457a4d796187F6Ba67fEB \
forge test --match-contract MorphoLoopStrategyTest -vvvvv --fork-url http://localhost:9123
```

This is the only test that matters for this repository. All development focuses on making MorphoLoopStrategyTest pass.

## Architecture

### MorphoLoopStrategy

The core contract implementing leveraged staking through Morpho Blue. Located at `src/strategy/MorphoLoopStrategy.sol`.

**Leverage Loop Pattern:**
1. User deposits ETH → receives stvETH (via DeFi Wrapper)
2. Pool mints wstETH against stvETH collateral
3. Strategy supplies wstETH to Morpho as collateral
4. Strategy borrows ETH from Morpho (using callback pattern)
5. Borrowed ETH is deposited back to pool → loop continues until target leverage reached
6. Final leverage ratio = `targetLeverageBp / 10000` (e.g., 30000 = 3x)

**Key Operations:**
- `deposit()`: Execute leveraged deposit loop
- `withdraw()`: Unwind position and return assets
- `rebalance()`: Adjust leverage to maintain target ratio
- Health factor monitoring to avoid liquidation

### Integration Points

The MorphoLoopStrategy integrates with three main systems:

#### 1. DeFi Wrapper (`src/`)
The strategy implements the `IStrategy` interface to integrate with the DeFi Wrapper system:
- `IStrategy.sol`: Main interface defining strategy operations (deposit, withdraw, rebalance)
- `IStvStETHPool.sol`: Pool interface for minting wstETH, deposits, and withdrawals
- `IFeaturePausable.sol`: Pausability controls
- Access control roles and permissions

**Key Components:**
- Strategy must be allowlisted by the pool to interact
- Uses callback pattern for atomic multi-step operations
- Coordinates with pool for wstETH minting/burning

#### 2. Lido V3 stVault (`src/interfaces/core/`)
Interacts indirectly via DeFi Wrapper with Lido's core contracts:
- `IDashboard.sol`: User-facing vault operations (deposits, minting, burning)
- `IVaultHub.sol`: Manages vault connections, reserve ratios, minting capacity
- `IStakingVault.sol`: Individual validator vault operations
- `IStETH.sol` / `IWstETH.sol`: Lido staking tokens

**Integration Flow:**
- DeFi Wrapper mints wstETH via Dashboard
- Strategy receives wstETH as collateral for Morpho
- Withdrawals coordinate through Dashboard burn operations

#### 3. Morpho Blue (`lib/morpho-blue/src/`)
Direct integration with Morpho lending markets:
- `IMorpho.sol`: Core lending market interface (supply, borrow, withdraw, repay)
- `IMorphoCallbacks.sol`: Callback interfaces for atomic operations:
  - `IMorphoSupplyCallback`: Callback during supply operations
  - `IMorphoRepayCallback`: Callback during repay operations
- Market parameters stored as immutables: `MARKET_ID`, `MARKET_LLTV`, `LOAN_TOKEN`, `COLLATERAL_TOKEN`

**Callback Pattern:**
Morpho uses callbacks to enable atomic multi-step operations. During a supply or repay call, Morpho calls back into the strategy contract, allowing it to execute additional logic (like borrowing) within the same transaction. This enables the leverage loop to happen atomically.

### Key Invariants

- Strategy must be allowlisted by the pool before operations
- Health factor must remain above liquidation threshold
- Target leverage bounded by market LLTV (Loan-to-Liquidation-Threshold-Value)
- All operations must be atomic (no intermediate states exposing funds)
- Precision handling: wstETH/stETH conversions use shares-based accounting

## Configuration Files

- `foundry.toml`: Solidity 0.8.30, via-ir enabled, optimizer_runs=200
- `.env`: Must contain `RPC_URL`, `CORE_LOCATOR_ADDRESS` for testing
- `lib/morpho-blue/`: Morpho Blue contracts as git submodule

## Testing Strategy

Tests should verify:
- **Deposit loop**: Correct leverage achieved, no fund loss
- **Withdrawal unwind**: Full position closure, correct asset return
- **Health factor**: Maintained above liquidation threshold
- **Callback security**: Only Morpho can trigger callbacks
- **Access control**: Only allowlisted strategy can interact with pool
- **Edge cases**: Max leverage, minimum positions, market volatility

Use fork testing against mainnet to test with real Morpho markets and Lido contracts.

## Important Patterns

### Callback Security
Morpho callbacks must validate caller:
```solidity
function onMorphoSupply(uint256 assets, bytes calldata data) external {
    require(msg.sender == address(MORPHO), "Only Morpho");
    // ... callback logic
}
```

### Atomic Operations
Leverage loops must complete atomically to prevent fund exposure:
- Use Morpho callbacks to chain: supply → borrow → deposit → loop
- No intermediate state where funds are vulnerable
- Revert entire transaction on any step failure

### Precision Handling
- **wstETH**: Non-rebasing, shares-based (18 decimals)
- **stETH**: Rebasing, use shares for accounting (18 decimals)
- **stvETH**: 27 decimals for high precision
- Use `getSharesByPooledEth()` / `getPooledEthByShares()` for conversions
- Always round in protocol's favor to prevent exploits

### Health Factor Monitoring
```solidity
// Calculate current health factor
uint256 collateralValue = morpho.collateral(MARKET_ID, address(this)) * price;
uint256 borrowValue = morpho.borrowShares(MARKET_ID, address(this)) * price;
uint256 healthFactor = collateralValue * MARKET_LLTV / borrowValue;

// Ensure safe margin above liquidation
require(healthFactor > LIQUIDATION_THRESHOLD + SAFETY_MARGIN, "Unhealthy position");
```

## Development Workflow

1. **Implement core operations**: deposit, withdraw, rebalance
2. **Add health monitoring**: Track and maintain health factor
3. **Security hardening**: Callback validation, reentrancy guards, access control
4. **Gas optimization**: Minimize external calls, use immutables, efficient loops
5. **Comprehensive testing**: Unit tests, fork tests, edge cases
6. **Audit preparation**: Documentation, invariant checks, formal verification considerations

## Common Pitfalls

- **Oracle manipulation**: Use time-weighted or manipulation-resistant oracles
- **Liquidation risk**: Monitor health factor continuously, maintain safety margin
- **Slippage**: Account for price impact during large operations
- **Reentrancy**: Use checks-effects-interactions pattern, reentrancy guards
- **Precision loss**: Round strategically to avoid exploitable rounding errors
- **Callback validation**: Always verify `msg.sender` in callbacks

## Active Development

See `TODO.md` for detailed development status and current phase objectives.

Current focus: Building out core MorphoLoopStrategy functionality with secure deposit/withdrawal flows and health factor management.
