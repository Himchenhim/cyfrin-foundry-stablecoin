// SPDX-License-Identifier: MIT

// Layout of Contract:
// 1. version
// 2. imports
// 3. errors
// 4. Interfaces/Libraries/Contracts
// 5. Type declarations
// 6. State variables
// 7. Events
// 8. Modifiers
// 9. Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.20;

import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from
    "../lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Patrick Collins & Dmytro Khimchenko
 *
 * The system is designed to be as minimal as possible and have the tokens maintain a token == $1 peg.
 * this stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees and was ony backed by wETH and wBTC
 *
 * Our DSC system should always be "overcollateralized". At no poit, should the value of of collateral <= the $ backd value of all the DSC.
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for minting and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) systenm
 */

// Threshold to let's say 150%
// $100 ETH -> $74 ETH
// $50 DSC ->

// if someone pays back your minted DSC, they can have all your collateral for a discount.
contract DSCEngine is ReentrancyGuard {
    ////////////
    // Errors //
    ////////////

    error DSCEngine__NeedMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreakHealthFactor(uint256 healthFactor);
    error DSCEngine_MintFailed();
    error DSCEngine__AmountToExtractMoreThanAmountOfCollateral();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ///////////////////////
    // State variables ////
    ///////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // this means a 10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////
    // Events       //
    //////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    ///////////////
    // Modifiers //
    ///////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ///////////////
    // Functions //
    ///////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; ++i) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////////
    // External Functions ///
    /////////////////////////
    /**
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountUsdcToMint The amount of Usdc to min
     * @notice this function will deposit your collateral and mint USDC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountUsdcToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountUsdcToMint);
    }

    /**
     * @notice follows CEI
     *
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral       The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant // whenever we work with another smart contracts -> consider using "nonReentrant" modifier
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool transactionSuccess =
            IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);

        if (!transactionSuccess) {
            revert DSCEngine__TransferFailed();
        }
    }
    /**
     * @notice follows CEI
     * @param amountDscToMint the amount DSC to mint for user
     * @notice user must have more collateral alue than the minimum threshold
     */

    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine_MintFailed();
        }
    }

    /**
     *
     * @param tokenCollateralAddress the collateral address to redeem
     * @param amountCollateral the amount of collateral to redeem
     * @param amountDscToBurn  the amount of DSC to burn
     * This function burns DSC and redeems underlying collateral in one transaction
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks health factor
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't believe, that it would ever hit...
    }

    /**
     * @dev Low-leven internal function, do not call unless the function calling is checking for
     * health factors being broken
     */
    function _burnDsc(uint256 amount, address onBehalfOf, address dscFrom) private moreThanZero(amount) {
        s_DSCMinted[onBehalfOf] -= amount;
        bool transferSuccess = i_dsc.transferFrom(dscFrom, address(this), amount);
        if (!transferSuccess) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amount);
    }

    // $100 ETH backing $50 DSC
    // $20 ETH back $50 DSC <- DSC isn't even worth $1!!!

    // $75 backing $50 DSC
    // liquidator take $75 backing and burns off the $50DSC

    // if someone is almost undercollateralize, we will pay you to liquidate them!
    /**
     *
     * @param tokenCollateralAddress the tokenCollateralAddress (erc20) to liquidate
     * @param userToLiquidate collateral's of which user we want to liquidate. Their _healthfactor should be below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the users health factor
     *
     * @notice you can partially liquidate a user.
     * @notice you will get a liquidation bonus for taking the users funds.
     * @notice this function working assumes the protocol will be roughly 200% overcollateralized in order for this work
     * @notice a known bug would be if the protocol were %100  or less collaterlized, then we wouldn't be able to incentive the liquidators.
     *
     * CEI
     */
    function liquidate(address tokenCollateralAddress, address userToLiquidate, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(userToLiquidate);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // we want to burn their DSC "debt"
        // and take their collateral
        // Bad User: $140 ETH, $100 DSC.
        // debtToCover = $100
        // $100 of DSC === ??? ETH?
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(tokenCollateralAddress, debtToCover);
        // give them 10% bonus
        // so we are giving the liquidotr $110 of WETH for 100 DSC
        // we should implement a feature to liquidate in the event the protocol is insolvent
        // and sweep extra amounts into a treasury

        // 0.05 ETH * .1 = 0.005 ETH -> Getting 0.055 ETH as a bonus
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        _redeemCollateral(
            userToLiquidate, msg.sender, tokenCollateralAddress, tokenAmountFromDebtCovered + bonusCollateral
        );

        _burnDsc(debtToCover, userToLiquidate, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(userToLiquidate);
        if (endingUserHealthFactor <= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // function getHealthFactor() external view {}

    ///////////////////////////////////////
    // Private & Internal View Functions //
    ///////////////////////////////////////

    function _redeemCollateral(address from, address to, address tokenCollateral, uint256 amountCollateral) private {
        s_collateralDeposited[from][tokenCollateral] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateral, amountCollateral);

        bool transactionSuccess = IERC20(tokenCollateral).transfer(to, amountCollateral);
        if (!transactionSuccess) {
            revert DSCEngine__TransferFailed();
        }
        // breaking CEI for gas optimization
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated
     */
    // < 1 -- bad health factor
    // > 1 -- good health factor
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsdt) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsdt);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustForThreshold * PRECISION) / totalDscMinted;
    }

    // 1. check health factor (do they have enough collateral?)
    // 2. revert if they don't
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreakHealthFactor(userHealthFactor);
        }
    }

    ///////////////////////////////////////
    // Public & External View Functions  //
    ///////////////////////////////////////
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // price of ETH (token)
        // $/ETH ETH ??
        // $2000 / ETH. $1000 = 0.5ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        uint256 amountOfToken = 0;
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            amountOfToken = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amountOfToken);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = $1000
        // The returned value 1000 * 1e8 (how many floating numbers?)

        // (1000 * 1e8) (data-feed) *  1000(amount) * 1e18(WEI) *10) * 1e10 (FOR PRECISION); (because in WEI)
        return (uint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}
