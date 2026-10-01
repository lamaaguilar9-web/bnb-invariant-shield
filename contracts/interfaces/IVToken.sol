// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IVToken - Venus Protocol vToken Interface
interface IVToken {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function repayBorrow(uint256 repayAmount) external returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function balanceOfUnderlying(address owner) external returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function underlying() external view returns (address);
    function totalBorrows() external view returns (uint256);
    function getCash() external view returns (uint256);
}
