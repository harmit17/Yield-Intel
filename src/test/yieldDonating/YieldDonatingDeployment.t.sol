// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {YieldDonatingSetup as Setup, IStrategyInterface, ITokenizedStrategy} from "./YieldDonatingSetup.sol";

/**
 * @notice Standard ERC4626 Tokenized Vault interface
 */
interface IERC4626 {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/**
 * @title YieldDonatingStrategy Deployment Tests
 * @notice Tests for strategy deployment and configuration
 */
contract YieldDonatingDeploymentTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_StrategyInitialization() public {
        assertEq(strategy.asset(), address(asset), "Asset mismatch");
        assertEq(strategy.management(), management, "Management mismatch");
        assertEq(strategy.keeper(), keeper, "Keeper mismatch");
        assertEq(ITokenizedStrategy(address(strategy)).dragonRouter(), dragonRouter, "Dragon router mismatch");
        
        // Check enableBurning
        (bool success, bytes memory data) = address(strategy).staticcall(abi.encodeWithSignature("enableBurning()"));
        require(success, "enableBurning call failed");
        bool currentEnableBurning = abi.decode(data, (bool));
        assertEq(currentEnableBurning, enableBurning, "Enable burning mismatch");
    }

    function test_YieldSourceIsERC4626() public {
        // Verify yield source implements ERC4626
        IERC4626 vault = IERC4626(yieldSource);
        assertEq(vault.asset(), address(asset), "Vault asset mismatch");
        assertGt(vault.totalAssets(), 0, "Vault should have assets");
    }

    function test_StrategyRoles() public {
        // Verify management role
        assertTrue(strategy.management() == management, "Management not set");
        
        // Verify keeper role
        assertTrue(strategy.keeper() == keeper, "Keeper not set");
        
        // Verify emergency admin
        assertEq(strategy.emergencyAdmin(), emergencyAdmin, "Emergency admin mismatch");
    }

    function test_StrategyName() public {
        assertEq(strategy.name(), "YieldDonating Strategy", "Strategy name mismatch");
    }

    function test_StrategyAssetEqualsVaultAsset() public {
        IERC4626 vault = IERC4626(yieldSource);
        assertEq(strategy.asset(), vault.asset(), "Strategy asset should match vault asset");
    }
}

/**
 * @title YieldDonatingStrategy Deposit/Withdraw Tests
 * @notice Tests for deposit and withdrawal functionality
 */
contract YieldDonatingDepositWithdrawTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_Deposit(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        
        mintAndDepositIntoStrategy(strategy, user, _amount);
        
        assertEq(strategy.totalAssets(), _amount, "Total assets mismatch");
        assertEq(strategy.balanceOf(user), _amount, "User shares mismatch");
    }

    function test_DepositZeroAmount() public {
        vm.prank(user);
        vm.expectRevert();
        strategy.deposit(0, user);
    }

    function test_Withdraw(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        
        mintAndDepositIntoStrategy(strategy, user, _amount);
        
        uint256 balanceBefore = asset.balanceOf(user);
        
        vm.prank(user);
        strategy.redeem(_amount, user, user);
        
        // Allow 2 wei tolerance for rounding in ERC4626 vaults
        assertApproxEqAbs(asset.balanceOf(user), balanceBefore + _amount, 2, "User should receive assets");
        assertEq(strategy.balanceOf(user), 0, "User shares should be 0");
    }

    function test_PartialWithdraw(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount * 2 && _amount < maxFuzzAmount);
        
        mintAndDepositIntoStrategy(strategy, user, _amount);
        
        uint256 withdrawAmount = _amount / 2;
        uint256 balanceBefore = asset.balanceOf(user);
        
        vm.prank(user);
        strategy.withdraw(withdrawAmount, user, user);
        
        assertGe(asset.balanceOf(user), balanceBefore + withdrawAmount, "User should receive withdrawn assets");
        assertGt(strategy.balanceOf(user), 0, "User should still have shares");
    }

    function test_MultipleDeposits(uint256 _amount1, uint256 _amount2) public {
        vm.assume(_amount1 > minFuzzAmount && _amount1 < maxFuzzAmount / 2);
        vm.assume(_amount2 > minFuzzAmount && _amount2 < maxFuzzAmount / 2);
        
        mintAndDepositIntoStrategy(strategy, user, _amount1);
        mintAndDepositIntoStrategy(strategy, user, _amount2);
        
        assertEq(strategy.totalAssets(), _amount1 + _amount2, "Total assets should equal sum");
        assertEq(strategy.balanceOf(user), _amount1 + _amount2, "User shares should equal sum");
    }

    function test_DepositForDifferentReceiver(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        
        address receiver = address(0x123);
        airdrop(asset, user, _amount);
        
        vm.prank(user);
        asset.approve(address(strategy), _amount);
        
        vm.prank(user);
        strategy.deposit(_amount, receiver);
        
        assertEq(strategy.balanceOf(receiver), _amount, "Receiver should have shares");
        assertEq(strategy.balanceOf(user), 0, "User should not have shares");
    }

    function test_WithdrawWithApproval(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        
        mintAndDepositIntoStrategy(strategy, user, _amount);
        
        address withdrawer = address(0x456);
        
        vm.prank(user);
        strategy.approve(withdrawer, _amount);
        
        vm.prank(withdrawer);
        strategy.redeem(_amount, withdrawer, user);
        
        // Allow 2 wei tolerance for rounding in ERC4626 vaults
        assertApproxEqAbs(asset.balanceOf(withdrawer), _amount, 2, "Withdrawer should receive assets");
    }
}

/**
 * @title YieldDonatingStrategy Yield Distribution Tests
 * @notice Tests for yield generation and distribution to dragon router
 */
contract YieldDonatingYieldDistributionTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_YieldGoesToDragonRouter(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        
        mintAndDepositIntoStrategy(strategy, user, _amount);
        
        // Skip time to accrue yield
        skip(30 days);
        
        // Report to harvest yield
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();
        
        assertGt(profit, 0, "Should have profit");
        assertEq(loss, 0, "Should have no loss");
        
        // Dragon router should have shares representing the profit
        uint256 dragonRouterShares = strategy.balanceOf(dragonRouter);
        assertGt(dragonRouterShares, 0, "Dragon router should have shares");
        
        uint256 dragonRouterAssets = strategy.convertToAssets(dragonRouterShares);
        assertEq(dragonRouterAssets, profit, "Dragon router assets should equal profit");
    }

    function test_NoYieldWithoutTimeElapsed(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        
        mintAndDepositIntoStrategy(strategy, user, _amount);
        
        // Report immediately without time passing
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();
        
        // Minimal or no profit expected, but loss can occur due to rounding in ERC4626 vaults
        // Allow up to 2 wei loss for rounding
        assertLe(loss, 2, "Should have minimal/no loss");
        
        uint256 dragonRouterShares = strategy.balanceOf(dragonRouter);
        // May have minimal shares due to rounding
        assertLe(dragonRouterShares, 100, "Dragon router should have minimal/no shares");
    }

    function test_MultipleReportsAccumulateYield(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        
        mintAndDepositIntoStrategy(strategy, user, _amount);
        
        // First report
        skip(15 days);
        vm.prank(keeper);
        (uint256 profit1, ) = strategy.report();
        
        uint256 dragonSharesAfterFirst = strategy.balanceOf(dragonRouter);
        
        // Second report
        skip(15 days);
        vm.prank(keeper);
        (uint256 profit2, ) = strategy.report();
        
        uint256 dragonSharesAfterSecond = strategy.balanceOf(dragonRouter);
        
        assertGt(profit1, 0, "First report should have profit");
        assertGt(profit2, 0, "Second report should have profit");
        assertGt(dragonSharesAfterSecond, dragonSharesAfterFirst, "Dragon router shares should increase");
    }

    function test_DragonRouterCanRedeemYield(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        
        mintAndDepositIntoStrategy(strategy, user, _amount);
        
        skip(30 days);
        vm.prank(keeper);
        strategy.report();
        
        uint256 dragonShares = strategy.balanceOf(dragonRouter);
        assertGt(dragonShares, 0, "Dragon router should have shares");
        
        uint256 dragonBalanceBefore = asset.balanceOf(dragonRouter);
        
        // Dragon router redeems its shares
        vm.prank(dragonRouter);
        strategy.redeem(dragonShares, dragonRouter, dragonRouter);
        
        uint256 dragonBalanceAfter = asset.balanceOf(dragonRouter);
        assertGt(dragonBalanceAfter, dragonBalanceBefore, "Dragon router should receive assets");
    }
}

