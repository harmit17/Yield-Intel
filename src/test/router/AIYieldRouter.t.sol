// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AIYieldRouterSetup} from "./AIYieldRouterSetup.sol";
import {AIYieldRouter} from "../../router/AIYieldRouter.sol";

/**
 * @title AIYieldRouter Basic Tests
 * @notice Tests for basic functionality and initialization
 */
contract AIYieldRouterBasicTest is AIYieldRouterSetup {
    
    function test_Initialization() public {
        assertEq(address(router.STABLE()), address(stableToken), "Stable token mismatch");
        assertEq(address(router.VAULT_SHARES()), address(vaultShares), "Vault shares mismatch");
        assertEq(router.vault(), address(vaultShares), "Vault address mismatch");
        assertEq(router.donationBps(), 10000, "Default donation BPS should be 10000");
        assertEq(router.redeemInterval(), 7 days, "Default redeem interval should be 7 days");
        assertTrue(router.hasRole(router.DEFAULT_ADMIN_ROLE(), admin), "Admin should have DEFAULT_ADMIN_ROLE");
        assertTrue(router.hasRole(ADMIN_ROLE, admin), "Admin should have ADMIN_ROLE");
        assertTrue(router.hasRole(ORACLE_ROLE, oracle), "Oracle should have ORACLE_ROLE");
    }

    function test_InitialBalances() public {
        assertEq(stableToken.balanceOf(address(router)), INITIAL_BALANCE, "Router should have initial balance");
        assertEq(router.assetsAvailable(), INITIAL_BALANCE, "Assets available should match balance");
        assertEq(router.sharesBalance(), 0, "Initial shares balance should be 0");
    }

    function test_ConstructorRevertsOnZeroAddresses() public {
        vm.expectRevert("stable zero");
        new AIYieldRouter(address(0), address(vaultShares), admin);

        vm.expectRevert("vaultShares zero");
        new AIYieldRouter(address(stableToken), address(0), admin);

        vm.expectRevert("admin zero");
        new AIYieldRouter(address(stableToken), address(vaultShares), address(0));
    }
}

/**
 * @title AIYieldRouter Protocol Management Tests
 * @notice Tests for protocol configuration and management
 */
contract AIYieldRouterProtocolTest is AIYieldRouterSetup {
    
    function test_SetProtocol() public {
        vm.prank(admin);
        router.setProtocol(protocolIdA, "Protocol A", 100, true);

        (string memory name, bytes32 id, uint32 weight, bool enabled) = router.protocols(protocolIdA);
        
        assertEq(name, "Protocol A", "Protocol name mismatch");
        assertEq(id, protocolIdA, "Protocol ID mismatch");
        assertEq(weight, 100, "Protocol weight mismatch");
        assertTrue(enabled, "Protocol should be enabled");
        assertEq(router.totalProtocolWeights(), 100, "Total weights mismatch");
    }

    function test_UpdateProtocol() public {
        vm.startPrank(admin);
        router.setProtocol(protocolIdA, "Protocol A", 100, true);
        router.setProtocol(protocolIdA, "Protocol A Updated", 200, false);
        vm.stopPrank();

        (string memory name, bytes32 id, uint32 weight, bool enabled) = router.protocols(protocolIdA);
        
        assertEq(name, "Protocol A Updated", "Protocol name not updated");
        assertEq(weight, 200, "Protocol weight not updated");
        assertFalse(enabled, "Protocol should be disabled");
        assertEq(router.totalProtocolWeights(), 200, "Total weights not updated");
    }

    function test_SetProtocolOnlyAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        router.setProtocol(protocolIdA, "Protocol A", 100, true);
    }

    function test_SetProtocolRevertsOnZeroId() public {
        vm.prank(admin);
        vm.expectRevert("id zero");
        router.setProtocol(bytes32(0), "Protocol", 100, true);
    }

    function test_MultipleProtocols() public {
        setupProtocols();

        bytes32[] memory protocols = router.getProtocols();
        assertEq(protocols.length, 2, "Should have 2 protocols");
        assertEq(protocols[0], protocolIdA, "First protocol mismatch");
        assertEq(protocols[1], protocolIdB, "Second protocol mismatch");
        assertEq(router.totalProtocolWeights(), 100, "Total weights should be 100");
    }

    function test_GetPendingAllocations() public {
        setupProtocols();

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = protocolIdA;
        ids[1] = protocolIdB;

        uint256[] memory allocations = router.getPendingAllocations(ids);
        assertEq(allocations[0], 0, "Protocol A should have 0 pending");
        assertEq(allocations[1], 0, "Protocol B should have 0 pending");
    }
}

