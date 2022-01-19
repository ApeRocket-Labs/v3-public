// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.10;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {Auth, Authority} from "solmate/auth/Auth.sol";
import {Bytes32AddressLib} from "solmate/utils/Bytes32AddressLib.sol";

import {StrategyPoolStaking} from "./StrategyPoolStaking.sol";

/// @notice Factory which enables deploying a Strategy Pool contract for any Pancake Pool.
contract StrategyPoolFactory is Auth {
    using Bytes32AddressLib for address;
    using Bytes32AddressLib for bytes32;

    /*///////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a Strategy Pool factory.
    /// @param _owner The owner of the factory.
    /// @param _authority The Authority of the factory.
    constructor(address _owner, Authority _authority) Auth(_owner, _authority) {}

    /*///////////////////////////////////////////////////////////////
                          STRATEGY DEPLOYMENT LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new Strategy is deployed.
    /// @param strategy The newly deployed Vault contract.
    /// @param underlying The underlying token the new Vault accepts.
    event StrategyPoolDeployed(StrategyPoolStaking strategy, ERC20 underlying, ERC20 reward, address indexed smartChef);

    /// @notice Deploys a new Strategy which supports a specific underlying token.
    /// @param _underlying The ERC20 token that the Strategy should accept.
    function deployStrategyPool(
        ERC20 _underlying,
        ERC20 _reward,
        address _vault,
        address smartChef,
        address[] memory router,
        address[] memory _pathToWETH,
        address[] memory _pathToUnderlying
    ) external requiresAuth returns (StrategyPoolStaking strategy) {
        strategy = new StrategyPoolStaking{salt: smartChef.fillLast12Bytes()}(
            _underlying,
            _reward,
            _vault,
            smartChef,
            router,
            _pathToWETH,
            _pathToUnderlying
        );

        require(
            strategy == getStrategy(_underlying, _reward, _vault, smartChef, router, _pathToWETH, _pathToUnderlying),
            "DEPLOYMENT_GONE_WRONG"
        );

        emit StrategyPoolDeployed(strategy, _underlying, _reward, smartChef);
    }

    /*///////////////////////////////////////////////////////////////
                            STRATEGY LOOKUP LOGIC
    //////////////////////////////////////////////////////////////*/

    function getStrategy(
        ERC20 _underlying,
        ERC20 _reward,
        address _vault,
        address smartChef,
        address[] memory router,
        address[] memory _pathToWETH,
        address[] memory _pathToUnderlying
    ) public view returns (StrategyPoolStaking) {
        return
            StrategyPoolStaking(
                payable(
                    keccak256(
                        abi.encodePacked(
                            // Prefix:
                            bytes1(0xFF),
                            // Creator:
                            address(this),
                            // Salt:
                            smartChef.fillLast12Bytes(),
                            // Bytecode hash:
                            keccak256(
                                abi.encodePacked(
                                    // Deployment bytecode:
                                    type(StrategyPoolStaking).creationCode,
                                    // Constructor arguments:
                                    abi.encode(
                                        _underlying,
                                        _reward,
                                        _vault,
                                        smartChef,
                                        router,
                                        _pathToWETH,
                                        _pathToUnderlying
                                    )
                                )
                            )
                        )
                    ).fromLast20Bytes() // Convert the CREATE2 hash into an address.
                )
            );
    }

    function isStrategyPoolDeployed(StrategyPoolStaking strategy) external view returns (bool) {
        return address(strategy).code.length > 0;
    }
}
