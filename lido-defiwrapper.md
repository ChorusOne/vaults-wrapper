# Lido v3 stVault DeFi Wrapper - Contract Architecture

## Overview

This repository implements a DeFi wrapper system for Lido v3 staking vaults (stVaults) that enables looped staking strategies. The wrapper provides an ERC4626-compliant interface for users to deposit ETH and receive vault tokens, while supporting leverage through lending protocols like Morpho.

**Core Concept:** Users deposit ETH → receive stvETH tokens → optionally loop their position by minting stETH, borrowing against it, and redepositing to amplify staking exposure.

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        User Interactions                         │
└──────────┬──────────────────────────────────┬───────────────────┘
           │                                  │
           ▼                                  ▼
    ┌──────────────┐                   ┌──────────────┐
    │   Wrapper    │◄──────────────────│    Escrow    │
    │  (ERC4626)   │                   │              │
    └──────┬───────┘                   └──────┬───────┘
           │                                  │
           │ funds/mints                      │ executes
           ▼                                  ▼
    ┌──────────────┐                   ┌──────────────┐
    │  Dashboard   │                   │   Strategy   │
    │              │                   │ (ExampleStrategy)│
    └──────┬───────┘                   └──────┬───────┘
           │                                  │
           │ interacts                        │ borrows
           ▼                                  ▼
    ┌──────────────┐                   ┌──────────────┐
    │  VaultHub    │                   │ Lending Pool │
    │  (Lido v3)   │                   │ (Morpho/etc) │
    └──────┬───────┘                   └──────────────┘
           │
           ▼
    ┌──────────────┐
    │StakingVault  │
    │ (stVault)    │
    └──────────────┘
```

## Core Contracts

### 1. Wrapper.sol

**Purpose:** Main user-facing contract implementing ERC4626 vault standard for native ETH deposits.

**Key Responsibilities:**
- Accept ETH deposits and mint stvETH shares
- Manage total vault assets via Lido v3 Dashboard
- Handle withdrawals through WithdrawalQueue
- Track locked shares used in leverage positions
- Interface with Escrow for minting stETH

**Critical State Variables:**
```solidity
IDashboard public immutable DASHBOARD;           // Entry point to stVault
IVaultHub public immutable VAULT_HUB;            // Lido v3 core contract
address public immutable STAKING_VAULT;          // The actual stVault
WithdrawalQueue public immutable WITHDRAWAL_QUEUE;
Escrow public ESCROW;                            // Set post-deployment
uint256 public totalLockedStvShares;             // Shares in leverage positions
```

**Key External Functions:**

```solidity
// Deposit ETH and receive stvETH shares
function depositETH(address receiver) public payable returns (uint256 shares)

// Request withdrawal (queued if insufficient liquidity)
function withdraw(uint256 shares) external returns (uint256 requestId)

// Mint stETH from locked stvToken shares (called by Escrow)
function mintStETHForEscrow(uint256 stvShares, address stethReceiver) 
    external returns (uint256 mintedStethShares)

// Calculate share rate accounting for borrowed assets
function calculateShareRate() public view returns (uint256)
```

**Integration with Lido v3 stVault:**
1. **Funding:** `DASHBOARD.fund{value: msg.value}()` deposits ETH into stVault
2. **Minting:** `DASHBOARD.mintShares(recipient, shares)` mints stETH shares
3. **Querying:** `VAULT_HUB.totalValue(STAKING_VAULT)` gets total vault value
4. **Withdrawing:** `DASHBOARD.withdrawableValue()` checks available liquidity

### 2. Escrow.sol

**Purpose:** Holds user shares during leverage operations and coordinates between Wrapper and Strategy.

**Key Responsibilities:**
- Custody stvToken shares during position lifecycle
- Coordinate position opening/closing with Strategy
- Track individual user positions
- Mint stETH from deposited stvToken shares

**Critical State Variables:**
```solidity
Wrapper public immutable WRAPPER;
IStrategy public immutable STRATEGY;
WithdrawalQueue public immutable WITHDRAWAL_QUEUE;
IERC20 public immutable STETH;                   // Lido stETH token
IERC20 public immutable STV_TOKEN;               // Wrapper token

mapping(address => uint256) public lockedStvSharesByUser;
uint256 public totalBorrowedAssets;
```

**Key External Functions:**

```solidity
// Open a leveraged position
function openPosition(uint256 stvShares) external

// Close position and initiate exit
function closePosition(uint256 stvShares) external

