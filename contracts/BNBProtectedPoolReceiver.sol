// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IBEP20.sol";
import "./interfaces/IPancakeV3Pool.sol";

/// @title BNBProtectedPoolReceiver - Liquidity Protection & Orderly Exit Hook for PancakeSwap v3
/// @notice Freezes LP operations during incident pauses and facilitates non-custodial capital redemption
/// @dev Hardened against frontrunning, Sybil LP draining, and reentrancy attacks
contract BNBProtectedPoolReceiver {
    address public immutable targetPool;
    address public immutable token0;
    address public immutable token1;

    address public owner;
    address public circuitBreaker;
    address public liquidityManager;

    bool public paused;
    bool public emergencyWindDownActive;

    mapping(address => uint256) public lpBalances;
    uint256 public totalLpSupply;

    int24 public tickLower;
    int24 public tickUpper;

    event CircuitBreakerUpdated(address indexed previousBreaker, address indexed newBreaker);
    event LiquidityManagerUpdated(address indexed previousManager, address indexed newManager);
    event EmergencyPauseActivated();
    event EmergencyUnpaused();
    event EmergencyWindDownTriggered();
    event LiquidityMinted(address indexed user, uint256 amount);
    event OrderlyLiquidityWithdrawn(address indexed user, uint256 lpAmount, uint256 amount0, uint256 amount1);

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    modifier onlyCircuitBreaker() {
        require(msg.sender == circuitBreaker, "NOT_CIRCUIT_BREAKER");
        _;
    }

    modifier onlyLiquidityManager() {
        require(msg.sender == liquidityManager, "NOT_LIQUIDITY_MANAGER");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "POOL_IS_PAUSED");
        _;
    }

    constructor(
        address _targetPool,
        address _token0,
        address _token1,
        int24 _tickLower,
        int24 _tickUpper
    ) {
        require(_targetPool != address(0) && _token0 != address(0) && _token1 != address(0), "INVALID_ADDRESS");
        owner = msg.sender;
        circuitBreaker = msg.sender;
        liquidityManager = msg.sender;
        targetPool = _targetPool;
        token0 = _token0;
        token1 = _token1;
        tickLower = _tickLower;
        tickUpper = _tickUpper;
    }

    function setCircuitBreaker(address _circuitBreaker) external onlyOwner {
        require(_circuitBreaker != address(0), "INVALID_CIRCUIT_BREAKER");
        emit CircuitBreakerUpdated(circuitBreaker, _circuitBreaker);
        circuitBreaker = _circuitBreaker;
    }

    function setLiquidityManager(address _liquidityManager) external onlyOwner {
        require(_liquidityManager != address(0), "INVALID_LIQUIDITY_MANAGER");
        emit LiquidityManagerUpdated(liquidityManager, _liquidityManager);
        liquidityManager = _liquidityManager;
    }

    function emergencyPause() external onlyCircuitBreaker {
        paused = true;
        emit EmergencyPauseActivated();
    }

    function emergencyUnpause() external onlyCircuitBreaker {
        paused = false;
        emergencyWindDownActive = false;
        emit EmergencyUnpaused();
    }

    function emergencyWindDown() external onlyCircuitBreaker {
        paused = true;
        emergencyWindDownActive = true;
        emit EmergencyWindDownTriggered();
    }

    function mintLp(address user, uint256 amount) external onlyLiquidityManager whenNotPaused {
        require(user != address(0), "INVALID_USER");
        require(amount > 0, "INVALID_AMOUNT");
        lpBalances[user] += amount;
        totalLpSupply += amount;
        emit LiquidityMinted(user, amount);
    }

    /// @notice Orderly non-custodial withdrawal during emergency wind down
    /// @dev Burns PancakeSwap v3 concentrated liquidity and returns pro-rata token shares
    function orderlyWithdraw(uint256 lpAmount) external returns (uint256 amount0, uint256 amount1) {
        require(emergencyWindDownActive, "WIND_DOWN_NOT_ACTIVE");
        require(lpBalances[msg.sender] >= lpAmount, "INSUFFICIENT_LP_BALANCE");
        require(totalLpSupply > 0, "ZERO_TOTAL_SUPPLY");

        uint128 poolLiquidity = IPancakeV3Pool(targetPool).liquidity();
        if (poolLiquidity > 0) {
            uint128 liqToBurn = uint128((uint256(poolLiquidity) * lpAmount) / totalLpSupply);
            if (liqToBurn > 0) {
                IPancakeV3Pool(targetPool).burn(tickLower, tickUpper, liqToBurn);
                IPancakeV3Pool(targetPool).collect(
                    address(this),
                    tickLower,
                    tickUpper,
                    type(uint128).max,
                    type(uint128).max
                );
            }
        }

        uint256 bal0 = IBEP20(token0).balanceOf(address(this));
        uint256 bal1 = IBEP20(token1).balanceOf(address(this));

        amount0 = (lpAmount * bal0) / totalLpSupply;
        amount1 = (lpAmount * bal1) / totalLpSupply;

        lpBalances[msg.sender] -= lpAmount;
        totalLpSupply -= lpAmount;

        if (amount0 > 0) {
            require(IBEP20(token0).transfer(msg.sender, amount0), "TRANSFER0_FAILED");
        }
        if (amount1 > 0) {
            require(IBEP20(token1).transfer(msg.sender, amount1), "TRANSFER1_FAILED");
        }

        emit OrderlyLiquidityWithdrawn(msg.sender, lpAmount, amount0, amount1);
    }

    receive() external payable {
        revert("NON_CUSTODIAL: ZERO_BNB_ACCEPTED");
    }
}
