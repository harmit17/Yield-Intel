// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {AIYieldRouter} from "../../router/AIYieldRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock ERC20 for testing
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }
}

// Mock ERC4626 Vault for testing
contract MockERC4626 {
    IERC20 public asset;
    mapping(address => uint256) private _balances;
    uint256 public totalShares;
    uint256 public totalAssets_;

    constructor(address _asset) {
        asset = IERC20(_asset);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        asset.transferFrom(msg.sender, address(this), assets);
        shares = assets; // 1:1 for simplicity
        _balances[receiver] += shares;
        totalShares += shares;
        totalAssets_ += assets;
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(_balances[owner] >= shares, "insufficient shares");
        _balances[owner] -= shares;
        totalShares -= shares;
        
        assets = shares; // 1:1 for simplicity
        totalAssets_ -= assets;
        asset.transfer(receiver, assets);
        return assets;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _balances[owner];
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return _balances[owner];
    }

    // Helper to simulate yield generation
    function simulateYield(uint256 amount) external {
        MockERC20(address(asset)).mint(address(this), amount);
        totalAssets_ += amount;
    }
}

contract AIYieldRouterSetup is Test {
    AIYieldRouter public router;
    MockERC20 public stableToken;
    MockERC4626 public vaultShares;

    address public admin = address(1);
    address public oracle = address(2);
    address public user = address(3);
    address public protocolA = address(4);
    address public protocolB = address(5);

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    
    bytes32 public protocolIdA = keccak256("PROTOCOL_A");
    bytes32 public protocolIdB = keccak256("PROTOCOL_B");

    uint256 public constant INITIAL_BALANCE = 1_000_000e6; // 1M USDC

    function setUp() public virtual {
        // Deploy mock tokens
        stableToken = new MockERC20("USD Coin", "USDC", 6);
        vaultShares = new MockERC4626(address(stableToken));

        // Deploy router
        vm.prank(admin);
        router = new AIYieldRouter(address(stableToken), address(vaultShares), admin);

        // Grant roles
        vm.startPrank(admin);
        router.grantRole(ORACLE_ROLE, oracle);
        vm.stopPrank();

        // Mint tokens to test accounts
        stableToken.mint(address(vaultShares), INITIAL_BALANCE);
        stableToken.mint(user, INITIAL_BALANCE);
        stableToken.mint(address(router), INITIAL_BALANCE);

        // Label addresses for better trace readability
        vm.label(admin, "Admin");
        vm.label(oracle, "Oracle");
        vm.label(user, "User");
        vm.label(address(router), "Router");
        vm.label(address(stableToken), "USDC");
        vm.label(address(vaultShares), "Vault");
        vm.label(protocolA, "ProtocolA");
        vm.label(protocolB, "ProtocolB");

        // Warp past initial cooldown to allow redemptions in tests
        vm.warp(block.timestamp + 7 days + 1);
    }

    // Helper function to setup protocols
    function setupProtocols() public {
        vm.startPrank(admin);
        router.setProtocol(protocolIdA, "Protocol A", 60, true); // 60% weight
        router.setProtocol(protocolIdB, "Protocol B", 40, true); // 40% weight
        vm.stopPrank();
    }

    // Helper function to send vault shares to router
    function mintVaultSharesToRouter(uint256 amount) public {
        vm.startPrank(user);
        stableToken.approve(address(vaultShares), amount);
        vaultShares.deposit(amount, address(router));
        vm.stopPrank();
    }
}
