// SPDX-License-Identifier: MIT
/*
██████╗░██╗░░░░░░█████╗░░█████╗░███╗░░░███╗
██╔══██╗██║░░░░░██╔══██╗██╔══██╗████╗░████║
██████╦╝██║░░░░░██║░░██║██║░░██║██╔████╔██║
██╔══██╗██║░░░░░██║░░██║██║░░██║██║╚██╔╝██║
██████╦╝███████╗╚█████╔╝╚█████╔╝██║░╚═╝░██║
╚═════╝░╚══════╝░╚════╝░░╚════╝░╚═╝░░░░░╚═╝
*/
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib as FpMath} from "@solady/utils/FixedPointMathLib.sol";

import {BloomPool} from "@bloom-v2/BloomPool.sol";
import {Tby} from "@bloom-v2/token/Tby.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";
import "../src/interfaces/IOrderbook.sol";
import {console} from "forge-std/console.sol";

abstract contract BloomTestSetup is Test {
    using FpMath for uint256;

    BloomPool internal bloomPool;
    Tby internal tby;
    MockERC20 internal stable;
    MockERC20 internal billToken;
    MockPriceFeed internal priceFeed;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal borrower = makeAddr("borrower");
    address internal marketMaker = makeAddr("marketMaker");
    address internal rando = makeAddr("rando");

    uint256 internal initialLeverage = 50e18;
    uint256 internal initialSpread = 0.995e18;

    address[] public lenders;
    address[] public borrowers;
    address[] public filledOrders;
    uint256[] public filledAmounts;

    function setUp() public virtual {
        stable = new MockERC20("Mock USDC", "USDC", 6);
        billToken = new MockERC20("Mock T-Bill Token", "bIb01", 18);

        // Start at a non-0 block timestamp
        skip(1 weeks);

        vm.startPrank(owner);
        priceFeed = new MockPriceFeed(8);
        priceFeed.setLatestRoundData(1, 110e8, 0, block.timestamp, 1);

        bloomPool = new BloomPool(
            address(stable), address(billToken), address(priceFeed), 1 days, initialLeverage, initialSpread, owner
        );
        vm.stopPrank();

        tby = Tby(bloomPool.tby());
        assertNotEq(address(bloomPool), address(0));
    }

    function testKillFiftyPercentOrder( ) public {
     
        uint256[3] memory orders;
        uint256 killAmount;
        orders[0] = 50e18;
        orders[1] = 100e18;
        orders[2] = 100e18;
        killAmount = 140e18;

        address borrower2 = makeAddr("borrower2");
        address borrower3 = makeAddr("borrower3");

        vm.startPrank(owner);
        bloomPool.whitelistBorrower(borrower, true);
        bloomPool.whitelistBorrower(borrower2, true);
        bloomPool.whitelistBorrower(borrower3, true);
        vm.stopPrank();

        vm.startPrank(owner);
        bloomPool.whitelistBorrower(borrower2, true);
        bloomPool.whitelistBorrower(borrower3, true);

        stable.mint(borrower, orders[0].divWadUp(initialLeverage));
        stable.mint(borrower2, orders[1].divWadUp(initialLeverage));
        stable.mint(borrower3, orders[2].divWadUp(initialLeverage));

        // Create 3 filled orders with alice w/ 3 different borrowers
        _createLendOrder(alice, orders[0]);
        vm.startPrank(borrower);
        stable.approve(address(bloomPool), orders[0].divWadUp(initialLeverage));
        bloomPool.fillOrder(alice, orders[0]);
        _createLendOrder(alice, orders[1]);
        vm.startPrank(borrower2);
        stable.approve(address(bloomPool), orders[1].divWadUp(initialLeverage));
        bloomPool.fillOrder(alice, orders[1]);
        _createLendOrder(alice, orders[2]);
        vm.startPrank(borrower3);
        stable.approve(address(bloomPool), orders[2].divWadUp(initialLeverage));
        bloomPool.fillOrder(alice, orders[2]);

        vm.startPrank(alice);
        bloomPool.killMatchOrder(killAmount);

        assertEq(bloomPool.matchedOrder(alice, 1).lCollateral, 50e18);
    }

    function testIncorrectMatchOrderDeletionDueToEmptyMatchOrders() public{
        address lender1 = makeAddr("lender1");
        address borrower1 = makeAddr("borrower1");
        address borrower2 = makeAddr("borrower2");
        
        vm.startPrank(owner);
        bloomPool.whitelistBorrower(borrower1, true);
        bloomPool.whitelistBorrower(borrower2, true);
        stable.mint(borrower1, 100 ether);
        stable.mint(borrower2, 100 ether);
        stable.mint(lender1, 100 ether);
        // fillOrder without a previous lendOrder to create a matchOrder with zero amounts
        vm.startPrank(borrower1);
        bloomPool.fillOrder(lender1, 10 ether);
        IOrderbook.MatchOrder memory emptyMatchOrder = bloomPool.matchedOrder(lender1, 0);
        assertEq(emptyMatchOrder.lCollateral, 0);
        assertEq(emptyMatchOrder.bCollateral, 0);
        assertEq(emptyMatchOrder.borrower, borrower1);

       _createLendOrder(lender1, 40 ether);
        
        vm.startPrank(borrower2);
        stable.approve(address(bloomPool), 40 ether);
        bloomPool.fillOrder(lender1, 40 ether);

        vm.startPrank(lender1);
        bloomPool.killMatchOrder(20 ether);
        vm.stopPrank();

        // assertEq(stable.balanceOf(address(bloomPool)), 1.58e19);
        console.log('stable.balanceOf(address(bloomPool): ', stable.balanceOf(address(bloomPool)));
        
        IOrderbook.MatchOrder memory remainingMatchOrder = bloomPool.matchedOrder(lender1, 0);
        uint256 matchOrderCount = bloomPool.matchedOrderCount(lender1);
        // There is only one remaining match order with zero amount that correspond to borrower1.
        // Match order of borrower2 should have a least 20 ether of lCollateral but it was deleted by error.
        assertEq(matchOrderCount, 1);
        assertEq(remainingMatchOrder.lCollateral, 0);
        assertEq(remainingMatchOrder.bCollateral, 0);
        assertEq(remainingMatchOrder.borrower, borrower1);
    }

    function testIncorrectMatchOrderDeletionDueToEmptyMatchOrderProducedInKillBorrowerMatchFunction() public{
        address lender1 = makeAddr("lender1");
        address borrower1 = makeAddr("borrower1");
        address borrower2 = makeAddr("borrower2");
        
        vm.startPrank(owner);
        bloomPool.whitelistBorrower(borrower1, true);
        bloomPool.whitelistBorrower(borrower2, true);
        stable.mint(borrower1, 100 ether);
        stable.mint(borrower2, 100 ether);
        stable.mint(lender1, 100 ether);


       _createLendOrder(lender1, 40 ether);
        
        vm.startPrank(borrower1);
        stable.approve(address(bloomPool), 40 ether);
        bloomPool.fillOrder(lender1, 40 ether);
        vm.stopPrank();

        vm.startPrank(borrower1);
        bloomPool.killBorrowerMatch(lender1);
        vm.stopPrank();

        // After Borrower kill a match the match remains with zero balances(an empty match order).
        IOrderbook.MatchOrder memory emptyMatchOrder = bloomPool.matchedOrder(lender1, 0);
        assertEq(emptyMatchOrder.lCollateral, 0);
        assertEq(emptyMatchOrder.bCollateral, 0);
        assertEq(emptyMatchOrder.borrower, borrower1);

    
        vm.startPrank(borrower2);
        stable.approve(address(bloomPool), 40 ether);
        bloomPool.fillOrder(lender1, 40 ether);
        vm.stopPrank();

        vm.startPrank(lender1);
        bloomPool.killMatchOrder(20 ether);
        vm.stopPrank();

        IOrderbook.MatchOrder memory remainingMatchOrder = bloomPool.matchedOrder(lender1, 0);
        uint256 matchOrderCount = bloomPool.matchedOrderCount(lender1);
        // There is only one remaining match order with zero amount and that one belongs to borrower1.
        // Match order of borrower2 should have a least 20 ether of lCollateral but it was deleted by error.
        assertEq(matchOrderCount, 1);
        assertEq(remainingMatchOrder.lCollateral, 0);
        assertEq(remainingMatchOrder.bCollateral, 0);
        assertEq(remainingMatchOrder.borrower, borrower1);
    }

    function testSwapInConvertAllAmountInOneMatchOrder() public {
        address lender1 = makeAddr("lender1");
        address borrower1 = makeAddr("borrower1");
        address borrower2 = makeAddr("borrower2");
        
        vm.startPrank(owner);
        bloomPool.whitelistBorrower(borrower1, true);
        bloomPool.whitelistBorrower(borrower2, true);
        bloomPool.whitelistMarketMaker(marketMaker, true);
        stable.mint(borrower1, 100 ether);
        stable.mint(borrower2, 100 ether);
        stable.mint(lender1, 100 ether);

       _createLendOrder(lender1, 40 ether);
        
        vm.startPrank(borrower1);
        stable.approve(address(bloomPool), 20 ether);
        bloomPool.fillOrder(lender1, 20 ether);
        vm.stopPrank();

        vm.startPrank(borrower2);
        stable.approve(address(bloomPool), 10 ether);
        bloomPool.fillOrder(lender1, 10 ether);
        vm.stopPrank();

        uint256 stableAmount = 30 ether;
        (, int256 answer,,,) = priceFeed.latestRoundData();
        uint256 answerScaled = uint256(answer) * (10 ** (18 - priceFeed.decimals()));
        uint256 rwaAmount = (stableAmount * (10 ** (18 - stable.decimals()))).divWadUp(answerScaled);

        vm.startPrank(marketMaker);
        billToken.mint(marketMaker, rwaAmount);
        billToken.approve(address(bloomPool), rwaAmount);
        address[] memory _lenders = new address[](1);
        _lenders[0] = lender1;
        bloomPool.swapIn(_lenders, stableAmount);
        uint256 borrower1ConvertedAmount = bloomPool.borrowerAmount(borrower1, bloomPool.lastMintedId());
        console.log('borrower1ConvertedAmount: ', borrower1ConvertedAmount);
        uint256 borrower2ConvertedAmount = bloomPool.borrowerAmount(borrower2, bloomPool.lastMintedId());
        console.log('borrower2ConvertedAmount: ', borrower2ConvertedAmount);
        
    }

    function _createLendOrder(address account, uint256 amount) internal {
        stable.mint(account, amount);
        vm.startPrank(account);
        stable.approve(address(bloomPool), amount);
        bloomPool.lendOrder(amount);
        vm.stopPrank();
    }

    function _fillOrder(address lender, uint256 amount) internal returns (uint256 borrowAmount) {
        borrowAmount = amount.divWad(initialLeverage);
        stable.mint(borrower, borrowAmount);
        vm.startPrank(borrower);
        stable.approve(address(bloomPool), borrowAmount);
        bloomPool.fillOrder(lender, amount);
        vm.stopPrank();
    }

    function _swapIn(uint256 stableAmount) internal returns (uint256 id, uint256 assetAmount) {
        (, int256 answer,,,) = priceFeed.latestRoundData();
        uint256 answerScaled = uint256(answer) * (10 ** (18 - priceFeed.decimals()));
        uint256 rwaAmount = (stableAmount * (10 ** (18 - stable.decimals()))).divWadUp(answerScaled);

        vm.startPrank(marketMaker);
        billToken.mint(marketMaker, rwaAmount);
        billToken.approve(address(bloomPool), rwaAmount);
        return bloomPool.swapIn(lenders, stableAmount);
    }

    function _swapOut(uint256 id, uint256 stableAmount) internal returns (uint256 assetAmount) {
        (, int256 answer,,,) = priceFeed.latestRoundData();
        uint256 answerScaled = uint256(answer) * (10 ** (18 - priceFeed.decimals()));
        uint256 rwaAmount = (stableAmount * (10 ** (18 - stable.decimals()))).divWadUp(answerScaled);

        vm.startPrank(marketMaker);
        stable.mint(marketMaker, stableAmount);
        stable.approve(address(bloomPool), stableAmount);
        return bloomPool.swapOut(id, rwaAmount);
    }

    function _skipAndUpdatePrice(uint256 time, uint256 price, uint80 roundId) internal {
        vm.startPrank(owner);
        skip(time);
        priceFeed.setLatestRoundData(roundId, int256(price), block.timestamp, block.timestamp, roundId);
        vm.stopPrank();
    }

    function _fillOrderWithCustomBorrower(address lender, uint256 amount, address customBorrower)
        internal
        returns (uint256 borrowAmount)
    {
        borrowAmount = amount.divWad(initialLeverage);
        stable.mint(customBorrower, borrowAmount);
        vm.startPrank(customBorrower);
        stable.approve(address(bloomPool), borrowAmount);
        bloomPool.fillOrder(lender, amount);
        vm.stopPrank();
    }

    function _swapInWithCustomMarketMaker(uint256 stableAmount, address customMarketMaker)
        internal
        returns (uint256 id, uint256 assetAmount)
    {
        (, int256 answer,,,) = priceFeed.latestRoundData();
        uint256 answerScaled = uint256(answer) * (10 ** (18 - priceFeed.decimals()));
        uint256 rwaAmount = (stableAmount * (10 ** (18 - stable.decimals()))).divWadUp(answerScaled);

        vm.startPrank(customMarketMaker);
        billToken.mint(customMarketMaker, rwaAmount);
        billToken.approve(address(bloomPool), rwaAmount);
        return bloomPool.swapIn(lenders, stableAmount);
    }

    function _swapOutWithCustomMarketMaker(uint256 id, uint256 stableAmount, address customMarketMaker)
        internal
        returns (uint256 assetAmount)
    {
        (, int256 answer,,,) = priceFeed.latestRoundData();
        uint256 answerScaled = uint256(answer) * (10 ** (18 - priceFeed.decimals()));
        uint256 rwaAmount = (stableAmount * (10 ** (18 - stable.decimals()))).divWadUp(answerScaled);

        vm.startPrank(customMarketMaker);
        stable.mint(customMarketMaker, stableAmount);
        stable.approve(address(bloomPool), stableAmount);
        return bloomPool.swapOut(id, rwaAmount);
    }

    /// @notice Checks if a is equal to b with a 2 wei buffer. If A is less than b the call will return false.
    function _isEqualWithDust(uint256 a, uint256 b) internal pure returns (bool) {
        if (a >= b) {
            return a - b <= 1e2;
        } else {
            return false;
        }
    }
}
