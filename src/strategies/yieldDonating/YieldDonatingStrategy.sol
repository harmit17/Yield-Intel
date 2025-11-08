// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {BaseStrategy} from "@octant-core/core/BaseStrategy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*//////////////////////////////////////////////////////////////
                            INTERFACES
//////////////////////////////////////////////////////////////*/

/**
 * @notice Interface for yield source identification
 * @dev This interface can be extended to include specific yield source functions
 */
interface IYieldSource {}

/**
 * @notice Standard ERC4626 Tokenized Vault interface
 * @dev Implements the core functionality for yield-bearing vault interactions
 */
interface IERC4626 {
    /// @notice Deposits assets and mints shares to receiver
    function deposit(uint256 assets, address receiver) external returns (uint256);
    
    /// @notice Withdraws assets by burning shares from owner
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
    
    /// @notice Returns the underlying asset token address
    function asset() external view returns (address);
    
    /// @notice Returns the total amount of underlying assets held by the vault
    function totalAssets() external view returns (uint256);
    
    /// @notice Converts asset amount to share amount
    function convertToShares(uint256 assets) external view returns (uint256);
    
    /// @notice Converts share amount to asset amount
    function convertToAssets(uint256 shares) external view returns (uint256);
    
    /// @notice Returns maximum amount of assets that can be deposited
    function maxDeposit(address receiver) external view returns (uint256);
    
    /// @notice Returns maximum amount of assets that can be withdrawn
    function maxWithdraw(address owner) external view returns (uint256);
    
    /// @notice Simulates the effects of a deposit at current block
    function previewDeposit(uint256 assets) external view returns (uint256);
    
    /// @notice Simulates the effects of a withdrawal at current block
    function previewWithdraw(uint256 assets) external view returns (uint256);
    
    /// @notice Returns the share balance of an account
    function balanceOf(address account) external view returns (uint256);
}

/*//////////////////////////////////////////////////////////////
                            ERRORS
//////////////////////////////////////////////////////////////*/

/// @notice Thrown when attempting to deposit more than the vault's maximum deposit limit
error DepositExceedsLimit();


/*//////////////////////////////////////////////////////////////
                        MAIN CONTRACT
//////////////////////////////////////////////////////////////*/

/**
 * @title YieldDonating Strategy
 * @author Octant
 * @notice A strategy that generates yield from ERC4626 vaults and donates profits to a specified address
 * @dev This strategy template works with the TokenizedStrategy pattern where initialization 
 *      and management functions are handled by a separate contract. The strategy focuses on 
 *      core yield generation logic by depositing assets into an ERC4626-compliant vault.
 *
 *      Key Features:
 *      - Deposits user assets into ERC4626 vaults for yield generation
 *      - Automatically handles share accounting and asset conversion
 *      - Supports donation of generated yield to specified addresses
 *      - Implements comprehensive deposit and withdrawal limits
 *
 *      Access Control:
 *      - onlyManagement: For strategic parameter changes
 *      - onlyEmergencyAuthorized: For emergency withdrawals and pausing
 *      - onlyKeepers: For routine maintenance operations like tend()
 */
