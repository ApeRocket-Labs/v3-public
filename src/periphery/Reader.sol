// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.10;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {Auth, Authority} from "solmate/auth/Auth.sol";
import {Bytes32AddressLib} from "solmate/utils/Bytes32AddressLib.sol";

interface IVault {
    function UNDERLYING() external view returns (address);

    function balanceOfUnderlying(address user) external view returns (uint256);

    function balanceOf(address user) external view returns (uint256);
}

contract Reader {
    struct UserInfo {
        uint256 allowance;
        uint256 balanceOfUnderlying;
        uint256 balanceOf;
    }

    function infoOfVault(address _user, address _vault) external view returns (UserInfo memory info) {
        IVault vault = IVault(_vault);
        ERC20 underlying = ERC20(vault.UNDERLYING());
        info.allowance = underlying.allowance(_user, address(vault));
        info.balanceOfUnderlying = vault.balanceOfUnderlying(_user);
        info.balanceOf = vault.balanceOf(_user);
    }
}
