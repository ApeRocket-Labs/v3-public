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
import {ERC20} from "solmate/tokens/ERC20.sol";
import {Auth, Authority} from "solmate/auth/Auth.sol";
import {Masterchef} from "../../interfaces/Masterchef.sol";
import {ERC20Strategy} from "../../interfaces/Strategy.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

/// @notice Main Staking Strategy deployed by factory
contract StrategyMainStaking is ERC20Strategy, Auth {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /// @notice The base unit.
    /// @dev Equal to 10 ** 18. Used for fixed point arithmetic.
    uint256 public constant DENOMINATOR = 1e18;

    /// @notice The address of the vault using this strategy.
    address public immutable VAULT;

    /// @notice The underlying token the strategy accepts.
    ERC20 public immutable UNDERLYING;

    /// @notice The base unit of the underlying token.
    /// @dev Equal to 10 ** decimals. Used for fixed point arithmetic.
    uint256 public immutable BASE_UNIT;

    /// @notice The staking contract where the underlying token is deposited.
    address public immutable MASTERCHEF;

    /// @notice Creates a new Strategy of the Main Staking Pool (pid=0) that accepts a specific underlying token.
    /// @param _underlying The ERC20 compliant token the Strategy should accept.
    /// @param _masterchef The address the Strategy should deposit.
    /// @param _vault The address the Vault using the strategy.
    constructor(
        ERC20 _underlying,
        address _vault,
        address _masterchef
    )
        ERC20(
            string(abi.encodePacked("Strategy ", _underlying.name(), " Pool")),
            string(abi.encodePacked("sp", _underlying.symbol())),
            // Underlying decimals for arithmetic.
            _underlying.decimals()
        )
        Auth(msg.sender, Authority(address(0)))
    {
        VAULT = _vault;
        MASTERCHEF = _masterchef;
        UNDERLYING = _underlying;
        BASE_UNIT = 10**decimals;
    }

    function underlying() external view override returns (ERC20) {
        return UNDERLYING;
    }

    function isEther() external pure override returns (bool) {
        return false;
    }

    /*///////////////////////////////////////////////////////////////
                    STRATEGY DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted after a successful deposit.
    /// @param underlyingAmount The amount of underlying tokens that were deposited.
    /// @param timestamp Timestamp when deposit occured.
    event Deposit(uint256 underlyingAmount, uint256 timestamp);

    /// @notice Emitted after a successful withdrawal.
    /// @param underlyingAmount The amount of underlying tokens that were withdrawn.
    /// @param timestamp Timestamp when deposit occured.
    event Withdraw(uint256 underlyingAmount, uint256 timestamp);

    /// @notice Deposit a specific amount of underlying tokens.
    /// @param underlyingAmount The amount of the underlying token to deposit.
    function mint(uint256 underlyingAmount) external override requiresAuth returns (uint256) {
        require(msg.sender == VAULT, "ONLY_VAULT_ALLOWED");
        // We don't allow depositing 0 to prevent emitting a useless event.
        require(underlyingAmount != 0, "AMOUNT_CANNOT_BE_ZERO");

        // Determine the equivalent amount of sTokens and mint them.
        _mint(msg.sender, underlyingAmount.fdiv(exchangeRate(), BASE_UNIT));

        emit Deposit(underlyingAmount, block.timestamp);

        // Transfer in underlying tokens from the vault.
        // This will revert if the vault does not have the amount specified.
        UNDERLYING.transferFrom(msg.sender, address(this), underlyingAmount);

        // Call reward accrual.
        return accrueReward();
    }

    function redeemUnderlying(uint256 underlyingAmount) external override requiresAuth returns (uint256) {
        require(msg.sender == VAULT, "ONLY_VAULT_ALLOWED");
        // We don't allow withdrawing 0 to prevent emitting a useless event.
        require(underlyingAmount != 0, "AMOUNT_CANNOT_BE_ZERO");

        uint256 currentBalance = UNDERLYING.balanceOf(address(this));

        // Withdraw underlying amount from the staking contract.
        if (currentBalance < underlyingAmount) {
            Masterchef(MASTERCHEF).leaveStaking(underlyingAmount - currentBalance);
            currentBalance = UNDERLYING.balanceOf(address(this));
        }

        if (underlyingAmount > currentBalance) {
            underlyingAmount = currentBalance;
        }

        // Determine the equivalent amount of sTokens and burn them.
        // This will revert if the vault does not have enough sToken.
        _burn(msg.sender, underlyingAmount.fdiv(exchangeRate(), BASE_UNIT));

        emit Withdraw(underlyingAmount, block.timestamp);

        // Transfer the provided amount of underlying tokens.
        UNDERLYING.transfer(msg.sender, underlyingAmount);

        // Call reward accrual.
        return accrueReward();
    }

    /*///////////////////////////////////////////////////////////////
                         STRATEGY ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns a user's Strategy balance in underlying tokens.
    /// @param user The user to get the underlying balance of.
    /// @return The vault balance in underlying tokens.
    function balanceOfUnderlying(address user) external view override returns (uint256) {
        return balanceOf[user].fmul(exchangeRate(), BASE_UNIT);
    }

    /// @notice Returns the amount of underlying tokens an sToken can be redeemed for.
    /// @return The amount of underlying tokens an sToken can be redeemed for.
    function exchangeRate() public view returns (uint256) {
        // Get the total supply of sToken.
        uint256 strategyTotalSupply = totalSupply;

        // If there are no sToken in circulation, return an exchange rate of 1:1.
        if (strategyTotalSupply == 0) return BASE_UNIT;

        // Calculate the exchange rate by dividing the total holdings by the sToken supply.
        return totalHoldings().fdiv(strategyTotalSupply, BASE_UNIT);
    }

    /// @notice Calculates the total amount of underlying tokens the strategy manages.
    /// @return totalUnderlyingHeld The total amount of underlying tokens the strategy manages.
    function totalHoldings() public view returns (uint256 totalUnderlyingHeld) {
        uint256 currentBalance = UNDERLYING.balanceOf(address(this));
        (uint256 totalUnderlyingStaked, ) = Masterchef(MASTERCHEF).userInfo(0, address(this));

        totalUnderlyingHeld = currentBalance + totalUnderlyingStaked;
    }

    /*///////////////////////////////////////////////////////////////
                       REWARD ACCRUAL CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted after a successful harvest.
    /// @param user The authorized user who triggered the harvest.
    /// @param profits The amount of profits accrued.
    event RewardAccrued(address indexed user, uint256 profits);

    /// @notice The last harvest timestamp.
    uint256 public lastRewardAccrual;

    /// @notice Used to compare strategy performances.
    uint256 public rewardRatePerSecond;

    /// @notice Fee to reward harvest caller.
    uint256 public callAccrueFee = 5e15; // 0.5%

    function updateCallAccrueFee(uint256 _newCallFeeAccrue) external requiresAuth {
        // No more than 1%.
        require(_newCallFeeAccrue <= 1e16, "TOO_HIGH");
        callAccrueFee = _newCallFeeAccrue;
    }

    /// @notice Accrues reward from staking contract.
    function accrueReward() public requiresAuth returns (uint256) {
        uint256 balance = UNDERLYING.balanceOf(address(this));
        uint256 pendingCake = Masterchef(MASTERCHEF).pendingCake(0, address(this));
        if (balance + pendingCake == 0) return 0;

        // If the function is called by anyone except the vault, rewards them with callAccrueFee.
        if (msg.sender != VAULT) {
            uint256 callerRewards = pendingCake.fmul(callAccrueFee, DENOMINATOR);
            Masterchef(MASTERCHEF).enterStaking(0);
            UNDERLYING.transfer(msg.sender, callerRewards);
            balance = UNDERLYING.balanceOf(address(this));
        }

        // Deposit balance
        Masterchef(MASTERCHEF).enterStaking(balance);

        rewardRatePerSecond = pendingCake / (block.timestamp - lastRewardAccrual);
        lastRewardAccrual = block.timestamp;

        emit RewardAccrued(msg.sender, pendingCake);

        // Should be 0 if everything went well.
        balance = UNDERLYING.balanceOf(address(this));
        return balance;
    }

    function _approveTokenIfNeeded(ERC20 token, address router) internal {
        if (router == address(0)) return;
        if (token.allowance(address(this), address(router)) == 0) {
            token.safeApprove(address(router), type(uint256).max);
        }
    }

    /*///////////////////////////////////////////////////////////////
                             EMERGENCY LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a token is sweeped from the Strategy.
    /// @param user The user who sweeped the token from the Strategy.
    /// @param to The recipient of the sweeped tokens.
    /// @param amount The amount of the token that was sweeped.
    event TokenSweeped(address indexed user, address indexed to, ERC20 indexed token, uint256 amount);

    /// @notice Emitted when the Strategy is fired.
    /// @param user The user who sweeped the token from the Strategy.
    /// @param when dev ? when ser.
    event StrategyFired(address indexed user, uint256 when);

    /// @notice Claim tokens sitting idly in the Safe.
    /// @param to The recipient of the sweeped tokens.
    /// @param token The token to sweep and send.
    /// @param amount The amount of the token to sweep.
    function sweep(
        address to,
        ERC20 token,
        uint256 amount
    ) external override requiresAuth {
        // Ensure the caller is not trying to steal strategy shares.
        // Permit the sweep of reward token in case of malfunction.
        require(address(token) != address(UNDERLYING), "INVALID_TOKEN");

        emit TokenSweeped(msg.sender, to, token, amount);

        // Transfer the sweeped tokens to the recipient.
        token.safeTransfer(to, amount);
    }

    /// @notice Fire the strategy and send underlying back to vault.
    /// @dev must come after seizeStrategy.
    function fire() external override requiresAuth {
        Masterchef(MASTERCHEF).emergencyWithdraw(0);
        _burn(msg.sender, balanceOf[msg.sender]);
        // send back token to vault
        uint256 balance = UNDERLYING.balanceOf(address(this));
        UNDERLYING.transfer(VAULT, balance);

        emit StrategyFired(msg.sender, block.timestamp);
    }

    /*///////////////////////////////////////////////////////////////
                    INITIALIZATION AND DESTRUCTION LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the Vault is initialized.
    /// @param user The authorized user who triggered the initialization.
    event Initialized(address indexed user);

    /// @notice Whether the Vault has been initialized yet.
    /// @dev Can go from false to true, never from true to false.
    bool public isInitialized;

    function initialize() public requiresAuth {
        // Ensure the Strategy has not already been initialized.
        require(!isInitialized, "ALREADY_INITIALIZED");

        // Mark the Strategy as initialized.
        isInitialized = true;
        _approveTokenIfNeeded(UNDERLYING, MASTERCHEF);
        lastRewardAccrual = block.timestamp;
    }

    /// @notice Self destructs a Strategy, enabling it to be redeployed.
    /// @dev Caller will receive any BNB held as float in the Strategy.
    function destroy() external requiresAuth {
        selfdestruct(payable(msg.sender));
    }

    /// @dev Required for the Strategy to receive unwrapped ETH.
    receive() external payable {}
}
