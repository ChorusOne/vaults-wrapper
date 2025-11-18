# MorphoLoopStrategy Testing Guide

This guide explains the testing infrastructure created for MorphoLoopStrategy and how to use it.

## Overview

The testing structure mirrors the GGVStrategy testing pattern, providing a solid foundation for testing your Morpho-based leveraged staking strategy.

## Files Created

### 1. **Mock Contracts** (`src/mock/morpho/`)

#### `MorphoMock.sol`
A complete mock implementation of the Morpho protocol with:
- **Market creation** - Create lending markets with custom parameters
- **Collateral operations** - Supply/withdraw wstETH collateral
- **Borrow/Repay** - Borrow WETH against collateral with callback support
- **Position tracking** - Track user positions (collateral, borrow shares)
- **Oracle simulation** - Mock oracle for wstETH/WETH price
- **Health checks** - Validates position health based on LLTV

**Key Features:**
- Implements the full `IMorpho` interface
- Supports `onMorphoRepay` callback (crucial for atomic leverage loops)
- Simplified 1:1 share/asset ratio for easier testing
- Helper functions: `fundMarket()`, `simulateInterest()`, `setOraclePrice()`

### 2. **Test Harness Updates** (`test/utils/`)

#### `StvPoolHarness.sol`
- Added `MORPHO_LOOP` to `StrategyKind` enum
- Added `morpho` and `morphoWeth` fields to `DeploymentConfig`
- Updated deployment logic to handle MORPHO_LOOP strategy type

### 3. **Integration Tests** (`test/integration/morpho-loop.test.sol`)

#### `MorphoLoopStrategyTest`
Main test contract that demonstrates the complete testing pattern.

**Test Suite Includes:**
1. **`test_simple_deposit_and_loop()`** - Basic deposit with 2x leverage
2. **`test_revert_if_user_not_allowlisted()`** - Allowlist validation
3. **`test_revert_if_leverage_too_high()`** - Max leverage enforcement
4. **`test_revert_if_leverage_below_1x()`** - Min leverage validation

**Mock Contracts Included:**
- `MockWETH` - Simple WETH implementation
- `SimpleStrategyCallForwarder` - Basic call forwarder for testing

## Running Tests

### Run the Simple Deposit Test

```bash
# Run just the simple deposit test
forge test --match-test test_simple_deposit_and_loop -vvv

# Run all MorphoLoopStrategy tests
forge test --match-contract MorphoLoopStrategyTest -vvv

# Run with full verbosity to see console logs
forge test --match-contract MorphoLoopStrategyTest -vvvv
```

### Expected Output

The `test_simple_deposit_and_loop` test will:
1. Deposit 1 ETH from USER1
2. Mint wstETH from the pool
3. Execute 2x leverage loop via Morpho callbacks
4. Verify the Morpho position has correct collateral and debt
5. Check actual leverage matches target (within 5% tolerance)
6. Verify position health factor is safe (> 105%)

## Test Structure Explanation

### Setup Phase

```solidity
function setUp() public {
    // 1. Initialize Lido core (stETH, wstETH, VaultHub)
    _initializeCore();
    
    // 2. Deploy WETH mock
    weth = IWETH(deployMockWETH());
    
    // 3. Deploy Morpho mock
    morpho = new MorphoMock();
    
    // 4. Create Morpho market (wstETH/WETH)
    morpho.createMarket(marketParams);
    
    // 5. Fund Morpho with WETH for lending
    morpho.fundMarket(address(weth), 1000 ether);
    
    // 6. Deploy pool system
    ctx = _deployStvStETHPool(...);
    
    // 7. Deploy MorphoLoopStrategy manually
    morphoStrategy = deployMorphoLoopStrategy();
    
    // 8. Configure allowlists and roles
}
```

### Test Pattern

```solidity
function test_simple_deposit_and_loop() public {
    // 1. Calculate minting capacity
    uint256 wstethToMint = pool.remainingMintingCapacitySharesOf(USER1, depositAmount);
    
    // 2. Prepare supply parameters
    MorphoLoopStrategy.LoopSupplyParams memory supplyParams = 
        MorphoLoopStrategy.LoopSupplyParams({targetLeverageBp: 20000});
    
    // 3. Execute deposit and leverage
    vm.prank(USER1);
    morphoStrategy.supply{value: depositAmount}(
        address(0),
        wstethToMint,
        abi.encode(supplyParams)
    );
    
    // 4. Verify results
    assertGt(morphoStrategy.stvOf(USER1), 0, "Should have stvETH");
    (,, uint256 collateral) = morphoStrategy.morphoPositionOf(USER1);
    assertGt(collateral, wstethToMint, "Should have leveraged");
}
```

## How the Atomic Loop Works

The test verifies the atomic leverage loop mechanism:

1. **User calls `supply()`** with ETH and target leverage
2. **Strategy mints wstETH** from the pool against stvETH collateral
3. **Strategy supplies wstETH** to Morpho as collateral
4. **Strategy borrows WETH** from Morpho
5. **Morpho calls back** to strategy's `onMorphoRepay()`
6. **In callback, strategy:**
   - Unwraps WETH → ETH
   - Stakes ETH → stETH (via Lido)
   - Wraps stETH → wstETH
   - Supplies new wstETH back to Morpho as collateral
