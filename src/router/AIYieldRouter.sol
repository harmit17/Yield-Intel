// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*//////////////////////////////////////////////////////////////
                            INTERFACES
//////////////////////////////////////////////////////////////*/

/**
 * @notice Minimal ERC4626 interface for vault share redemption
 * @dev This interface includes only the functions needed by the router
 */
interface IERC4626 {
    /// @notice Redeems vault shares for underlying assets
    /// @param shares Amount of shares to redeem
    /// @param receiver Address that will receive the assets
    /// @param owner Address that owns the shares being redeemed
    /// @return Amount of underlying assets received
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    
    /// @notice Returns the maximum amount of assets that can be withdrawn
    /// @param owner Address to check withdrawal limit for
    /// @return Maximum withdrawable asset amount
    function maxWithdraw(address owner) external view returns (uint256);
    
    /// @notice Returns the share balance of an account
    /// @param owner Address to check balance for
    /// @return Share token balance
    function balanceOf(address owner) external view returns (uint256);
}

/*//////////////////////////////////////////////////////////////
                        MAIN CONTRACT
//////////////////////////////////////////////////////////////*/

/**
 * @title AIYieldRouter
 * @author YieldIntel
 * @notice Manages yield donation distribution from ERC4626 vaults to various protocols
 * @dev This contract acts as a router that:
 *      - Receives ERC4626 vault shares representing harvested yield
 *      - Redeems shares periodically (default: every 7 days) to underlying assets
 *      - Allocates redeemed assets to configured donation protocols based on weights
 *      - Tracks pending allocations and facilitates off-chain execution
 *      - Maintains minimal on-chain logic for gas efficiency
 *
 *      Key Features:
 *      - Time-gated redemption with configurable intervals
 *      - Weighted allocation across multiple protocols
 *      - Role-based access control (ADMIN_ROLE, ORACLE_ROLE)
 *      - Reentrancy protection for all state-changing operations
 *      - Emergency withdrawal functionality
 *
 *      Architecture:
 *      - On-chain: Accounting, cooldown enforcement, allocation tracking
 *      - Off-chain: Actual swaps, bridges, and cross-chain operations (Oracle role)
 */