/**
 * @title AIYieldRouter Redemption Tests
 * @notice Tests for share redemption and allocation logic
 */
contract AIYieldRouterRedemptionTest is AIYieldRouterSetup {
    
    function setUp() public override {
        super.setUp();
        setupProtocols();
        mintVaultSharesToRouter(100_000e6); // Mint 100k shares to router
    }

    function test_RedeemAndAllocate() public {
        uint256 sharesBefore = router.sharesBalance();
        assertGt(sharesBefore, 0, "Should have shares");

        vm.prank(admin);
        router.redeemAndAllocate();

        assertEq(router.sharesBalance(), 0, "All shares should be redeemed");
        assertEq(router.lastRedeem(), block.timestamp, "Last redeem timestamp not updated");
        
        // Check allocations
        assertGt(router.pendingAllocation(protocolIdA), 0, "Protocol A should have allocation");
        assertGt(router.pendingAllocation(protocolIdB), 0, "Protocol B should have allocation");
    }

    function test_RedeemAndAllocateDistribution() public {
        uint256 sharesAmount = 100_000e6;

        vm.prank(admin);
        router.redeemAndAllocate();

        uint256 allocA = router.pendingAllocation(protocolIdA);
        uint256 allocB = router.pendingAllocation(protocolIdB);

        // Protocol A has 60% weight, Protocol B has 40%
        // Allow 1% tolerance for rounding
        assertApproxEqRel(allocA, (sharesAmount * 60) / 100, 0.01e18, "Protocol A allocation incorrect");
        assertApproxEqRel(allocB, (sharesAmount * 40) / 100, 0.01e18, "Protocol B allocation incorrect");
        assertEq(allocA + allocB, sharesAmount, "Total allocation should equal redeemed amount");
    }

    function test_RedeemRespectsCooldown() public {
        vm.prank(admin);
        router.redeemAndAllocate();

        // Try to redeem again immediately
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                AIYieldRouter.CooldownNotElapsed.selector,
                block.timestamp + 7 days
            )
        );
        router.redeemAndAllocate();
    }

    function test_RedeemAfterCooldown() public {
        vm.prank(admin);
        router.redeemAndAllocate();

        // Warp time forward
        vm.warp(block.timestamp + 7 days + 1);

        // Mint more shares
        mintVaultSharesToRouter(50_000e6);

        vm.prank(admin);
        router.redeemAndAllocate(); // Should succeed
    }

    function test_RedeemOnlyAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        router.redeemAndAllocate();
    }

    function test_RedeemWithDisabledProtocol() public {
        // Disable protocol B
        vm.prank(admin);
        router.setProtocol(protocolIdB, "Protocol B", 40, false);

        vm.prank(admin);
        router.redeemAndAllocate();

        // All allocation should go to Protocol A
        assertEq(router.pendingAllocation(protocolIdA), 100_000e6, "All should go to Protocol A");
        assertEq(router.pendingAllocation(protocolIdB), 0, "Protocol B should get nothing");
    }

    function test_RedeemRevertsWithNoProtocols() public {
        // Deploy new router without protocols
        vm.prank(admin);
        AIYieldRouter newRouter = new AIYieldRouter(address(stableToken), address(vaultShares), admin);

        // Mint shares to new router
        vm.startPrank(user);
        stableToken.approve(address(vaultShares), 100_000e6);
        vaultShares.deposit(100_000e6, address(newRouter));
        vm.stopPrank();

        vm.prank(admin);
        vm.expectRevert("no protocols configured");
        newRouter.redeemAndAllocate();
    }

    function test_RedeemWithCustomDonationBps() public {
        // Set donation to 50%
        vm.prank(admin);
        router.setDonationBps(5000);

        vm.prank(admin);
        router.redeemAndAllocate();

        uint256 totalAllocated = router.pendingAllocation(protocolIdA) + router.pendingAllocation(protocolIdB);
        
        // Should be 50% of 100k = 50k
        assertEq(totalAllocated, 50_000e6, "Should allocate 50% as donation");
    }
}

