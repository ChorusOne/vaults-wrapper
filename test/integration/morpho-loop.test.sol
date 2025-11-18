// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {console} from "forge-std/Test.sol";

import {TableUtils} from "../utils/format/TableUtils.sol";
import {StvStrategyPoolHarness} from "test/utils/StvStrategyPoolHarness.sol";

import {AllowList} from "src/AllowList.sol";
import {StvPool} from "src/StvPool.sol";
import {StvStETHPool} from "src/StvStETHPool.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {IStrategy} from "src/interfaces/IStrategy.sol";
import {IStrategyCallForwarder} from "src/interfaces/IStrategyCallForwarder.sol";
import {MorphoLoopStrategy} from "src/strategy/MorphoLoopStrategy.sol";
import {StrategyCallForwarder} from "src/strategy/StrategyCallForwarder.sol";

import {IWETH} from "src/interfaces/erc20/IWETH.sol";

// Import Morpho types from lib for real Morpho interaction
import {Morpho} from "lib/morpho-blue/src/Morpho.sol";
import {IMorpho, Id, Market, MarketParams, Position} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "lib/morpho-blue/src/libraries/MarketParamsLib.sol";

// Morpho mocks.
import {IrmMock} from "lib/morpho-blue/src/mocks/IrmMock.sol";
import {OracleMock} from "lib/morpho-blue/src/mocks/OracleMock.sol";

/**
 * @title MorphoLoopStrategyTest
 * @notice Integration tests for MorphoLoopStrategy
 * @dev Follows the GGVStrategy test pattern but simplified for initial testing
 */
