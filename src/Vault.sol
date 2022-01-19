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

/// @notice Multi-strategy vaults
contract Vault is ERC20, Auth {
    using SafeCastLib for uint256;
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /// @notice The underlying token the Vault accepts.
    ERC20 public immutable UNDERLYING;

    /// @notice The base unit of the underlying token and hence arToken.
    /// @dev Equal to 10 ** decimals. Used for fixed point arithmetic.
    uint256 public immutable BASE_UNIT;

    /// @notice Creates a new Vault that accepts a specific underlying token.
    /// @param _UNDERLYING The ERC20 compliant token the Vault should accept.
    constructor(ERC20 _UNDERLYING)
        ERC20(
            string(abi.encodePacked("Aperocket ", _UNDERLYING.name(), " Vault")),
            string(abi.encodePacked("ar", _UNDERLYING.symbol())),
            _UNDERLYING.decimals()
        )
        Auth(Auth(msg.sender).owner(), Auth(msg.sender).authority())
    {
        UNDERLYING = _UNDERLYING;
        BASE_UNIT = 10**decimals;
        // Prevent minting of arTokens until
        // the initialize function is called.
        totalSupply = type(uint256).max;
    }

    /// @notice The percentage of withdrawal recognized each withdraw/redeem to reserve as fees.
    /// @dev A fixed point number where 1e18 represents 100% and 0 represents 0%.
    uint256 public withdrawalFeePercent;

    /// @notice The percentage of profit recognized each harvest to reserve as fees.
    /// @dev A fixed point number where 1e18 represents 100% and 0 represents 0%.
    uint256 public feePercent;

    /// @notice Emitted when the fee percentage is updated.
    /// @param user The authorized user who triggered the update.
    /// @param newFeePercent The new fee percentage.
    event FeePercentUpdated(address indexed user, uint256 newFeePercent);

    /// @notice Emitted when the withdrawal fee percentage is updated.
    /// @param user The authorized user who triggered the update.
    /// @param newWithdrawalFeePercent The new fee percentage.
    event WithdrawalFeeUpdated(address indexed user, uint256 newWithdrawalFeePercent);

    /// @notice Sets a new fee percentage.
    /// @param newFeePercent The new fee percentage.
    function setFeePercent(uint256 newFeePercent) external requiresAuth {
        // A fee percentage over 100% doesn't make sense.
        require(newFeePercent <= 1e18, "FEE_TOO_HIGH");

        // Update the fee percentage.
        feePercent = newFeePercent;

        emit FeePercentUpdated(msg.sender, newFeePercent);
    }

    /// @notice Sets a new withdrawal fee percentage.
    /// @param newWithdrawalFeePercent The new fee percentage.
    /// @dev 1% Max.
    function setWithdrawalFeePercent(uint256 newWithdrawalFeePercent) external requiresAuth {
        require(newWithdrawalFeePercent <= 1e16, "FEE_TOO_HIGH");

        // Update the fee percentage.
        withdrawalFeePercent = newWithdrawalFeePercent;

        emit FeePercentUpdated(msg.sender, newWithdrawalFeePercent);
    }

    /*///////////////////////////////////////////////////////////////
                        HARVEST CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the harvest window is updated.
    /// @param user The authorized user who triggered the update.
    /// @param newHarvestWindow The new harvest window.
    event HarvestWindowUpdated(address indexed user, uint128 newHarvestWindow);

    /// @notice Emitted when the harvest delay is updated.
    /// @param user The authorized user who triggered the update.
    /// @param newHarvestDelay The new harvest delay.
    event HarvestDelayUpdated(address indexed user, uint64 newHarvestDelay);

    /// @notice Emitted when the harvest delay is scheduled to be updated next harvest.
    /// @param user The authorized user who triggered the update.
    /// @param newHarvestDelay The scheduled updated harvest delay.
    event HarvestDelayUpdateScheduled(address indexed user, uint64 newHarvestDelay);

    /// @notice The period in seconds during which multiple harvests can occur
    /// regardless if they are taking place before the harvest delay has elapsed.
    /// @dev Long harvest windows open the Vault up to profit distribution slowdown attacks.
    uint128 public harvestWindow;

    /// @notice The period in seconds over which locked profit is unlocked.
    /// @dev Cannot be 0 as it opens harvests up to sandwich attacks.
    uint64 public harvestDelay;

    /// @notice The value that will replace harvestDelay next harvest.
    /// @dev In the case that the next delay is 0, no update will be applied.
    uint64 public nextHarvestDelay;

    /// @notice Sets a new harvest window.
    /// @param newHarvestWindow The new harvest window.
    /// @dev The Vault's harvestDelay must already be set before calling.
    function setHarvestWindow(uint128 newHarvestWindow) external requiresAuth {
        // A harvest window longer than the harvest delay doesn't make sense.
        require(newHarvestWindow <= harvestDelay, "WINDOW_TOO_LONG");

        // Update the harvest window.
        harvestWindow = newHarvestWindow;

        emit HarvestWindowUpdated(msg.sender, newHarvestWindow);
    }

    /// @notice Sets a new harvest delay.
    /// @param newHarvestDelay The new harvest delay to set.
    /// @dev If the current harvest delay is 0, meaning it has not
    /// been set before, it will be updated immediately, otherwise
    /// it will be scheduled to take effect after the next harvest.
    function setHarvestDelay(uint64 newHarvestDelay) external requiresAuth {
        // A harvest delay of 0 makes harvests vulnerable to sandwich attacks.
        require(newHarvestDelay != 0, "DELAY_CANNOT_BE_ZERO");

        // A harvest delay longer than 1 year doesn't make sense.
        require(newHarvestDelay <= 365 days, "DELAY_TOO_LONG");

        // If the harvest delay is 0, meaning it has not been set before:
        if (harvestDelay == 0) {
            // We'll apply the update immediately.
            harvestDelay = newHarvestDelay;

            emit HarvestDelayUpdated(msg.sender, newHarvestDelay);
        } else {
            // We'll apply the update next harvest.
            nextHarvestDelay = newHarvestDelay;

            emit HarvestDelayUpdateScheduled(msg.sender, newHarvestDelay);
        }
    }

    /*///////////////////////////////////////////////////////////////
                       TARGET FLOAT CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice The desired percentage of the Vault's holdings to keep as float.
    /// @dev A fixed point number where 1e18 represents 100% and 0 represents 0%.
    uint256 public targetFloatPercent;

    /// @notice Emitted when the target float percentage is updated.
    /// @param user The authorized user who triggered the update.
    /// @param newTargetFloatPercent The new target float percentage.
    event TargetFloatPercentUpdated(address indexed user, uint256 newTargetFloatPercent);

    /// @notice Set a new target float percentage.
    /// @param newTargetFloatPercent The new target float percentage.
    function setTargetFloatPercent(uint256 newTargetFloatPercent) external requiresAuth {
        // A target float percentage over 100% doesn't make sense.
        require(newTargetFloatPercent <= 1e18, "TARGET_TOO_HIGH");

        // Update the target float percentage.
        targetFloatPercent = newTargetFloatPercent;

        emit TargetFloatPercentUpdated(msg.sender, newTargetFloatPercent);
    }

    /*///////////////////////////////////////////////////////////////
                   UNDERLYING IS WETH CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Whether the Vault should treat the underlying token as WETH compatible.
    /// @dev If enabled the Vault will allow trusting strategies that accept Ether.
    bool public underlyingIsWETH;

    /// @notice Emitted when whether the Vault should treat the underlying as WETH is updated.
    /// @param user The authorized user who triggered the update.
    /// @param newUnderlyingIsWETH Whether the Vault nows treats the underlying as WETH.
    event UnderlyingIsWETHUpdated(address indexed user, bool newUnderlyingIsWETH);

    /// @notice Sets whether the Vault treats the underlying as WETH.
    /// @param newUnderlyingIsWETH Whether the Vault should treat the underlying as WETH.
    /// @dev The underlying token must have 18 decimals, to match Ether's decimal scheme.
    function setUnderlyingIsWETH(bool newUnderlyingIsWETH) external requiresAuth {
        // Ensure the underlying token's decimals match ETH.
        require(UNDERLYING.decimals() == 18, "WRONG_DECIMALS");

        // Update whether the Vault treats the underlying as WETH.
        underlyingIsWETH = newUnderlyingIsWETH;

        emit UnderlyingIsWETHUpdated(msg.sender, newUnderlyingIsWETH);
    }

    /*///////////////////////////////////////////////////////////////
                          STRATEGY STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The total amount of underlying tokens held in strategies at the time of the last harvest.
    /// @dev Includes maxLockedProfit, must be correctly subtracted to compute available/free holdings.
    uint256 public totalStrategyHoldings;

    /// @dev Packed struct of strategy data.
    /// @param trusted Whether the strategy is trusted.
    /// @param balance The amount of underlying tokens held in the strategy.
    struct StrategyData {
        // Used to determine if the Vault will operate on a strategy.
        bool trusted;
        // Used to determine profit and loss during harvests of the strategy.
        uint248 balance;
    }

    /// @notice Maps strategies to data the Vault holds on them.
    mapping(Strategy => StrategyData) public getStrategyData;

    /*///////////////////////////////////////////////////////////////
                             HARVEST STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice A timestamp representing when the first harvest in the most recent harvest window occurred.
    /// @dev May be equal to lastHarvest if there was/has only been one harvest in the most last/current window.
    uint64 public lastHarvestWindowStart;

    /// @notice A timestamp representing when the most recent harvest occurred.
    uint64 public lastHarvest;

    /// @notice The amount of locked profit at the end of the last harvest.
    uint128 public maxLockedProfit;

    /*///////////////////////////////////////////////////////////////
                        WITHDRAWAL QUEUE STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice An ordered array of strategies representing the withdrawal queue.
    /// @dev The queue is processed in descending order, meaning the last index will be withdrawn from first.
    /// @dev Strategies that are untrusted, duplicated, or have no balance are filtered out when encountered at
    /// withdrawal time, not validated upfront, meaning the queue may not reflect the "true" set used for withdrawals.
    Strategy[] public withdrawalQueue;

    /// @notice Gets the full withdrawal queue.
    /// @return An ordered array of strategies representing the withdrawal queue.
    /// @dev This is provided because Solidity converts public arrays into index getters,
    /// but we need a way to allow external contracts and users to access the whole array.
    function getWithdrawalQueue() external view returns (Strategy[] memory) {
        return withdrawalQueue;
    }

    /*///////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted after a successful deposit.
    /// @param user The address that deposited into the Vault.
    /// @param underlyingAmount The amount of underlying tokens that were deposited.
    event Deposit(address indexed user, uint256 underlyingAmount);

    /// @notice Emitted after a successful withdrawal.
    /// @param user The address that withdrew from the Vault.
    /// @param underlyingAmount The amount of underlying tokens that were withdrawn.
    event Withdraw(address indexed user, uint256 underlyingAmount);

    /// @notice Deposit all user balance of underlying tokens.
    function depositAll() external {
        uint256 underlyingAmount = UNDERLYING.balanceOf(msg.sender);
        _deposit(underlyingAmount);
    }

    /// @notice Deposit a specific amount of underlying tokens.
    /// @param underlyingAmount The amount of the underlying token to deposit.
    function deposit(uint256 underlyingAmount) external {
        // We don't allow depositing 0 to prevent emitting a useless event.
        require(underlyingAmount != 0, "AMOUNT_CANNOT_BE_ZERO");
        _deposit(underlyingAmount);
    }

    /// @notice Deposit a specific amount of underlying tokens.
    function _deposit(uint256 underlyingAmount) internal {
        // Determine the equivalent amount of arTokens and mint them.
        _mint(msg.sender, underlyingAmount.fdiv(exchangeRate(), BASE_UNIT));

        emit Deposit(msg.sender, underlyingAmount);

        // Transfer in underlying tokens from the user.
        // This will revert if the user does not have the amount specified.
        UNDERLYING.safeTransferFrom(msg.sender, address(this), underlyingAmount);
    }

    /// @notice Withdraw a specific amount of underlying tokens.
    /// @param underlyingAmount The amount of underlying tokens to withdraw.
    function withdraw(uint256 underlyingAmount) external {
        // We don't allow withdrawing 0 to prevent emitting a useless event.
        require(underlyingAmount != 0, "AMOUNT_CANNOT_BE_ZERO");

        uint256 arToken = underlyingAmount.fdiv(exchangeRate(), BASE_UNIT);
        underlyingAmount = underlyingAmount.fmul(1e18 - withdrawalFeePercent, 1e18);

        // Determine the equivalent amount of arTokens and burn them.
        // This will revert if the user does not have enough arTokens.
        _burn(msg.sender, arToken);

        emit Withdraw(msg.sender, underlyingAmount);

        // Withdraw from strategies if needed and transfer.
        transferUnderlyingTo(msg.sender, underlyingAmount);
    }

    /// @notice Redeem all balance of arTokens for underlying tokens.
    function redeemAll() external {
        uint256 arTokenAmount = balanceOf[msg.sender];

        uint256 underlyingAmount = arTokenAmount.fmul(exchangeRate(), BASE_UNIT);
        underlyingAmount = underlyingAmount.fmul(1e18 - withdrawalFeePercent, 1e18);

        _redeem(arTokenAmount, underlyingAmount);
    }

    /// @notice Redeem a specific amount of arTokens for underlying tokens.
    /// @param arTokenAmount The amount of arTokens to redeem for underlying tokens.
    function redeem(uint256 arTokenAmount) external {
        // We don't allow redeeming 0 to prevent emitting a useless event.
        require(arTokenAmount != 0, "AMOUNT_CANNOT_BE_ZERO");
        uint256 underlyingAmount = arTokenAmount.fmul(exchangeRate(), BASE_UNIT);
        underlyingAmount = underlyingAmount.fmul(1e18 - withdrawalFeePercent, 1e18);

        _redeem(arTokenAmount, underlyingAmount);
    }

    /// @notice Redeem a specific amount of arTokens for underlying tokens without withdrawal fees.
    /// @param arTokenAmount The amount of arTokens to redeem for underlying tokens.
    /// @dev Used by strategies/approved contracts
    function redeemRestricted(uint256 arTokenAmount) external requiresAuth {
        // We don't allow redeeming 0 to prevent emitting a useless event.
        require(arTokenAmount != 0, "AMOUNT_CANNOT_BE_ZERO");
        uint256 underlyingAmount = arTokenAmount.fmul(exchangeRate(), BASE_UNIT);
        _redeem(arTokenAmount, underlyingAmount);
    }

    function _redeem(uint256 arTokenAmount, uint256 underlyingAmount) internal {
        // Burn the provided amount of arTokens.
        // This will revert if the user does not have enough arTokens.
        _burn(msg.sender, arTokenAmount);

        emit Withdraw(msg.sender, underlyingAmount);

        // Withdraw from strategies if needed and transfer.
        transferUnderlyingTo(msg.sender, underlyingAmount);
    }

    /// @dev Transfers a specific amount of underlying tokens held in strategies and/or float to a recipient.
    /// @dev Only withdraws from strategies if needed and maintains the target float percentage if possible.
    /// @param recipient The user to transfer the underlying tokens to.
    /// @param underlyingAmount The amount of underlying tokens to transfer.
    function transferUnderlyingTo(address recipient, uint256 underlyingAmount) internal {
        // Get the Vault's floating balance.
        uint256 float = totalFloat();

        // If the amount is greater than the float, withdraw from strategies.
        if (underlyingAmount > float) {
            // Compute the amount needed to reach our target float percentage.
            uint256 floatMissingForTarget = (totalHoldings() - underlyingAmount).fmul(targetFloatPercent, 1e18);

            // Compute the bare minimum amount we need for this withdrawal.
            uint256 floatMissingForWithdrawal = underlyingAmount - float;

            // Pull enough to cover the withdrawal and reach our target float percentage.
            pullFromWithdrawalQueue(floatMissingForWithdrawal + floatMissingForTarget);
        }

        // Transfer the provided amount of underlying tokens.
        UNDERLYING.safeTransfer(recipient, underlyingAmount);
    }

    /*///////////////////////////////////////////////////////////////
                        VAULT ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns a user's Vault balance in underlying tokens.
    /// @param user The user to get the underlying balance of.
    /// @return The user's Vault balance in underlying tokens.
    function balanceOfUnderlying(address user) external view returns (uint256) {
        return balanceOf[user].fmul(exchangeRate(), BASE_UNIT);
    }

    /// @notice Returns the amount of underlying tokens an arToken can be redeemed for.
    /// @return The amount of underlying tokens an arToken can be redeemed for.
    function exchangeRate() public view returns (uint256) {
        // Get the total supply of arTokens.
        uint256 arTokenSupply = totalSupply;

        // If there are no arTokens in circulation, return an exchange rate of 1:1.
        if (arTokenSupply == 0) return BASE_UNIT;

        // Calculate the exchange rate by dividing the total holdings by the arToken supply.
        return totalHoldings().fdiv(arTokenSupply, BASE_UNIT);
    }

    /// @notice Calculates the total amount of underlying tokens the Vault holds.
    /// @return totalUnderlyingHeld The total amount of underlying tokens the Vault holds.
    function totalHoldings() public view returns (uint256 totalUnderlyingHeld) {
        unchecked {
            // Cannot underflow as locked profit can't exceed total strategy holdings.
            totalUnderlyingHeld = totalStrategyHoldings - lockedProfit();
        }

        // Include our floating balance in the total.
        totalUnderlyingHeld += totalFloat();
    }

    /// @notice Calculates the current amount of locked profit.
    /// @return The current amount of locked profit.
    function lockedProfit() public view returns (uint256) {
        // Get the last harvest and harvest delay.
        uint256 previousHarvest = lastHarvest;
        uint256 harvestInterval = harvestDelay;

        unchecked {
            // If the harvest delay has passed, there is no locked profit.
            // Cannot overflow on human timescales since harvestInterval is capped.
            if (block.timestamp >= previousHarvest + harvestInterval) return 0;

            // Get the maximum amount we could return.
            uint256 maximumLockedProfit = maxLockedProfit;

            // Compute how much profit remains locked based on the last harvest and harvest delay.
            // It's impossible for the previous harvest to be in the future, so this will never underflow.
            return maximumLockedProfit - (maximumLockedProfit * (block.timestamp - previousHarvest)) / harvestInterval;
        }
    }

    /// @notice Returns the amount of underlying tokens that idly sit in the Vault.
    /// @return The amount of underlying tokens that sit idly in the Vault.
    function totalFloat() public view returns (uint256) {
        return UNDERLYING.balanceOf(address(this));
    }

    /*///////////////////////////////////////////////////////////////
                             HARVEST LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted after a successful harvest.
    /// @param user The authorized user who triggered the harvest.
    /// @param strategies The trusted strategies that were harvested.
    event Harvest(address indexed user, Strategy[] strategies);

    /// @notice Harvest a set of trusted strategies.
    /// @param strategies The trusted strategies to harvest.
    /// @dev Will always revert if called outside of an active
    /// harvest window or before the harvest delay has passed.
    function harvest(Strategy[] calldata strategies) external requiresAuth {
        // If this is the first harvest after the last window:
        if (block.timestamp >= lastHarvest + harvestDelay) {
            // Set the harvest window's start timestamp.
            // Cannot overflow 64 bits on human timescales.
            lastHarvestWindowStart = uint64(block.timestamp);
        } else {
            // We know this harvest is not the first in the window so we need to ensure it's within it.
            require(block.timestamp <= lastHarvestWindowStart + harvestWindow, "BAD_HARVEST_TIME");
        }

        // Get the Vault's current total strategy holdings.
        uint256 oldTotalStrategyHoldings = totalStrategyHoldings;

        // Used to store the total profit accrued by the strategies.
        uint256 totalProfitAccrued;

        // Used to store the new total strategy holdings after harvesting.
        uint256 newTotalStrategyHoldings = oldTotalStrategyHoldings;

        // Will revert if any of the specified strategies are untrusted.
        for (uint256 i = 0; i < strategies.length; i++) {
            // Get the strategy at the current index.
            Strategy strategy = strategies[i];

            // If an untrusted strategy could be harvested a malicious user could use
            // a fake strategy that over-reports holdings to manipulate the exchange rate.
            require(getStrategyData[strategy].trusted, "UNTRUSTED_STRATEGY");

            // Get the strategy's previous and current balance.
            uint256 balanceLastHarvest = getStrategyData[strategy].balance;
            uint256 balanceThisHarvest = strategy.balanceOfUnderlying(address(this));

            // Update the strategy's stored balance. Cast overflow is unrealistic.
            getStrategyData[strategy].balance = balanceThisHarvest.safeCastTo248();

            // Increase/decrease newTotalStrategyHoldings based on the profit/loss registered.
            // We cannot wrap the subtraction in parenthesis as it would underflow if the strategy had a loss.
            newTotalStrategyHoldings = newTotalStrategyHoldings + balanceThisHarvest - balanceLastHarvest;

            unchecked {
                // Update the total profit accrued while counting losses as zero profit.
                // Cannot overflow as we already increased total holdings without reverting.
                totalProfitAccrued += balanceThisHarvest > balanceLastHarvest
                    ? balanceThisHarvest - balanceLastHarvest // Profits since last harvest.
                    : 0; // If the strategy registered a net loss we don't have any new profit.
            }
        }

        // Compute fees as the fee percent multiplied by the profit.
        uint256 feesAccrued = totalProfitAccrued.fmul(feePercent, 1e18);

        // If we accrued any fees, mint an equivalent amount of arTokens.
        // Authorized users can claim the newly minted arTokens via claimFees.
        _mint(address(this), feesAccrued.fdiv(exchangeRate(), BASE_UNIT));

        // Update max unlocked profit based on any remaining locked profit plus new profit.
        maxLockedProfit = (lockedProfit() + totalProfitAccrued - feesAccrued).safeCastTo128();

        // Set strategy holdings to our new total.
        totalStrategyHoldings = newTotalStrategyHoldings;

        // Update the last harvest timestamp.
        // Cannot overflow on human timescales.
        lastHarvest = uint64(block.timestamp);

        emit Harvest(msg.sender, strategies);

        // Get the next harvest delay.
        uint64 newHarvestDelay = nextHarvestDelay;

        // If the next harvest delay is not 0:
        if (newHarvestDelay != 0) {
            // Update the harvest delay.
            harvestDelay = newHarvestDelay;

            // Reset the next harvest delay.
            nextHarvestDelay = 0;

            emit HarvestDelayUpdated(msg.sender, newHarvestDelay);
        }
    }

    /*///////////////////////////////////////////////////////////////
                    STRATEGY DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted after the Vault deposits into a strategy contract.
    /// @param user The authorized user who triggered the deposit.
    /// @param strategy The strategy that was deposited into.
    /// @param underlyingAmount The amount of underlying tokens that were deposited.
    event StrategyDeposit(address indexed user, Strategy indexed strategy, uint256 underlyingAmount);

    /// @notice Emitted after the Vault withdraws funds from a strategy contract.
    /// @param user The authorized user who triggered the withdrawal.
    /// @param strategy The strategy that was withdrawn from.
    /// @param underlyingAmount The amount of underlying tokens that were withdrawn.
    event StrategyWithdrawal(address indexed user, Strategy indexed strategy, uint256 underlyingAmount);

    /// @notice Deposit a specific amount of float into a trusted strategy.
    /// @param strategy The trusted strategy to deposit into.
    /// @param underlyingAmount The amount of underlying tokens in float to deposit.
    function depositIntoStrategy(Strategy strategy, uint256 underlyingAmount) external requiresAuth {
        // A strategy must be trusted before it can be deposited into.
        require(getStrategyData[strategy].trusted, "UNTRUSTED_STRATEGY");

        // We don't allow depositing 0 to prevent emitting a useless event.
        require(underlyingAmount != 0, "AMOUNT_CANNOT_BE_ZERO");

        // Increase totalStrategyHoldings to account for the deposit.
        totalStrategyHoldings += underlyingAmount;

        unchecked {
            // Without this the next harvest would count the deposit as profit.
            // Cannot overflow as the balance of one strategy can't exceed the sum of all.
            getStrategyData[strategy].balance += underlyingAmount.safeCastTo248();
        }

        emit StrategyDeposit(msg.sender, strategy, underlyingAmount);

        // We need to deposit differently if the strategy takes ETH.
        if (strategy.isEther()) {
            // Unwrap the right amount of WETH.
            WETH(payable(address(UNDERLYING))).withdraw(underlyingAmount);

            // Deposit into the strategy and assume it will revert on error.
            ETHStrategy(address(strategy)).mint{value: underlyingAmount}();
        } else {
            // Approve underlyingAmount to the strategy so we can deposit.
            UNDERLYING.safeApprove(address(strategy), underlyingAmount);

            // Deposit into the strategy and revert if it returns an error code.
            require(ERC20Strategy(address(strategy)).mint(underlyingAmount) == 0, "MINT_FAILED");
        }
    }

    /// @notice Withdraw a specific amount of underlying tokens from a strategy.
    /// @param strategy The strategy to withdraw from.
    /// @param underlyingAmount  The amount of underlying tokens to withdraw.
    /// @dev Withdrawing from a strategy will not remove it from the withdrawal queue.
    function withdrawFromStrategy(Strategy strategy, uint256 underlyingAmount) external requiresAuth {
        // A strategy must be trusted before it can be withdrawn from.
        require(getStrategyData[strategy].trusted, "UNTRUSTED_STRATEGY");

        // We don't allow withdrawing 0 to prevent emitting a useless event.
        require(underlyingAmount != 0, "AMOUNT_CANNOT_BE_ZERO");

        // Without this the next harvest would count the withdrawal as a loss.
        getStrategyData[strategy].balance -= underlyingAmount.safeCastTo248();

        unchecked {
            // Decrease totalStrategyHoldings to account for the withdrawal.
            // Cannot underflow as the balance of one strategy will never exceed the sum of all.
            totalStrategyHoldings -= underlyingAmount;
        }

        emit StrategyWithdrawal(msg.sender, strategy, underlyingAmount);

        // Withdraw from the strategy and revert if it returns an error code.
        require(strategy.redeemUnderlying(underlyingAmount) == 0, "REDEEM_FAILED");

        // Wrap the withdrawn Ether into WETH if necessary.
        if (strategy.isEther()) WETH(payable(address(UNDERLYING))).deposit{value: underlyingAmount}();
    }

    /*///////////////////////////////////////////////////////////////
                      STRATEGY TRUST/DISTRUST LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a strategy is set to trusted.
    /// @param user The authorized user who trusted the strategy.
    /// @param strategy The strategy that became trusted.
    event StrategyTrusted(address indexed user, Strategy indexed strategy);

    /// @notice Emitted when a strategy is set to untrusted.
    /// @param user The authorized user who untrusted the strategy.
    /// @param strategy The strategy that became untrusted.
    event StrategyDistrusted(address indexed user, Strategy indexed strategy);

    /// @notice Stores a strategy as trusted, enabling it to be harvested.
    /// @param strategy The strategy to make trusted.
    function trustStrategy(Strategy strategy) external requiresAuth {
        // Ensure the strategy accepts the correct underlying token.
        // If the strategy accepts ETH the Vault should accept WETH, it'll handle wrapping when necessary.
        require(
            strategy.isEther() ? underlyingIsWETH : ERC20Strategy(address(strategy)).underlying() == UNDERLYING,
            "WRONG_UNDERLYING"
        );

        // Store the strategy as trusted.
        getStrategyData[strategy].trusted = true;

        emit StrategyTrusted(msg.sender, strategy);
    }

    /// @notice Stores a strategy as untrusted, disabling it from being harvested.
    /// @param strategy The strategy to make untrusted.
    function distrustStrategy(Strategy strategy) external requiresAuth {
        // Store the strategy as untrusted.
        getStrategyData[strategy].trusted = false;

        emit StrategyDistrusted(msg.sender, strategy);
    }

    /*///////////////////////////////////////////////////////////////
                         WITHDRAWAL QUEUE LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a strategy is pushed to the withdrawal queue.
    /// @param user The authorized user who triggered the push.
    /// @param pushedStrategy The strategy pushed to the withdrawal queue.
    event WithdrawalQueuePushed(address indexed user, Strategy indexed pushedStrategy);

    /// @notice Emitted when a strategy is popped from the withdrawal queue.
    /// @param user The authorized user who triggered the pop.
    /// @param poppedStrategy The strategy popped from the withdrawal queue.
    event WithdrawalQueuePopped(address indexed user, Strategy indexed poppedStrategy);

    /// @notice Emitted when the withdrawal queue is updated.
    /// @param user The authorized user who triggered the set.
    /// @param replacedWithdrawalQueue The new withdrawal queue.
    event WithdrawalQueueSet(address indexed user, Strategy[] replacedWithdrawalQueue);

    /// @notice Emitted when an index in the withdrawal queue is replaced.
    /// @param user The authorized user who triggered the replacement.
    /// @param index The index of the replaced strategy in the withdrawal queue.
    /// @param replacedStrategy The strategy in the withdrawal queue that was replaced.
    /// @param replacementStrategy The strategy that overrode the replaced strategy at the index.
    event WithdrawalQueueIndexReplaced(
        address indexed user,
        uint256 index,
        Strategy indexed replacedStrategy,
        Strategy indexed replacementStrategy
    );

    /// @notice Emitted when an index in the withdrawal queue is replaced with the tip.
    /// @param user The authorized user who triggered the replacement.
    /// @param index The index of the replaced strategy in the withdrawal queue.
    /// @param replacedStrategy The strategy in the withdrawal queue replaced by the tip.
    /// @param previousTipStrategy The previous tip of the queue that replaced the strategy.
    event WithdrawalQueueIndexReplacedWithTip(
        address indexed user,
        uint256 index,
        Strategy indexed replacedStrategy,
        Strategy indexed previousTipStrategy
    );

    /// @notice Emitted when the strategies at two indexes are swapped.
    /// @param user The authorized user who triggered the swap.
    /// @param index1 One index involved in the swap
    /// @param index2 The other index involved in the swap.
    /// @param newStrategy1 The strategy (previously at index2) that replaced index1.
    /// @param newStrategy2 The strategy (previously at index1) that replaced index2.
    event WithdrawalQueueIndexesSwapped(
        address indexed user,
        uint256 index1,
        uint256 index2,
        Strategy indexed newStrategy1,
        Strategy indexed newStrategy2
    );

    /// @dev Withdraw a specific amount of underlying tokens from strategies in the withdrawal queue.
    /// @param underlyingAmount The amount of underlying tokens to pull into float.
    /// @dev Automatically removes depleted strategies from the withdrawal queue.
    function pullFromWithdrawalQueue(uint256 underlyingAmount) internal {
        // We will update this variable as we pull from strategies.
        uint256 amountLeftToPull = underlyingAmount;

        // We'll start at the tip of the queue and traverse backwards.
        uint256 currentIndex = withdrawalQueue.length - 1;

        // Iterate in reverse so we pull from the queue in a "last in, first out" manner.
        // Will revert due to underflow if we empty the queue before pulling the desired amount.
        for (; ; currentIndex--) {
            // Get the strategy at the current queue index.
            Strategy strategy = withdrawalQueue[currentIndex];

            // Get the balance of the strategy before we withdraw from it.
            uint256 strategyBalance = getStrategyData[strategy].balance;

            // If the strategy is currently untrusted or was already depleted:
            if (!getStrategyData[strategy].trusted || strategyBalance == 0) {
                // Remove it from the queue.
                withdrawalQueue.pop();

                emit WithdrawalQueuePopped(msg.sender, strategy);

                // Move onto the next strategy.
                continue;
            }

            uint256 amountToPull = amountLeftToPull < strategyBalance ? amountLeftToPull : strategyBalance;

            unchecked {
                // Compute the balance of the strategy that will remain after we withdraw.
                // Cannot underflow as we cap the amount to pull at the strategy's balance.
                uint256 strategyBalanceAfterWithdrawal = strategyBalance - amountToPull;

                // Without this the next harvest would count the withdrawal as a loss.
                getStrategyData[strategy].balance = strategyBalanceAfterWithdrawal.safeCastTo248();

                // Adjust our goal based on how much we can pull from the strategy.
                // Cannot underflow as we cap the amount to pull at the amount left to pull.
                amountLeftToPull -= amountToPull;

                emit StrategyWithdrawal(msg.sender, strategy, amountToPull);

                // Withdraw from the strategy and revert if returns an error code.
                require(strategy.redeemUnderlying(amountToPull) == 0, "REDEEM_FAILED");

                // If we fully depleted the strategy:
                if (strategyBalanceAfterWithdrawal == 0) {
                    // Remove it from the queue.
                    withdrawalQueue.pop();

                    emit WithdrawalQueuePopped(msg.sender, strategy);
                }
            }

            // If we've pulled all we need, exit the loop.
            if (amountLeftToPull == 0) break;
        }

        unchecked {
            // Account for the withdrawals done in the loop above.
            // Cannot underflow as the balances of some strategies cannot exceed the sum of all.
            totalStrategyHoldings -= underlyingAmount;
        }

        // Cache the Vault's balance of ETH.
        uint256 ethBalance = address(this).balance;

        // If the Vault's underlying token is WETH compatible and we have some ETH, wrap it into WETH.
        if (ethBalance != 0 && underlyingIsWETH) WETH(payable(address(UNDERLYING))).deposit{value: ethBalance}();
    }

    /// @notice Pushes a single strategy to front of the withdrawal queue.
    /// @param strategy The strategy to be inserted at the front of the withdrawal queue.
    /// @dev Strategies that are untrusted, duplicated, or have no balance are
    /// filtered out when encountered at withdrawal time, not validated upfront.
    function pushToWithdrawalQueue(Strategy strategy) external requiresAuth {
        // Push the strategy to the front of the queue.
        withdrawalQueue.push(strategy);

        emit WithdrawalQueuePushed(msg.sender, strategy);
    }

    /// @notice Removes the strategy at the tip of the withdrawal queue.
    /// @dev Be careful, another authorized user could push a different strategy
    /// than expected to the queue while a popFromWithdrawalQueue transaction is pending.
    function popFromWithdrawalQueue() external requiresAuth {
        // Get the (soon to be) popped strategy.
        Strategy poppedStrategy = withdrawalQueue[withdrawalQueue.length - 1];

        // Pop the first strategy in the queue.
        withdrawalQueue.pop();

        emit WithdrawalQueuePopped(msg.sender, poppedStrategy);
    }

    /// @notice Sets a new withdrawal queue.
    /// @param newQueue The new withdrawal queue.
    /// @dev Strategies that are untrusted, duplicated, or have no balance are
    /// filtered out when encountered at withdrawal time, not validated upfront.
    function setWithdrawalQueue(Strategy[] calldata newQueue) external requiresAuth {
        // Replace the withdrawal queue.
        withdrawalQueue = newQueue;

        emit WithdrawalQueueSet(msg.sender, newQueue);
    }

    /// @notice Replaces an index in the withdrawal queue with another strategy.
    /// @param index The index in the queue to replace.
    /// @param replacementStrategy The strategy to override the index with.
    /// @dev Strategies that are untrusted, duplicated, or have no balance are
    /// filtered out when encountered at withdrawal time, not validated upfront.
    function replaceWithdrawalQueueIndex(uint256 index, Strategy replacementStrategy) external requiresAuth {
        // Get the (soon to be) replaced strategy.
        Strategy replacedStrategy = withdrawalQueue[index];

        // Update the index with the replacement strategy.
        withdrawalQueue[index] = replacementStrategy;

        emit WithdrawalQueueIndexReplaced(msg.sender, index, replacedStrategy, replacementStrategy);
    }

    /// @notice Moves the strategy at the tip of the queue to the specified index and pop the tip off the queue.
    /// @param index The index of the strategy in the withdrawal queue to replace with the tip.
    function replaceWithdrawalQueueIndexWithTip(uint256 index) external requiresAuth {
        // Get the (soon to be) previous tip and strategy we will replace at the index.
        Strategy previousTipStrategy = withdrawalQueue[withdrawalQueue.length - 1];
        Strategy replacedStrategy = withdrawalQueue[index];

        // Replace the index specified with the tip of the queue.
        withdrawalQueue[index] = previousTipStrategy;

        // Remove the now duplicated tip from the array.
        withdrawalQueue.pop();

        emit WithdrawalQueueIndexReplacedWithTip(msg.sender, index, replacedStrategy, previousTipStrategy);
    }

    /// @notice Swaps two indexes in the withdrawal queue.
    /// @param index1 One index involved in the swap
    /// @param index2 The other index involved in the swap.
    function swapWithdrawalQueueIndexes(uint256 index1, uint256 index2) external requiresAuth {
        // Get the (soon to be) new strategies at each index.
        Strategy newStrategy2 = withdrawalQueue[index1];
        Strategy newStrategy1 = withdrawalQueue[index2];

        // Swap the strategies at both indexes.
        withdrawalQueue[index1] = newStrategy1;
        withdrawalQueue[index2] = newStrategy2;

        emit WithdrawalQueueIndexesSwapped(msg.sender, index1, index2, newStrategy1, newStrategy2);
    }

    /*///////////////////////////////////////////////////////////////
                         SEIZE STRATEGY LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted after a strategy is seized.
    /// @param user The authorized user who triggered the seize.
    /// @param strategy The strategy that was seized.
    event StrategySeized(address indexed user, Strategy indexed strategy);

    /// @notice Seizes a strategy.
    /// @param strategy The strategy to seize.
    /// @dev Intended for use in emergencies or other extraneous situations where the
    /// strategy requires interaction outside of the Vault's standard operating procedures.
    function seizeStrategy(Strategy strategy) external requiresAuth {
        // A strategy must be trusted before it can be seized.
        require(getStrategyData[strategy].trusted, "UNTRUSTED_STRATEGY");

        // Get the strategy's last reported balance of underlying tokens.
        uint256 strategyBalance = getStrategyData[strategy].balance;

        // If the strategy's balance exceeds the Vault's current
        // holdings, instantly unlock any remaining locked profit.
        if (strategyBalance > totalHoldings()) maxLockedProfit = 0;

        // Set the strategy's balance to 0.
        getStrategyData[strategy].balance = 0;

        unchecked {
            // Decrease totalStrategyHoldings to account for the seize.
            // Cannot underflow as the balance of one strategy will never exceed the sum of all.
            totalStrategyHoldings -= strategyBalance;
        }

        emit StrategySeized(msg.sender, strategy);

        // Transfer all of the strategy's tokens to the caller.
        ERC20(strategy).safeTransfer(msg.sender, strategy.balanceOf(address(this)));
    }

    /*///////////////////////////////////////////////////////////////
                             FEE CLAIM LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted after fees are claimed.
    /// @param user The authorized user who claimed the fees.
    /// @param arTokenAmount The amount of arTokens that were claimed.
    event FeesClaimed(address indexed user, uint256 arTokenAmount);

    /// @notice Claims fees accrued from harvests.
    /// @param arTokenAmount The amount of arTokens to claim.
    /// @dev Accrued fees are measured as arTokens held by the Vault.
    function claimFees(uint256 arTokenAmount) external requiresAuth {
        emit FeesClaimed(msg.sender, arTokenAmount);

        // Transfer the provided amount of arTokens to the caller.
        ERC20(this).safeTransfer(msg.sender, arTokenAmount);
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

    /// @notice Initializes the Vault, enabling it to receive deposits.
    /// @dev All critical parameters must already be set before calling.
    function initialize() external requiresAuth {
        // Ensure the Vault has not already been initialized.
        require(!isInitialized, "ALREADY_INITIALIZED");

        // Mark the Vault as initialized.
        isInitialized = true;

        // Open for deposits.
        totalSupply = 0;

        emit Initialized(msg.sender);
    }

    /// @notice Self destructs a Vault, enabling it to be redeployed.
    /// @dev Caller will receive any ETH held as float in the Vault.
    function destroy() external requiresAuth {
        selfdestruct(payable(msg.sender));
    }

    /*///////////////////////////////////////////////////////////////
                          RECIEVE ETHER LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Required for the Vault to receive unwrapped ETH.
    receive() external payable {}
}