/**
 * @title AIYieldRouter Action Tests
 * @notice Tests for protocol action requests and execution
 */
contract AIYieldRouterActionTest is AIYieldRouterSetup {
    
    function setUp() public override {
        super.setUp();
        setupProtocols();
        mintVaultSharesToRouter(100_000e6);
        
        // Redeem to get allocations
        vm.prank(admin);
        router.redeemAndAllocate();
    }

    function test_RequestProtocolAction() public {
        uint256 allocationBefore = router.pendingAllocation(protocolIdA);
        uint256 requestAmount = 10_000e6;
        bytes memory data = abi.encode("bridge", "ethereum", "optimism");

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit AIYieldRouter.ProtocolActionRequested(protocolIdA, requestAmount, data);
        router.requestProtocolAction(protocolIdA, requestAmount, data);

        assertEq(
            router.pendingAllocation(protocolIdA),
            allocationBefore - requestAmount,
            "Allocation not deducted"
        );
    }

    function test_RequestActionRevertsInsufficientAllocation() public {
        uint256 allocation = router.pendingAllocation(protocolIdA);
        
        vm.prank(admin);
        vm.expectRevert("insufficient allocation");
        router.requestProtocolAction(protocolIdA, allocation + 1, "");
    }

    function test_RequestActionRevertsZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert("amount zero");
        router.requestProtocolAction(protocolIdA, 0, "");
    }

    function test_RequestActionRevertsUnknownProtocol() public {
        bytes32 unknownId = keccak256("UNKNOWN");
        
        vm.prank(admin);
        vm.expectRevert("unknown protocol");
        router.requestProtocolAction(unknownId, 1000, "");
    }

    function test_RequestActionOnlyAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        router.requestProtocolAction(protocolIdA, 1000, "");
    }

    function test_ExecuteProtocolAction() public {
        vm.prank(oracle);
        vm.expectEmit(true, true, true, true);
        emit AIYieldRouter.ProtocolActionExecuted(protocolIdA, 10_000e6, "0xabc123");
        router.executeProtocolAction(protocolIdA, 10_000e6, "0xabc123");
    }

    function test_ExecuteActionOnlyOracle() public {
        vm.prank(user);
        vm.expectRevert();
        router.executeProtocolAction(protocolIdA, 10_000e6, "0xabc123");
    }

    function test_RecordImpact() public {
        address donor = address(123);
        
        vm.prank(oracle);
        vm.expectEmit(true, true, true, true);
        emit AIYieldRouter.ImpactRecorded(protocolIdA, donor, 5_000e6, "ipfs://Qm...");
        router.recordImpact(protocolIdA, donor, 5_000e6, "ipfs://Qm...");
    }

    function test_RecordImpactOnlyOracle() public {
        vm.prank(user);
        vm.expectRevert();
        router.recordImpact(protocolIdA, user, 1000, "ipfs://...");
    }
}

/**
 * @title AIYieldRouter Admin Tests
 * @notice Tests for administrative functions
 */
