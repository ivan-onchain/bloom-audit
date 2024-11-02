# [H-1] Logic error in `Orderbook::_closeMatchOrders` function causes Loss of remaining collateral when removing exactly half of a Match Order.

## Summary
In the `Orderbook` contract, the `_closeMatchOrders` function contains a logic error that leads to lenders losing the remaining half of their collateral when they attempt to remove exactly 50% of a matched order.

## Finding Description.

When a lender calls killMatchOrder to partially close a matched order by removing an amount that is exactly half of matches[index].lCollateral, the function reduces matches[index].lCollateral by the amountToRemove. However, due to the specific condition used to determine whether to delete the MatchOrder, the function mistakenly deletes the entire MatchOrder even though there is still 50% of the collateral remaining.

## Impact Explanation

This not only results in direct financial loss for the lender but also affects the associated borrower, whose collateral (bCollateral) is also inadvertently deleted. The premature deletion of the MatchOrder breaks the expected contractual agreement between lenders and borrowers, damaging the protocol's reliability.

## Likelihood Explanation

Lenders frequently adjust their positions by exact fractions like 50% for risk management, rebalancing, or liquidity needs. This makes the scenario where a lender removes exactly half of their collateral a realistic and common action.

## PoC

This test creates three filled orders with Alice, each involving different borrowers, for amounts of 50 ether, 100 ether, and 100 ether respectively. Then, we attempt to kill matched orders with 150 ether. Since the filling order operates in a LIFO (Last-In, First-Out) manner, the order with index 2 is filled, and the order with index 1 should be filled at 50%. However, in this case, that order doesn't exist because it was deleted.

If you run the test, you will encounter a `panic: array out-of-bounds access (0x32)` error, which indicates that the order doesn't exist.

```js
    function testKillFiftyPercentOrder( ) public {
     
        uint256[3] memory orders;
        uint256 killAmount;
        orders[0] = 50e18;
        orders[1] = 100e18;
        orders[2] = 100e18;
        killAmount = 150e18;

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
```

## Recommendation.

It is recommended to store previous value of `matches[index].lCollateral` in a variable and then, after decreasing the values, 
check if the `previousLenderCollateral` is equal to the `amountToRemove`.

```diff
    function _closeMatchOrders(address account, uint256 amount) internal returns (uint256 totalRemoved) {
        MatchOrder[] storage matches = _userMatchedOrders[account];
        uint256 remainingAmount = amount;

        uint256 length = matches.length;
        for (uint256 i = length; i != 0; --i) {
            uint256 index = i - 1;

            // If the match order is already closed, remove it from the array
            if (matches[index].lCollateral == 0) {
                matches.pop();
                continue;
            }

            if (remainingAmount != 0) {
                uint256 amountToRemove = Math.min(remainingAmount, matches[index].lCollateral);
                uint256 borrowAmount = uint256(matches[index].bCollateral);
-               if (amountToRemove != matches[index].lCollateral) {
+               uint256 previousLenderCollateral = matches[index].lCollateral;
+               if (amountToRemove != previousLenderCollateral) {
                    borrowAmount = amountToRemove.divWad(_leverage);
                    matches[index].lCollateral -= uint128(amountToRemove);
                    matches[index].bCollateral -= uint128(borrowAmount);
                }
                   remainingAmount -= amountToRemove;
                _idleCapital[matches[index].borrower] += borrowAmount;
                emit MatchOrderKilled(account, matches[index].borrower, amountToRemove);
+               if (previousLenderCollateral == amountToRemove) matches.pop();
-               if (matches[index].lCollateral == amountToRemove) matches.pop();
            } else {
                break;
            }
        }
        totalRemoved = amount - remainingAmount;
        _matchedDepth -= totalRemoved;
    }
```


# [H-2]  Wrong MatchOrder deletion logic in the `Orderbook::_fillOrder` function.

## Finding Description

The `Orderbook::_fillOrder` function lacks a restriction to prevent the creation of new match orders when the userOpenOrder depth is zero. This absence allows for the creation of match orders with zero amounts (empty match orders). These empty match orders disrupt the logic in the `Orderbook::_closeMatchOrders` function, particularly when deleting (popping) match orders. This can lead to match orders with remaining amounts being erroneously deleted.

