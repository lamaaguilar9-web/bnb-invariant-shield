// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IBEP20.sol";
import "./interfaces/IPancakeV3Pool.sol";

/// @title BNBProtectedPoolReceiver - Production-Grade Concentrated Liquidity Vault & Safe Exit Hook
/// @notice Manages PancakeSwap v3 LP positions with atomic circuit breaker pauses and non-custodial emergency wind-down
/// @dev Hardened against Reentrancy (H-R1), Global Liquidity Share Overburn (H-R2), Unbacked Mints (H-R3), Capital Evacuation (B-5), and Drift Deadlock (N-2)
contract BNBProtectedPoolReceiver is IPancakeV3MintCallback {
    address public immutable targetPool;
    address public immutable token0;
    address public immutable token1;

    address public owner;
    address public circuitBreaker;
    address public liquidityManager;

    bool public paused;
    bool public emergencyWindDownActive;
    bool private _locked;
    address private _activeMintPayer; // Pass 6: Guard against unauthorized mint callbacks

    // H-R2: Track receiver's OWN position liquidity (not global pool liquidity)
    uint128 public ownPositionLiquidity;
    uint128 public retreatedLiquidity; // B-5: Tracks liquidity evacuated into vault during active pause

    mapping(address => uint256) public lpBalances;
    uint256 public totalLpSupply;

    int24 public immutable tickLower;
    int24 public immutable tickUpper;

    event CircuitBreakerUpdated(address indexed previousBreaker, address indexed newBreaker);
    event LiquidityManagerUpdated(address indexed previousManager, address indexed newManager);
    event EmergencyPauseActivated();
    event EmergencyLiquidityRetreated(uint128 liquidityBurned);
    event LiquidityRestored(uint128 liquidityMinted);
    event EmergencyUnpaused();
    event EmergencyWindDownTriggered();
    event LiquidityDeposited(address indexed user, uint128 liquidityMinted, uint256 amount0Used, uint256 amount1Used);
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

    // H-R1: Formal ReentrancyGuard implementation
    modifier nonReentrant() {
        require(!_locked, "REENTRANCY_GUARD: REENTRANT_CALL");
        _locked = true;
        _;
        _locked = false;
    }

    constructor(
        address _targetPool,
        address _token0,
        address _token1,
        int24 _tickLower,
        int24 _tickUpper,
        address _initialCircuitBreaker
    ) {
        require(_targetPool != address(0) && _token0 != address(0) && _token1 != address(0), "INVALID_ADDRESS");
        owner = msg.sender;
        liquidityManager = msg.sender;
        circuitBreaker = _initialCircuitBreaker != address(0) ? _initialCircuitBreaker : msg.sender;
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

    /// @notice B-5: Atomic capital evacuation on emergency pause (active safeguarding)
    /// @dev Burns active position from compromised pool and collects all underlying tokens to vault
    function emergencyPause() external onlyCircuitBreaker nonReentrant {
        paused = true;
        if (ownPositionLiquidity > 0) {
            uint128 liq = ownPositionLiquidity;
            retreatedLiquidity += liq;
            ownPositionLiquidity = 0;
            IPancakeV3Pool(targetPool).burn(tickLower, tickUpper, liq);
            IPancakeV3Pool(targetPool).collect(
                address(this),
                tickLower,
                tickUpper,
                type(uint128).max,
                type(uint128).max
            );
            emit EmergencyLiquidityRetreated(liq);
        }
        emit EmergencyPauseActivated();
    }

    function emergencyUnpause() external onlyCircuitBreaker {
        paused = false;
        emergencyWindDownActive = false;
        emit EmergencyUnpaused();
    }

    /// @notice N-2: Re-deploys sheltered liquidity back into PancakeSwap v3 once crisis is safely resolved
    /// @dev Payer (msg.sender) covers any composition drift between retreat and restore ticks
    function restoreRetreatedLiquidity() external onlyLiquidityManager whenNotPaused nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(retreatedLiquidity > 0, "NO_RETREATED_LIQUIDITY");
        uint128 liq = retreatedLiquidity;
        retreatedLiquidity = 0;

        // B-1, N-2, & Pass 6 Guard: Authorize mint callback exclusively for this transaction
        _activeMintPayer = msg.sender;
        (amount0, amount1) = IPancakeV3Pool(targetPool).mint(
            address(this),
            tickLower,
            tickUpper,
            liq,
            abi.encode(msg.sender)
        );
        _activeMintPayer = address(0);

        ownPositionLiquidity += liq;
        emit LiquidityRestored(liq);
    }

    function emergencyWindDown() external onlyCircuitBreaker {
        paused = true;
        emergencyWindDownActive = true;
        emit EmergencyWindDownTriggered();
    }

    /// @notice H-R3 & B-1: Deposit underlying tokens and mint active concentrated liquidity on PancakeSwap v3
    /// @dev Pass 6 Guard: Authorizes mint callback exclusively for msg.sender
    function depositLiquidity(
        address user,
        uint128 liquidityAmount
    ) external onlyLiquidityManager whenNotPaused nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(user != address(0), "INVALID_USER");
        require(liquidityAmount > 0, "INVALID_LIQUIDITY_AMOUNT");

        // B-1 & Pass 6 Guard: Authorize mint callback exclusively for this transaction
        _activeMintPayer = msg.sender;
        (amount0, amount1) = IPancakeV3Pool(targetPool).mint(
            address(this),
            tickLower,
            tickUpper,
            liquidityAmount,
            abi.encode(msg.sender)
        );
        _activeMintPayer = address(0);

        ownPositionLiquidity += liquidityAmount;
        lpBalances[user] += liquidityAmount;
        totalLpSupply += liquidityAmount;

        emit LiquidityDeposited(user, liquidityAmount, amount0, amount1);
    }

    /// @notice PancakeSwap v3 mint callback to transfer tokens owed during liquidity creation
    /// @dev Pass 6 Hardening (Medio 1): Only executes when initiated internally by receiver (_activeMintPayer != 0)
    function pancakeV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external override {
        require(msg.sender == targetPool, "ONLY_TARGET_POOL_CALLBACK");
        require(_activeMintPayer != address(0), "UNAUTHORIZED_MINT_CALLBACK");
        require(data.length == 32, "INVALID_CALLBACK_DATA");

        address payer = abi.decode(data, (address));
        require(payer == _activeMintPayer, "UNAUTHORIZED_PAYER");

        uint256 bal0 = IBEP20(token0).balanceOf(address(this));
        uint256 bal1 = IBEP20(token1).balanceOf(address(this));

        if (amount0Owed > 0) {
            if (bal0 >= amount0Owed) {
                require(IBEP20(token0).transfer(msg.sender, amount0Owed), "TRANSFER0_FAILED");
            } else {
                if (bal0 > 0) {
                    require(IBEP20(token0).transfer(msg.sender, bal0), "TRANSFER0_PARTIAL_FAILED");
                }
                uint256 remaining0 = amount0Owed - bal0;
                require(IBEP20(token0).transferFrom(payer, msg.sender, remaining0), "PULL_TOKEN0_FAILED");
            }
        }
        if (amount1Owed > 0) {
            if (bal1 >= amount1Owed) {
                require(IBEP20(token1).transfer(msg.sender, amount1Owed), "TRANSFER1_FAILED");
            } else {
                if (bal1 > 0) {
                    require(IBEP20(token1).transfer(msg.sender, bal1), "TRANSFER1_PARTIAL_FAILED");
                }
                uint256 remaining1 = amount1Owed - bal1;
                require(IBEP20(token1).transferFrom(payer, msg.sender, remaining1), "PULL_TOKEN1_FAILED");
            }
        }
    }

    /// @notice Orderly non-custodial capital redemption during emergency wind down or active pause
    /// @dev Pass 6 Hardening (Medio 3 / N-4): Allows orderly exit while paused or in emergency wind down
    function orderlyWithdraw(uint256 lpAmount) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(emergencyWindDownActive || paused, "WIND_DOWN_OR_PAUSE_NOT_ACTIVE");
        return _executeWithdraw(msg.sender, lpAmount);
    }

    /// @notice N-4: Unlocks non-custodial capital redemption for LPs who did not exit before governance restoration
    function claimRemainingLp(uint256 lpAmount) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        return _executeWithdraw(msg.sender, lpAmount);
    }

    function _executeWithdraw(address user, uint256 lpAmount) internal returns (uint256 amount0, uint256 amount1) {
        require(lpAmount > 0, "INVALID_LP_AMOUNT");
        require(lpBalances[user] >= lpAmount, "INSUFFICIENT_LP_BALANCE");
        require(totalLpSupply > 0, "ZERO_TOTAL_SUPPLY");

        // H-R2: Calculate burn strictly against the receiver's own position liquidity (if any left unretreated)
        if (ownPositionLiquidity > 0) {
            uint128 liqToBurn = uint128((uint256(ownPositionLiquidity) * lpAmount) / totalLpSupply);
            if (liqToBurn > 0) {
                ownPositionLiquidity -= liqToBurn;
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

        // P7-M1: Pro-rata deduction of retreated liquidity if withdrawal occurs during active pause
        if (retreatedLiquidity > 0) {
            uint128 retreatedDeduct = uint128((uint256(retreatedLiquidity) * lpAmount) / totalLpSupply);
            if (retreatedDeduct > 0) {
                retreatedLiquidity -= retreatedDeduct;
            }
        }

        uint256 bal0 = IBEP20(token0).balanceOf(address(this));
        uint256 bal1 = IBEP20(token1).balanceOf(address(this));

        amount0 = (lpAmount * bal0) / totalLpSupply;
        amount1 = (lpAmount * bal1) / totalLpSupply;

        // H-R1: CEI Pattern — State deducted BEFORE any external token transfers
        lpBalances[user] -= lpAmount;
        totalLpSupply -= lpAmount;

        if (amount0 > 0) {
            require(IBEP20(token0).transfer(user, amount0), "TRANSFER0_FAILED");
        }
        if (amount1 > 0) {
            require(IBEP20(token1).transfer(user, amount1), "TRANSFER1_FAILED");
        }

        emit OrderlyLiquidityWithdrawn(user, lpAmount, amount0, amount1);
    }

    receive() external payable {
        revert("NON_CUSTODIAL: ZERO_BNB_ACCEPTED");
    }
}