contract AIYieldRouterAdminTest is AIYieldRouterSetup {
    
    function test_SetDonationBps() public {
        vm.prank(admin);
        router.setDonationBps(5000);
        
        assertEq(router.donationBps(), 5000, "Donation BPS not updated");
    }

    function test_SetDonationBpsRevertsOverMax() public {
        vm.prank(admin);
        vm.expectRevert("bps>10000");
        router.setDonationBps(10001);
    }

    function test_SetDonationBpsOnlyAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        router.setDonationBps(5000);
    }

    function test_SetRedeemInterval() public {
        vm.prank(admin);
        router.setRedeemInterval(14 days);
        
        assertEq(router.redeemInterval(), 14 days, "Redeem interval not updated");
    }

    function test_SetRedeemIntervalRevertsSmallInterval() public {
        vm.prank(admin);
        vm.expectRevert("interval too small");
        router.setRedeemInterval(30 minutes);
    }

    function test_SetRedeemIntervalOnlyAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        router.setRedeemInterval(14 days);
    }

    function test_SetVault() public {
        address newVault = address(99);
        
        vm.prank(admin);
        router.setVault(newVault);
        
        assertEq(router.vault(), newVault, "Vault not updated");
    }

    function test_SetVaultRevertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("vault zero");
        router.setVault(address(0));
    }

    function test_SetVaultOnlyAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        router.setVault(address(99));
    }

    function test_EmergencyWithdraw() public {
        uint256 routerBalance = stableToken.balanceOf(address(router));
        address recipient = address(789);
        
        vm.prank(admin);
        router.emergencyWithdraw(address(stableToken), recipient, routerBalance);
        
        assertEq(stableToken.balanceOf(recipient), routerBalance, "Tokens not withdrawn");
        assertEq(stableToken.balanceOf(address(router)), 0, "Router should have 0 balance");
    }

    function test_EmergencyWithdrawRevertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("to zero");
        router.emergencyWithdraw(address(stableToken), address(0), 1000);
    }

    function test_EmergencyWithdrawOnlyDefaultAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        router.emergencyWithdraw(address(stableToken), user, 1000);
    }
}

/**
 * @title AIYieldRouter View Functions Tests
 * @notice Tests for view and helper functions
 */
contract AIYieldRouterViewTest is AIYieldRouterSetup {
    
    function test_GetProtocols() public {
        setupProtocols();
        
        bytes32[] memory protocols = router.getProtocols();
        assertEq(protocols.length, 2, "Should return 2 protocols");
    }

    function test_SharesBalance() public {
        mintVaultSharesToRouter(50_000e6);
        
        assertEq(router.sharesBalance(), 50_000e6, "Shares balance mismatch");
    }

    function test_AssetsAvailable() public {
        uint256 balance = stableToken.balanceOf(address(router));
        assertEq(router.assetsAvailable(), balance, "Assets available mismatch");
    }
}

/**
 * @title AIYieldRouter Fuzz Tests
 * @notice Fuzz tests for various scenarios
 */
contract AIYieldRouterFuzzTest is AIYieldRouterSetup {
    
    function setUp() public override {
        super.setUp();
        setupProtocols();
    }

    function testFuzz_RedeemAndAllocate(uint256 amount) public {
        amount = bound(amount, 1e6, 1_000_000e6); // Between 1 and 1M USDC
        
        mintVaultSharesToRouter(amount);
        
        vm.prank(admin);
        router.redeemAndAllocate();
        
        uint256 totalAllocated = router.pendingAllocation(protocolIdA) + router.pendingAllocation(protocolIdB);
        assertEq(totalAllocated, amount, "Total allocation should equal redeemed amount");
    }

    function testFuzz_SetDonationBps(uint16 bps) public {
        bps = uint16(bound(bps, 0, 10000));
        
        vm.prank(admin);
        router.setDonationBps(bps);
        
        assertEq(router.donationBps(), bps, "Donation BPS not set correctly");
    }

    function testFuzz_SetRedeemInterval(uint256 interval) public {
        interval = bound(interval, 1 hours, 365 days);
        
        vm.prank(admin);
        router.setRedeemInterval(interval);
        
        assertEq(router.redeemInterval(), interval, "Redeem interval not set correctly");
    }

    function testFuzz_ProtocolWeights(uint32 weightA, uint32 weightB) public {
        weightA = uint32(bound(weightA, 1, 1000));
        weightB = uint32(bound(weightB, 1, 1000));
        
        vm.startPrank(admin);
        router.setProtocol(protocolIdA, "Protocol A", weightA, true);
        router.setProtocol(protocolIdB, "Protocol B", weightB, true);
        vm.stopPrank();
        
        assertEq(router.totalProtocolWeights(), uint256(weightA) + uint256(weightB), "Total weights incorrect");
    }
}
