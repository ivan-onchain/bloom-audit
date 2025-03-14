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

import {FixedPointMathLib as Math} from "@solady/utils/FixedPointMathLib.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BloomErrors as Errors} from "@bloom-v2/helpers/BloomErrors.sol";

import {PoolStorage} from "@bloom-v2/PoolStorage.sol";
import {IOrderbook} from "@bloom-v2/interfaces/IOrderbook.sol";
import {console} from "forge-std/console.sol";

/**
 * @title Orderbook
 * @notice An orderbook matching lender and borrower orders for RWA loans.
 */
abstract contract Orderbook is IOrderbook, PoolStorage {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*///////////////////////////////////////////////////////////////
                                Storage    
    //////////////////////////////////////////////////////////////*/

    /// @notice Current total depth of unfilled orders.
    uint256 private _openDepth;

    /// @notice Current total depth of matched orders.
    uint256 internal _matchedDepth;

    /// @notice Mapping of users to their open order amount.
    mapping(address => uint256) private _userOpenOrder;

    /// @notice Mapping of the user's matched orders.
    mapping(address => MatchOrder[]) internal _userMatchedOrders;

    /// @notice Mapping of borrower's to the amount of idle capital they have.
    mapping(address => uint256) private _idleCapital;

    /*///////////////////////////////////////////////////////////////
                            Constructor    
    //////////////////////////////////////////////////////////////*/

    constructor(address asset_, address rwa_, uint256 initLeverage, uint256 initSpread, address owner_)
        PoolStorage(asset_, rwa_, initLeverage, initSpread, owner_)
    {}

    /*///////////////////////////////////////////////////////////////
                            Functions    
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOrderbook
    function lendOrder(uint256 amount) external {
        _amountZeroCheck(amount);
        _openOrder(msg.sender, amount);
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @inheritdoc IOrderbook
    function fillOrder(address account, uint256 amount)
        external
        KycBorrower
        returns (uint256 filledAmount, uint256 borrowAmount)
    {
        (filledAmount, borrowAmount) = _fillOrder(account, amount);
        _depositBorrower(borrowAmount);
    }

    /// @inheritdoc IOrderbook
    function fillOrders(address[] memory accounts, uint256 amount)
        external
        KycBorrower
        returns (uint256 filledAmount, uint256 borrowAmount)
    {   
        // @audit if accounts array is empty, tx won't revert and borrower will believe he fill an order.
        uint256 len = accounts.length;
        for (uint256 i = 0; i != len; ++i) {
            (uint256 fillSize, uint256 borrowSize) = _fillOrder(accounts[i], amount);
            amount -= fillSize;
            filledAmount += fillSize;
            borrowAmount += borrowSize;
            if (amount == 0) break;
        }
        _depositBorrower(borrowAmount);
    }

    /// @inheritdoc IOrderbook
    function killOpenOrder(uint256 amount) external {
        uint256 orderDepth = _userOpenOrder[msg.sender];
        _amountZeroCheck(amount);
        require(amount <= orderDepth, Errors.InsufficientDepth());

        _userOpenOrder[msg.sender] -= amount;
        _openDepth -= amount;

        emit OpenOrderKilled(msg.sender, amount);
        IERC20(_asset).safeTransfer(msg.sender, amount);
    }

    /// @inheritdoc IOrderbook
    function killMatchOrder(uint256 amount) external returns (uint256 totalRemoved) {
        _amountZeroCheck(amount);
        // if the order is already matched we have to account for the borrower's who filled the order.
        // If you kill a match order and there are multiple borrowers, the order will be closed in a LIFO manner.
        totalRemoved = _closeMatchOrders(msg.sender, amount);
        IERC20(_asset).safeTransfer(msg.sender, totalRemoved);
    }

    /// @inheritdoc IOrderbook
    function killBorrowerMatch(address lender) external returns (uint256 lenderAmount, uint256 borrowerReturn) {
        MatchOrder[] storage matches = _userMatchedOrders[lender];

        uint256 len = matches.length;
        for (uint256 i = 0; i != len; ++i) {
            if (matches[i].borrower == msg.sender) {

               
                lenderAmount = uint256(matches[i].lCollateral);
                borrowerReturn = uint256(matches[i].bCollateral);
                // Zero out the collateral amounts of the match order to preserve the array's order
                // @audit FillOrder has a zero amount restriction, check how this can affect. Research about zero amount vulns
                 // Shift the elements to the left from the index
                // for (uint j = i; j < matches.length - 1; j++) {
                //     matches[j] = matches[j + 1];
                // }

                // Remove the last element (which is now duplicated)
                // matches.pop();

                matches[i].lCollateral = 0;
                matches[i].bCollateral = 0;
                // Decrement the matched depth and open move the lenders collateral to an open order.
                _matchedDepth -= lenderAmount;
                _openOrder(lender, lenderAmount);
                break;
            }
        }

        require(lenderAmount != 0, Errors.MatchOrderNotFound());
        emit MatchOrderKilled(lender, msg.sender, lenderAmount);
        // @audit research about re-entrance to see if there is a chance here.
        IERC20(_asset).safeTransfer(msg.sender, borrowerReturn);
    }

    /// @inheritdoc IOrderbook
    function withdrawIdleCapital(uint256 amount) external {
        address account = msg.sender;
        _amountZeroCheck(amount);

        uint256 idleFunds = _idleCapital[account];

        if (amount == type(uint256).max) {
            amount = idleFunds;
        } else {
            require(idleFunds >= amount, Errors.InsufficientBalance());
        }

        _idleCapital[account] -= amount;
        emit IdleCapitalWithdrawn(account, amount);
        IERC20(_asset).safeTransfer(account, amount);
    }

    /*///////////////////////////////////////////////////////////////
                            Internal Functions    
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fills an order with a specified amount of underlying assets
     * @param account The address of the order to fill
     * @param amount Amount of underlying assets of the order to fill
     */
    function _fillOrder(address account, uint256 amount) internal returns (uint256 filled, uint256 borrowAmount) {
        require(account != address(0), Errors.ZeroAddress());
        _amountZeroCheck(amount);

        uint256 orderDepth = _userOpenOrder[account];
        _amountZeroCheck(orderDepth);
        
        // @audit filled is going to be zero if orderDepth is zero, so that MatchOrder will have zero values.
        filled = Math.min(orderDepth, amount);
        _openDepth -= filled;
        _matchedDepth += filled;
        _userOpenOrder[account] -= filled;

        borrowAmount = filled.divWad(_leverage);

        MatchOrder[] storage matches = _userMatchedOrders[account];
        uint256 len = matches.length;

        for (uint256 i = 0; i != len; ++i) {
            if (matches[i].borrower == msg.sender) {
                matches[i].lCollateral += uint128(filled);
                matches[i].bCollateral += uint128(borrowAmount);
                emit OrderFilled(account, msg.sender, _leverage, filled);
                return (filled, borrowAmount);
            }
        }
        // @audit q: why 128 it can't be 256
        matches.push(
            MatchOrder({lCollateral: uint128(filled), bCollateral: uint128(borrowAmount), borrower: msg.sender})
        );
        emit OrderFilled(account, msg.sender, _leverage, filled);
    }

    /**
     * @notice Opens an order for the lender
     * @param lender The address of the lender
     * @param amount The amount of underlying assets to open the order
     */
    function _openOrder(address lender, uint256 amount) internal {
        _openDepth += amount;
        _userOpenOrder[lender] += amount;
        emit OrderCreated(lender, amount);
    }

    /**
     * @notice Deposits the leveraged matched amount of underlying assets from the borrower
     * @dev If the borrower has idle capital, it will be used to match the order first before depositing
     * @param amount Amount of underlying assets matched by the borrower
     */
    function _depositBorrower(uint256 amount) internal {
        amount = _utilizeIdleCapital(msg.sender, amount);
        require(IERC20(_asset).balanceOf(msg.sender) >= amount, Errors.InsufficientBalance());

        IERC20(_asset).safeTransferFrom(msg.sender, address(this), amount);
    }

    function _utilizeIdleCapital(address account, uint256 amount) internal returns (uint256) {
        uint256 idleUsed = Math.min(_idleCapital[account], amount);
        if (idleUsed > 0) {
            _idleCapital[account] -= idleUsed;
            //@audit if idleUsed == amount, amount will be zero. I heard some tokens can revert due to  zero values, research about this.
            amount -= idleUsed;
            emit IdleCapitalDecreased(account, idleUsed);
        }
        return amount;
    }

    /**
     * @notice Closes matched orders for the user
     * @dev Orders are closed in a LIFO manner
     * @param amount The amount of underlying assets to close the matched order
     * @return totalRemoved The amount for each borrower that was removed.
     */
    function _closeMatchOrders(address account, uint256 amount) internal returns (uint256 totalRemoved) {
        MatchOrder[] storage matches = _userMatchedOrders[account];
        uint256 remainingAmount = amount;

        uint256 length = matches.length;
        for (uint256 i = length; i != 0; --i) {
            uint256 index = i - 1;

            // If the match order is already closed, remove it from the array
            if (matches[index].lCollateral == 0) {
                 // Shift the elements to the left from the index
                for (uint j = index; j < matches.length - 1; j++) {
                    matches[j] = matches[j + 1];
                }
                matches.pop();
                continue;
            }

            if (remainingAmount != 0) {
                uint256 amountToRemove = Math.min(remainingAmount, matches[index].lCollateral);
                uint256 borrowAmount = uint256(matches[index].bCollateral);
                if (amountToRemove != matches[index].lCollateral) {
                    borrowAmount = amountToRemove.divWad(_leverage);
                    matches[index].lCollateral -= uint128(amountToRemove);
                    matches[index].bCollateral -= uint128(borrowAmount);
                }
        
                remainingAmount -= amountToRemove;
                _idleCapital[matches[index].borrower] += borrowAmount;
                emit MatchOrderKilled(account, matches[index].borrower, amountToRemove);
                if (matches[index].lCollateral == amountToRemove) matches.pop();
            } else {
                break;
            }
        }
        totalRemoved = amount - remainingAmount;
        _matchedDepth -= totalRemoved;
    }

    /**
     * @notice Checks if the amount is greater than zero
     * @param amount The amount of underlying assets to close the matched order
     */
    function _amountZeroCheck(uint256 amount) internal pure {
        require(amount > 0, Errors.ZeroAmount());
    }

    /*///////////////////////////////////////////////////////////////
                            View Functions    
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOrderbook
    function leverage() external view override returns (uint256) {
        return _leverage;
    }

    /// @inheritdoc IOrderbook
    function openDepth() external view returns (uint256) {
        return _openDepth;
    }

    /// @inheritdoc IOrderbook
    function matchedDepth() external view returns (uint256) {
        return _matchedDepth;
    }

    /// @inheritdoc IOrderbook
    function amountOpen(address account) external view returns (uint256) {
        return _userOpenOrder[account];
    }

    /// @inheritdoc IOrderbook
    function amountMatched(address account) external view returns (uint256 amount) {
        uint256 len = _userMatchedOrders[account].length;
        for (uint256 i = 0; i != len; ++i) {
            amount += _userMatchedOrders[account][i].lCollateral;
        }
    }

    /// @inheritdoc IOrderbook
    function matchedOrder(address account, uint256 index) external view returns (MatchOrder memory) {
        return _userMatchedOrders[account][index];
    }

    /// @inheritdoc IOrderbook
    function matchedOrderCount(address account) external view returns (uint256) {
        return _userMatchedOrders[account].length;
    }

    /// @inheritdoc IOrderbook
    function idleCapital(address account) external view returns (uint256) {
        return _idleCapital[account];
    }
}
