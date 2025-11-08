
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title AIYieldRouter - Yield donation router for YieldIntel (with ERC4626 redemption cadence)
/// @author YieldIntel
/// @notice Accepts harvested vault shares (ERC4626) and redeems them every 7 days, allocating donation to protocols.
/// @dev Keeps on-chain responsibilities minimal: accounting, cooldown, and allocation. Off-chain worker executes swaps/bridges.
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC4626 {
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    // minimal needed interface; expand if needed
}

contract AIYieldRouter is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant ADMIN_ROLE  = keccak256("ADMIN_ROLE");

    // Stable token we operate in (e.g., USDC)
    IERC20 public immutable STABLE;

    // Vault token (ERC4626 shares) minted to this contract when vault harvests
    IERC4626 public immutable VAULT_SHARES;

    // Vault contract that mints shares (optional reference for checks)
    address public vault; // address of the ERC4626 vault contract (same as vaultShares addr)

    // Donation configuration
    uint16 public donationBps = 10000; // default donate 100% (bps) of redeemed assets
    uint256 public redeemInterval = 7 days; // cadence

    // timestamp of last successful redeem
    uint256 public lastRedeem;

    struct Protocol {
        string name;
        bytes32 id;
        uint32 weight;
        bool enabled;
    }

    mapping(bytes32 => Protocol) public protocols;
    bytes32[] public protocolList;
    mapping(bytes32 => uint256) public pendingAllocation;
    uint256 public totalProtocolWeights;

    /* ========== EVENTS ========== */
    event HarvestSharesReceived(address indexed fromVault, uint256 sharesAmount);
    event RedeemedShares(uint256 assetsOut, uint256 donationAmount);
    event DonationAllocated(bytes32 indexed protocolId, uint256 amount);
    event ProtocolActionRequested(bytes32 indexed protocolId, uint256 amount, bytes data);
    event ProtocolActionExecuted(bytes32 indexed protocolId, uint256 amount, string externalTx);
    event ImpactRecorded(bytes32 indexed protocolId, address indexed donor, uint256 amount, string metadataUri);

    /* ========== ERRORS ========== */
    error NotVault();
    error CooldownNotElapsed(uint256 availableAt);

    constructor(address _stable, address _vaultShares, address admin) {
        require(_stable != address(0), "stable zero");
        require(_vaultShares != address(0), "vaultShares zero");
        require(admin != address(0), "admin zero");

        STABLE = IERC20(_stable);
        VAULT_SHARES = IERC4626(_vaultShares);
        vault = _vaultShares;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
    }

    /* ========== REDEEM & ALLOCATION (7-day cadence) ========== */

   
    function redeemAndAllocate() external nonReentrant onlyRole(ADMIN_ROLE) {
        // enforce cadence
        if (block.timestamp < lastRedeem + redeemInterval) {
            revert CooldownNotElapsed(lastRedeem + redeemInterval);
        }

        uint256 availableShares = VAULT_SHARES.balanceOf(address(this));

        // record before external call
        lastRedeem = block.timestamp;

        // call ERC4626 redeem: returns assetsOut
        uint256 assetsOut = VAULT_SHARES.redeem(availableShares, address(this), address(this));

        // allocate donation portion
        uint256 donationAmount = (assetsOut * donationBps) / 10000;

        // allocate the donations across enabled protocols (weights)
        if (donationAmount > 0) {
            _allocateDonation(donationAmount);
        }

        emit RedeemedShares(assetsOut, donationAmount);
    }

    /// @notice Internal: split donation across configured protocols according to weights (keeps rounding to last protocol)
    function _allocateDonation(uint256 donationAmount) internal {
        require(totalProtocolWeights > 0, "no protocols configured");
        uint256 remaining = donationAmount;

        // allocate proportionally; last enabled gets remainder
        uint256 enabledCount = 0;
        for (uint256 i = 0; i < protocolList.length; i++) {
            if (protocols[protocolList[i]].enabled) enabledCount++;
        }
        require(enabledCount > 0, "no enabled protocols");

        uint256 processed = 0;
        uint256 lastIndex = 0;
        for (uint256 i = 0; i < protocolList.length; i++) {
            bytes32 pid = protocolList[i];
            Protocol memory p = protocols[pid];
            if (!p.enabled) continue;

            uint256 share;
            // find last enabled index to give remainder there
            lastIndex = i;
            if (processed + 1 < enabledCount) {
                share = (donationAmount * p.weight) / totalProtocolWeights;
            } else {
                // last enabled gets remaining
                share = remaining;
            }

            if (share > 0) {
                pendingAllocation[pid] += share;
                remaining -= share;
                emit DonationAllocated(pid, share);
            }
            processed++;
        }

        // any tiny remainder stays in contract stable balance (could be sent to treasury)
    }

    /* ========== PROTOCOL CONFIG ========= */

    function setProtocol(bytes32 id, string calldata name, uint32 weight, bool enabled) external onlyRole(ADMIN_ROLE) {
        require(id != bytes32(0), "id zero");
        if (protocols[id].id == bytes32(0)) {
            protocols[id] = Protocol({ name: name, id: id, weight: weight, enabled: enabled });
            protocolList.push(id);
            totalProtocolWeights += weight;
            emit DonationAllocated(id, 0); // no-op event to mark existence (optional)
        } else {
            uint32 oldWeight = protocols[id].weight;
            protocols[id].name = name;
            protocols[id].weight = weight;
            protocols[id].enabled = enabled;
            if (weight >= oldWeight) {
                totalProtocolWeights += (weight - oldWeight);
            } else {
                totalProtocolWeights -= (oldWeight - weight);
            }
        }
    }

    /* ========== REQUEST / EXECUTION (same as prior pattern) ========== */

    function requestProtocolAction(bytes32 protocolId, uint256 amount, bytes calldata data) external onlyRole(ADMIN_ROLE) {
        require(protocols[protocolId].id != bytes32(0), "unknown protocol");
        require(amount > 0, "amount zero");
        require(pendingAllocation[protocolId] >= amount, "insufficient allocation");

        pendingAllocation[protocolId] -= amount;
        emit ProtocolActionRequested(protocolId, amount, data);
    }

    function executeProtocolAction(bytes32 protocolId, uint256 amount, string calldata externalTx) external onlyRole(ORACLE_ROLE) {
        emit ProtocolActionExecuted(protocolId, amount, externalTx);
    }

    function recordImpact(bytes32 protocolId, address donor, uint256 amount, string calldata metadataUri) external onlyRole(ORACLE_ROLE) {
        emit ImpactRecorded(protocolId, donor, amount, metadataUri);
    }

    /* ========== ADMIN UTILITIES ========== */

    function setDonationBps(uint16 bps) external onlyRole(ADMIN_ROLE) {
        require(bps <= 10000, "bps>10000");
        donationBps = bps;
    }

    function setRedeemInterval(uint256 intervalSeconds) external onlyRole(ADMIN_ROLE) {
        require(intervalSeconds >= 1 hours, "interval too small");
        redeemInterval = intervalSeconds;
    }

    function setVault(address _vault) external onlyRole(ADMIN_ROLE) {
        require(_vault != address(0), "vault zero");
        vault = _vault;
        // Note: vaultShares was set at constructor; if you need dynamic, change design
    }

    // emergency withdraw for stable tokens
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(to != address(0), "to zero");
        IERC20(token).safeTransfer(to, amount);
    }

    /* ========== VIEW HELPERS ========== */

    function getProtocols() external view returns (bytes32[] memory) {
        return protocolList;
    }

    function getPendingAllocations(bytes32[] calldata ids) external view returns (uint256[] memory) {
        uint256[] memory outs = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            outs[i] = pendingAllocation[ids[i]];
        }
        return outs;
    }

    function sharesBalance() external view returns (uint256) {
        return VAULT_SHARES.balanceOf(address(this));
    }

    function assetsAvailable() external view returns (uint256) {
        return STABLE.balanceOf(address(this));
    }
}





