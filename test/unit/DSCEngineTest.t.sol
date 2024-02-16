// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../../lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_TO_MINT = 1 ether; // !IMPORTANT! in this case: 1 ether === 1 USD

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /////////////////
    // Price Tests //
    /////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    /////////////////////////////
    // depositCollateral Tests //
    /////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 exptectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, exptectedDepositAmount);
    }

    /////////////////////////////
    // mintDSC Tests           //
    /////////////////////////////
    function testMintDSCwithNotEnoughCollateral() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__BreakHealthFactor.selector);
        dsce.mintDsc(10e18);
        vm.stopPrank();
    }

    modifier depositedAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(AMOUNT_TO_MINT);
        vm.stopPrank();
        _;
    }

    function testMintDSCWithEnoughCollateral() public depositedAndMintedDsc {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 1e18;
        uint256 exptectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, exptectedDepositAmount);
    }

    /////////////////////////////
    // Deposit + mintDSC Tests //
    /////////////////////////////
    function testDepositCollateralAndMintDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 1e18;
        uint256 exptectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, exptectedDepositAmount);
    }

    /////////////////////////////
    // burnCollateral Tests    //
    /////////////////////////////
    function testBurnZero() public depositedAndMintedDsc {
        vm.startPrank(USER);
        ERC20Mock(address(dsc)).approve(address(dsce), AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testBurnMoreThanUserHas() public depositedAndMintedDsc {
        vm.startPrank(USER);
        ERC20Mock(address(dsc)).approve(address(dsce), AMOUNT_TO_MINT);
        vm.expectRevert();
        dsce.burnDsc(AMOUNT_TO_MINT * 2);
        vm.stopPrank();
    }

    function testBurnDSC() public depositedAndMintedDsc {
        vm.startPrank(USER);
        ERC20Mock(address(dsc)).approve(address(dsce), AMOUNT_TO_MINT);
        dsce.burnDsc(AMOUNT_TO_MINT);
        vm.stopPrank();

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 exptectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, exptectedDepositAmount);
    }

    /////////////////////////////
    // redeem Tests            //
    /////////////////////////////
    function testRedeemZero() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.startPrank(USER);
    }

    function testRedeemingButBreakingHealthFactor() public depositedAndMintedDsc {
        vm.startPrank(USER);
        dsce.mintDsc(AMOUNT_TO_MINT * 2000);
        uint256 AMOUNT_TO_REDEEM = 9 ether;
        uint256 expectedHealthFactor = dsce.calculateHealthFactor(
            AMOUNT_TO_MINT * 2001, dsce.getUsdValue(weth, AMOUNT_COLLATERAL - AMOUNT_TO_REDEEM)
        );
        // 4000 000 000 000 000 000 000
        // getUsdValue = 1400 000 000 000 000 000 000
        uint256 resultUsdValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL - AMOUNT_TO_REDEEM);
        console.log(resultUsdValue);
        // 6×10²⁰  600 000 000 000 000 000 000
        console.log(expectedHealthFactor);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakHealthFactor.selector, expectedHealthFactor));

        dsce.redeemCollateral(weth, AMOUNT_TO_REDEEM);
        vm.stopPrank();
    }

    function testRedeemingWithMinting() public depositedAndMintedDsc {
        vm.startPrank(USER);
        uint256 AMOUNT_TO_REDEEM = 9 ether;

        dsce.redeemCollateral(weth, AMOUNT_TO_REDEEM);
        vm.stopPrank();
    }

    function testRedeemingAllSumWithoutMinting() public depositedCollateral {
        vm.startPrank(USER);
        dsce.redeemCollateral(weth, 10 ether);
        vm.stopPrank();

        uint256 expectedTotalAmountOfToken = 10 ether;
        uint256 totalAmountOfToken = ERC20Mock(weth).balanceOf(USER);
        assertEq(expectedTotalAmountOfToken, totalAmountOfToken);

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 DepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        uint256 expectedDepositAmount = 0;

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(DepositAmount, expectedDepositAmount);
    }

    /////////////////////////////
    // redeem & burn Tests     //
    /////////////////////////////
    function testBurnNotEnoughDscForRedeemingCollateral() public depositedAndMintedDsc {
        vm.startPrank(USER);

        dsce.mintDsc(AMOUNT_TO_MINT * 2001);
        uint256 AMOUNT_TO_REDEEM = 9 ether;
        uint256 AMOUNT_TO_BURN = 1 ether;
        uint256 expectedHealthFactor = dsce.calculateHealthFactor(
            AMOUNT_TO_MINT * 2001, dsce.getUsdValue(weth, AMOUNT_COLLATERAL - AMOUNT_TO_REDEEM)
        );

        dsc.approve(address(dsce), AMOUNT_TO_BURN);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakHealthFactor.selector, expectedHealthFactor));
        dsce.redeemCollateralForDsc(weth, AMOUNT_TO_REDEEM, AMOUNT_TO_BURN);

        vm.stopPrank();
    }

    function testBurnEnoughDscForRedeemingCollateral() public depositedAndMintedDsc {
        vm.startPrank(USER);

        dsce.mintDsc(AMOUNT_TO_MINT * 999);
        uint256 AMOUNT_TO_REDEEM = 9 ether;
        uint256 AMOUNT_TO_BURN = AMOUNT_TO_MINT;

        uint256 expectedHealthFactor = dsce.calculateHealthFactor(
            AMOUNT_TO_MINT * 999, dsce.getUsdValue(weth, AMOUNT_COLLATERAL - AMOUNT_TO_REDEEM)
        );
        // 1 ether -> $2000 -> we can borrow only $1000 max
        console.log(expectedHealthFactor);

        dsc.approve(address(dsce), AMOUNT_TO_BURN);
        dsce.redeemCollateralForDsc(weth, AMOUNT_TO_REDEEM, AMOUNT_TO_BURN);

        vm.stopPrank();
    }

    // TODO: liquidate test
    /////////////////////////////
    // liquidate Tests     //
    /////////////////////////////
}