```js
    function _closeMatchOrders(address account, uint256 amount) internal returns (uint256 totalRemoved) {
        MatchOrder[] storage matches = _userMatchedOrders[account];
        uint256 remainingAmount = amount;

        uint256 length = matches.length;
        for (uint256 i = length; i != 0; --i) {
            uint256 index = i - 1;

            // If the match order is already closed, remove it from the array
@>           if (matches[index].lCollateral == 0) {
@>               matches.pop();
                continue;
            }

```
When a lender has two match orders —one with empty values and another with a balance— the function processes the last one (the one with a balance) first, followed by the empty one. Since the empty match order has lCollateral equal to 0, the matches.pop() operation removes the last match order, which is the one with the remaining balance.

Refer to the Proof of Concept (PoC) section for detailed information.


## Impact Explanation

This vulnerability has a critical impact on user funds. The contract loses track of lender and borrower balances when a match order with a remaining balance is deleted by mistake, leading to potential loss of user funds.

## Likelihood Explanation

The likelihood is very high because anyone can create an empty match order at any time, either accidentally or with malicious intent, due to the lack of zero-value restrictions.

## PoC

Here is an step by step to proof the vulnerability

1. Borrower1 calls fundOrder function passing lender1 as param.
2. As lender1 does't have any open order a new match order is created with zero amount on-behalf of borrower1
3. Lender1 calls lenderOrder function with 40 ether as amount.
4. Borrower2 calls fundOrder passing lender1 and 40 ethers as params, so all the open order of lender1 is filled.At this point Lender1 has 2 MatchOrders, one for borrower1 with empty amount and a second one for borrower2 with balances.
5. Lender1 calls killMatchOrder function with 20 ether as amount. killMatchOrder calls internally _closeMatchOrders function which iterated from last matchOrder created to the first one. Therefore it start with the matchOrder of borrower2, decreased the balances and continue with the next matchOrder, the empty one.
it checks of lCollateral is zero, as it is tru, it pops up the last match order, which is the matchOrder with remaining value of borrower2.

Next test code performs the steps described above, paste in the BloomTestSetup.t.sol file and run it with `forge test --mt testIncorrectMatchOrderDeletionDueToEmptyMatchOrders`

```js

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
```


## Recommendation

Under the presence of empty match orders a recommendation could be make sure of deleting the match order with .lcollateral equal to zero, not just delete the last one. To do it you can shift the empty element of the matches array to the left and finally pop it up. Below you can see how to do it.

```diff
 function _closeMatchOrders(address account, uint256 amount) internal returns (uint256 totalRemoved) {
        MatchOrder[] storage matches = _userMatchedOrders[account];
        uint256 remainingAmount = amount;

        uint256 length = matches.length;
        for (uint256 i = length; i != 0; --i) {
            uint256 index = i - 1;

            // If the match order is already closed, remove it from the array
            if (matches[index].lCollateral == 0) {
+                // Shift the elements to the left from the index
+               for (uint j = index; j < matches.length - 1; j++) {
+                   matches[j] = matches[j + 1];
+               }
                matches.pop();
                continue;
            }
```

# [H-3] Lack of restriction for the creation of match orders with empty values in the `Orderbook::_fillOrder` function.

## Finding Description

The Orderbook::_fillOrder function does not prevent the creation of new match orders when the userOpenOrder depth is zero. This omission allows match orders with zero amounts (empty match orders) to be created

```js
  function _fillOrder(address account, uint256 amount) internal returns (uint256 filled, uint256 borrowAmount) {
        require(account != address(0), Errors.ZeroAddress());
        _amountZeroCheck(amount);

        uint256 orderDepth = _userOpenOrder[account];
  
        
        // @audit filled is going to be zero if orderDepth is zero, so that MatchOrder will have zero values.
@>      filled = Math.min(orderDepth, amount);
        _openDepth -= filled;
        _matchedDepth += filled;
        _userOpenOrder[account] -= filled;

        borrowAmount = filled.divWad(_leverage);

```
This can lead to several issues, including wasted storage, increased gas costs, unexpected contract behavior like DoS, etc.


## Impact Explanation

Empty match orders continue to occupy space in the matches array, causing iteration over a large number of empty entries to consume unnecessary gas. Also it could lead into a potential denial of service attack by filling the array with empty match orders (if permitted by the contract logic), causing legitimate transactions to exceed gas limits and potentially fail.

## Likelihood Explanation

The likelihood is very high because anyone can create an empty match order at any time, either accidentally or with malicious intent, due to the lack of zero-value restrictions.

## PoC

Here is an step by step to proof the vulnerability

1. Borrower1 calls fundOrder function passing lender1 as param.
2. As lender1 does't have any open order a new match order is created with zero amount on-behalf of borrower1

