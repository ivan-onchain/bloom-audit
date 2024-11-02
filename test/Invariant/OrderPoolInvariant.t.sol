// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import "../../src/interfaces/IOrderbook.sol";
import {OrderBookHandler as Handler} from "./OrderBookHandler.t.sol";
import {BloomTestSetup} from "../BloomTestSetup.t.sol";

contract Invariant is StdInvariant, BloomTestSetup {
    uint256 INITIAL_LENDER_BALANCE = 100 ether;
    uint256 INITIAL_BORROWER_BALANCE = 100 ether;

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

        handler = new Handler(bloomPool, lenders, borrowers, stable);
        bytes4[] memory selectors = new bytes4[](6);

        selectors[0] = handler.lenderOrder.selector;
        selectors[1] = handler.fillOrder.selector;
        selectors[2] = handler.killOpenOrder.selector;
        selectors[3] = handler.killMatchOrder.selector;
        selectors[4] = handler.killBorrowerMatch.selector;
        selectors[5] = handler.withdrawIdleCapital.selector;

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
        console.log("openDepth: ", openDepth);
        console.log("totalLCollateral: ", totalLCollateral);
        console.log("totalBCollateral: ", totalBCollateral);
        console.log("totalIdleCapitalBalance: ", totalIdleCapitalBalance);

        assertEq(assetContractBalance, openDepth + totalLCollateral + totalBCollateral + totalIdleCapitalBalance);
    }

    function statefulFuzz_lendersOpenOrdersShouldBeEqualToOpenDepth() public view {
        uint256 totalLendersOpenOrders;
        for (uint256 i = 0; i < lenders.length; i++) {
            totalLendersOpenOrders += bloomPool.amountOpen(lenders[i]);
        }
        assertEq(
            totalLendersOpenOrders, bloomPool.openDepth(), " Total lenders OpenOrders is not equal to the open depth"
        );
    }

    function statefulFuzz_lendersMatchedAmountShouldBeEqualToMatchDepth() public view {
        uint256 totalLendersMatched;
        for (uint256 i = 0; i < lenders.length; i++) {
            totalLendersMatched += bloomPool.amountMatched(lenders[i]);
        }
        assertEq(
            totalLendersMatched,
            bloomPool.matchedDepth(),
            " Total lenders matched amount is not equal to the matched depth"
        );
    }

function statefulFuzz_totalBorrowDepositShouldBeEqualToMatchedAmountAndIdleCapital() public view {
        IOrderbook.MatchOrder memory matchOrder;

        for (uint256 iBorrower = 0; iBorrower < borrowers.length; iBorrower++) {
            address currentBorrower = borrowers[iBorrower];
            uint256 depositedAmount = INITIAL_BORROWER_BALANCE - stable.balanceOf(currentBorrower);
            uint256 idleCapital = bloomPool.idleCapital(currentBorrower);
            uint128 totalBCollateral;

            uint256 matchOrderCount;
            for (uint256 iLender = 0; iLender < lenders.length; iLender++) {
                matchOrderCount = bloomPool.matchedOrderCount(lenders[iLender]);

                for (uint256 j = 0; j < matchOrderCount; j++) {
                    matchOrder = bloomPool.matchedOrder(lenders[iLender], j);
                    if (matchOrder.borrower == currentBorrower) {
                    totalBCollateral += matchOrder.bCollateral;
                    }
                }
            }
            assertEq(depositedAmount, totalBCollateral + idleCapital,  'Total Deposited does not correspond' );
        }
    }
}
