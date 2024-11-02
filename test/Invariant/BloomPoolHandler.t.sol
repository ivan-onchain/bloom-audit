// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.27;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {BloomPool} from "@bloom-v2/BloomPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import "../../src/interfaces/IOrderbook.sol";
import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {Tby} from "@bloom-v2/token/Tby.sol";

contract BloomPoolHandler is Test {
    BloomPool bloomPool;
    address[] lenders;
    address[] borrowers;
    MockERC20 asset;
    address marketMaker;
    address[] lendersToSwap;
    MockPriceFeed priceFeed;
    address owner;
    uint256 constant MIN_SWAP_OUT_PERCENT = 0.0025e18;
    uint256 constant WAD = 1e18;
    Tby tby;

    constructor(
        BloomPool _bloomPool,
        address[] memory _lenders,
        address[] memory _borrowers,
        MockERC20 _asset,
        address _marketMaker,
        MockPriceFeed _priceFeed,
        address _owner,
        Tby _tby
    ) {
        bloomPool = _bloomPool;
        lenders = _lenders;
        borrowers = _borrowers;
        asset = _asset;
        marketMaker = _marketMaker;
        priceFeed = _priceFeed;
        owner = _owner;
        tby = _tby;
    }

    function lenderOrder(uint8 lendersSeed, uint256 amount) public {
        address lender = lenders[lendersSeed % lenders.length];
        amount = bound(amount, 0, asset.balanceOf(lender));

        if (amount < 1) {
            return;
        }

        vm.startPrank(lender);
        asset.approve(address(bloomPool), amount);
        bloomPool.lendOrder(amount);
        vm.stopPrank();

        _checkContractBalanceInvariant();
    }

    function fillOrder(uint16 lendersSeed, uint16 borrowersSeed, uint256 amount) public {
        address lender = lenders[lendersSeed % lenders.length];

        uint256 lenderOpenOrder = bloomPool.amountOpen(lender);
        if (lenderOpenOrder == 0) {
            return;
        }
        address borrower = borrowers[borrowersSeed % borrowers.length];
        amount = bound(amount, 0, asset.balanceOf(borrower));

        if (amount < 1) {
            return;
        }

        vm.startPrank(borrower);
        asset.approve(address(bloomPool), amount);
        bloomPool.fillOrder(lender, amount);
        vm.stopPrank();
        _checkContractBalanceInvariant();
    }

    function swapIn(uint256 amount) public {
        delete lendersToSwap;

        amount = bound(amount, 1, type(uint256).max);
        // if (
        //     !_hastMatchOrderAmount(lenders[0]) ||
        //     !_hastMatchOrderAmount(lenders[1]) ||
        //     !_hastMatchOrderAmount(lenders[2]) ||
        //     !_hastMatchOrderAmount(lenders[3])
        //     // !_hastMatchOrderAmount(lenders[4])
        // ) {
        //     return;
        // }
        for (uint256 i = 0; i < lenders.length; i++) {
            if (_hastMatchOrderAmount(lenders[i])) {
                lendersToSwap.push(lenders[i]);
            }
        }
        if (lendersToSwap.length == 0) {
            return;
        }

        _setLatestRoundData();
        _increaseTimestamp(12 hours);

        vm.startPrank(marketMaker);
        bloomPool.swapIn(lenders, amount);
        vm.stopPrank();
    }

    function swapOut(uint256 amount, uint256 id) public {
        _increaseTimestamp(60 days);
        _setLatestRoundData();
        amount = bound(amount, 1, type(uint128).max);

        id = bound(id, 0, bloomPool.lastMintedId());
        uint128 endMaturity = bloomPool.tbyMaturity(id).end;
        // To avoid Errors.TBYNotMatured().
        if (endMaturity < 1 || (endMaturity > block.timestamp)) {
            return;
        }

        uint256 currentRwaAmount = bloomPool.tbyCollateral(id).currentRwaAmount;
        if (currentRwaAmount < 1) {
            return;
        }
        // To avoid Errors.SwapOutTooSmall()
        if (amount * WAD / currentRwaAmount < MIN_SWAP_OUT_PERCENT) {
            return;
        }

        if (tby.totalSupply(id) < 1) {
            return;
        }

        vm.startPrank(marketMaker);
        bloomPool.swapOut(id, amount);
        vm.stopPrank();
    }

    function redeemLender(uint256 id, uint16 lendersSeed, uint256 amount) public {
        id = bound(id, 0, bloomPool.lastMintedId());

        if (!bloomPool.isTbyRedeemable(id)) return;

        if (bloomPool.lenderReturns(id) < 1) return;

        address lender = lenders[lendersSeed % lenders.length];

        if (tby.balanceOf(lender, id) < 1) return;

        amount = bound(amount, 1, tby.balanceOf(lender, id));

        vm.startPrank(lender);
        bloomPool.redeemLender(id, amount);
        vm.stopPrank();
    }

    function _hastMatchOrderAmount(address lender) public view returns (bool) {
        uint256 matchOrderCount = bloomPool.matchedOrderCount(lender);

        if (matchOrderCount == 0) {
            return false;
        } else {
            for (uint256 j = 0; j < matchOrderCount; j++) {
                IOrderbook.MatchOrder memory matchOrder = bloomPool.matchedOrder(lender, j);
                if (matchOrder.lCollateral > 0) {
                    return true;
                }
            }
        }
    }

    function _setLatestRoundData() public {
        vm.startPrank(owner);
        priceFeed.setLatestRoundData(1, 110e8, 0, block.timestamp, 1);
        vm.stopPrank();
    }

    function _increaseTimestamp(uint256 increment) internal {
        // increment = uint32(bound(uint256(increment), 1 hours, 100 days));
        // console.log('block.timestamp: ', block.timestamp);

        // console.log('block.timestamp + increment: ', increment);

        vm.warp(block.timestamp + increment);
    }

    // This function is used for debugging.
    function _checkContractBalanceInvariant() public view {
        uint256 openDepth = bloomPool.openDepth();

        uint256 totalIdleCapitalBalance;
        for (uint256 i = 0; i < borrowers.length; i++) {
            totalIdleCapitalBalance += bloomPool.idleCapital(borrowers[i]);
        }

        uint128 totalLCollateral;
        uint128 totalBCollateral;

        IOrderbook.MatchOrder memory matchOrder;

        uint256 assetContractBalance = asset.balanceOf(address(bloomPool));

        uint256 matchOrderCount;
        for (uint256 i = 0; i < lenders.length; i++) {
            matchOrderCount = bloomPool.matchedOrderCount(lenders[i]);

            for (uint256 j = 0; j < matchOrderCount; j++) {
                matchOrder = bloomPool.matchedOrder(lenders[i], j);
                totalLCollateral += matchOrder.lCollateral;
                totalBCollateral += matchOrder.bCollateral;
            }
        }
        console.log("assetContractBalance: ", assetContractBalance);
        console.log("openDepth: ", openDepth);
        console.log("totalLCollateral: ", totalLCollateral);
        console.log("totalBCollateral: ", totalBCollateral);
        console.log("totalIdleCapitalBalance: ", totalIdleCapitalBalance);
        console.log(
            "ASSERT?:",
            assetContractBalance == openDepth + totalLCollateral + totalBCollateral + totalIdleCapitalBalance
        );
    }
}