```js

    function testCreatingEmptyMatchOrders() public{
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
    }
```

## Recommendation

Add a restriction that no match order can be created if that specific lender don't have any open order amount.

```diff
function _fillOrder(address account, uint256 amount) internal returns (uint256 filled, uint256 borrowAmount) {
        require(account != address(0), Errors.ZeroAddress());
        _amountZeroCheck(amount);

        uint256 orderDepth = _userOpenOrder[account];
+       require(orderDepth > 0, Errors.ZeroOpenOrderAmount());
```


# [H-4] The `Orderbook::killBorrowerMatch` function allows match order with zero values which leads on unexpected contract behavior.

## Finding Description

The `Orderbook::killBorrowerMatch` function set zero values to match orders, resulting in lenders with empty match order. These empty match orders can lead to several issues, including wasted storage, increased gas costs, unexpected contract behavior like DoS, etc.

```js
    function killBorrowerMatch(address lender) external returns (uint256 lenderAmount, uint256 borrowerReturn) {
        MatchOrder[] storage matches = _userMatchedOrders[lender];

        uint256 len = matches.length;
        for (uint256 i = 0; i != len; ++i) {
            if (matches[i].borrower == msg.sender) {

               
                lenderAmount = uint256(matches[i].lCollateral);
                borrowerReturn = uint256(matches[i].bCollateral);

@>              matches[i].lCollateral = 0;
@>              matches[i].bCollateral = 0;
                // Decrement the matched depth and open move the lenders collateral to an open order.
                _matchedDepth -= lenderAmount;
                _openOrder(lender, lenderAmount);
                break;
            }
        }
        emit MatchOrderKilled(lender, msg.sender, lenderAmount);
        IERC20(_asset).safeTransfer(msg.sender, borrowerReturn);
    }

```
The `OrderBook::_closeMatchOrders` function integrates a mechanism to delete the matched orders with zero value, which look for sweep the contract of empty math order, which is right in term of security. Therefore we need to avoid it.


## Impact Explanation

Empty match orders continue to occupy space in the matches array, causing iteration over a large number of empty entries to consume unnecessary gas. Also it could lead into a potential denial of service attack by filling the array with empty match orders (if permitted by the contract logic), causing legitimate transactions to exceed gas limits and potentially fail. Therefore, we must avoid having empty match orders at all costs.

## Likelihood Explanation

This will happen every time `OrderBook::killBorrowerMatch` function is called

## PoC

Run next code snippet into the `BloomTestSetup.t.sol` file

Here you can verify that after `killBorrowerMatch` is called the match order will remain with zero amount, so an empty matched order.

```js
    function testCreationOfEmptyOrdersWhenKillBorrowerMatchCalled() public{
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
    }
```

## Recommendation

Instead of set zero values to the match order, the code should delete it.
Here is a recommendation about how to do it.

```diff
    function killBorrowerMatch(address lender) external returns (uint256 lenderAmount, uint256 borrowerReturn) {
        MatchOrder[] storage matches = _userMatchedOrders[lender];

        uint256 len = matches.length;
        for (uint256 i = 0; i != len; ++i) {
            if (matches[i].borrower == msg.sender) {
                lenderAmount = uint256(matches[i].lCollateral);
                borrowerReturn = uint256(matches[i].bCollateral);

+               // Shift the elements to the left from the index
+               for (uint j = i; j < matches.length - 1; j++) {
+                    matches[j] = matches[j + 1];
+               }

+               // Remove the last element (which is now duplicated)
+               matches.pop();

-               matches[i].lCollateral = 0;
-               matches[i].bCollateral = 0;
                // Decrement the matched depth and open move the lenders collateral to an open order.
                _matchedDepth -= lenderAmount;
                _openOrder(lender, lenderAmount);
                break;
            }
        }
```
# [H-5] Wrong MatchOrder deletion logic in the `BloomPool::_convertMatchOrders` function.

## Finding Description

The `BloomPool::_convertMatchOrders` function delete match orders assuming the last one is the only one with empty values.

```js
    function _convertMatchOrders(uint256 id, address account, uint256 amount) internal returns (uint256 amountUsed) {
        MatchOrder[] storage matches = _userMatchedOrders[account];
        uint256 remainingAmount = amount;
        uint256 borrowerAmountConverted = 0;

        uint256 length = matches.length;
        for (uint256 i = length; i != 0; --i) {
            uint256 index = i - 1;

            if (remainingAmount != 0) {
                // If the match order is already closed by the borrower, skip it
                if (matches[index].lCollateral == 0) {
@>                    matches.pop();
                    continue;
                }

```
When a lender has two match orders —one with empty values and another with a balance— the function processes the last one (the one with a balance) first, followed by the empty one. Since the empty match order has lCollateral equal to 0, the matches.pop() operation removes the last match order, which is the one with the remaining balance.