contract MorphoLoopStrategyTest is StvStrategyPoolHarness {
    using TableUtils for TableUtils.Context;
    using MarketParamsLib for MarketParams;

    TableUtils.Context private _log;

    address public constant ADMIN = address(0x1337);
    address public constant MORPHO_OWNER = address(0x7777);
    address public constant FEE_RECIPIENT = address(0x8888);

    // Morpho-specific contracts
    IMorpho public morpho;
    IWETH public weth;
    OracleMock internal oracle;
    IrmMock internal irm;
    MarketParams public marketParams;
    Id public marketId;

    // Wrapper system
    StvStETHPool public pool;
    WithdrawalQueue public withdrawalQueue;
    MorphoLoopStrategy public morphoStrategy;

    WrapperContext public ctx;

    address public user1StrategyCallForwarder;
    address public user2StrategyCallForwarder;

    // Test constants
    uint256 public constant MAX_LEVERAGE_BP = 30000; // 3x max leverage
    uint256 public constant MARKET_LLTV = 0.965e18; // 95% LLTV (matches mainnet wstETH/WETH)
    uint256 public constant ANNUAL_INTEREST_RATE = 0.016e18; // 1.6% APR (matches mainnet)
    uint256 public constant ORACLE_PRICE_SCALE = 1e36; // Morpho oracle price scale

    function setUp() public {
        console.log("\n=== Starting MorphoLoopStrategyTest setUp ===");

        // 1. Initialize Lido core contracts
        console.log("[SETUP] Step 1: Initializing Lido core contracts");
        _initializeCore();
        console.log("[SETUP] Core initialized - stETH:", address(steth), "wstETH:", address(wsteth));

        vm.deal(ADMIN, 100_000 ether);
        console.log("[SETUP] Funded ADMIN with 100k ETH");

        // 2. Deploy WETH mock (simple wrapper)
        console.log("[SETUP] Step 2: Deploying WETH mock");
        weth = IWETH(deployMockWETH());
        console.log("[SETUP] WETH deployed at:", address(weth));

        // 3. Deploy real Morpho via MorphoDeployer helper
        console.log("[SETUP] Step 3: Deploying real Morpho");
        morpho = IMorpho(address(new Morpho(MORPHO_OWNER)));
        vm.label(address(morpho), "Morpho");
        console.log("[SETUP] Morpho deployed at:", address(morpho));

        // 4. Deploy Morpho mocks (Oracle and IRM)
        console.log("[SETUP] Step 4: Deploying Oracle and IRM mocks");
        oracle = new OracleMock();
        uint256 wsteth_weth_price = wsteth.stEthPerToken();
        oracle.setPrice((ORACLE_PRICE_SCALE * wsteth_weth_price) / 1e18); // Scale to Morpho's expected format
        vm.label(address(oracle), "OracleMock");
        console.log("[SETUP] Oracle deployed at:", address(oracle));
        console.log("[SETUP] Oracle price set: 1 wstETH =", wsteth_weth_price, "ETH");

        irm = new IrmMock();
        vm.label(address(irm), "FixedRateIrm");
        console.log("[SETUP] IRM deployed at:", address(irm));
        console.log("[SETUP] Fixed interest rate:", ANNUAL_INTEREST_RATE, "(1.6% APR)");

        // 5. Configure Morpho as owner
        console.log("[SETUP] Step 5: Configuring Morpho");
        vm.startPrank(MORPHO_OWNER);
        morpho.enableIrm(address(irm));
        morpho.enableIrm(address(0)); // Enable zero IRM for testing
        morpho.enableLltv(MARKET_LLTV);
        morpho.setFeeRecipient(FEE_RECIPIENT);
        vm.stopPrank();
        console.log("[SETUP] Morpho configured - IRM enabled, LLTV enabled, fee recipient set");

        // 6. Create Morpho market (wstETH collateral, WETH loan)
        console.log("[SETUP] Step 6: Creating Morpho market");

        // Create MarketParams for real Morpho (from lib)
        MarketParams memory realMarketParams = MarketParams({
            loanToken: address(weth),
            collateralToken: address(wsteth),
            oracle: address(oracle),
            irm: address(irm),
            lltv: MARKET_LLTV
        });

        morpho.createMarket(realMarketParams);
        marketId = Id.wrap(Id.unwrap(MarketParamsLib.id(realMarketParams)));
        console.log("[SETUP] Market created with ID:", vm.toString(Id.unwrap(marketId)));

        // Also store in strategy-compatible format
        marketParams = MarketParams({
            loanToken: address(weth),
            collateralToken: address(wsteth),
            oracle: address(oracle),
            irm: address(irm),
            lltv: MARKET_LLTV
        });

        console.log("[SETUP] Market params:");
        console.log("  - Loan token (WETH):", address(weth));
        console.log("  - Collateral token (wstETH):", address(wsteth));
        console.log("  - LLTV:", MARKET_LLTV);

        // 7. Fund Morpho market with WETH for lending
        console.log("[SETUP] Step 7: Funding Morpho market with WETH");
        vm.startPrank(ADMIN);
        vm.deal(ADMIN, 10000 ether);
        weth.deposit{value: 1000 ether}();
        weth.approve(address(morpho), type(uint256).max);
        morpho.supply(realMarketParams, 1000 ether, 0, ADMIN, "");
        vm.stopPrank();
        console.log("[SETUP] Morpho market funded with 1000 WETH");

        // 8. Deploy pool WITHOUT strategy (we'll deploy strategy manually)
        console.log("[SETUP] Step 8: Deploying StvStETHPool");
        ctx = _deployStvStETHPool(true, 0, 0, address(0), address(0));
        pool = StvStETHPool(payable(ctx.pool));
        vm.label(address(pool), "StvStETHPool");
        console.log("[SETUP] Pool deployed at:", address(pool));
        uint256 reserveRatio = pool.reserveRatioBP();
        console.log("[SETUP] Reserve ratio in basis points:", reserveRatio);

        withdrawalQueue = pool.WITHDRAWAL_QUEUE();
        console.log("[SETUP] Withdrawal queue:", address(withdrawalQueue));

        // 9. Deploy MorphoLoopStrategy manually
        console.log("[SETUP] Step 9: Deploying MorphoLoopStrategy");
        morphoStrategy = deployMorphoLoopStrategy();
        vm.label(address(morphoStrategy), "MorphoLoopStrategy");
        console.log("[SETUP] Strategy deployed at:", address(morphoStrategy));

        // Set the strategy in the context for harness compatibility
        ctx.strategy = address(morphoStrategy);
        strategy = IStrategy(address(morphoStrategy));
        console.log("[SETUP] Strategy set in context");

        // 10. Add strategy to pool's allowlist
        console.log("[SETUP] Step 10: Adding strategy to pool allowlist");
        // Get the timelock address (which is the actual admin of the pool)
        address poolAdmin = address(ctx.timelock);
        console.log("[SETUP] Pool admin (timelock):", poolAdmin);

        // Grant ALLOW_LIST_MANAGER_ROLE to NODE_OPERATOR if needed
        bytes32 allowListManagerRole = pool.ALLOW_LIST_MANAGER_ROLE();
        if (!pool.hasRole(allowListManagerRole, NODE_OPERATOR)) {
            console.log("[SETUP] Granting ALLOW_LIST_MANAGER_ROLE to NODE_OPERATOR");
            vm.prank(poolAdmin);
            pool.grantRole(allowListManagerRole, NODE_OPERATOR);
        }

        vm.prank(NODE_OPERATOR);
        pool.addToAllowList(address(morphoStrategy));
        console.log("[SETUP] Strategy added to allowlist");

        // 11. Get user call forwarders
        console.log("[SETUP] Step 11: Getting user call forwarders");
        user1StrategyCallForwarder = address(morphoStrategy.getStrategyCallForwarderAddress(USER1));
        vm.label(user1StrategyCallForwarder, "User1StrategyCallForwarder");
        console.log("[SETUP] User1 forwarder:", user1StrategyCallForwarder);

        user2StrategyCallForwarder = address(morphoStrategy.getStrategyCallForwarderAddress(USER2));
        vm.label(user2StrategyCallForwarder, "User2StrategyCallForwarder");
        console.log("[SETUP] User2 forwarder:", user2StrategyCallForwarder);

        // 12. Initialize logging
        console.log("[SETUP] Step 12: Initializing logging");
        _log.init(address(pool), address(morpho), address(steth), address(wsteth), address(0));

        console.log("\n=== MorphoLoopStrategy Test Setup Complete ===");
        console.log("Pool:", address(pool));
        console.log("Strategy:", address(morphoStrategy));
        console.log("Morpho:", address(morpho));
        console.log("WETH:", address(weth));
        console.log("Market LLTV:", MARKET_LLTV);
        console.log("============================================\n");

        // 13. Print pricing.
        console.log("[SETUP] wstETH -> stETH price:", wsteth.stEthPerToken());
        console.log("[SETUP] stETH -> wstETH price:", wsteth.tokensPerStEth());
        console.log("[SETUP] stETH total supply:", steth.totalSupply());
        console.log("[SETUP] stETH total shares price:", steth.getTotalShares());
        console.log("[SETUP] stETH -> ETH price:", steth.totalSupply() / steth.getTotalShares());

        console.log("[SETUP] reserve rate: ");
    }

    /**
     * @notice Test simple deposit workflow with leveraged looping
     * @dev This is the simplest test to verify:
     *      1. User deposits ETH to pool
     *      2. Mints wstETH from pool
     *      3. Executes leverage loop via Morpho
     *      4. Verifies position is created correctly
     */
    function test_simple_deposit_and_loop() public {
        uint256 depositAmount = 1 ether;
        uint256 targetLeverageBp = 30000; // 2x leverage

        console.log("\n=== Test: Simple Deposit and Loop (2x) ===");

        // Get initial minting capacity
        uint256 stvShares = strategy.remainingMintingCapacitySharesOf(USER1, depositAmount);
        console.log("Can mint %d shares from %d ETH deposit", stvShares, depositAmount);

        // Prepare supply params for 2x leverage
        MorphoLoopStrategy.LoopSupplyParams memory supplyParams = MorphoLoopStrategy.LoopSupplyParams({
            targetLeverageBp: targetLeverageBp
        });
        bytes memory encodedParams = abi.encode(supplyParams);

        // Stv token uses 1e27 precision, and for the first deposit we expect 1:1
        // when we take the precision difference into account.
        uint256 expectedStvShares = depositAmount * 1e9;

        // Expect StrategySupplied event.
        // vm.expectEmit(true, true, true, true, address(morphoStrategy));
        // emit IStrategy.StrategySupplied(
        //     address(USER1),
        //     address(0), // no referrer
        //     depositAmount,
        //     expectedStvShares,
        //     wstethToMint,
        //     encodedParams
        // );

        // Call supply to deposit ETH into the strategy.
        vm.prank(USER1);
        uint256 stvReceived = morphoStrategy.supply{value: depositAmount}(
            address(0), // no referral
            0, // Mint up to the full capacity.
            encodedParams
        );

        // TODO: Return number of minted stv shares.
        assertEq(stvReceived, 0, "Returning minted stvShares is not implemented yet");

        // Verify user has stvETH
        uint256 userStvBalance = morphoStrategy.stvOf(USER1);
        assertGt(userStvBalance, 0, "User should have stvETH balance");
        assertGt(userStvBalance, expectedStvShares, "User should have stvETH balance");
        console.log("User stvETH balance:", userStvBalance);

        // Verify Morpho position was created
        (uint256 supplyShares, uint256 borrowShares, uint256 collateral) = morphoStrategy.morphoPositionOf(USER1);

        console.log("\nMorpho Position:");
        console.log("  Supply shares:", supplyShares);
        console.log("  Borrow shares:", borrowShares);
        console.log("  Collateral (wstETH):", collateral);
        // TODO: assert collateral amount from the deposit and the LTV limits
        assertEq(supplyShares, 0, "User has not supplied any funds");
        assertGt(borrowShares, 0, "User has borrowed");
        // assertEq(collateral, 1.6e18, "User has borrowed");

        // Get actual position from Morpho (convert Id to RealId)
        Position memory position = morpho.position(marketId, user1StrategyCallForwarder);
        Market memory market = morpho.market(marketId);

        console.log("\nMorpho Market State:");
        console.log("  Total supply assets (wstETH):", market.totalSupplyAssets);
        console.log("  Total supply shares:", market.totalSupplyShares);
        console.log("  Total borrow assets (WETH):", market.totalBorrowAssets);
        console.log("  Total borrow shares:", market.totalBorrowShares);
        // TODO: Assert that Strategy position and Morpho positin data matches!

        // Assertions
        // NOTE: Loop logic not yet fully implemented, so collateral equals initial wstETH
        // TODO: Once loop is implemented, this should be assertGt
        // assertEq(collateral, wstethToMint, "Collateral should equal initial wstETH (loop not yet implemented)");
        // assertGt(borrowShares, 0, "Should have borrowed WETH");

        // Calculate actual leverage
        // Leverage = total collateral / initial collateral
        uint256 actualLeverageBp = (collateral * 10000) / stvShares;
        console.log("\nTarget leverage (bp):", targetLeverageBp);
        console.log("Actual leverage (bp):", actualLeverageBp);

        // NOTE: Loop not implemented yet, so leverage will be 1x
        // TODO: Uncomment this once loop logic is implemented
        // // Allow some tolerance (within 5%)
        // uint256 leverageTolerance = targetLeverageBp / 20; // 5%
        // assertApproxEqAbs(
        //     actualLeverageBp,
        //     targetLeverageBp,
        //     leverageTolerance,
        //     "Actual leverage should match target within tolerance"
        // );

        // For now, just verify we have 1x leverage (no loop)
        // assertEq(actualLeverageBp, 10000, "Should have 1x leverage (loop not implemented)");

        // For now, simplify - they're exactly equal so it's just totalBorrowAssets
        uint256 borrowAssets = market.totalBorrowAssets;

        console.log("  borrowAssets:", borrowAssets);

        // Calculate collateral value in loan token terms
        console.log("\nDebug - collateral value:");
        console.log("  position.collateral:", position.collateral);

        console.log("About to call oracle.price()...");
        uint256 oraclePrice = oracle.price();
        console.log("  oracle.price():", oraclePrice);
        console.log("  ORACLE_PRICE_SCALE:", ORACLE_PRICE_SCALE);

        // Avoid overflow: divide oracle price first, then multiply
        // Oracle price is price * 1e36, so divide by 1e18 to get price * 1e18
        console.log("About to divide oraclePrice by 1e18...");
        uint256 priceInEth = oraclePrice / 1e18; // Now in 1e18 scale
        console.log("priceInEth calculated successfully");

        console.log("About to calculate collateralValue...");
        uint256 collateralValue = (position.collateral * priceInEth) / 1e18;
        console.log("collateralValue calculated successfully");
        console.log("  priceInEth:", priceInEth);
        console.log("  collateralValue:", collateralValue);

        // Calculate max borrow based on LLTV
        uint256 maxBorrow = (collateralValue * MARKET_LLTV) / 1e18;

        // Health factor: how much of max borrow is being used
        uint256 healthFactor = borrowAssets > 0 ? (maxBorrow * 10000) / borrowAssets : type(uint256).max;

        console.log("\nPosition Health:");
        console.log("  Borrow assets:", borrowAssets);
        console.log("  Collateral value:", collateralValue);
        console.log("  Max borrow capacity:", maxBorrow);
        console.log("  Health factor (bp):", healthFactor);

        assertGt(healthFactor, 10500, "Health factor should be > 105% (safe buffer)");

        uint256 stETHBalance = morphoStrategy.mintedStethSharesOf(USER1);
        console.log("Minted stETH shares on Lido:", stETHBalance);
        // assertEq(stETHBalance, 1.6e18, "We have minted stETH on Lido");

        uint256 wstETHBalance = morphoStrategy.wstethOf(USER1);
        console.log("Minted wstETH shares on Lido:", wstETHBalance);
        assertEq(wstETHBalance, 0, "wstETH is not minted on Lido, the strategy wraps stETH itself");

        // This is the "free" portion not locked by the reserve ratio
        uint256 stvBalance = morphoStrategy.stvOf(USER1);
        uint256 unlockedStv = pool.unlockedStvOf(USER1);
        console.log("Total STV balance:", stvBalance);
        console.log("Unlocked STV (withdrawable without rebalance):", unlockedStv);
        console.log("Locked STV (collateralizing minted stETH):", stvBalance - unlockedStv);

        // Ask to withdraw.
        // console.log("User1 has %d unlocked stv tokens available for withdrawal without rebalance", unlockedStv);
        // vm.prank(USER1);
        // uint256 withdraw_request_id = morphoStrategy.requestWithdrawalFromPool(msg.sender, unlockedStv, 0);
        // console.log("Withdraw request id: %d", withdraw_request_id);
        // Get current position

        // Get the LLTV
        uint256 lltv = morphoStrategy.MARKET_LLTV();
        console.log("Morpho LLTV:", lltv); // e.g., 0.86e18

        // Get actual debt amount
        Market memory m = morpho.market(morphoStrategy.MARKET_ID());
        uint256 debt = (uint256(borrowShares) * m.totalBorrowAssets) / m.totalBorrowShares;

        // Calculate max withdrawable collateral (simplified, assuming price ~= 1)
        uint256 minCollateral = (debt * 1e18) / lltv;
        uint256 maxWithdrawable = collateral > minCollateral ? collateral - minCollateral : 0;

        console.log("Current collateral:", collateral);
        console.log("Current debt:", debt);
        console.log("Min collateral required:", minCollateral);
        console.log("Max withdrawable (at LLTV limit):", maxWithdrawable);

        // IStakingVault vault = dashboard.stakingVault();
        uint256 immediatelyAvailable = ctx.vault.availableBalance();
        console.log("Available for fast withdrawal: %d", immediatelyAvailable);
        uint256 systemMaxWithdrawable = ctx.dashboard.withdrawableValue();
        console.log("System max withdrawable: %d", systemMaxWithdrawable);
    }

    /**
     * @notice Test that deposits without strategy allowlist fail
     */
    function test_revert_if_user_not_allowlisted() public {
        uint256 depositAmount = 1 ether;

        // Try to deposit directly to pool (should fail)
        vm.prank(USER1);
        vm.expectRevert(abi.encodeWithSelector(AllowList.NotAllowListed.selector, USER1));
        pool.depositETH{value: depositAmount}(USER1, address(0));
    }

    /**
     * @notice Test leverage limits are enforced
     */
    function test_revert_if_leverage_too_high() public {
        uint256 depositAmount = 1 ether;
        uint256 wstethToMint = pool.remainingMintingCapacitySharesOf(USER1, depositAmount);

        // Try to use 4x leverage (above MAX_LEVERAGE_BP of 3x)
        MorphoLoopStrategy.LoopSupplyParams memory supplyParams = MorphoLoopStrategy.LoopSupplyParams({
            targetLeverageBp: 40000
        });

        vm.prank(USER1);
        vm.expectRevert(MorphoLoopStrategy.InvalidLeverage.selector);
        morphoStrategy.supply{value: depositAmount}(address(0), wstethToMint, abi.encode(supplyParams));
    }

    /**
     * @notice Test leverage below 1x is rejected
     */
    function test_revert_if_leverage_below_1x() public {
        uint256 depositAmount = 1 ether;
        uint256 wstethToMint = pool.remainingMintingCapacitySharesOf(USER1, depositAmount);

        // Try to use 0.5x leverage (invalid)
        MorphoLoopStrategy.LoopSupplyParams memory supplyParams = MorphoLoopStrategy.LoopSupplyParams({
            targetLeverageBp: 5000
        });

        vm.prank(USER1);
        vm.expectRevert(MorphoLoopStrategy.InvalidLeverage.selector);
        morphoStrategy.supply{value: depositAmount}(address(0), wstethToMint, abi.encode(supplyParams));
    }

    // =================================================================================
    // HELPER FUNCTIONS
    // =================================================================================

    /**
     * @notice Deploy MorphoLoopStrategy with test configuration
     */
    function deployMorphoLoopStrategy() internal returns (MorphoLoopStrategy) {
        console.log("\n[DEBUG] Starting deployMorphoLoopStrategy");

        // Deploy strategy call forwarder implementation
        address forwarderImpl = deployStrategyCallForwarderImpl();
        console.log("[DEBUG] Deployed forwarder impl:", forwarderImpl);

        bytes32 strategyId = keccak256("MORPHO_LOOP_STRATEGY_V1");
        console.log("[DEBUG] Strategy ID:", vm.toString(strategyId));

        console.log("[DEBUG] Creating MorphoLoopStrategy with params:");
        console.log("  - pool:", address(pool));
        console.log("  - morpho:", address(morpho));
        console.log("  - weth:", address(weth));
        console.log("  - maxLeverageBp:", MAX_LEVERAGE_BP);

        // Create memory copy of marketParams for constructor
        MarketParams memory marketParamsMem = MarketParams({
            loanToken: marketParams.loanToken,
            collateralToken: marketParams.collateralToken,
            oracle: marketParams.oracle,
            irm: marketParams.irm,
            lltv: marketParams.lltv
        });

        MorphoLoopStrategy strategy = new MorphoLoopStrategy(
            strategyId,
            forwarderImpl,
            address(pool),
            address(morpho),
            address(weth),
            marketParamsMem,
            MAX_LEVERAGE_BP
        );
        console.log("[DEBUG] MorphoLoopStrategy deployed at:", address(strategy));

        // Initialize strategy
        console.log("[DEBUG] Attempting to initialize strategy with admin:", NODE_OPERATOR);
        vm.prank(NODE_OPERATOR);
        strategy.initialize(NODE_OPERATOR);
        console.log("[DEBUG] Strategy initialized successfully");

        // Resume supply feature (it's paused in constructor)
        console.log("[DEBUG] Granting SUPPLY_RESUME_ROLE to NODE_OPERATOR");
        bytes32 supplyResumeRole = strategy.SUPPLY_RESUME_ROLE();
        vm.prank(NODE_OPERATOR);
        strategy.grantRole(supplyResumeRole, NODE_OPERATOR);

        console.log("[DEBUG] Resuming supply feature");
        vm.prank(NODE_OPERATOR);
        strategy.resumeSupply();
        console.log("[DEBUG] Supply feature resumed");

        return strategy;
    }

    /**
     * @notice Deploy StrategyCallForwarder implementation
     */
    function deployStrategyCallForwarderImpl() internal returns (address) {
        StrategyCallForwarder callForwarder = new StrategyCallForwarder();
        vm.label(address(callForwarder), "StrategyCallForwarder");
        return address(callForwarder);
    }

    /**
     * @notice Deploy a simple WETH mock
     */
    function deployMockWETH() internal returns (address) {
        MockWETH wethContract = new MockWETH();
        vm.label(address(wethContract), "MockWETH");
        return address(wethContract);
    }

    /**
     * @notice Override to add Morpho strategy to possible stv holders
     */
    function _allPossibleStvHolders(WrapperContext memory _ctx) internal view override returns (address[] memory) {
        address[] memory holders_ = super._allPossibleStvHolders(_ctx);
        address[] memory holders = new address[](holders_.length + 1);
        uint256 i = 0;
        for (i = 0; i < holders_.length; i++) {
            holders[i] = holders_[i];
        }
        holders[i++] = address(morphoStrategy);
        return holders;
    }
}

// =================================================================================
// MOCK CONTRACTS
// =================================================================================

/**
 * @notice WETH9 mock for testing - matches mainnet WETH implementation
 */
contract MockWETH is IWETH {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // Note: Transfer and Approval events are inherited from IERC20 via IWETH
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) public {
        require(balanceOf[msg.sender] >= wad, "Insufficient balance");
        balanceOf[msg.sender] -= wad;
        payable(msg.sender).transfer(wad);
        emit Withdrawal(msg.sender, wad);
    }

    function totalSupply() public view returns (uint256) {
        return address(this).balance;
    }

    function approve(address guy, uint256 wad) public returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    function transfer(address dst, uint256 wad) public returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint256 wad) public returns (bool) {
        require(balanceOf[src] >= wad, "Insufficient balance");

        if (src != msg.sender && allowance[src][msg.sender] != type(uint256).max) {
            require(allowance[src][msg.sender] >= wad, "Insufficient allowance");
            allowance[src][msg.sender] -= wad;
        }

        balanceOf[src] -= wad;
        balanceOf[dst] += wad;

        emit Transfer(src, dst, wad);

        return true;
    }
}