// Mint stETH from stvToken shares
function mintStETH(uint256 stvShares) external returns (uint256 mintedStethShares)
```

**Flow for Opening Position:**
1. User approves Wrapper to transfer their stvToken shares
2. User calls `openPosition(shares)`
3. Escrow transfers shares from user
4. Escrow approves Strategy to use shares
5. Escrow calls `STRATEGY.execute(user, shares)`
6. Strategy executes looping mechanism

### 3. ExampleStrategy.sol

**Purpose:** Implements the leverage looping strategy using a lending protocol.

**Key Responsibilities:**
- Execute multi-loop leverage strategy
- Coordinate with lending pool (Morpho/Aave/etc)
- Track individual user positions
- Manage position exit flow

**Critical State Variables:**
```solidity
IERC20 public immutable STETH;
Wrapper public immutable WRAPPER;
LenderMock public immutable LENDER_MOCK;         // Replace with real Morpho integration
uint256 public immutable LOOPS;                   // Number of leverage loops

struct UserPosition {
    address user;
    uint256 shares;                               // Initial shares deposited
    uint256 borrowAmount;                         // Total ETH borrowed
    bool isExiting;
    uint256 totalStvTokenShares;                  // Accumulated shares from loops
}

mapping(address => UserPosition) public userPositions;
```

**Key External Functions:**

```solidity
// Execute leverage strategy (called by Escrow)
function execute(address user, uint256 stvTokenShares) external override

// Initiate position exit
function initiateExit(address user, uint256 assets) external override

// Finalize exit and return assets
function finalizeExit(address user) external override returns (uint256 assets)

// Get position details
function getBorrowDetails() external view override returns (
    uint256 borrowAssets,
    uint256 userAssets,
    uint256 totalAssets
)
```

**Leverage Loop Mechanics:**

The strategy executes N loops (configurable via LOOPS parameter):

```
For each loop iteration:
1. Mint stETH from stvToken shares
   └─> Call WRAPPER.mintStETH() via Escrow
   
2. Borrow ETH against stETH collateral
   └─> Transfer stETH to lending pool (Morpho)
   └─> Receive ETH (typically 75% LTV)
   
3. Deposit borrowed ETH back to Wrapper
   └─> Call WRAPPER.depositETH()
   └─> Receive new stvToken shares
   
4. Use new shares for next loop iteration
```

**Example Loop Flow (2 loops, 75% LTV):**
```
Initial: User deposits 1000 stvETH shares

Loop 1:
  - Mint stETH from 1000 shares → get ~1000 stETH shares
  - Borrow against 1000 stETH → get 750 ETH
  - Deposit 750 ETH → get 750 stvETH shares

Loop 2:
  - Mint stETH from 750 shares → get ~750 stETH shares
  - Borrow against 750 stETH → get 562.5 ETH
  - Deposit 562.5 ETH → get 562.5 stvETH shares

Total Position:
  - Initial: 1000 stvETH
  - Accumulated: 1312.5 stvETH (750 + 562.5)
  - Total Borrowed: 1312.5 ETH
  - Total Exposure: 2312.5 stvETH worth of staking
```

### 4. WithdrawalQueue.sol

**Purpose:** Manages deferred withdrawals when immediate liquidity is unavailable in the stVault.

**Key Responsibilities:**
- Queue withdrawal requests
- Track cumulative assets/shares for efficient batch processing
- Implement checkpoint system for share rate adjustments
- Process claims when liquidity becomes available

**Critical State Variables:**
```solidity
IDashboard public immutable dashboard;

struct WithdrawalRequest {
    uint256 cumulativeAssets;
    uint256 cumulativeShares;
    address user;
    uint256 timestamp;
    bool isFinalized;
    bool isClaimed;
}

struct Checkpoint {
    uint256 fromRequestId;
    uint256 shareRate;                           // E27 precision
}

mapping(uint256 => WithdrawalRequest) public requests;
mapping(uint256 => Checkpoint) public checkpoints;
uint256 public nextRequestId;
uint256 public lastFinalizedRequestId;
```

**Key External Functions:**

```solidity
// Request withdrawal (called by Wrapper)
function requestWithdrawal(address user, uint256 shares, uint256 assets) 
    external onlyOwner returns (uint256 requestId)

// Finalize batch of requests
function finalize(uint256 lastRequestIdToFinalize, uint256 amountOfETH, uint256 shareRate) 
    external onlyOwner

// User claims their finalized withdrawal
function claim(uint256 requestId) external

