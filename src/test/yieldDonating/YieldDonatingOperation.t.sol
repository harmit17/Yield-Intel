// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {console2} from "forge-std/console2.sol";
import {YieldDonatingSetup as Setup, ITokenizedStrategy} from "./YieldDonatingSetup.sol";

contract YieldDonatingOperationTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupStrategyOK() public {
        console2.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(ITokenizedStrategy(address(strategy)).dragonRouter(), dragonRouter);
        assertEq(strategy.keeper(), keeper);
        // Check enableBurning using low-level call since it's not in the interface
        (bool success, bytes memory data) = address(strategy).staticcall(abi.encodeWithSignature("enableBurning()"));
        require(success, "enableBurning call failed");
        bool currentEnableBurning = abi.decode(data, (bool));
        assertEq(currentEnableBurning, enableBurning);
    }

    function test_profitableReport(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        uint256 _timeInDays = 30; // Fixed 30 days

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Move forward in time to simulate yield accrual period
        uint256 timeElapsed = _timeInDays * 1 days;
        skip(timeElapsed);

        // Report profit - should detect the simulated yield
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values - should have profit equal to simulated yield
        assertGt(profit, 0, "!profit should equal expected yield");
        assertEq(loss, 0, "!loss should be 0");

        // Check that profit was minted to dragon router
        uint256 dragonRouterShares = strategy.balanceOf(dragonRouter);
        assertGt(dragonRouterShares, 0, "!dragon router shares");

        // Convert shares back to assets to verify
        uint256 dragonRouterAssets = strategy.convertToAssets(dragonRouterShares);
        assertEq(dragonRouterAssets, profit, "!dragon router assets should equal profit");

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds (user gets original amount, dragon router gets the yield)
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");

        // Assert that dragon router still has shares (the yield portion)
        uint256 dragonRouterSharesAfter = strategy.balanceOf(dragonRouter);
        assertGt(dragonRouterSharesAfter, 0, "!dragon router shares after withdrawal");
    }

    function test_tendTrigger(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Skip some time
        skip(30 days);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(keeper);
        strategy.report();

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);
    }
}
