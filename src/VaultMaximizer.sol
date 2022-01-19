// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.10;
/**
 ▄▄▄       ██▓███  ▓█████  ██▀███   ▒█████   ▄████▄   ██ ▄█▀▓█████▄▄▄█████▓
▒████▄    ▓██░  ██▒▓█   ▀ ▓██ ▒ ██▒▒██▒  ██▒▒██▀ ▀█   ██▄█▒ ▓█   ▀▓  ██▒ ▓▒
▒██  ▀█▄  ▓██░ ██▓▒▒███   ▓██ ░▄█ ▒▒██░  ██▒▒▓█    ▄ ▓███▄░ ▒███  ▒ ▓██░ ▒░
░██▄▄▄▄██ ▒██▄█▓▒ ▒▒▓█  ▄ ▒██▀▀█▄  ▒██   ██░▒▓▓▄ ▄██▒▓██ █▄ ▒▓█  ▄░ ▓██▓ ░ 
 ▓█   ▓██▒▒██▒ ░  ░░▒████▒░██▓ ▒██▒░ ████▓▒░▒ ▓███▀ ░▒██▒ █▄░▒████▒ ▒██▒ ░ 
 ▒▒   ▓▒█░▒▓▒░ ░  ░░░ ▒░ ░░ ▒▓ ░▒▓░░ ▒░▒░▒░ ░ ░▒ ▒  ░▒ ▒▒ ▓▒░░ ▒░ ░ ▒ ░░   
  ▒   ▒▒ ░░▒ ░      ░ ░  ░  ░▒ ░ ▒░  ░ ▒ ▒░   ░  ▒   ░ ░▒ ▒░ ░ ░  ░   ░    
  ░   ▒   ░░          ░     ░░   ░ ░ ░ ░ ▒  ░        ░ ░░ ░    ░    ░      
      ░  ░            ░  ░   ░         ░ ░  ░ ░      ░  ░      ░  ░        
                                            ░                              
 */
import {Auth} from "solmate/auth/Auth.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeCastLib} from "solmate/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {Strategy, ERC20Strategy, ETHStrategy} from "./interfaces/Strategy.sol";

contract VaultMaximizer {
    // TODO
}