// Calculate claimable amount with share rate adjustments
function calculateClaimableAssets(uint256 requestId) external view returns (uint256)
```

**Withdrawal Flow:**

1. **Immediate Withdrawal (Fast Path):**
   ```
   User calls withdraw() → Check dashboard.withdrawableValue()
   If sufficient → Transfer ETH immediately, return requestId = 0
   ```

2. **Queued Withdrawal (Deferred Path):**
   ```
   User calls withdraw() → Insufficient liquidity
   Create withdrawal request with cumulative accounting
   Return requestId > 0
   
   Later, when liquidity available:
   Admin calls finalize() with batch of requests + share rate
   Creates checkpoint for share rate adjustment
   
   User calls claim() → Receive ETH with adjusted share rate
   ```

**Share Rate Adjustments:**

The checkpoint system allows the protocol to adjust payouts based on vault performance:

```solidity
// When vault value changes between request and finalization:
claimableAssets = (requestedAssets * checkpointShareRate) / E27_PRECISION_BASE

// Example:
// - User requests withdrawal worth 1000 ETH
// - Vault loses 5% value before finalization
// - Checkpoint shareRate = 0.95e27
// - User receives: 1000 * 0.95e27 / 1e27 = 950 ETH
```

## Lido v3 stVault Integration Points

### Dashboard Contract

The Dashboard is the primary interface for vault owners to interact with their stVault.

**Key Functions Used:**

```solidity
// Fund the vault with ETH
function fund() external payable
// → Called by Wrapper.depositETH()
// → Increases stVault's ETH balance

// Mint stETH shares to recipient
function mintShares(address recipient, uint256 shares) external payable
// → Called by Wrapper.mintStETHForEscrow()
// → Converts vault ETH to stETH shares based on minting capacity

// Withdraw ETH from vault
function withdraw(address recipient, uint256 ether) external
// → Called by WithdrawalQueue
// → Returns ETH from stVault to withdrawal queue

// Check minting capacity
function remainingMintingCapacityShares(uint256 etherToFund) external view returns (uint256)
// → Used to determine how much stETH can be minted
// → Affected by reserveRatioBP and vault's total value
```

**Required Permissions:**

The Wrapper and Escrow need specific roles granted on the Dashboard:

```solidity
// Wrapper needs:
dashboard.grantRole(FUND_ROLE(), address(wrapper))
dashboard.grantRole(MINT_ROLE(), address(wrapper))

// Escrow needs:
dashboard.grantRole(MINT_ROLE(), address(escrow))
```

### VaultHub Contract

The VaultHub tracks all connected vaults and manages the relationship between vaults and Lido.

**Key Functions Used:**

```solidity
// Get total value of vault (includes beacon chain + local balance)
function totalValue(address vault) external view returns (uint256)
// → Called by Wrapper.totalAssets()
// → Critical for share price calculation

// Get withdrawable value (local ETH balance)
function withdrawableValue(address vault) external view returns (uint256)
// → Called by WithdrawalQueue
// → Determines if immediate withdrawal is possible

// Get vault connection details
function vaultConnection(address vault) external view returns (VaultConnection memory)
// → Returns reserveRatioBP, shareLimit, fees, etc.
// → Important for understanding minting constraints
```

**VaultConnection Struct:**

```solidity
struct VaultConnection {
    address owner;                              // Wrapper is the owner
    uint96 shareLimit;                          // Max stETH shares mintable
    uint96 vaultIndex;
    bool pendingDisconnect;
    uint16 reserveRatioBP;                      // % of ETH kept as reserve (e.g., 3000 = 30%)
    uint16 forcedRebalanceThresholdBP;
    uint16 infraFeeBP;
    uint16 liquidityFeeBP;
    uint16 reservationFeeBP;
    bool isBeaconDepositsManuallyPaused;
}
```

**Reserve Ratio Impact:**

The reserveRatioBP determines how much stETH can be minted from vault ETH:

```
If vault has 1000 ETH and reserveRatioBP = 3000 (30%):
- Max stETH mintable = 700 stETH (70% of vault value)
- 300 ETH must stay in vault as reserve
```

### StakingVault Contract

The StakingVault is where ETH is actually held and staked to the beacon chain.

**Key Properties:**

```solidity
function owner() external view returns (address)
// → Should be the VaultHub or Dashboard

function withdrawalCredentials() external view returns (bytes32)
// → Used for validator deposits

