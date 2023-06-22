//SPDX-License-Identifier: MIT

//Allow WETH, WBTC, DAI as collateral
//Borrow rate APR 3%
//Supply rate APR 3%
//Protocol charges a flat percentage fee per transaction when user borrows (0.1%);
//Utilization rate from the time when user supplies and when they redeem
//average position of total protocol balance
//Total interest accumulated during period
//interest wil

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

pragma solidity 0.8.19;

contract Protocol is ReentrancyGuard {
    error Protocol__MustBeMoreThanZero();
    error Protocol__TokenAndPriceFeedDoNotMatch();
    error Protocol__ProtocolDoesNotSupportToken(address token);
    error Protocol__BreaksHealthFactor(uint256 userHealthFactor);
    error Protocol__ProtocolDoesNotHaveEnoughBalance();

    using OracleLib for AggregatorV3Interface;

    constructor(address[] memory token, address[] memory priceFeed) {
        if (token.length != priceFeed.length) {
            revert Protocol__TokenAndPriceFeedDoNotMatch();
        }
        for (uint256 i = 0; i < token.length; ++i) {
            s_priceFeeds[token[i]] = priceFeed[i];
            s_allowedTokens.push(token[i]);
        }
    }

    address[] public s_allowedTokens;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant TRANSACTION_FEE = 1000;
    uint256 private constant OPTIMAL_RATE = 45e18;
    uint256 private constant RATE_PRECISION = 100e18;
    uint256 private constant VARIABLE_RATE_SLOPE1 = 4;
    

    //Events

    event SuupliedCollateral(address indexed user, address indexed token, uint256 amount);
    event RedeemedCollateral(address indexed user, address indexed token, uint256 amount);
    event BorrowedToken(address indexed user, address indexed token, uint256 amount);

    mapping(address user => mapping(address token => uint256 balance)) private s_userCollateralBalance;
    mapping(address user => mapping(address token => uint256 balance)) private s_userBorrowAmount;
    mapping(address token => address priceFeed) private s_priceFeeds;

    //Modifiers

    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert Protocol__MustBeMoreThanZero();
        }
        _;
    }

    modifier validCollateralToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert Protocol__ProtocolDoesNotSupportToken(token);
        }
        _;
    }

    function supply(address token, uint256 amount)
        external
        moreThanZero(amount)
        validCollateralToken(token)
        nonReentrant
    {
        s_userCollateralBalance[msg.sender][token] += amount;

        //@notice this is to keep track of all collateral available to calculate utilization rate
        s_userCollateralBalance[address(this)][token] += amount;

        emit SuupliedCollateral(msg.sender, token, amount);
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }

    function borrow(address tokenToBorrow, uint256 amount)
        external
        moreThanZero(amount)
        validCollateralToken(tokenToBorrow)
        nonReentrant
    {
        revertIfProtocolBalanceNotEnough(tokenToBorrow, amount);

        s_userBorrowAmount[msg.sender][tokenToBorrow] += amount;

        uint256 transactionFee = amount / TRANSACTION_FEE; 

        s_userCollateralBalance[address(this)][tokenToBorrow] += transactionFee;

        emit BorrowedToken(msg.sender, tokenToBorrow, amount);
        IERC20(tokenToBorrow).transfer(msg.sender, amount - transactionFee);
    }

    function revertIfProtocolBalanceNotEnough(address token, uint256 amount) private view {
        uint256 availableBalanceInProtocol = getProtocolBalance(token);
        if (availableBalanceInProtocol < amount) {
            revert Protocol__ProtocolDoesNotHaveEnoughBalance();
        }
    }

    function redeemCollateral(address token, uint256 amount) external moreThanZero(amount) nonReentrant {
        s_userCollateralBalance[msg.sender][token] -= amount;

        emit RedeemedCollateral(msg.sender, token, amount);

        IERC20(token).transfer(msg.sender, amount);
    }

    function repay(address token, uint256 amount) external moreThanZero(amount) nonReentrant{

    }

    function repayAndRedeemCollateral() external {}

    function liquidate(address user, uint256 debtToCover) public {

    }

    // function healthFactor(address user) public {
    //     (uint256 totalBorrowAmountInUsd, uint256 collateralValueInUsd) = _getAccountInformation(user);

    //     return _calculateHealthFactor(totalBorrowAmountInUsd, collateralValueInUsd);
    // }

    // function _getAccountInformation(address user)
    //     private
    //     view
    //     returns (uint256 totalCollateralValueInUsd, uint256 totalBorrowValueInUsd)
    // {
    //     (totalCollateralValueInUsd, totalBorrowValueInUsd) = getAccountInformationInUsd(user);
    // }

    function _healthFactor(address user) private view returns (uint256) {
        //Total DSC minted
        //total collateral Value
        (uint256 totalCollateralValueInUsd, uint256 totalBorrowValueInUsd) = getAccountInformationInUsd(user);
        // return (collateralValueInUsd / totalDscMinted);
        return _calculateHealthFactor(totalBorrowValueInUsd, totalCollateralValueInUsd);
    }

    function _calculateHealthFactor(uint256 totalBorrowAmountInUsd, uint256 totalCollateralValueInUsd)
        private
        pure
        returns (uint256 healthFactor)
    {
        if (totalBorrowAmountInUsd == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (totalCollateralValueInUsd * LIQUIDATION_THRESHOLD) / 100;
        return (collateralAdjustedForThreshold * 1e18) / totalBorrowAmountInUsd;
    }

    function getAccountInformationInUsd(address user)
        public
        view
        returns (uint256 totalCollateralValueInUsd, uint256 totalBorrowValueInUsd)
    {
        for (uint256 i = 0; i < s_allowedTokens.length; ++i) {
            address token = s_allowedTokens[i];
            uint256 collateralAmount = s_userCollateralBalance[user][token];
            uint256 borrowAmount = s_userBorrowAmount[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, collateralAmount);
            totalBorrowValueInUsd += _getUsdValue(token, borrowAmount);
        }
    }

    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        //1 ETH = $1000
        //The returned value from CL will be 1000 *1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor <= MIN_HEALTH_FACTOR) {
            revert Protocol__BreaksHealthFactor(userHealthFactor);
        }
    }

    function getProtocolBalance(address token) private view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function getVariableRate(address token) private view returns(uint256 rate){
        (uint256 utilizationRate) = getTotalUtilization(token);
    
        
        if(utilizationRate <= OPTIMAL_RATE / RATE_PRECISION){
            return (utilizationRate/(OPTIMAL_RATE / RATE_PRECISION)) * (VARIABLE_RATE_SLOPE1 /RATE_PRECISION);
        }
    }

    //Total utilization = amount lended / total amount available in protocol
    function getTotalUtilization(address token) private view returns(uint256){
        uint256 avaialbleCollateral = getProtocolBalance(token);
        uint256 utilizedCollateral = s_userCollateralBalance[address(this)][token] - avaialbleCollateral;
        if(utilizedCollateral <= 0){
            return 0;
        }
        return ((utilizedCollateral * 100 ) / s_userCollateralBalance[address(this)][token]);
    }
}
