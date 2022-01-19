// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.10;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {Auth, Authority} from "solmate/auth/Auth.sol";

import {VaultFactory} from "../VaultFactory.sol";
import {ERC20Strategy, Vault} from "../Vault.sol";

/// @notice Module to manage newly created Vaults.
contract VaultManagementModule is Auth {
    constructor(address _owner, Authority _authority) Auth(_owner, _authority) {}

    /// @notice Kill a strategy and send back funds to vault
    function kill(Vault vault, ERC20Strategy strategy) external requiresAuth {
        vault.seizeStrategy(strategy);
        strategy.fire();
    }
}