## Impact Explanation

This vulnerability has a critical impact on user funds. The contract loses track of lender and borrower balances when a match order with a remaining balance is deleted by mistake, leading to potential loss of user funds.

## Likelihood Explanation

The likelihood is high because, in several parts of the project's code, there are no restrictions against empty match orders, or they are even intentionally created. You can refer to findings #751 and #754 for examples of how the code allows empty match orders

## PoC

Refer to the PoC of the finding #748 that show the same logic to remove an order in the `OrderBook` contract incurs in a wrong order deletion. 

## Recommendation

Here the recommendation is the same recommendation show in the finding # basically under the presence of empty match orders make sure of deleting the match order with .lcollateral equal to zero, not just delete the last one. To do it you can shift the empty element of the matches array to the left and finally pop it up. Below you can see how to do it.

```diff
    function _convertMatchOrders(uint256 id, address account, uint256 amount) internal returns (uint256 amountUsed) {
        MatchOrder[] storage matches = _userMatchedOrders[account];
        uint256 remainingAmount = amount;
        uint256 borrowerAmountConverted = 0;

        uint256 length = matches.length;
        for (uint256 i = length; i != 0; --i) {
            uint256 index = i - 1;

            if (remainingAmount != 0) {
                // If the match order is already closed by the borrower, skip it
                if (matches[index].lCollateral == 0) {
+                   // Shift the elements to the left from the index
+                   for (uint j = index; j < matches.length - 1; j++) {
+                      matches[j] = matches[j + 1];
+                  }
                    matches.pop();
                    continue;
                }
```


# [H-6] Underflow Vulnerability in `BloomPool::swapOut` Function Due to Premature Rounding Prevents Market Makers of Swapping Out'

## Summary

A vulnerability has been identified in the swapOut function of the BloomPool contract, where arbitrary rounding up in the calculation of tbyAmount leads to scenarios where lenderReturn exceeds assetAmount by 1 unit. This discrepancy causes an underflow error when computing borrowerReturn as assetAmount - lenderReturn, resulting in transaction reverts.

## Description

In the swapOut function, the calculation of tbyAmount uses the mulWadUp function, which rounds up the result:

```js
uint256 tbyAmount = percentSwapped != Math.WAD ? tbyTotalSupply.mulWadUp(percentSwapped) : tbyTotalSupply;
```

When percentSwapped is a small fraction, this rounding up causes tbyAmount to increase from 0 to 1 arbitrarily. Consequently, the lenderReturn calculated using this inflated tbyAmount becomes greater than the assetAmount, greater in 1 unit when the scenario of the issue happens. When assetAmount is small or zero (due to scaling and rounding), subtracting a lenderReturn that is greater by 1 unit leads to an underflow error:

```js
uint256 borrowerReturn = assetAmount - lenderReturn; // Underflow if lenderReturn > assetAmount
```
Check a very detail walk thought of this vulnerability in the PoC section to get the entire picture of the issue.

## Impact Explanation

This error prevents successful execution of swapOut transactions for a range of common values, leading to frequent transaction failures. This block users'(lenders, borrowers)ability to redeem their investments , directly affecting their financial activities.
Also, continuous operational failures can damage the protocol's reputation in the community. This may stop new users from joining and encourage existing users to look for alternative platforms, impacting the protocol's growth and sustainability.


## Likelihood Explanation:

Stateful fuzz testing has demonstrated that the underflow error arises with multiple combinations of lenderReturn and assetAmount, such as (3 and 4), (6 and 7), (14 and 15), (47 and 18), respectively. Therefore the error can manifest under various conditions, making it a systemic problem rather than an isolated edge case. This increases the probability of market makers be blocked to swap out,  which is a key protocol interaction.

## PoC

This vulnerability was discovered through stateful fuzz tests conducted using Foundry. The following values were obtained from these tests; therefore, consider them to recreate the failure scenario.