7. **Borrow completes** with position now properly collateralized

This all happens **atomically** in a single transaction!

## Key Testing Constants

```solidity
uint256 MAX_LEVERAGE_BP = 30000;     // 3x max leverage
uint256 MARKET_LLTV = 0.86e18;       // 86% loan-to-value
uint256 ORACLE_PRICE = 1.15e18;      // 1 wstETH = 1.15 ETH
```

## Expanding the Test Suite

To add more complex tests, follow this pattern:

### 1. Test with Different Leverage Levels

```solidity
function test_deposit_with_3x_leverage() public {
    MorphoLoopStrategy.LoopSupplyParams memory params = 
        MorphoLoopStrategy.LoopSupplyParams({targetLeverageBp: 30000});
    // ... rest of test
}
```

### 2. Test Rebase Scenarios

```solidity
function test_positive_rebase_with_leverage() public {
    // 1. Deposit with leverage
    // 2. Simulate stETH rebase
    core.increaseBufferedEther(steth.totalSupply() / 100); // 1% increase
    // 3. Verify position value increased
}
```

### 3. Test Exit Flow

```solidity
function test_exit_leveraged_position() public {
    // 1. Create leveraged position
    // 2. Request exit
    // 3. Verify deleverage execution
    // 4. Claim final ETH
}
```

### 4. Test Liquidation Scenarios

```solidity
function test_near_liquidation_scenario() public {
    // 1. Create position
    // 2. Simulate price crash
    morpho.setOraclePrice(marketId, 0.8e18); // wstETH drops 30%
    // 3. Verify position health
}
```

## Debugging Tips

### 1. Use Console Logging

The test includes detailed console output:
```solidity
console.log("wstETH to mint:", wstethToMint);
console.log("Morpho Position:");
console.log("  Collateral:", collateral);
console.log("  Borrow shares:", borrowShares);
```

### 2. Use TableUtils (optional)

You can enable the TableUtils debug output used in GGV tests:
```solidity
_log.printUsers("After Deposit", logUsers, 0);
```

### 3. Check Position Health

```solidity
Position memory position = morpho.position(marketId, userCallForwarder);
uint256 healthFactor = calculateHealthFactor(position);
console.log("Health Factor:", healthFactor);
```

## Next Steps

### Immediate Next Steps:
1. **Run the basic test** to verify everything compiles and works
2. **Add more leverage levels** (1.5x, 2.5x, 3x) to test edge cases
3. **Test exit flow** - implement `test_exit_leveraged_position()`
4. **Test edge cases** - zero amounts, max leverage, etc.

### Advanced Testing:
1. **Rebase scenarios** - Test with stETH appreciation/depreciation
2. **Interest accrual** - Use `morpho.simulateInterest()` to test over time
3. **Multiple users** - Test with USER1 and USER2 simultaneously
4. **Strategy integration** - Test withdrawal queue integration
5. **Recovery functions** - Test `recoverERC20()` for stuck funds

### Future Enhancements:
1. **Factory integration** - Create MorphoLoopStrategyFactory
2. **Mainnet fork tests** - Test against real Morpho deployment
3. **Gas optimization tests** - Measure gas costs
4. **Fuzz testing** - Random leverage levels, amounts, etc.

## Common Issues & Solutions

### Issue: "Call failed" in doCall
**Solution:** Check that the call forwarder has correct permissions and the target function exists.

### Issue: "Insufficient collateral" 
**Solution:** The leverage might be too high. Check:
- LLTV is set correctly (0.86e18 = 86%)
- Oracle price is reasonable
- Safety factor in `_executeAtomicLoop` (currently 95%)

### Issue: Test hangs or runs out of gas
**Solution:** Check that:
- Morpho is funded with WETH
- WETH mock deposit/withdraw work correctly
- No infinite loops in callbacks

## Architecture Diagram

```
User (1 ETH)
    |
    v
MorphoLoopStrategy.supply()
    |
    +---> Pool.depositETH() --> stvETH minted
    |
    +---> Pool.mintWsteth() --> wstETH minted
    |
    +---> Morpho.supplyCollateral() --> wstETH locked
    |
    +---> Morpho.borrow() --> WETH borrowed
            |
            v
          onMorphoRepay() CALLBACK
            |
            +---> WETH.withdraw() --> ETH
            |
            +---> stETH.submit() --> stETH
            |
            +---> wstETH.wrap() --> wstETH
            |
            +---> Morpho.supplyCollateral() --> more wstETH locked
            |
            v
          Borrow succeeds (fully collateralized!)
```

## File Locations Summary

```
src/mock/morpho/
  └── MorphoMock.sol                    # Morpho protocol mock

test/utils/
  └── StvPoolHarness.sol                # Updated with MORPHO_LOOP support

test/integration/
  └── morpho-loop.test.sol              # Main test suite

MORPHO_TESTING_GUIDE.md                 # This file
```

## Questions?

If you encounter issues:
1. Check that all contracts compile: `forge build`
2. Run with verbose output: `forge test -vvvv`
3. Review the console logs for detailed execution flow
4. Compare with GGV tests in `test/integration/ggv.test.sol`

Good luck with your testing! Start with the simple test and gradually add complexity.
