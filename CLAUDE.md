# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **Lido Vaults Wrapper** system that provides an ERC4626-compliant wrapper around Lido staking vaults with leverage strategy capabilities. The project enables users to deposit ETH, receive vault tokens, and optionally leverage their positions through DeFi protocols.

**Tech Stack:** Solidity 0.8.25, Foundry, OpenZeppelin contracts

## Development Commands

### Building and Testing

```bash
# Build the project
forge build

# Run all tests
forge test

# Run integration tests (requires local fork)
make test-integration

# Run integration tests with verbose output
forge test test/integration/**/*.test.sol -vvv --fork-url http://localhost:9123

# Watch mode for tests (requires entr utility)
make test-watch

# Format code
forge fmt

# Generate gas snapshots
forge snapshot
```

### Local Development with Lido Core

The project integrates with Lido Core contracts for testing. Set up a local fork:

```bash
# Initialize Lido Core submodule (first time only)
make core-init

# Start local Anvil fork
make start-fork

# Deploy Lido Core contracts to local fork (in separate terminal)
make core-deploy
```

**Important:** Integration tests require a running local fork at `http://localhost:9123` with deployed Lido Core contracts.

## Architecture

### Core Components

**Wrapper.sol** (src/Wrapper.sol)
- Main entry point implementing ERC4626 standard for native ETH
- Users deposit ETH and receive stvETH shares
- Overrides standard ERC4626 to work with native ETH instead of ERC20 tokens
- Key methods: `depositETH()`, `withdraw()`, `mintStETHForEscrow()`
- Tracks `totalLockedStvShares` for leveraged positions
- Interacts with Lido's Dashboard to fund vaults and mint stETH shares

**Escrow.sol** (src/Escrow.sol)
- Holds user shares during leverage operations
- Manages position lifecycle: opening, closing, claiming
- Acts as intermediary between Wrapper and Strategy
- Tracks individual positions with `Position` struct
- Key methods: `openPosition()`, `closePosition()`, `mintStETH()`

**ExampleStrategy.sol** (src/ExampleStrategy.sol)
- Implements `IStrategy` interface for leverage strategies
- Executes looping strategy: mint stETH → borrow ETH → deposit ETH (repeat LOOPS times)
- Contains mock lender (`LenderMock`) for borrowing against stETH collateral
- Configurable loop count for leverage multiplier
- Key methods: `execute()`, `initiateExit()`, `finalizeExit()`

**WithdrawalQueue.sol** (src/WithdrawalQueue.sol)
- Manages withdrawal requests when immediate liquidity is unavailable
- Implements checkpoint system for tracking share rates during withdrawals
- Handles cumulative assets/shares accounting
- Key methods: `requestWithdrawal()`, `finalize()`, `claim()`
- Returns requestId=0 for immediate withdrawals when liquidity is sufficient

### Integration Points

**Lido Core Integration:**
- `IDashboard`: Interface to vault management (fund, mint, withdraw)
- `IVaultHub`: Tracks vault state and total value
- `IStakingVault`: The actual staking vault holding ETH
- `IStETH`: Lido's staked ETH token

The system uses file system permissions to read Lido deployment info:
```toml
fs_permissions = [{ access = "read", path = "./lido-core/deployed-local.json"}]
```

### Key Architectural Patterns

**Circular Dependency Resolution:**
- Wrapper and Escrow have circular dependency
- Resolved via two-phase initialization: Wrapper deploys with address(0), then `setEscrowAddress()` is called
- See test setup in `test/integration/position-happy-path.test.sol:setUp()` for example

**Share Rate Calculation:**
- Uses E27_PRECISION_BASE (1e27) for high-precision share rate calculations
- `calculateShareRate()` computes rate accounting for borrowed assets: `(userTotalAssets * 1e27) / totalSupply`
- WithdrawalQueue applies share rates via checkpoints to handle vault value changes

**Leverage Loop Mechanics:**
1. User deposits stvToken shares to Escrow
2. Strategy loops N times:
   - Mint stETH from stvToken shares
   - Borrow ETH against stETH collateral (75% LTV in mock)
   - Deposit borrowed ETH to Wrapper for new stvToken shares
3. Accumulates total borrowed assets and total shares in Position struct

## Testing Strategy

Integration tests (`test/integration/`) require full Lido Core deployment and test end-to-end flows:
- Position opening with leverage loops
- Withdrawal queue mechanics
- Share rate calculations

Mock contracts (`test/mocks/`) provide lightweight alternatives for unit tests.

## Configuration

**foundry.toml:**
- Solidity version: 0.8.25
- Optimizer enabled with 200 runs
- Key remappings:
  - `@openzeppelin/contracts/` → OpenZeppelin
  - `core/` → Lido Core (for interfaces)
  - `forge-std/` → Foundry standard library

**Makefile variables:**
- `CORE_RPC_PORT`: Local fork port (default: 9123)
- `CORE_BRANCH`: Lido Core branch (default: chore/wrapper-dev)
- `CORE_SUBDIR`: Local directory for Lido Core (default: lido-core)

## Important Notes

- All token amounts involving stvToken shares and stETH use high precision (E27_PRECISION_BASE)
- The system handles native ETH, not WETH - standard ERC4626 methods like `deposit()` are disabled
- Reserve ratio from Dashboard affects how much stETH can be minted from vault ETH
- Integration tests depend on specific Lido Core deployment state and configuration
