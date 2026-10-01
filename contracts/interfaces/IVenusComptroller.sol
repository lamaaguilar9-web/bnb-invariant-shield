// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IVenusComptroller - Venus Protocol Comptroller Interface on BNB Chain
interface IVenusComptroller {
    function isComptroller() external view returns (bool);
    function enterMarkets(address[] calldata vTokens) external returns (uint256[] memory);
    function exitMarket(address vToken) external returns (uint256);
    function getAccountLiquidity(address account) external view returns (uint256 error, uint256 liquidity, uint256 shortfall);
    function mintGuardianPaused(address vToken) external view returns (bool);
    function borrowGuardianPaused(address vToken) external view returns (bool);
    function _setMintPaused(address vToken, bool state) external returns (bool);
    function _setBorrowPaused(address vToken, bool state) external returns (bool);
}