function depositToBeaconChain(Deposit[] calldata deposits) external
// → Node operator deposits validators to beacon chain
// → Not directly called by wrapper
```

## Key Architectural Patterns

### 1. Circular Dependency Resolution

**Problem:** Wrapper needs Escrow address, Escrow needs Wrapper address.

**Solution:** Two-phase initialization:

```solidity
// Phase 1: Deploy Wrapper without Escrow
wrapper = new Wrapper(
    address(dashboard),
    address(withdrawalQueue),
    address(0),  // ← Escrow placeholder
    "stvETH",
    "stvETH"
);

// Phase 2: Deploy Escrow with Wrapper
escrow = new Escrow(
    address(wrapper),
    address(withdrawalQueue),
    address(strategy),
    address(steth)
);

// Phase 3: Link Escrow to Wrapper
wrapper.setEscrowAddress(address(escrow));
```

### 2. High-Precision Accounting

All share rate calculations use E27 precision (1e27) to avoid rounding errors:

```solidity
uint256 public constant E27_PRECISION_BASE = 1e27;

function calculateShareRate() public view returns (uint256) {
    uint256 vaultTotalAssets = totalAssets();
    uint256 totalBorrowedAssets = ESCROW.getTotalBorrowedAssets();
    uint256 userTotalAssets = vaultTotalAssets - totalBorrowedAssets;
    
    if (totalSupply() == 0) return E27_PRECISION_BASE; // 1.0
    
    return (userTotalAssets * E27_PRECISION_BASE) / totalSupply();
}
```

### 3. Minting Capacity Management

The amount of stETH that can be minted is constrained by:

1. **Reserve Ratio:** Vault must keep minimum % as ETH reserve
2. **Share Limit:** Maximum stETH shares vault can mint (governance parameter)

```solidity
// Check remaining capacity before minting
uint256 remainingCapacity = dashboard.remainingMintingCapacityShares(0);
require(sharesToMint <= remainingCapacity, "Insufficient minting capacity");
```

**Impact on Leverage:**
- If reserve ratio is 30%, each loop can only mint 70% of vault value
- This limits the effective leverage multiplier
- Strategy must account for this when calculating max loops

## Complete User Flow Examples

### Example 1: Simple Deposit

```
1. User has 10 ETH
2. User calls wrapper.depositETH{value: 10 ETH}()
   ├─> Wrapper calls dashboard.fund{value: 10 ETH}()
   │   └─> Dashboard increases stVault balance by 10 ETH
   ├─> Wrapper calculates shares: 10 ETH * totalSupply / totalAssets
   └─> Wrapper mints shares to user

3. User receives ~10 stvETH tokens (1:1 if first deposit)
4. User's stvETH represents claim on vault's staked ETH + rewards
```

### Example 2: Leveraged Position (2x Loop, 75% LTV)

```
1. User deposits 10 ETH → receives 10 stvETH (same as Example 1)

2. User calls escrow.openPosition(10 stvETH)
   ├─> Transfer 10 stvETH from user to Escrow
   └─> Escrow calls strategy.execute(user, 10 stvETH)

3. Strategy Loop 1:
   ├─> Call escrow.mintStETH(10 stvETH)
   │   └─> Wrapper calls dashboard.mintShares(escrow, ~7 stETH)
   │       (7 instead of 10 due to 30% reserve ratio)
   ├─> Strategy borrows 5.25 ETH from lending pool (75% LTV on 7 stETH)
   └─> Strategy deposits 5.25 ETH to wrapper → receives 5.25 stvETH

4. Strategy Loop 2:
   ├─> Call escrow.mintStETH(5.25 stvETH)
   │   └─> Wrapper calls dashboard.mintShares(escrow, ~3.675 stETH)
   ├─> Strategy borrows 2.756 ETH from lending pool
   └─> Strategy deposits 2.756 ETH to wrapper → receives 2.756 stvETH

5. Final Position:
   - User's initial deposit: 10 stvETH (locked in Escrow)
   - Accumulated through loops: 7.756 stvETH
   - Total borrowed: 7.756 ETH
   - Total staking exposure: ~17.756 ETH worth
   - Leverage multiplier: ~1.78x
```

### Example 3: Withdrawal with Queue

```
1. User wants to withdraw 5 stvETH

2. User calls wrapper.withdraw(5 stvETH)
   ├─> Wrapper burns 5 stvETH from user
   ├─> Wrapper calculates assets: ~5 ETH
   └─> Wrapper calls withdrawalQueue.requestWithdrawal(user, 5, ~5 ETH)

