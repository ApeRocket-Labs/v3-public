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
import {Router} from "../../interfaces/Router.sol";
import {Auth, Authority} from "solmate/auth/Auth.sol";
import {SmartChef} from "../../interfaces/SmartChef.sol";
import {ERC20Strategy} from "../../interfaces/Strategy.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

/// @notice Pools Strategy deployed by factory
contract StrategyPoolStaking is ERC20Strategy, Auth {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /// @notice The base unit.
    /// @dev Equal to 10 ** 18. Used for fixed point arithmetic.
    uint256 public constant DENOMINATOR = 1e18;

    /// @notice Default slippage of the underlying token.
    uint256 public constant SLIP_DEFAULT = 995e15; // 0.5% default

    /// @notice WETH.
    address public constant WBNB = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

    /// @notice The address of the vault using this strategy.
    address public immutable VAULT;

    /// @notice The reward token the strategy accepts.
    ERC20 public immutable REWARD;

    /// @notice The underlying token the strategy accepts.
    ERC20 public immutable UNDERLYING;

    /// @notice The base unit of the underlying token.
    /// @dev Equal to 10 ** decimals. Used for fixed point arithmetic.
    uint256 public immutable BASE_UNIT;

    /// @notice The staking contract where the underlying token is deposited.
    address public immutable SMARTCHEF;

    /// @notice Creates a new Strategy of Syrup pools that accepts a specific underlying token.
    /// @param _underlying The ERC20 compliant token the Strategy should accept.
    /// @param _reward The ERC20 compliant token the Strategy should collect.
    /// @param _vault The address the Vault using the strategy.
    /// @param _smartChef The address the Strategy should deposit.
    /// @param _pathToWETH If required, the path to WETH of the reward token.
    /// @param _pathToUnderlying The ERC20 compliant token the Vault should accept.
    constructor(
        ERC20 _underlying,
        ERC20 _reward,
        address _vault,
        address _smartChef,
        address[] memory _router,
        address[] memory _pathToWETH,
        address[] memory _pathToUnderlying
    )
        ERC20(
            // Reward token info
            string(abi.encodePacked("Strategy ", _reward.name(), " Pool")),
            string(abi.encodePacked("sp", _reward.symbol())),
            // Underlying decimals for arithmetic.
            _underlying.decimals()
        )
        Auth(Auth(msg.sender).owner(), Auth(msg.sender).authority())
    {
        require(_router.length > 0, "NO_ROUTER_SET");
        require(_pathToUnderlying.length > 1, "NO_PATH_SET");

        VAULT = _vault;
        REWARD = _reward;
        UNDERLYING = _underlying;
        BASE_UNIT = 10**decimals;

        getRouter[_underlying] = _router[0];
        getRouter[_reward] = _router[1];

        SMARTCHEF = _smartChef;
        pathToWETH = _pathToWETH;
        pathToUnderlying = _pathToUnderlying;
    }

    function underlying() external view override returns (ERC20) {
        return UNDERLYING;
    }

    function isEther() external pure override returns (bool) {
        return false;
    }

    /*///////////////////////////////////////////////////////////////
                             SLIPPAGE STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Slippage tolerance of Reward token.
    uint256 public rewardSlippageTolerance = 995e15; // 0.5% default

    function updateSlippageTolerence(uint256 _newSlippageTolerance) public requiresAuth {
        rewardSlippageTolerance = _newSlippageTolerance;
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
    function mint(uint256 underlyingAmount) external override returns (uint256) {
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

    /// @notice Withdraw a specific amount of underlying tokens.
    /// @param underlyingAmount The amount of underlying tokens to withdraw.
    function redeemUnderlying(uint256 underlyingAmount) external override returns (uint256) {
        require(msg.sender == VAULT, "ONLY_VAULT_ALLOWED");
        // We don't allow withdrawing 0 to prevent emitting a useless event.
        require(underlyingAmount != 0, "AMOUNT_CANNOT_BE_ZERO");

        uint256 currentBalance = UNDERLYING.balanceOf(address(this));

        // Withdraw underlying amount from the staking contract.
        if (currentBalance < underlyingAmount) {
            SmartChef(SMARTCHEF).withdraw(underlyingAmount - currentBalance);
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
        (uint256 totalUnderlyingStaked, ) = SmartChef(SMARTCHEF).userInfo(address(this));

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

    /// @notice Path to WETH in case Reward token have better liquidity on another DEX.
    address[] public pathToWETH;

    /// @notice Path to Underlying
    /// @dev From WETH if pathToWETH.length > 0, else, from Reward token.
    address[] public pathToUnderlying;

    /// @notice Associated Router for an ERC20.
    mapping(ERC20 => address) getRouter;

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
        // Retrieve the total underlying token the strategy manages before the accrual.
        uint256 beforeAccrual = totalHoldings();
        // Retrieve the total rewards made with staking.
        uint256 pendingReward = SmartChef(SMARTCHEF).pendingReward(address(this));

        // If rewards, collect it and swap it to underlying.
        if (pendingReward > 0) {
            SmartChef(SMARTCHEF).deposit(0);

            // If the function is called by anyone except the vault, rewards them with callAccrueFee.
            if (msg.sender != VAULT) {
                uint256 rewards = REWARD.balanceOf(address(this));
                uint256 callerRewards = rewards.fmul(callAccrueFee, DENOMINATOR);
                REWARD.transfer(msg.sender, callerRewards);
            }
            swapToUnderlying();
        }

        // Retrieve the balance of underlying after the accrual.
        // Compare it to the state before to compute the profits made.
        // Deposit to staking contract.
        uint256 balance = UNDERLYING.balanceOf(address(this));
        if (balance == 0) return balance;

        SmartChef(SMARTCHEF).deposit(balance);
        uint256 afterAccrual = totalHoldings();

        // rewardRatePerSecond is used to compare strategies performances in order to rebalance the amount it manages.
        rewardRatePerSecond = (afterAccrual - beforeAccrual) / (block.timestamp - lastRewardAccrual);

        // Store timestamp for next accrual.
        lastRewardAccrual = block.timestamp;

        emit RewardAccrued(msg.sender, afterAccrual - beforeAccrual);

        // Should be 0 if everything went well.
        balance = UNDERLYING.balanceOf(address(this));
        return balance;
    }

    function swapToUnderlying() internal {
        if (getRouter[REWARD] != address(0)) {
            swapToWETH();
            swapToUnderlyingFromWETH();
        } else {
            address router = getRouter[UNDERLYING];
            uint256 balance = REWARD.balanceOf(address(this));

            uint256[] memory outs = Router(router).getAmountsOut(balance, pathToUnderlying);
            uint256 out = outs[outs.length - 1];

            Router(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                balance,
                out.fmul(rewardSlippageTolerance, DENOMINATOR),
                pathToUnderlying,
                address(this),
                block.timestamp + 20
            );
        }
        require(UNDERLYING.balanceOf(address(this)) > 0, "SWAP_FAILED");
    }

    function swapToWETH() internal {
        address router = getRouter[REWARD];
        uint256 balance = REWARD.balanceOf(address(this));

        uint256[] memory outs = Router(router).getAmountsOut(balance, pathToWETH);
        uint256 out = outs[outs.length - 1];

        Router(router).swapExactTokensForETHSupportingFeeOnTransferTokens(
            balance,
            out.fmul(rewardSlippageTolerance, DENOMINATOR),
            pathToWETH,
            address(this),
            block.timestamp + 20
        );
    }

    function swapToUnderlyingFromWETH() internal {
        address router = getRouter[UNDERLYING];
        uint256 balance = address(this).balance;

        uint256[] memory outs = Router(router).getAmountsOut(balance, pathToUnderlying);
        uint256 out = outs[outs.length - 1];

        Router(router).swapExactETHForTokens{value: balance}(
            out.fmul(SLIP_DEFAULT, DENOMINATOR),
            pathToUnderlying,
            address(this),
            block.timestamp + 20
        );
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
        SmartChef(SMARTCHEF).emergencyWithdraw();
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

    /// @notice Strategy init.
    ///         Approves every contract the Strategy interacts with.
    ///         Initialize the lastRewardAccrual to current timestamp to allows accrual.
    function initialize() public requiresAuth {
        // Ensure the Strategy has not already been initialized.
        require(!isInitialized, "ALREADY_INITIALIZED");

        // Mark the Strategy as initialized.
        isInitialized = true;

        _approveTokenIfNeeded(UNDERLYING, SMARTCHEF);
        _approveTokenIfNeeded(REWARD, getRouter[REWARD]);
        _approveTokenIfNeeded(REWARD, getRouter[UNDERLYING]);

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
