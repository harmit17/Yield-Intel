// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {YieldDonatingStrategy} from "./YieldDonatingStrategy.sol";
import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";
import {YieldDonatingTokenizedStrategy} from "@octant-core/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

contract YieldDonatingStrategyFactory {
    event NewStrategy(address indexed strategy, address indexed asset);

    address public immutable EMERGENCY_ADMIN;
    address public immutable TOKENIZED_STRATEGY_ADDRESS;

    address public management;
    address public donationAddress;
    address public keeper;
    bool public enableBurning = true;

    /// @notice Track the deployments. asset => strategy
    mapping(address => address) public deployments;

    constructor(address _management, address _donationAddress, address _keeper, address _emergencyAdmin) {
        management = _management;
        donationAddress = _donationAddress;
        keeper = _keeper;
        EMERGENCY_ADMIN = _emergencyAdmin;

        // Deploy the standard TokenizedStrategy implementation
        TOKENIZED_STRATEGY_ADDRESS = address(new YieldDonatingTokenizedStrategy());
    }

    /**
     * @notice Deploy a new YieldDonating Strategy.
     * @param _compounderVault The yield source (e.g., AAVE pool, Compound, Yearn vault)
     * @param _asset The underlying asset for the strategy to use.
     * @param _name The name for the strategy.
     * @return The address of the new strategy.
     */
    function newStrategy(
        address _compounderVault,
        address _asset,
        string calldata _name
    ) external virtual returns (address) {
        // Deploy new YieldDonating strategy
        IStrategyInterface _newStrategy = IStrategyInterface(
            address(
                new YieldDonatingStrategy(
                    _compounderVault,
                    _asset,
                    _name,
                    management,
                    keeper,
                    EMERGENCY_ADMIN,
                    donationAddress,
                    enableBurning,
                    TOKENIZED_STRATEGY_ADDRESS
                )
            )
        );

        emit NewStrategy(address(_newStrategy), _asset);

        deployments[_asset] = address(_newStrategy);
        return address(_newStrategy);
    }

    function setAddresses(address _management, address _donationAddress, address _keeper) external {
        require(msg.sender == management, "!management");
        management = _management;
        donationAddress = _donationAddress;
        keeper = _keeper;
    }

    function setEnableBurning(bool _enableBurning) external {
        require(msg.sender == management, "!management");
        enableBurning = _enableBurning;
    }

    function isDeployedStrategy(address _strategy) external view returns (bool) {
        address _asset = IStrategyInterface(_strategy).asset();
        return deployments[_asset] == _strategy;
    }
}