/**
 * @title YieldDonatingStrategy Configuration Tests
 * @notice Tests for changing strategy configuration
 */
contract YieldDonatingConfigurationTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_SetDragonRouter() public {
        address newRouter = address(0x789);
        
        vm.prank(management);
        ITokenizedStrategy(address(strategy)).setDragonRouter(newRouter);
        
        // Fast forward past cooldown (14 days + 1 second to be safe)
        skip(14 days + 1);
        
        // Finalize change
        ITokenizedStrategy(address(strategy)).finalizeDragonRouterChange();
        
        assertEq(ITokenizedStrategy(address(strategy)).dragonRouter(), newRouter, "Dragon router not updated");
    }

    function test_SetDragonRouterRequiresCooldown() public {
        address newRouter = address(0x789);
        
        vm.prank(management);
        ITokenizedStrategy(address(strategy)).setDragonRouter(newRouter);
        
        // Try to finalize immediately
        vm.expectRevert();
        ITokenizedStrategy(address(strategy)).finalizeDragonRouterChange();
    }

    function test_SetDragonRouterOnlyManagement() public {
        vm.prank(user);
        vm.expectRevert();
        ITokenizedStrategy(address(strategy)).setDragonRouter(address(0x789));
    }

    function test_SetEnableBurning() public {
        vm.prank(management);
        (bool success, ) = address(strategy).call(abi.encodeWithSignature("setEnableBurning(bool)", false));
        require(success, "setEnableBurning failed");
        
        (bool checkSuccess, bytes memory data) = address(strategy).staticcall(abi.encodeWithSignature("enableBurning()"));
        require(checkSuccess, "enableBurning check failed");
        bool newEnableBurning = abi.decode(data, (bool));
        assertFalse(newEnableBurning, "Enable burning should be false");
    }

    function test_SetEnableBurningOnlyManagement() public {
        vm.prank(user);
        (bool success, ) = address(strategy).call(abi.encodeWithSignature("setEnableBurning(bool)", false));
        assertFalse(success, "Non-management should not be able to set enable burning");
    }
}

/**
 * @title YieldDonatingStrategy Emergency Tests
 * @notice Tests for emergency shutdown and fund recovery
 */
contract YieldDonatingEmergencyTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_EmergencyWithdraw(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        
        mintAndDepositIntoStrategy(strategy, user, _amount);
        
        // Shutdown strategy first (required for emergency withdraw)
        vm.prank(management);
        strategy.shutdownStrategy();
        
        // Emergency admin withdraws
        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(_amount);
        
        // Check funds returned to strategy (allow 2 wei tolerance for ERC4626 rounding)
        assertApproxEqAbs(asset.balanceOf(address(strategy)), _amount, 2, "Funds should be in strategy");
    }

    function test_EmergencyWithdrawOnlyEmergencyAdmin() public {
        mintAndDepositIntoStrategy(strategy, user, 1000e6);
        
        vm.prank(user);
        vm.expectRevert();
        strategy.emergencyWithdraw(1000e6);
    }

    function test_ShutdownStrategy(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        
        mintAndDepositIntoStrategy(strategy, user, _amount);
        
        // Management shuts down strategy
        vm.prank(management);
        strategy.shutdownStrategy();
        
        // Try to deposit after shutdown
        airdrop(asset, user, _amount);
        vm.prank(user);
        asset.approve(address(strategy), _amount);
        
        vm.prank(user);
        vm.expectRevert();
        strategy.deposit(_amount, user);
    }

    function test_WithdrawAfterShutdown(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        
        mintAndDepositIntoStrategy(strategy, user, _amount);
        
        vm.prank(management);
        strategy.shutdownStrategy();
        
        uint256 balanceBefore = asset.balanceOf(user);
        
        // Withdrawals should still work
        vm.prank(user);
        strategy.redeem(_amount, user, user);
        
        // Allow 2 wei tolerance for rounding in ERC4626 vaults
        assertApproxEqAbs(asset.balanceOf(user), balanceBefore + _amount, 2, "User should receive assets after shutdown");
    }
}

/**
 * @title YieldDonatingStrategy Limit Tests
 * @notice Tests for deposit limits and available deposit amount
 */
contract YieldDonatingLimitTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_AvailableDepositLimit() public {
        uint256 maxDeposit = strategy.availableDepositLimit(user);
        assertGt(maxDeposit, 0, "Should have deposit limit");
    }

    function test_AvailableWithdrawLimit(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        
        mintAndDepositIntoStrategy(strategy, user, _amount);
        
        uint256 maxWithdraw = strategy.availableWithdrawLimit(user);
        assertGe(maxWithdraw, _amount, "Should be able to withdraw deposited amount");
    }

    function test_DepositUpToLimit() public {
        uint256 maxDeposit = strategy.availableDepositLimit(user);
        
        if (maxDeposit > maxFuzzAmount) {
            maxDeposit = maxFuzzAmount;
        }
        
        if (maxDeposit > minFuzzAmount) {
            mintAndDepositIntoStrategy(strategy, user, maxDeposit);
            assertEq(strategy.balanceOf(user), maxDeposit, "Should deposit up to limit");
        }
    }
}

/**
 * @title YieldDonatingStrategy View Function Tests
 * @notice Tests for view functions and state queries
 */
contract YieldDonatingViewTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_TotalAssets(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        
        assertEq(strategy.totalAssets(), 0, "Initial total assets should be 0");
        
        mintAndDepositIntoStrategy(strategy, user, _amount);
        
        assertEq(strategy.totalAssets(), _amount, "Total assets should equal deposit");
    }

    function test_ConvertToShares(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        
        mintAndDepositIntoStrategy(strategy, user, _amount);
        
        uint256 shares = strategy.convertToShares(_amount);
        assertEq(shares, _amount, "Initial conversion should be 1:1");
    }

    function test_ConvertToAssets(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        
        mintAndDepositIntoStrategy(strategy, user, _amount);
        
        uint256 assets = strategy.convertToAssets(_amount);
        assertEq(assets, _amount, "Initial conversion should be 1:1");
    }

    function test_PreviewDeposit(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        
        uint256 expectedShares = strategy.previewDeposit(_amount);
        assertEq(expectedShares, _amount, "Preview deposit should show 1:1");
    }

    function test_PreviewWithdraw(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        
        mintAndDepositIntoStrategy(strategy, user, _amount);
        
        uint256 expectedShares = strategy.previewWithdraw(_amount);
        assertEq(expectedShares, _amount, "Preview withdraw should show 1:1");
    }

    function test_MaxDeposit() public {
        uint256 maxDeposit = strategy.maxDeposit(user);
        assertGt(maxDeposit, 0, "Max deposit should be greater than 0");
    }

    function test_MaxWithdraw(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        
        mintAndDepositIntoStrategy(strategy, user, _amount);
        
        uint256 maxWithdraw = strategy.maxWithdraw(user);
        assertGe(maxWithdraw, _amount, "Max withdraw should be at least deposit amount");
    }
}
