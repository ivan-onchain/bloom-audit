// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.27;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {BloomPool} from "@bloom-v2/BloomPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import "../../src/interfaces/IOrderbook.sol";

contract OrderBookHandler is Test {
    BloomPool bloomPool;
    address[] lenders;
    address[] borrowers;
    MockERC20 asset;

    constructor(BloomPool _bloomPool, address[] memory _lenders, address[] memory _borrowers, MockERC20 _asset) {
        bloomPool = _bloomPool;
        lenders = _lenders;
        borrowers = _borrowers;
        asset = _asset;
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

    function killOpenOrder(uint8 lendersSeed, uint256 amount) public {
        address lender = lenders[lendersSeed % lenders.length];
        uint256 lenderOpenOrder = bloomPool.amountOpen(lender);
        amount = bound(amount, 0, lenderOpenOrder);

        if (amount < 1) {
            return;
        }

        vm.startPrank(lender);
        bloomPool.killOpenOrder(amount);
        vm.stopPrank();
        _checkContractBalanceInvariant();
    }

    function killMatchOrder(uint8 lendersSeed, uint256 amount) public {
        address lender = lenders[lendersSeed % lenders.length];
        amount = bound(amount, 0, type(uint256).max);

        if (amount < 1) {
            return;
        }

        vm.startPrank(lender);
        bloomPool.killMatchOrder(amount);
        vm.stopPrank();
        _checkContractBalanceInvariant();

    }

    function killBorrowerMatch(uint16 lendersSeed, uint16 borrowersSeed) public {
        address lender = lenders[lendersSeed % lenders.length];

        uint256 lenderOpenOrder = bloomPool.amountOpen(lender);
        if (lenderOpenOrder == 0) {
            return;
        }
        address borrower = borrowers[borrowersSeed % borrowers.length];
        vm.startPrank(borrower);
        bloomPool.killBorrowerMatch(lender);
        vm.stopPrank();
        _checkContractBalanceInvariant();

    }


    function withdrawIdleCapital( uint16 borrowersSeed, uint256 amount) public {
        address borrower = borrowers[borrowersSeed % borrowers.length];
        amount = bound(amount, 0, bloomPool.idleCapital(borrower));

        if (amount < 1) {
            return;
        } 
        
        vm.startPrank(borrower);
        bloomPool.withdrawIdleCapital(amount);
        vm.stopPrank();
        _checkContractBalanceInvariant();
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
        console.log('assetContractBalance: ', assetContractBalance);
        console.log('openDepth: ', openDepth);
        console.log('totalLCollateral: ', totalLCollateral);
        console.log('totalBCollateral: ', totalBCollateral);
        console.log('totalIdleCapitalBalance: ', totalIdleCapitalBalance);
        console.log('ASSERT?:',assetContractBalance ==openDepth + totalLCollateral + totalBCollateral + totalIdleCapitalBalance );
    }
}