contract AIYieldRouter is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role identifier for oracle operations (off-chain execution reporting)
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    
    /// @notice Role identifier for administrative operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    /// @notice Basis points denominator (10000 = 100%)
    uint16 private constant BPS_DENOMINATOR = 10000;

    /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The stable token used for donations (e.g., USDC, USDT)
    /// @dev Immutable to ensure donation token cannot be changed after deployment
    IERC20 public immutable STABLE;

    /// @notice The ERC4626 vault shares representing harvested yield
    /// @dev Immutable to ensure vault shares token cannot be changed after deployment
    IERC4626 public immutable VAULT_SHARES;

    /// @notice Address of the ERC4626 vault contract
    /// @dev Can be updated by admin if needed; used for validation purposes
    address public vault;

    /// @notice Percentage of redeemed assets to donate (in basis points)
    /// @dev Default is 10000 (100%). Can be reduced to retain some assets
    uint16 public donationBps = BPS_DENOMINATOR;

    /// @notice Minimum time interval between redemption operations
    /// @dev Default is 7 days. Prevents excessive redemption frequency
    uint256 public redeemInterval = 7 days;

    /// @notice Timestamp of the last successful redemption
    /// @dev Used to enforce redeemInterval cooldown period
    uint256 public lastRedeem;

    /// @notice Total sum of all protocol weights
    /// @dev Used for proportional allocation calculations
    uint256 public totalProtocolWeights;

    /*//////////////////////////////////////////////////////////////
                            STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Represents a donation protocol configuration
     * @param name Human-readable protocol name
     * @param id Unique identifier for the protocol
     * @param weight Relative weight for allocation (higher = larger share)
     * @param enabled Whether the protocol is currently accepting donations
     */
    struct Protocol {
        string name;
        bytes32 id;
        uint32 weight;
        bool enabled;
    }

    /*//////////////////////////////////////////////////////////////
                            MAPPINGS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maps protocol IDs to their configuration
    mapping(bytes32 => Protocol) public protocols;
    
    /// @notice Array of all protocol IDs in order of addition
    bytes32[] public protocolList;
    
    /// @notice Maps protocol IDs to their pending allocation amounts
    /// @dev Allocated but not yet executed donations
    mapping(bytes32 => uint256) public pendingAllocation;

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when vault shares are received by this contract
    /// @param fromVault Address of the vault that sent shares
    /// @param sharesAmount Amount of shares received
    event HarvestSharesReceived(address indexed fromVault, uint256 sharesAmount);
    
    /// @notice Emitted when vault shares are redeemed for underlying assets
    /// @param assetsOut Total amount of assets received from redemption
    /// @param donationAmount Amount allocated for donation (after applying donationBps)
    event RedeemedShares(uint256 assetsOut, uint256 donationAmount);
    
    /// @notice Emitted when assets are allocated to a protocol
    /// @param protocolId Unique identifier of the protocol receiving allocation
    /// @param amount Amount of assets allocated
    event DonationAllocated(bytes32 indexed protocolId, uint256 amount);
    
    /// @notice Emitted when an admin requests protocol action execution
    /// @param protocolId Unique identifier of the protocol
    /// @param amount Amount of assets involved in the action
    /// @param data Additional data for off-chain executor
    event ProtocolActionRequested(bytes32 indexed protocolId, uint256 amount, bytes data);
    
    /// @notice Emitted when oracle confirms off-chain action execution
    /// @param protocolId Unique identifier of the protocol
    /// @param amount Amount that was executed
    /// @param externalTx Reference to external transaction (e.g., tx hash, receipt)
    event ProtocolActionExecuted(bytes32 indexed protocolId, uint256 amount, string externalTx);
    
    /// @notice Emitted when donation impact is recorded
    /// @param protocolId Unique identifier of the protocol
    /// @param donor Address of the original donor (if tracked)
    /// @param amount Amount of donation impact
    /// @param metadataUri URI pointing to impact metadata (IPFS, etc.)
    event ImpactRecorded(bytes32 indexed protocolId, address indexed donor, uint256 amount, string metadataUri);

    /*//////////////////////////////////////////////////////////////
                            ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when attempting to redeem before cooldown period has elapsed
    /// @param availableAt Timestamp when next redemption will be available
    error CooldownNotElapsed(uint256 availableAt);
    
    /// @notice Thrown when caller is not the authorized vault
    error NotVault();

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the AIYieldRouter with essential configuration
     * @dev Sets up immutable token references and grants initial roles
     * @param _stable Address of the stable token for donations (e.g., USDC)
     * @param _vaultShares Address of the ERC4626 vault shares token
     * @param admin Address to receive DEFAULT_ADMIN_ROLE and ADMIN_ROLE
     *
     * Requirements:
     * - None of the addresses can be zero address
     * - Stable token must be a valid ERC20
     * - Vault shares must implement ERC4626 interface
     */
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

    /*//////////////////////////////////////////////////////////////
                    REDEMPTION & ALLOCATION LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Redeems all accumulated vault shares and allocates donations to protocols
     * @dev Main function for periodic yield processing. Enforces time-based cooldown.
     *
     *      Process Flow:
     *      1. Verify cooldown period has elapsed
     *      2. Query current vault share balance
     *      3. Update lastRedeem timestamp
     *      4. Redeem shares for underlying stable assets
     *      5. Calculate donation amount based on donationBps
     *      6. Distribute donation across enabled protocols proportionally
     *
     * Requirements:
     * - Caller must have ADMIN_ROLE
     * - Cooldown period (redeemInterval) must have elapsed since lastRedeem
     * - At least one protocol must be configured and enabled
     *
     * @custom:security Uses nonReentrant to prevent reentrancy attacks during redemption
     */
    function redeemAndAllocate() external nonReentrant onlyRole(ADMIN_ROLE) {
        // Enforce cooldown period to prevent excessive redemptions
        if (block.timestamp < lastRedeem + redeemInterval) {
            revert CooldownNotElapsed(lastRedeem + redeemInterval);
        }

        // Get all available vault shares held by this contract
        uint256 availableShares = VAULT_SHARES.balanceOf(address(this));

        // Update timestamp before external call (checks-effects-interactions pattern)
        lastRedeem = block.timestamp;

        // Redeem ERC4626 shares for underlying stable assets
        // Shares are burned and assets are transferred to this contract
        uint256 assetsOut = VAULT_SHARES.redeem(availableShares, address(this), address(this));

        // Calculate the portion to donate based on configured percentage
        uint256 donationAmount = (assetsOut * donationBps) / BPS_DENOMINATOR;

        // Distribute donation across enabled protocols using their weights
        if (donationAmount > 0) {
            _allocateDonation(donationAmount);
        }

        emit RedeemedShares(assetsOut, donationAmount);
    }

    /**
     * @notice Internally distributes donation amount across enabled protocols
     * @dev Uses weighted proportional allocation with remainder handling
     *
     *      Allocation Strategy:
     *      - Each enabled protocol receives: (donationAmount * protocolWeight) / totalProtocolWeights
     *      - The last enabled protocol receives any remaining dust to ensure full distribution
     *      - Disabled protocols are skipped
     *      - Allocations are added to pendingAllocation mapping for later execution
     *
     * @param donationAmount Total amount to distribute across protocols
     *
     * Requirements:
     * - At least one protocol must be configured (totalProtocolWeights > 0)
     * - At least one protocol must be enabled
     *
     * @custom:security Internal function, called only by redeemAndAllocate
     */
    function _allocateDonation(uint256 donationAmount) internal {
        require(totalProtocolWeights > 0, "no protocols configured");
        
        uint256 remaining = donationAmount;

        // First pass: count enabled protocols
        uint256 enabledCount = 0;
        for (uint256 i = 0; i < protocolList.length; i++) {
            if (protocols[protocolList[i]].enabled) {
                enabledCount++;
            }
        }
        require(enabledCount > 0, "no enabled protocols");

        // Second pass: allocate proportionally
        uint256 processed = 0;
        for (uint256 i = 0; i < protocolList.length; i++) {
            bytes32 pid = protocolList[i];
            Protocol memory p = protocols[pid];
            
            // Skip disabled protocols
            if (!p.enabled) continue;

            uint256 share;
            
            // Calculate proportional share, except for the last protocol
            if (processed + 1 < enabledCount) {
                // Standard proportional allocation
                share = (donationAmount * p.weight) / totalProtocolWeights;
            } else {
                // Last enabled protocol gets all remaining (handles rounding dust)
                share = remaining;
            }

            // Update state if share is non-zero
            if (share > 0) {
                pendingAllocation[pid] += share;
                remaining -= share;
                emit DonationAllocated(pid, share);
            }
            
            processed++;
        }

        // Note: Any dust (typically 0-1 wei) remains in contract and accumulates over time
        // This approach prevents rounding errors and ensures complete allocation
    }

    /*//////////////////////////////////////////////////////////////
                    PROTOCOL CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adds a new protocol or updates an existing protocol configuration
     * @dev Manages protocol registry and maintains totalProtocolWeights
     *
     *      For New Protocols:
     *      - Creates new Protocol struct
     *      - Adds to protocolList array
     *      - Increases totalProtocolWeights
     *
     *      For Existing Protocols:
     *      - Updates name, weight, and enabled status
     *      - Adjusts totalProtocolWeights accordingly
     *
     * @param id Unique identifier for the protocol (must be non-zero)
     * @param name Human-readable protocol name
     * @param weight Relative weight for allocation (higher = more allocation)
     * @param enabled Whether protocol should receive allocations
     *
     * Requirements:
     * - Caller must have ADMIN_ROLE
     * - Protocol id cannot be bytes32(0)
     *
     * @custom:usage Example: setProtocol(keccak256("PROTOCOL_A"), "Protocol A", 500, true)
     */
    function setProtocol(bytes32 id, string calldata name, uint32 weight, bool enabled) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        require(id != bytes32(0), "id zero");
        
        // Check if this is a new protocol
        if (protocols[id].id == bytes32(0)) {
            // Register new protocol
            protocols[id] = Protocol({
                name: name,
                id: id,
                weight: weight,
                enabled: enabled
            });
            
            protocolList.push(id);
            totalProtocolWeights += weight;
            
            // Emit with 0 amount to mark protocol registration
            emit DonationAllocated(id, 0);
        } else {
            // Update existing protocol
            uint32 oldWeight = protocols[id].weight;
            
            // Update protocol fields
            protocols[id].name = name;
            protocols[id].weight = weight;
            protocols[id].enabled = enabled;
            
            // Adjust total weights based on weight change
            if (weight >= oldWeight) {
                totalProtocolWeights += (weight - oldWeight);
            } else {
                totalProtocolWeights -= (oldWeight - weight);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                    ACTION REQUEST & EXECUTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Requests execution of a protocol action using pending allocations
     * @dev Deducts from pending allocation and emits event for off-chain executor
     *
     *      This function initiates the process for off-chain execution:
     *      1. Validates protocol exists and has sufficient pending allocation
     *      2. Deducts the requested amount from pending allocation
     *      3. Emits event with execution data for off-chain oracle
     *
     * @param protocolId Unique identifier of the target protocol
     * @param amount Amount of stable tokens to use for the action
     * @param data Additional data for off-chain executor (e.g., swap params, bridge info)
     *
     * Requirements:
     * - Caller must have ADMIN_ROLE
     * - Protocol must be registered
     * - Amount must be greater than 0
     * - Protocol must have sufficient pending allocation
     *
     * @custom:security Amount is deducted before emitting event (checks-effects-interactions)
     */
    function requestProtocolAction(bytes32 protocolId, uint256 amount, bytes calldata data) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        require(protocols[protocolId].id != bytes32(0), "unknown protocol");
        require(amount > 0, "amount zero");
        require(pendingAllocation[protocolId] >= amount, "insufficient allocation");

        // Deduct from pending allocation
        pendingAllocation[protocolId] -= amount;
        
        // Emit event for off-chain oracle to process
        emit ProtocolActionRequested(protocolId, amount, data);
    }

    /**
     * @notice Records the successful execution of a protocol action by off-chain oracle
     * @dev Oracle-only function to confirm off-chain operations were completed
     *
     *      Use Cases:
     *      - Confirming cross-chain bridges
     *      - Recording swap executions
     *      - Documenting external protocol interactions
     *
     * @param protocolId Unique identifier of the protocol
     * @param amount Amount that was actually executed (may differ from requested)
     * @param externalTx External transaction reference (tx hash, receipt URL, etc.)
     *
     * Requirements:
     * - Caller must have ORACLE_ROLE
     *
     * @custom:security This is purely informational; no state changes occur
     */
    function executeProtocolAction(bytes32 protocolId, uint256 amount, string calldata externalTx) 
        external 
        onlyRole(ORACLE_ROLE) 
    {
        emit ProtocolActionExecuted(protocolId, amount, externalTx);
    }

    /**
     * @notice Records donation impact for transparency and tracking
     * @dev Oracle function to log donation outcomes and impact metrics
     *
     *      Impact Recording:
     *      - Links donations to specific donors (if tracked)
     *      - References impact metadata (IPFS, etc.)
     *      - Creates on-chain record of social impact
     *
     * @param protocolId Unique identifier of the protocol
     * @param donor Address of the original donor (or zero address if anonymous)
     * @param amount Amount of donation being recorded
     * @param metadataUri URI pointing to impact metadata (IPFS hash, HTTP URL, etc.)
     *
     * Requirements:
     * - Caller must have ORACLE_ROLE
     *
     * @custom:usage Used for creating transparent, verifiable impact records
     */
    function recordImpact(bytes32 protocolId, address donor, uint256 amount, string calldata metadataUri) 
        external 
        onlyRole(ORACLE_ROLE) 
    {
        emit ImpactRecorded(protocolId, donor, amount, metadataUri);
    }

    /*//////////////////////////////////////////////////////////////
                    ADMINISTRATIVE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the donation percentage
     * @dev Allows admin to adjust what portion of redeemed assets goes to donations
     *
     * @param bps New donation percentage in basis points (0-10000, where 10000 = 100%)
     *
     * Requirements:
     * - Caller must have ADMIN_ROLE
     * - bps must be <= 10000 (cannot exceed 100%)
     *
     * @custom:example setDonationBps(5000) sets donations to 50% of redeemed assets
     */
    function setDonationBps(uint16 bps) external onlyRole(ADMIN_ROLE) {
        require(bps <= BPS_DENOMINATOR, "bps>10000");
        donationBps = bps;
    }

    /**
     * @notice Updates the minimum interval between redemptions
     * @dev Controls how frequently shares can be redeemed to manage gas and timing
     *
     * @param intervalSeconds New interval in seconds (minimum 1 hour)
     *
     * Requirements:
     * - Caller must have ADMIN_ROLE
     * - Interval must be at least 1 hour to prevent spam
     *
     * @custom:security Prevents griefing through excessive redemption calls
     */
    function setRedeemInterval(uint256 intervalSeconds) external onlyRole(ADMIN_ROLE) {
        require(intervalSeconds >= 1 hours, "interval too small");
        redeemInterval = intervalSeconds;
    }

    /**
     * @notice Updates the vault address reference
     * @dev Updates the vault address used for validation purposes
     *
     * @param _vault New vault address
     *
     * Requirements:
     * - Caller must have ADMIN_ROLE
     * - Vault address cannot be zero
     *
     * @custom:note This only updates the reference address, not the immutable VAULT_SHARES token
     */
    function setVault(address _vault) external onlyRole(ADMIN_ROLE) {
        require(_vault != address(0), "vault zero");
        vault = _vault;
    }

    /**
     * @notice Emergency function to recover stuck tokens
     * @dev Allows DEFAULT_ADMIN to withdraw any ERC20 tokens from the contract
     *
     *      Use Cases:
     *      - Recovering accidentally sent tokens
     *      - Emergency fund extraction
     *      - Upgrading to new router contract
     *
     * @param token Address of the ERC20 token to withdraw
     * @param to Recipient address for the tokens
     * @param amount Amount of tokens to withdraw
     *
     * Requirements:
     * - Caller must have DEFAULT_ADMIN_ROLE (highest permission level)
     * - Recipient address cannot be zero
     *
     * @custom:security Only callable by DEFAULT_ADMIN_ROLE to prevent misuse
     */
    function emergencyWithdraw(address token, address to, uint256 amount) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        require(to != address(0), "to zero");
        IERC20(token).safeTransfer(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the list of all registered protocol IDs
     * @dev Returns array in order of registration
     *
     * @return Array of protocol IDs (bytes32)
     *
     * @custom:usage Use this to iterate through all protocols or build UI protocol lists
     */
    function getProtocols() external view returns (bytes32[] memory) {
        return protocolList;
    }

    /**
     * @notice Returns pending allocation amounts for multiple protocols
     * @dev Batch query function for efficient data retrieval
     *
     * @param ids Array of protocol IDs to query
     * @return Array of pending allocation amounts corresponding to input IDs
     *
     * @custom:gas More efficient than calling pendingAllocation repeatedly
     */
    function getPendingAllocations(bytes32[] calldata ids) 
        external 
        view 
        returns (uint256[] memory) 
    {
        uint256[] memory outs = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            outs[i] = pendingAllocation[ids[i]];
        }
        return outs;
    }

    /**
     * @notice Returns the current vault share balance held by this contract
     * @dev Useful for monitoring accumulated yield before redemption
     *
     * @return Amount of ERC4626 vault shares held by this contract
     *
     * @custom:usage Check this before calling redeemAndAllocate to see available shares
     */
    function sharesBalance() external view returns (uint256) {
        return VAULT_SHARES.balanceOf(address(this));
    }

    /**
     * @notice Returns the current stable token balance held by this contract
     * @dev Shows available funds for donations (redeemed but not yet allocated or executed)
     *
     * @return Amount of stable tokens held by this contract
     *
     * @custom:usage Monitor this to track accumulated dust and available liquidity
     */
    function assetsAvailable() external view returns (uint256) {
        return STABLE.balanceOf(address(this));
    }
}