3. WithdrawalQueue checks dashboard.withdrawableValue()
   
   Case A: Sufficient liquidity (≥5 ETH available)
   ├─> Call dashboard.withdraw(user, 5 ETH)
   ├─> Transfer 5 ETH directly to user
   └─> Return requestId = 0 (immediate withdrawal)
   
   Case B: Insufficient liquidity (<5 ETH available)
   ├─> Call dashboard.withdraw(address(queue), available)
   ├─> Create withdrawal request with requestId = N
   ├─> Store cumulative assets/shares
   └─> Return requestId = N

4. If queued (Case B), later when liquidity available:
   ├─> Admin calls withdrawalQueue.finalize(requestId, ethAmount, shareRate)
   ├─> Creates checkpoint with share rate
   └─> User can now claim

5. User calls withdrawalQueue.claim(requestId)
   ├─> Calculate claimable = requestedAssets * shareRate / 1e27
   ├─> Transfer ETH to user
   └─> Mark request as claimed
```

## Security Considerations

### 1. Access Control

**Critical Permissions:**
- Only Escrow can call `Wrapper.mintStETHFromShares()`
- Only Wrapper (owner) can call `WithdrawalQueue.requestWithdrawal()`
- Strategy must be authorized to interact with Escrow

### 2. Share Rate Manipulation

**Risk:** Attacker could manipulate share rate by donating/removing assets.

**Mitigations:**
- Use cumulative accounting in WithdrawalQueue
- Checkpoint system for share rate snapshots
- Reserve ratio prevents full drain

### 3. Reentrancy

**Risk:** ETH transfers could enable reentrancy attacks.

**Mitigations:**
- Follow checks-effects-interactions pattern
- Update state before external calls
- Consider using ReentrancyGuard where needed

### 4. Lending Protocol Risk

**Risk:** If Morpho/lending pool has issues, positions could be liquidated or locked.

**Mitigations:**
- Monitor health factor continuously
- Implement emergency exit mechanisms
- Set conservative LTV ratios
- Consider circuit breakers

## Integration Checklist for Morpho

To integrate Morpho as the lending provider (replacing LenderMock):

### Contract Changes Needed:

1. **ExampleStrategy.sol:**
   ```solidity
   // Replace LenderMock with Morpho interfaces
   import {IMorpho} from "morpho-contracts/interfaces/IMorpho.sol";
   
   IMorpho public immutable MORPHO;
   bytes32 public immutable MARKET_ID; // Morpho market for stETH/ETH
   
   // Update _borrowFromPool() to use Morpho
   function _borrowFromPool(uint256 stethCollateral) internal returns (uint256) {
       // 1. Approve Morpho to take stETH
       STETH.approve(address(MORPHO), stethCollateral);
       
       // 2. Supply stETH as collateral
       MORPHO.supplyCollateral(MARKET_ID, stethCollateral, address(this), "");
       
       // 3. Borrow ETH against collateral
       uint256 borrowAmount = /* calculate based on LTV */;
       MORPHO.borrow(MARKET_ID, borrowAmount, 0, address(this), address(this));
       
       return borrowAmount;
   }
   ```

2. **Add exit/repayment logic:**
   ```solidity
   function _repayAndWithdrawCollateral() internal {
       // 1. Repay borrowed ETH
       MORPHO.repay{value: borrowedAmount}(MARKET_ID, borrowedAmount, 0, address(this), "");
       
       // 2. Withdraw stETH collateral
       MORPHO.withdrawCollateral(MARKET_ID, stethCollateral, address(this), address(this));
   }
   ```

3. **Health monitoring:**
   ```solidity
   function getHealthFactor() external view returns (uint256) {
       // Query Morpho position health
       // Implement alerts if health factor drops too low
   }
   ```

### Configuration Parameters:

- **LTV Ratio:** Start conservative (e.g., 70-75%)
- **Loop Count:** Adjust based on gas costs and desired leverage
- **Reserve Ratio:** Coordinate with Lido vault settings
- **Share Limit:** Ensure sufficient for expected TVL

### Testing Requirements:

- Integration tests with Morpho fork
- Liquidation scenario testing
- Share rate accuracy across loops
- Emergency exit procedures

## Conclusion

This DeFi wrapper provides a sophisticated looping mechanism for Lido v3 stVaults while maintaining ERC4626 compatibility. The separation of concerns (Wrapper for user interface, Escrow for custody, Strategy for execution, WithdrawalQueue for liquidity management) creates a modular, extensible architecture suitable for production use with proper Morpho integration and additional safety mechanisms.