```js

collateral.currentRwaAmount = 63636363637
rwaAmount=508542456
collateral.originalRwaAmount=63636363637
tbyTotalSupply=7
rwaPrice.startPrice=110e18
currentPrice= 120e18
tbySpread=0.995e18

uint256 percentSwapped = rwaAmount.divWad(collateral.originalRwaAmount)=7991381451348657
uint256 percentSwapped = 508542456 * 63636363637 / 1e18 =7991381451348657

uint256 tbyAmount = tbyTotalSupply.mulWadUp(percentSwapped)
tbyAmount = 7 * 7991381451348657/Wad = 55939670159440599/1e18 =0.055939670159440599e18/1e18=0
Then rounding up tbyAmount = 1.

lenderReturn = getRate(id).mulWad(tbyAmount);

uint256 rate = (uint256(currentPrice).divWad(uint256(rwaPrice.startPrice))) = 120e18 * Wad /110e18 = 1.090909090909090909e18
uint256 yield = rate - Math.WAD = 1.090909090909090909e18-1e18 = 90909090909090909 = 0.090909090909090909e18
_takeSpread(rate, rwaPrice.spread);
_takeSpread() = Math.WAD + yield.mulWad(tbySpread) = 1e18 + 0.090909090909090909e18 * 0.995e18 / 1e18 = 1e18 + 90454545454545454
_takeSpread()=1.090454545454545454e18
getRate(id) = 1.090454545454545454e18

lenderReturn = getRate(id).mulWad(tbyAmount);
lenderReturn = 1.090454545454545454e18 * 1 / Wad = 1.090454545454545454e18 * 1 / 1e18 = 1.090454545454545454 = 1;

assetAmount = uint256(currentPrice).mulWadUp(rwaAmount) / (10 ** ((18 - _rwaDecimals) + (18 - _assetDecimals)));

assetAmount= (120e18 * 508542456 / Wad) / 10e(18-18 + 18-6) = (120e18 * 508542456 / 1e18) / 1e12 = 120*508542456/1e12
assetAmount=  0.061025094720e12/1e12 =  0.061025094720 = 0

uint256 borrowerReturn = assetAmount - lenderReturn = 0 - 1 => 'panic: arithmetic underflow or overflow'

```

## Recommendation

This solution worked successfully after more than 10,000 runs through the stateful fuzz testing suite; therefore, I am very confident in its effectiveness.

In general terms, the solution involves postponing the division by WAD until the lenderReturn calculation. This approach avoids forcing an early rounding up of tbyAmount, allowing the rounding to occur after the rate calculation.

TODO: Add the link of the repo with the invariant tests

```diff
       uint256 percentSwapped = rwaAmount.divWad(collateral.originalRwaAmount);
       uint256 percentOfLiquidity = rwaAmount.divWad(collateral.currentRwaAmount);
       require(percentOfLiquidity >= MIN_SWAP_OUT_PERCENT, Errors.SwapOutTooSmall());
       uint256 tbyTotalSupply = _tby.totalSupply(id);
        
++     uint256 tbyAmount = percentSwapped != Math.WAD ? tbyTotalSupply.rawMul(percentSwapped) : tbyTotalSupply;
--     uint256 tbyAmount = percentSwapped != Math.WAD ? tbyTotalSupply.mulWadUp(percentSwapped) : tbyTotalSupply;
  
        require(tbyAmount > 0, Errors.ZeroAmount());


        // Calculate the amount of assets that will be swapped out.
        assetAmount = uint256(currentPrice).mulWadUp(rwaAmount) / (10 ** ((18 - _rwaDecimals) + (18 - _assetDecimals)));

++      uint256 lenderReturn = getRate(id).mulWad(tbyAmount).mulWad(1);
--      uint256 lenderReturn = getRate(id).mulWad(tbyAmount);

```

Here the PoC but with the fix changes:

```js 
collateral.currentRwaAmount = 63636363637
rwaAmount=508542456
collateral.originalRwaAmount=63636363637
tbyTotalSupply=7
rwaPrice.startPrice=110e18
currentPrice= 120e18
tbySpread=0.995e18

uint256 percentSwapped = rwaAmount.divWad(collateral.originalRwaAmount)=7991381451348657
uint256 percentSwapped = 508542456 * 63636363637 / 1e18 =7991381451348657
//Here is the fix
uint256 tbyAmount = tbyTotalSupply.rawMul(percentSwapped)
tbyAmount = 7 * 7991381451348657/Wad = 55939670159440599
//Here is the fix
lenderReturn = getRate(id).mulWad(tbyAmount).mulWad(1);

uint256 rate = (uint256(currentPrice).divWad(uint256(rwaPrice.startPrice))) = 120e18 * Wad /110e18 = 1.090909090909090909e18
uint256 yield = rate - Math.WAD = 1.090909090909090909e18-1e18 = 90909090909090909 = 0.090909090909090909e18
_takeSpread(rate, rwaPrice.spread);
_takeSpread() = Math.WAD + yield.mulWad(tbySpread) = 1e18 + 0.090909090909090909e18 * 0.995e18 / 1e18 = 1e18 + 90454545454545454
_takeSpread()=1.090454545454545454e18
getRate(id) = 1.090454545454545454e18

lenderReturn = getRate(id).mulWad(tbyAmount).mulWad(1);
lenderReturn = 1.090454545454545454e18 * 55939670159440599 / Wad * 1 / Wad 
lenderReturn = 1.090454545454545454e18 * 55939670159440599 / 1e18 * 1 / Wad
lenderReturn = 1.090454545454545454 * 55939670159440599 * 1 / Wad
lenderReturn = 0.60999667596589998e18 * 1 / 1e18
lenderReturn = 0.60999667596589998 = 0

assetAmount = uint256(currentPrice).mulWadUp(rwaAmount) / (10 ** ((18 - _rwaDecimals) + (18 - _assetDecimals)));

assetAmount= (120e18 * 508542456 / Wad) / 10e(18-18 + 18-6) = (120e18 * 508542456 / 1e18) / 1e12 = 120*508542456/1e12
assetAmount=  0.061025094720e12/1e12 =  0.061025094720 = 0

uint256 borrowerReturn = assetAmount - lenderReturn = 0 - 0 = 0
```

# [H-7] DOS in `BloomPool::swapOut` function due to `percentSwapped` is rounded down to zero when currentRwaAmount is significantly smaller than collateral.originalRwaAmount.

## Description

A critical vulnerability exists in the `BloomPool::swapOut` function, when the currentRwaAmount is significantly smaller than the collateral.originalRwaAmount, the calculation of percentSwapped rounds down to zero due to solidity doesn't support decimals. Consequently, tbyAmount becomes zero, causing the require(tbyAmount > 0) check to fail. This prevents the market maker from swapping out the remaining collateral and setting the TBY as redeemable. As a result, lenders and borrowers are unable to redeem their funds, effectively locking their assets in the contract indefinitely.
Further details in the PoC section.


## Impact Explanation

n the scenario where the currentRwaAmount is significantly smaller than the collateral.originalRwaAmount, the Market Maker cannot finish swapping out all the RWA collateral. Consequently, they are unable to set the TBY as redeemable. This results in lenders and borrowers being unable to redeem their funds because their assets remain locked within the contract.

## Likelihood Explanation

This issue is likely to occur during normal protocol operations, especially as the currentRwaAmount decreases over time with successive swaps. In scenarios where only a small amount of collateral remains (e.g., the last swap to empty the collateral), percentSwapped can round down to zero.

## PoC

```js
// Here is a PoC with values got from the logs of stateful fuzz test logs
//TODO: Add repo link with the invariant tests

collateral.currentRwaAmount= 1
collateral.originalRwaAmount= 241968302496070606227272727274 [2.419e29]
tbyTotalSupply= 26094620857419379104
rwaAmount= 1

percentSwapped = rwaAmount.divWad(collateral.originalRwaAmount)
percentSwapped = 1 * wad / 2.419e29 = 1 * 1e18 / 241968302496.070606e18 = 1 / 241968302496.070606 = 0

tbyAmount = tbyTotalSupply.mulWadUp(percentSwapped) 
tbyAmount =26094620857419379104 * 0 / Wad = 0

// Then there is this requirement
require(tbyAmount > 0, Errors.ZeroAmount());


//Same scenario can happen with these values

collateral.currentRwaAmount= 100

collateral.originalRwaAmount= 1000e18 

rwaAmount= 100

tbyTotalSupply= 20e18

percentSwapped = rwaAmount.divWad(collateral.originalRwaAmount)
percentSwapped = 100 * wad / 1000e18 = 100 * 1e18 / 1000e18= 100 / 1000 = 0.1=0

tbyAmount = tbyTotalSupply.mulWadUp(percentSwapped) 
tbyAmount = 20e18 * 0 / Wad = 0
```

## Recommendation

A possible action could be handling of minimal collateral cases, for example,  a mechanism to handle the final portion of collateral, ensuring it can be swapped out regardless of size, therefore if currentRwaAmount is less than a certain threshold, allow a special case to process the swap.


# [H-i] 

## Summary

## Description

## Impact Explanation

## Likelihood Explanation:

## Poc

## Recommendation