contract YieldDonatingStrategy is BaseStrategy {
    using SafeERC20 for ERC20;

    /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The ERC4626 vault where assets are deployed to generate yield
    /// @dev Immutable to ensure yield source cannot be changed after deployment
    IERC4626 public immutable YIELD_SOURCE;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the YieldDonating strategy with all required parameters
     * @dev Sets up the strategy with an ERC4626 yield source and approves maximum spending.
     *      The constructor performs the following:
     *      1. Calls BaseStrategy constructor with all role assignments
     *      2. Sets the immutable yield source vault
     *      3. Approves maximum uint256 for the yield source to enable seamless deposits
     *
     * @param _yieldSource Address of the ERC4626 vault where assets will be deposited
     * @param _asset Address of the underlying asset token (e.g., USDC, DAI, WETH)
     * @param _name Human-readable name for this strategy instance
     * @param _management Address granted management permissions (can update parameters)
     * @param _keeper Address granted keeper permissions (can call tend and harvest)
     * @param _emergencyAdmin Address granted emergency permissions (can trigger emergency withdrawals)
     * @param _donationAddress Address that receives the minted shares representing donated yield
     * @param _enableBurning If true, allows burning tokens from donation address to cover losses
     * @param _tokenizedStrategyAddress Address of the TokenizedStrategy implementation contract
     */
    constructor(
        address _yieldSource,
        address _asset,
        string memory _name,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        bool _enableBurning,
        address _tokenizedStrategyAddress
    )
        BaseStrategy(
            _asset,
            _name,
            _management,
            _keeper,
            _emergencyAdmin,
            _donationAddress,
            _enableBurning,
            _tokenizedStrategyAddress
        )
    {
        // Store the yield source vault as an immutable variable
        YIELD_SOURCE = IERC4626(_yieldSource);

        // Grant maximum approval to the yield source for seamless deposits
        // Using forceApprove to handle tokens that don't return bool on approve
        ERC20(_asset).forceApprove(_yieldSource, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                    CORE STRATEGY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys idle assets into the yield-generating vault
     * @dev Called automatically at the end of deposit() or mint() operations.
     *      This function is permissionless and can be called by anyone during deposits,
     *      so be aware of potential sandwich attacks or MEV extraction.
     *
     *      Implementation Details:
     *      - Validates that amount is greater than zero
     *      - Checks the vault's maximum deposit limit to prevent reverts
     *      - Deposits assets into ERC4626 vault and receives shares in return
     *      - Shares are held by this contract and represent claim on underlying assets
     *
     * @param _amount The amount of underlying asset to deploy into the yield source
     *
     * @custom:security This function assumes the vault is trusted and implements proper
     *                   ERC4626 standards. Always verify vault implementation before deployment.
     */
    function _deployFunds(uint256 _amount) internal override {
        // Only proceed if there are assets to deploy
        if (_amount > 0) {
            // Query the maximum amount the vault will accept in a single deposit
            // This prevents transaction revert and provides better error handling
            uint256 maxDeposit = YIELD_SOURCE.maxDeposit(address(this));
            
            // Revert with custom error if deposit exceeds vault's capacity
            if (_amount > maxDeposit) {
                revert DepositExceedsLimit();
            }
            
            // Deposit assets into the ERC4626 vault
            // The vault will mint shares to this contract in return
            // Shares represent proportional ownership of vault's total assets
            YIELD_SOURCE.deposit(_amount, address(this));
        }
    }

    /**
     * @notice Withdraws assets from the yield source to fulfill withdrawal requests
     * @dev Called during withdraw() and redeem() operations. This function handles the
     *      withdrawal of assets from the ERC4626 vault back to the strategy contract.
     *
     *      Important Notes:
     *      - Loose assets (already in contract) are accounted for before this is called
     *      - This function is permissionless during withdrawals (potential MEV risk)
     *      - Should NOT rely on asset.balanceOf(address(this)) except for diff accounting
     *      - Any shortfall between requested and actual withdrawal is counted as a loss
     *
     *      Loss Handling:
     *      If the vault cannot provide the full requested amount, the difference is 
     *      treated as a realized loss and passed to the withdrawer. During illiquidity,
     *      it may be better to revert rather than realize incorrect losses.
     *
     * @param _amount The amount of underlying asset to withdraw from the yield source
     *
     * @custom:security The function limits withdrawal to maxWithdraw to prevent reverts
     *                   and gracefully handles partial withdrawals during vault illiquidity.
     */
    function _freeFunds(uint256 _amount) internal override {
        // Only proceed if there are assets to withdraw
        if (_amount > 0) {
            // Query maximum withdrawable amount from the vault
            // This accounts for vault liquidity constraints and withdrawal limits
            uint256 maxWithdraw = YIELD_SOURCE.maxWithdraw(address(this));
            
            // Calculate actual withdrawal amount, capped at available liquidity
            // If requested amount exceeds availability, withdraw what's possible
            // The shortfall will be accounted as a loss in the parent function
            uint256 amountToWithdraw = _amount > maxWithdraw ? maxWithdraw : _amount;
            
            // Execute withdrawal if there's a positive amount available
            if (amountToWithdraw > 0) {
                // Withdraw assets from ERC4626 vault
                // Parameters: (assets, receiver, owner)
                // - assets: amount of underlying asset to receive
                // - receiver: address to receive the assets (this contract)
                // - owner: address whose shares are burned (this contract)
                YIELD_SOURCE.withdraw(amountToWithdraw, address(this), address(this));
            }
        }
    }

    /**
     * @notice Performs accounting and reports the total value of assets managed by the strategy
     * @dev This function is called during report() to get an accurate snapshot of strategy holdings.
     *      It calculates the total value by summing idle assets and deployed assets.
     *
     *      Accounting Process:
     *      1. Count idle assets held directly in the strategy contract
     *      2. Count deployed assets by converting vault shares to underlying asset value
     *      3. Return the sum as the total managed assets
     *
     *      This function should provide the most accurate view of current assets for
     *      profit/loss accounting. All applicable assets including loose assets must be
     *      accounted for.
     *
     *      Post-Shutdown Behavior:
     *      This can be called after shutdown. Strategists can check TokenizedStrategy.isShutdown()
     *      to determine whether to redeploy idle funds or simply realize profits/losses.
     *
     * @return _totalAssets The total amount of underlying asset controlled by this strategy,
     *                      including both idle and deployed funds
     *
     * @custom:security Uses vault's convertToAssets() for accurate share valuation.
     *                   Avoid relying on oracles or swap values as all P&L accounting 
     *                   is based on this returned value.
     */
    function _harvestAndReport() internal override returns (uint256 _totalAssets) {
        // Calculate idle assets held directly in the strategy contract
        // These are assets waiting to be deployed or recently withdrawn
        uint256 idleAssets = ERC20(asset).balanceOf(address(this));
        
        // Get the strategy's share balance in the ERC4626 vault
        uint256 sharesBalance = YIELD_SOURCE.balanceOf(address(this));
        uint256 deployedAssets = 0;
        
        // Convert shares to underlying asset value if we have any shares
        // This represents the current value of deployed funds including accrued yield
        if (sharesBalance > 0) {
            deployedAssets = YIELD_SOURCE.convertToAssets(sharesBalance);
        }
        
        // Return total assets under management (idle + deployed)
        // This value determines profit/loss calculation in the parent contract
        _totalAssets = idleAssets + deployedAssets;
    }

    /*//////////////////////////////////////////////////////////////
                    LIMIT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn by an owner
     * @dev Default implementation returns max uint256 (no limit).
     *      Override this function to implement custom withdrawal limits such as:
     *      - Time-based withdrawal restrictions
     *      - Percentage-based limits
     *      - Liquidity-based constraints
     *      - User-tier based limits
     *
     * @return The maximum amount of assets that can be withdrawn (max uint256 = unlimited)
     */
    function availableWithdrawLimit(address /*_owner*/) public view virtual override returns (uint256) {
        return type(uint256).max;
    }

    /**
     * @notice Returns the maximum amount of assets that can be deposited by an address
     * @dev Default implementation returns max uint256 (no limit).
     *      Override this function to implement custom deposit limits such as:
     *      - Total value locked (TVL) caps
     *      - Per-user deposit limits
     *      - Whitelist-based restrictions
     *      - Vault capacity constraints
     *
     * @return The maximum amount of assets that can be deposited (max uint256 = unlimited)
     */
    function availableDepositLimit(address /*_owner*/) public view virtual override returns (uint256) {
        return type(uint256).max;
    }

    /*//////////////////////////////////////////////////////////////
                    MAINTENANCE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Performs maintenance operations between full reports
     * @dev Optional function that can be called by keepers to perform routine maintenance
     *      without triggering a full report. This is useful for operations that don't
     *      directly affect the price per share (PPS) calculation.
     *
     *      This function is only callable by permissioned roles (keepers) and may be
     *      accessed through protected relays for security.
     *
     *      Common Use Cases:
     *      - Harvesting and compounding reward tokens
     *      - Depositing accumulated idle funds
     *      - Position maintenance and rebalancing
     *      - Claiming incentives without triggering full report
     *
     *      Example Scenario:
     *      A strategy that's vulnerable to sandwich attacks during deposits can use tend()
     *      when idle assets exceed a certain threshold, allowing controlled deployments
     *      through keeper-only transactions.
     *
     *      Note: Changes made in _tend() won't affect PPS until report() is called.
     *      If _tend() is implemented, _tendTrigger() must also be overridden.
     *
     * @param _totalIdle The current amount of idle assets available for deployment
     */
    function _tend(uint256 _totalIdle) internal virtual override {
        // Default implementation: no maintenance needed
        // Override this function to implement custom maintenance logic
    }

    /**
     * @notice Determines whether tend() should be called
     * @dev This trigger function must be overridden if _tend() is implemented.
     *      Keepers will call this view function to determine if tend() is needed.
     *
     *      Implementation Examples:
     *      - Return true when idle assets exceed certain threshold
     *      - Return true when rewards accumulation reaches minimum claim amount
     *      - Return true when position needs rebalancing
     *      - Return true based on time elapsed since last tend
     *
     * @return shouldTend Returns true if _tend() should be called by keeper, false otherwise
     */
    function _tendTrigger() internal view virtual override returns (bool shouldTend) {
        // Default: tend is not used by this strategy
        return false;
    }

    /*//////////////////////////////////////////////////////////////
                    EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Allows emergency withdrawal of assets when the strategy is shut down
     * @dev This function enables management to manually withdraw deployed funds from the
     *      yield source in emergency situations. It's only callable when the strategy
     *      has been shut down via TokenizedStrategy.shutdown().
     *
     *      Important Characteristics:
     *      - Does NOT realize profits or losses automatically
     *      - May attempt to free more than currently deployed (won't revert)
     *      - Requires separate report() call to record actual P&L
     *
     *      Post-Withdrawal Considerations:
     *      After emergency withdrawal, if a report is needed, ensure _harvestAndReport()
     *      checks shutdown status to prevent automatic redeployment of freed funds.
     *
     *      Example Pattern:
     *      ```
     *      function _harvestAndReport() internal override returns (uint256) {
     *          uint256 totalAssets = calculateTotalAssets();
     *          
     *          if (idleAssets > 0 && !TokenizedStrategy.isShutdown()) {
     *              // Only redeploy if not shutdown
     *              _deployFunds(idleAssets);
     *          }
     *          
     *          return totalAssets;
     *      }
     *      ```
     *
     * @param _amount The amount of underlying asset to attempt to withdraw from yield source
     *                (may exceed currently deployed amount without reverting)
     */
    function _emergencyWithdraw(uint256 _amount) internal virtual override {
        // Delegate to the standard withdrawal mechanism
        // _freeFunds handles liquidity constraints gracefully
        _freeFunds(_amount);
    }
}
