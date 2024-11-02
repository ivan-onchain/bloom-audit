// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import "../../src/interfaces/IOrderbook.sol";
import {BloomPoolHandler as Handler}  from "./BloomPoolHandler.t.sol";
import {BloomTestSetup} from "../BloomTestSetup.t.sol";
import "../../src/interfaces/IBloomPool.sol";

contract BloomPoolInvariant is StdInvariant, BloomTestSetup {
    uint256 INITIAL_LENDER_BALANCE = 100 ether;
    uint256 INITIAL_BORROWER_BALANCE = 100 ether;

    uint256 initialAssetMarketMakerBalance;
    uint256 initialRwaMarketMakerBalance;

    uint256 finalAssetMarketMakerBalance;
    uint256 finalRwaMarketMakerBalance;


    address lender1 = makeAddr("lender1");
    address lender2 = makeAddr("lender2");
    address lender3 = makeAddr("lender3");
    address lender4 = makeAddr("lender4");
    address lender5 = makeAddr("lender5");

    address borrower1 = makeAddr("borrower1");
    address borrower2 = makeAddr("borrower2");
    address borrower3 = makeAddr("borrower3");
    address borrower4 = makeAddr("borrower4");
    address borrower5 = makeAddr("borrower5");

    Handler handler;

    function setUp() public override {
        super.setUp();
        initialAssetMarketMakerBalance = stable.balanceOf(marketMaker);
        lenders.push(lender1);
        lenders.push(lender2);
        lenders.push(lender3);
        lenders.push(lender4);
        lenders.push(lender5);

        for (uint256 i = 0; i < lenders.length; i++) {
            stable.mint(lenders[i], INITIAL_LENDER_BALANCE);
        }

        borrowers.push(borrower1);
        borrowers.push(borrower2);
        borrowers.push(borrower3);
        borrowers.push(borrower4);
        borrowers.push(borrower5);

        for (uint256 i = 0; i < borrowers.length; i++) {
            stable.mint(borrowers[i], INITIAL_BORROWER_BALANCE);
            vm.startPrank(owner);
            bloomPool.whitelistBorrower(borrowers[i], true);
            vm.stopPrank();
        }

        vm.startPrank(owner);
        bloomPool.whitelistMarketMaker(marketMaker, true);
        
        vm.startPrank(marketMaker);
        billToken.mint(marketMaker, type(uint256).max);
        billToken.approve(address(bloomPool), type(uint256).max);
        stable.approve(address(bloomPool), type(uint256).max);
        vm.stopPrank();

        initialRwaMarketMakerBalance = billToken.balanceOf(marketMaker);

        handler = new Handler(bloomPool, lenders, borrowers, stable, marketMaker, priceFeed, owner, tby);
        bytes4[] memory selectors = new bytes4[](4);

        selectors[0] = handler.lenderOrder.selector;
        selectors[1] = handler.fillOrder.selector;
        selectors[2] = handler.swapIn.selector;
        selectors[3] = handler.swapOut.selector;
        // selectors[4] = handler.redeemLender.selector;
        // selectors[5] = handler.withdrawIdleCapital.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function statefulFuzz_contractBalanceConsistency() public view {
        uint256 openDepth = bloomPool.openDepth();
        uint256 totalIdleCapitalBalance;
        for (uint256 i = 0; i < borrowers.length; i++) {
            totalIdleCapitalBalance += bloomPool.idleCapital(borrowers[i]);
        }

        uint128 totalLCollateral;
        uint128 totalBCollateral;

        IOrderbook.MatchOrder memory matchOrder;

        uint256 assetContractBalance = stable.balanceOf(address(bloomPool));

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
        console.log("openDepth: ", openDepth);
        console.log("totalLCollateral: ", totalLCollateral);
        console.log("totalBCollateral: ", totalBCollateral);
        console.log("totalIdleCapitalBalance: ", totalIdleCapitalBalance);

        assertEq(assetContractBalance, openDepth + totalLCollateral + totalBCollateral + totalIdleCapitalBalance);
    }

    function statefulFuzz_testAssetAndTBYBalanceConsistency() public view{
        uint256 assetMarketMakerBalance = stable.balanceOf(marketMaker) - initialAssetMarketMakerBalance;
        
        uint256 lastMintedId = bloomPool.lastMintedId();
        uint256 totalLendersReturn;
        uint256 totalBorrowersReturn;
        uint256 totalTbyLendersBalance;
        uint256 totalBorrowersBorrowed;
        console.log('lastMintedId: ', lastMintedId);
   

        if (lastMintedId == type(uint256).max) {
            return;
        }
        
        for (uint id = 0; id <= lastMintedId ; id++) {
            totalLendersReturn += bloomPool.lenderReturns(id);
            totalBorrowersReturn += bloomPool.borrowerReturns(id);
            for (uint i = 0; i < lenders.length; i++) {
                totalTbyLendersBalance += tby.balanceOf(lenders[i], id);
                totalBorrowersBorrowed += bloomPool.borrowerAmount(borrowers[i], id);

            }
        }

        console.log('assetMarketMakerBalance: ', assetMarketMakerBalance);
        console.log('totalLendersReturn: ', totalLendersReturn);
        console.log('totalBorrowersReturn: ', totalBorrowersReturn);
        console.log('totalTbyLendersBalance: ', totalTbyLendersBalance);
        console.log('totalBorrowersBorrowed: ', totalBorrowersBorrowed);
        console.log('totalTbyLendersBalance+totalBorrowersBorrowed: ', totalTbyLendersBalance+totalBorrowersBorrowed);
        

        assertEq(assetMarketMakerBalance + totalLendersReturn + totalBorrowersReturn, totalTbyLendersBalance + totalBorrowersBorrowed);
     }

     function statefulFuzz_testConsistencyOfRwaBalances() public {
        uint256 lastMintedId = bloomPool.lastMintedId();
        uint128 totalCurrentRwaAmount;

        if (lastMintedId == type(uint256).max) {
            return;
        }

        for (uint id = 0; id <= lastMintedId ; id++) {
            IBloomPool.TbyCollateral memory collateral = bloomPool.tbyCollateral(id);
            totalCurrentRwaAmount += collateral.currentRwaAmount;
        }

        finalRwaMarketMakerBalance = billToken.balanceOf(marketMaker);
        console.log('initialRwaMarketMakerBalance: ', initialRwaMarketMakerBalance);
        console.log('finalRwaMarketMakerBalance: ', finalRwaMarketMakerBalance);
        uint256 rwaMarketMakerMovement = initialRwaMarketMakerBalance - finalRwaMarketMakerBalance;
        assertEq(rwaMarketMakerMovement, totalCurrentRwaAmount );
     }


     function statefulFuzz_testConsistencyOfAssetBalance() public {
        uint256 lastMintedId = bloomPool.lastMintedId();
        uint128 totalAssetAmount;
        uint256 totalTbyLendersBalance;
        uint256 totalBorrowersBorrowed;

        if (lastMintedId == type(uint256).max) {
            return;
        }

        for (uint id = 0; id <= lastMintedId ; id++) {
            IBloomPool.TbyCollateral memory collateral = bloomPool.tbyCollateral(id);
            totalAssetAmount += collateral.assetAmount;
                for (uint i = 0; i < lenders.length; i++) {
                totalTbyLendersBalance += tby.balanceOf(lenders[i], id);
                totalBorrowersBorrowed += bloomPool.borrowerAmount(borrowers[i], id);
            }
        }

        finalAssetMarketMakerBalance = stable.balanceOf(marketMaker);
        console.log('finalAssetMarketMakerBalance: ', finalAssetMarketMakerBalance);
        console.log('totalAssetAmount: ', totalAssetAmount);
        console.log('totalTbyLendersBalance: ', totalTbyLendersBalance);
        console.log('totalBorrowersBorrowed: ', totalBorrowersBorrowed);
        
    
        assertEq(finalAssetMarketMakerBalance + totalAssetAmount, totalTbyLendersBalance + totalBorrowersBorrowed);

     }
}
