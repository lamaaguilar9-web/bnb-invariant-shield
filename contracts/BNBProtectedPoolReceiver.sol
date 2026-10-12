// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IBEP20.sol";
import "./interfaces/IPancakeV3Pool.sol";
import "./libraries/FullMath.sol";

/// @title BNBProtectedPoolReceiver - Production-Grade Concentrated Liquidity Vault & Safe Exit Hook
/// @notice Manages PancakeSwap v3 LP positions with atomic circuit breaker pauses and non-custodial emergency wind-down
/// @dev Hardened against Reentrancy (H-R1), Global Liquidity Share Overburn (H-R2), Unbacked Mints (H-R3),
///      Capital Evacuation (B-5), Drift Deadlock (N-2), Mint Cross-Financing (F1), Unrestricted LP Exit (F2),
///      Invalid Tick Configuration (F3), and Revert Vulnerability in Emergency Pause (F4).
contract BNBProtectedPoolReceiver is IPancakeV3MintCallback {
    enum MintMode { NONE, DEPOSIT, RESTORE }

    address public immutable targetPool;
    address public immutable token0;
    address public immutable token1;

    address public owner;
    address public circuitBreaker;
    address public liquidityManager;

    bool public paused;
    bool public emergencyWindDownActive;
    bool public wasEverWoundDown;
    bool private _locked;
    address private _activeMintPayer; // Pass 6: Guard against unauthorized mint callbacks
    MintMode private _activeMintMode;  // F1 Guard: Distinguishes new deposit vs sheltered restoration

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
    event EmergencyLiquidityRetreatFailed(uint128 liquidityAttempted);
    event EmergencyLiquidityRetreatPartial(uint128 liquidityBurned);
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
        
        // F3 Hardening: Validar orden de ticks y alineación estricta al tickSpacing del pool PancakeSwap v3
        require(_tickLower < _tickUpper, "INVALID_TICK_ORDER");
        require(_tickLower >= -887272 && _tickUpper <= 887272, "TICK_BOUNDS_EXCEEDED");
        int24 spacing = IPancakeV3Pool(_targetPool).tickSpacing();
        require(spacing > 0, "INVALID_POOL_TICK_SPACING");
        require(_tickLower % spacing == 0, "TICK_LOWER_NOT_ALIGNED");
        require(_tickUpper % spacing == 0, "TICK_UPPER_NOT_ALIGNED");

        // R1 Hardening: Validar tokens inmutables contra el pool real de PancakeSwap v3
        require(_token0 == IPancakeV3Pool(_targetPool).token0(), "TOKEN0_MISMATCH");
        require(_token1 == IPancakeV3Pool(_targetPool).token1(), "TOKEN1_MISMATCH");

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

    /// @notice B-5 & F4: Atomic capital evacuation on emergency pause with resilient try/catch
    /// @dev Sets pause immediately. External burn/collect is wrapped in try/catch so pause SURVIVES
    ///      even if external pool reverts. State (retreatedLiquidity) is updated only upon successful burn.
    function emergencyPause() external onlyCircuitBreaker nonReentrant {
        paused = true;
        if (ownPositionLiquidity > 0) {
            uint128 liq = ownPositionLiquidity;
            try IPancakeV3Pool(targetPool).burn(tickLower, tickUpper, liq) {
                try IPancakeV3Pool(targetPool).collect(
                    address(this),
                    tickLower,
                    tickUpper,
                    type(uint128).max,
                    type(uint128).max
                ) {
                    ownPositionLiquidity = 0;
                    retreatedLiquidity += liq;
                    emit EmergencyLiquidityRetreated(liq);
                } catch {
                    // Burn succeeded on-chain, position liquidity was converted to tokens owed in pool.
                    // R2: Tokens remain claimable from pool via collectTokensOwed().
                    ownPositionLiquidity = 0;
                    retreatedLiquidity += liq;
                    emit EmergencyLiquidityRetreatPartial(liq);
                }
            } catch {
                // Burn failed (e.g. pool frozen or reverting). Emergency pause SURVIVES!
                // State does not lie: retreatedLiquidity is NOT incremented.
                emit EmergencyLiquidityRetreatFailed(liq);
            }
        }
        emit EmergencyPauseActivated();
    }

    /// @notice R2: Allows recovering tokens owed in PancakeSwap v3 pool if collect reverted during emergency pause
    function collectTokensOwed() external onlyCircuitBreaker nonReentrant returns (uint128 amount0, uint128 amount1) {
        (amount0, amount1) = IPancakeV3Pool(targetPool).collect(
            address(this),
            tickLower,
            tickUpper,
            type(uint128).max,
            type(uint128).max
        );
    }

    function emergencyUnpause() external onlyCircuitBreaker {
        paused = false;
        emergencyWindDownActive = false;
        emit EmergencyUnpaused();
    }

    /// @notice N-2 & F1: Re-deploys sheltered liquidity back into PancakeSwap v3 once crisis is safely resolved
    /// @dev Authorizes RESTORE mode in callback so vault reserves are used, with payer covering composition drift
    function restoreRetreatedLiquidity() external onlyLiquidityManager whenNotPaused nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(retreatedLiquidity > 0, "NO_RETREATED_LIQUIDITY");
        uint128 liq = retreatedLiquidity;
        retreatedLiquidity = 0;

        _activeMintPayer = msg.sender;
        _activeMintMode = MintMode.RESTORE;
        (amount0, amount1) = IPancakeV3Pool(targetPool).mint(
            address(this),
            tickLower,
            tickUpper,
            liq,
            abi.encode(msg.sender)
        );
        _activeMintPayer = address(0);
        _activeMintMode = MintMode.NONE;

        ownPositionLiquidity += liq;
        emit LiquidityRestored(liq);
    }

    function emergencyWindDown() external onlyCircuitBreaker {
        paused = true;
        emergencyWindDownActive = true;
        wasEverWoundDown = true;
        emit EmergencyWindDownTriggered();
    }

    /// @notice H-R3, B-1, & F1: Deposit underlying tokens and mint active concentrated liquidity on PancakeSwap v3
    /// @dev F1 Hardening: Strictly forbids new deposits while retreated liquidity is pending in vault.
    ///      Authorizes DEPOSIT mode in callback so 100% of tokens are transferred from payer via transferFrom.
    function depositLiquidity(
        address user,
        uint128 liquidityAmount
    ) external onlyLiquidityManager whenNotPaused nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(user != address(0), "INVALID_USER");
        require(liquidityAmount > 0, "INVALID_LIQUIDITY_AMOUNT");
        require(retreatedLiquidity == 0, "RETREATED_LIQUIDITY_ACTIVE");

        _activeMintPayer = msg.sender;
        _activeMintMode = MintMode.DEPOSIT;
        (amount0, amount1) = IPancakeV3Pool(targetPool).mint(
            address(this),
            tickLower,
            tickUpper,
            liquidityAmount,
            abi.encode(msg.sender)
        );
        _activeMintPayer = address(0);
        _activeMintMode = MintMode.NONE;

        ownPositionLiquidity += liquidityAmount;
        lpBalances[user] += liquidityAmount;
        totalLpSupply += liquidityAmount;

        emit LiquidityDeposited(user, liquidityAmount, amount0, amount1);
    }

    /// @notice PancakeSwap v3 mint callback to transfer tokens owed during liquidity creation
    /// @dev Pass 6 & F1 Hardening: Validates caller is targetPool and _activeMintPayer is set.
    ///      In DEPOSIT mode: payment is pulled 100% from payer via transferFrom (NEVER touches vault balance).
    ///      In RESTORE mode: payment uses sheltered vault tokens first, with payer covering any drift deficit.
    function pancakeV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external override {
        require(msg.sender == targetPool, "ONLY_TARGET_POOL_CALLBACK");
        require(_activeMintPayer != address(0), "UNAUTHORIZED_MINT_CALLBACK");
        require(_activeMintMode != MintMode.NONE, "UNAUTHORIZED_MINT_MODE");
        require(data.length == 32, "INVALID_CALLBACK_DATA");

        address payer = abi.decode(data, (address));
        require(payer == _activeMintPayer, "UNAUTHORIZED_PAYER");

        if (_activeMintMode == MintMode.DEPOSIT) {
            // F1: For new deposits, 100% of owed tokens must come from payer via transferFrom
            if (amount0Owed > 0) {
                require(IBEP20(token0).transferFrom(payer, msg.sender, amount0Owed), "PULL_TOKEN0_FAILED");
            }
            if (amount1Owed > 0) {
                require(IBEP20(token1).transferFrom(payer, msg.sender, amount1Owed), "PULL_TOKEN1_FAILED");
            }
        } else if (_activeMintMode == MintMode.RESTORE) {
            // F1: For restored liquidity, spend sheltered vault balance first; payer covers composition drift
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
    }

    /// @notice Orderly non-custodial capital redemption during emergency wind down or active pause
    /// @dev Pass 6 Hardening (Medio 3 / N-4): Allows orderly exit while paused or in emergency wind down
    function orderlyWithdraw(uint256 lpAmount) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(emergencyWindDownActive || paused, "WIND_DOWN_OR_PAUSE_NOT_ACTIVE");
        return _executeWithdraw(msg.sender, lpAmount);
    }

    /// @notice N-4 & F2: Unlocks non-custodial capital redemption for LPs who did not exit before governance restoration
    /// @dev F2 Hardening: Requires an active crisis, pending retreated liquidity, or prior emergency wind-down state
    function claimRemainingLp(uint256 lpAmount) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(emergencyWindDownActive || paused || retreatedLiquidity > 0 || wasEverWoundDown, "CRISIS_OR_POST_CRISIS_STATE_REQUIRED");
        return _executeWithdraw(msg.sender, lpAmount);
    }

    function _executeWithdraw(address user, uint256 lpAmount) internal returns (uint256 amount0, uint256 amount1) {
        require(lpAmount > 0, "INVALID_LP_AMOUNT");
        require(lpBalances[user] >= lpAmount, "INSUFFICIENT_LP_BALANCE");
        require(totalLpSupply > 0, "ZERO_TOTAL_SUPPLY");

        // H-R2 & F5/F6: Calculate burn strictly against receiver's own position liquidity with FullMath
        if (ownPositionLiquidity > 0) {
            uint128 liqToBurn;
            if (lpAmount == totalLpSupply) {
                liqToBurn = ownPositionLiquidity;
            } else {
                liqToBurn = uint128(FullMath.mulDiv(uint256(ownPositionLiquidity), lpAmount, totalLpSupply));
            }
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

        // P7-M1 & F5/F6: Pro-rata deduction of retreated liquidity if withdrawal occurs during active pause
        if (retreatedLiquidity > 0) {
            uint128 retreatedDeduct;
            if (lpAmount == totalLpSupply) {
                retreatedDeduct = retreatedLiquidity;
            } else {
                retreatedDeduct = uint128(FullMath.mulDiv(uint256(retreatedLiquidity), lpAmount, totalLpSupply));
            }
            if (retreatedDeduct > 0) {
                retreatedLiquidity -= retreatedDeduct;
            }
        }

        uint256 bal0 = IBEP20(token0).balanceOf(address(this));
        uint256 bal1 = IBEP20(token1).balanceOf(address(this));

        // F5/F6: FullMath 512-bit safe mulDiv and full dust redemption on last exit
        if (lpAmount == totalLpSupply) {
            amount0 = bal0;
            amount1 = bal1;
        } else {
            amount0 = FullMath.mulDiv(lpAmount, bal0, totalLpSupply);
            amount1 = FullMath.mulDiv(lpAmount, bal1, totalLpSupply);
        }

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
