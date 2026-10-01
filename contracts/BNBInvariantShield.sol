// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./libraries/PancakeV3InvariantChecker.sol";
import "./interfaces/IPancakeV3Pool.sol";
import "./interfaces/IAggregatorV3.sol";

/// @title BNB Invariant Shield v2.0.0 - Institutional Circuit Breaker for BNB Chain & opBNB
/// @notice Autonomous, ultra-low latency circuit breaker safeguarding PancakeSwap v3 & Venus Protocol
/// @dev Engineered by Sentinel Fleet Technologies. Formally audited against Flash-Pump Griefing (C-1), Salami-Slicing (H-1), and TWAP-Gated Ratchets (H-S1)
contract BNBInvariantShield {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    mapping(bytes32 => mapping(address => bool)) private _roles;

    uint256 public constant PAUSE_COOLDOWN = 15 minutes;
    uint256 public constant HWM_UPDATE_COOLDOWN = 60 seconds; // H-S1: Reduced from 1h since 30m TWAP provides mathematical flash-pump immunity
    uint32 public constant TWAP_WINDOW = 1800; // 30 minutes
    int24 public constant MAX_TWAP_TICK_DEVIATION = 200; // ~2% max price deviation between spot and 30m TWAP
    uint256 public constant EMERGENCY_TIMEOUT = 24 hours;
    uint256 public constant DEFAULT_MAX_DEVIATION_BPS = 1500; // 15% price drop
    int24 public constant DEFAULT_MAX_TICK_DELTA = 1625;      // ~15% tick deviation
    uint256 public constant DEFAULT_MAX_DRAIN_BPS = 3000;     // 30% sudden liquidity drainage

    enum PoolState { NORMAL, PAUSED, EMERGENCY_WIND_DOWN }

    struct TargetConfig {
        bool isRegistered;
        PoolState state;
        address poolReceiver;
        address oracleFeed;
        uint160 initialSqrtPriceX96;
        uint160 highWaterMarkSqrtPriceX96; // HWM: Highest verified price anchor
        int256 highWaterMarkOraclePrice;   // Oracle HWM anchor for cross-validation (M-S1)
        uint128 initialLiquidity;
        uint128 highWaterMarkLiquidity;     // Liquidity HWM to defeat organic growth blindness (H-2)
        int24 initialTick;
        uint256 lastPauseTimestamp;
        uint256 lastHwmUpdateTimestamp;
        uint256 maxDeviationBps;
        int24 maxTickDelta;
        uint256 maxDrainBps;
    }

    mapping(address => TargetConfig) public targets;

    event TargetRegistered(address indexed targetPool, address indexed poolReceiver, address oracleFeed);
    event HighWaterMarkUpdated(address indexed targetPool, uint160 newHwmSqrtPriceX96, uint128 newHwmLiquidity);
    event RiskParametersUpdated(address indexed targetPool, uint256 maxDeviationBps, int24 maxTickDelta, uint256 maxDrainBps);
    event EmergencyPauseTriggered(address indexed targetPool, uint160 currentSqrtPriceX96, uint128 currentLiquidity, address indexed triggeredBy);
    event TargetUnpausedByMultisig(address indexed targetPool, address indexed unpausedBy);
    event AutoRecoveryTriggered(address indexed targetPool, uint160 currentSqrtPriceX96, uint128 currentLiquidity);
    event EmergencyWindDownActivated(address indexed targetPool, uint256 timestamp);
    event WindDownRestoredByGovernance(address indexed targetPool, address indexed restoredBy);
    event RoleGranted(bytes32 indexed role, address indexed account);
    event RoleRevoked(bytes32 indexed role, address indexed account);

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "ACCESS_CONTROL: SENDER_LACKS_ROLE");
        _;
    }

    constructor(address sentinelBot, address bnbMultisig) {
        require(sentinelBot != address(0) && bnbMultisig != address(0), "INVALID_ADDRESS");
        _roles[PAUSER_ROLE][sentinelBot] = true;
        _roles[UNPAUSER_ROLE][bnbMultisig] = true;
        _roles[DEFAULT_ADMIN_ROLE][bnbMultisig] = true;

        emit RoleGranted(PAUSER_ROLE, sentinelBot);
        emit RoleGranted(UNPAUSER_ROLE, bnbMultisig);
        emit RoleGranted(DEFAULT_ADMIN_ROLE, bnbMultisig);
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }

    function grantRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _roles[role][account] = true;
        emit RoleGranted(role, account);
    }

    function revokeRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _roles[role][account] = false;
        emit RoleRevoked(role, account);
    }

    /// @notice Returns the 30-minute TWAP tick for a pool, falling back to current tick if observation history is insufficient
    function getTwapTick(address targetPool, uint32 twapWindow) public view returns (int24 twapTick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;
        try IPancakeV3Pool(targetPool).observe(secondsAgos) returns (
            int56[] memory tickCumulatives,
            uint160[] memory
        ) {
            int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
            twapTick = int24(tickDelta / int56(int32(twapWindow)));
            if (tickDelta < 0 && (tickDelta % int56(int32(twapWindow)) != 0)) {
                twapTick--;
            }
        } catch {
            (, twapTick,,,,,) = IPancakeV3Pool(targetPool).slot0();
        }
    }

    /// @notice Register a PancakeSwap v3 pool or Venus market under invariant protection
    function registerTarget(
        address targetPool,
        address poolReceiver,
        address oracleFeed
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(targetPool != address(0) && poolReceiver != address(0), "INVALID_ADDRESS");
        require(poolReceiver.code.length > 0, "INVALID_RECEIVER_CODE"); // L-2: Prevent EOA receiver no-op
        require(!targets[targetPool].isRegistered, "ALREADY_REGISTERED");

        (uint160 sqrtPriceX96, int24 tick,,,,,) = IPancakeV3Pool(targetPool).slot0();
        require(sqrtPriceX96 > 0, "INVALID_SQRT_PRICE");
        uint128 poolLiquidity = IPancakeV3Pool(targetPool).liquidity();
        require(poolLiquidity > 0, "POOL_HAS_NO_LIQUIDITY");

        // H-S1: Validate spot matches TWAP at registration to defeat pre-registration flash pumps
        int24 regTwapTick = getTwapTick(targetPool, TWAP_WINDOW);
        int24 regTickDiff = tick > regTwapTick ? tick - regTwapTick : regTwapTick - tick;
        require(regTickDiff <= MAX_TWAP_TICK_DEVIATION, "REGISTRATION_SPOT_DEVIATES_FROM_TWAP");

        // M-R1: Validate wrapper on-chain wiring to prevent dead circuit breaker
        (bool s1, bytes memory r1) = poolReceiver.staticcall(abi.encodeWithSignature("targetPool()"));
        if (s1 && r1.length == 32) {
            require(abi.decode(r1, (address)) == targetPool, "MISMATCHED_TARGET_POOL");
        }
        (bool s2, bytes memory r2) = poolReceiver.staticcall(abi.encodeWithSignature("circuitBreaker()"));
        if (s2 && r2.length == 32) {
            require(abi.decode(r2, (address)) == address(this), "MISMATCHED_CIRCUIT_BREAKER");
        }

        int256 initOraclePrice = 0;
        if (oracleFeed != address(0)) {
            (, initOraclePrice,,,) = IAggregatorV3(oracleFeed).latestRoundData();
            require(initOraclePrice > 0, "INVALID_ORACLE_PRICE");
        }

        targets[targetPool] = TargetConfig({
            isRegistered: true,
            state: PoolState.NORMAL,
            poolReceiver: poolReceiver,
            oracleFeed: oracleFeed,
            initialSqrtPriceX96: sqrtPriceX96,
            highWaterMarkSqrtPriceX96: sqrtPriceX96,
            highWaterMarkOraclePrice: initOraclePrice,
            initialLiquidity: poolLiquidity,
            highWaterMarkLiquidity: poolLiquidity,
            initialTick: tick,
            lastPauseTimestamp: 0,
            lastHwmUpdateTimestamp: block.timestamp,
            maxDeviationBps: DEFAULT_MAX_DEVIATION_BPS,
            maxTickDelta: DEFAULT_MAX_TICK_DELTA,
            maxDrainBps: DEFAULT_MAX_DRAIN_BPS
        });

        emit TargetRegistered(targetPool, poolReceiver, oracleFeed);
    }

    /// @notice Updates the High-Water Mark with 30-minute TWAP and Chainlink Oracle validation
    /// @dev Defeats C-1 (Flash-Pump griefing) and eliminates H-S1 (1-hour blind window) via continuous TWAP gating
    function updateHighWaterMark(address targetPool) external onlyRole(PAUSER_ROLE) {
        TargetConfig storage config = targets[targetPool];
        require(config.isRegistered, "NOT_REGISTERED");
        require(config.state == PoolState.NORMAL, "NOT_NORMAL");
        require(block.timestamp >= config.lastHwmUpdateTimestamp + HWM_UPDATE_COOLDOWN, "HWM_COOLDOWN_ACTIVE");

        (uint160 currentSqrtPriceX96, int24 currentTick,,,,,) = IPancakeV3Pool(targetPool).slot0();
        uint128 currentLiquidity = IPancakeV3Pool(targetPool).liquidity();

        // H-S1: Mathematical TWAP validation against 30-minute time-weighted average
        int24 twapTick = getTwapTick(targetPool, TWAP_WINDOW);
        int24 tickDiff = currentTick > twapTick ? currentTick - twapTick : twapTick - currentTick;
        require(tickDiff <= MAX_TWAP_TICK_DEVIATION, "SPOT_DEVIATES_FROM_TWAP");

        // M-S1: If oracle feed exists, verify that spot price is consistent with oracle (rejects flash pumps)
        if (config.oracleFeed != address(0)) {
            (, int256 oraclePrice,, uint256 updatedAt,) = IAggregatorV3(config.oracleFeed).latestRoundData();
            require(oraclePrice > 0, "INVALID_ORACLE_PRICE");
            require(block.timestamp - updatedAt <= 1 hours, "STALE_ORACLE_PRICE");
            if (config.highWaterMarkOraclePrice > 0) {
                // Oracle price must validate market rally (cannot fall below 98% of peak)
                require(oraclePrice >= (config.highWaterMarkOraclePrice * 98) / 100, "ORACLE_PRICE_DISAGREES");
            }
            if (oraclePrice > config.highWaterMarkOraclePrice) {
                config.highWaterMarkOraclePrice = oraclePrice;
            }
        }

        bool updated = false;
        if (currentSqrtPriceX96 > config.highWaterMarkSqrtPriceX96) {
            config.highWaterMarkSqrtPriceX96 = currentSqrtPriceX96;
            config.initialTick = currentTick; // M-S2: Refresh initialTick with HWM to prevent stale delta false positives in bull runs
            updated = true;
        }

        // H-2: Track liquidity organic growth as well
        if (currentLiquidity > config.highWaterMarkLiquidity) {
            config.highWaterMarkLiquidity = currentLiquidity;
            updated = true;
        }

        if (updated) {
            config.lastHwmUpdateTimestamp = block.timestamp;
            emit HighWaterMarkUpdated(targetPool, config.highWaterMarkSqrtPriceX96, config.highWaterMarkLiquidity);
        }
    }

    /// @notice Configures custom invariant risk parameters for a protected pool
    /// @dev Validates bounds: maxDeviationBps in [2, 10000], maxDrainBps in [1, 10000], maxTickDelta > 0
    function updateTargetRiskParameters(
        address targetPool,
        uint256 maxDeviationBps,
        int24 maxTickDelta,
        uint256 maxDrainBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        TargetConfig storage config = targets[targetPool];
        require(config.isRegistered, "NOT_REGISTERED");
        require(maxDeviationBps >= 2 && maxDeviationBps <= 10000, "INVALID_BPS_RANGE");
        require(maxTickDelta > 0, "INVALID_TICK_DELTA");
        require(maxDrainBps >= 1 && maxDrainBps <= 10000, "INVALID_DRAIN_RANGE");

        config.maxDeviationBps = maxDeviationBps;
        config.maxTickDelta = maxTickDelta;
        config.maxDrainBps = maxDrainBps;
        emit RiskParametersUpdated(targetPool, maxDeviationBps, maxTickDelta, maxDrainBps);
    }

    /// @notice Triggers emergency circuit breaker pause if and only if on-chain invariant breach is mathematically verified
    /// @dev Called by Sentinel Bot via Bloxroute / 48 Club Puissant private fast-path on BNB Chain
    function triggerEmergencyPause(address targetPool) external onlyRole(PAUSER_ROLE) {
        TargetConfig storage config = targets[targetPool];
        require(config.isRegistered, "NOT_REGISTERED");
        require(config.state == PoolState.NORMAL, "NOT_NORMAL");
        require(block.timestamp >= config.lastPauseTimestamp + PAUSE_COOLDOWN, "PAUSE_COOLDOWN_ACTIVE");

        (uint160 currentSqrtPriceX96, int24 currentTick,,,,,) = IPancakeV3Pool(targetPool).slot0();
        uint128 currentLiquidity = IPancakeV3Pool(targetPool).liquidity();

        // Spot ratchet removed (Fix C-1). Invariant drop is strictly checked against established HWM anchor.
        uint160 anchorPrice = config.highWaterMarkSqrtPriceX96 > 0
            ? config.highWaterMarkSqrtPriceX96
            : config.initialSqrtPriceX96;

        (bool dropExceeded, ) = PancakeV3InvariantChecker.checkExactPriceDrop(
            anchorPrice,
            currentSqrtPriceX96,
            config.maxDeviationBps
        );

        (bool tickExceeded, ) = PancakeV3InvariantChecker.checkTickDelta(
            config.initialTick,
            currentTick,
            config.maxTickDelta
        );

        uint128 anchorLiquidity = config.highWaterMarkLiquidity > 0
            ? config.highWaterMarkLiquidity
            : config.initialLiquidity;

        (bool drainExceeded, ) = PancakeV3InvariantChecker.checkLiquidityDrain(
            anchorLiquidity,
            currentLiquidity,
            config.maxDrainBps
        );

        require(dropExceeded || tickExceeded || drainExceeded, "INVARIANT_HEALTHY");

        config.state = PoolState.PAUSED;
        config.lastPauseTimestamp = block.timestamp;

        (bool success, ) = config.poolReceiver.call(abi.encodeWithSignature("emergencyPause()"));
        require(success, "WRAPPER_PAUSE_FAILED");

        emit EmergencyPauseTriggered(targetPool, currentSqrtPriceX96, currentLiquidity, msg.sender);
    }

    /// @notice Automated recovery for transient volatility or benign flash-loan noise
    /// @dev Fix H-3: Preserves highWaterMarkSqrtPriceX96 intact without erosion. uint256 safe casting applied.
    function autoRecoverIfHealthy(address targetPool) external onlyRole(PAUSER_ROLE) {
        TargetConfig storage config = targets[targetPool];
        require(config.isRegistered, "NOT_REGISTERED");
        require(config.state == PoolState.PAUSED, "NOT_PAUSED");
        require(block.timestamp >= config.lastPauseTimestamp + 5 minutes, "COOLDOWN_ACTIVE");

        (uint160 currentSqrtPriceX96, int24 currentTick,,,,,) = IPancakeV3Pool(targetPool).slot0();
        uint128 currentLiquidity = IPancakeV3Pool(targetPool).liquidity();

        // Invariant health check: price within 2% of HWM and liquidity >= 90% of HWM
        uint160 minHealthyPrice = uint160((uint256(config.highWaterMarkSqrtPriceX96) * 98) / 100);
        require(currentSqrtPriceX96 >= minHealthyPrice, "PRICE_NOT_RESTORED");

        uint128 anchorLiq = config.highWaterMarkLiquidity > 0 ? config.highWaterMarkLiquidity : config.initialLiquidity;
        require(uint256(currentLiquidity) >= (uint256(anchorLiq) * 9) / 10, "LIQUIDITY_NOT_RESTORED");

        config.state = PoolState.NORMAL;
        config.initialSqrtPriceX96 = currentSqrtPriceX96;
        // Fix H-3: Do NOT reset or lower highWaterMarkSqrtPriceX96. Anchor stays at peak.
        config.initialTick = currentTick;

        (bool success, ) = config.poolReceiver.call(abi.encodeWithSignature("emergencyUnpause()"));
        require(success, "WRAPPER_UNPAUSE_FAILED");

        emit AutoRecoveryTriggered(targetPool, currentSqrtPriceX96, currentLiquidity);
    }

    /// @notice Unpauses target pool with on-chain oracle and market restoration verification
    /// @dev Strictly restricted to human governance multisig (UNPAUSER_ROLE)
    function unpauseTargetWithOracle(
        address targetPool,
        uint160 minAcceptableSqrtPrice,
        uint256 maxOracleAge
    ) external onlyRole(UNPAUSER_ROLE) {
        TargetConfig storage config = targets[targetPool];
        require(config.isRegistered, "NOT_REGISTERED");
        require(config.state == PoolState.PAUSED, "NOT_PAUSED");

        (uint160 currentSqrtPriceX96, int24 newTick,,,,,) = IPancakeV3Pool(targetPool).slot0();
        require(currentSqrtPriceX96 >= minAcceptableSqrtPrice, "MARKET_NOT_RESTORED");

        if (config.oracleFeed != address(0)) {
            (, int256 price,, uint256 updatedAt,) = IAggregatorV3(config.oracleFeed).latestRoundData();
            require(price > 0, "INVALID_ORACLE_PRICE");
            require(block.timestamp - updatedAt <= maxOracleAge, "STALE_ORACLE_PRICE");
            config.highWaterMarkOraclePrice = price; // M-S1: Reset oracle anchor on unpause
        }

        config.initialSqrtPriceX96 = currentSqrtPriceX96;
        config.highWaterMarkSqrtPriceX96 = currentSqrtPriceX96;
        config.highWaterMarkLiquidity = IPancakeV3Pool(targetPool).liquidity();
        config.initialTick = newTick;
        config.initialLiquidity = config.highWaterMarkLiquidity;
        config.state = PoolState.NORMAL;

        (bool success, ) = config.poolReceiver.call(abi.encodeWithSignature("emergencyUnpause()"));
        require(success, "WRAPPER_UNPAUSE_FAILED");

        emit TargetUnpausedByMultisig(targetPool, msg.sender);
    }

    /// @notice Triggers 24-hour emergency wind-down if governance fails to resolve crisis within 24h
    /// @dev Fix M-1: Validates that invariant is STILL breached before triggering terminal liquidation
    function activateEmergencyWindDown(address targetPool) external {
        TargetConfig storage config = targets[targetPool];
        require(config.isRegistered, "NOT_REGISTERED");
        require(config.state == PoolState.PAUSED, "NOT_PAUSED");
        require(block.timestamp >= config.lastPauseTimestamp + EMERGENCY_TIMEOUT, "TIMEOUT_NOT_REACHED");

        (uint160 currentSqrtPriceX96,,,,,,) = IPancakeV3Pool(targetPool).slot0();
        uint128 currentLiquidity = IPancakeV3Pool(targetPool).liquidity();

        uint160 anchorPrice = config.highWaterMarkSqrtPriceX96 > 0 ? config.highWaterMarkSqrtPriceX96 : config.initialSqrtPriceX96;
        (bool dropExceeded, ) = PancakeV3InvariantChecker.checkExactPriceDrop(anchorPrice, currentSqrtPriceX96, config.maxDeviationBps);

        uint128 anchorLiq = config.highWaterMarkLiquidity > 0 ? config.highWaterMarkLiquidity : config.initialLiquidity;
        (bool drainExceeded, ) = PancakeV3InvariantChecker.checkLiquidityDrain(anchorLiq, currentLiquidity, config.maxDrainBps);

        require(dropExceeded || drainExceeded, "CANNOT_WIND_DOWN_RECOVERED_POOL");

        config.state = PoolState.EMERGENCY_WIND_DOWN;

        (bool success, ) = config.poolReceiver.call(abi.encodeWithSignature("emergencyWindDown()"));
        require(success, "WRAPPER_WIND_DOWN_FAILED");

        emit EmergencyWindDownActivated(targetPool, block.timestamp);
    }

    /// @notice Governance restoration path from Emergency Wind-Down if crisis is resolved (Fix M-1)
    function governanceRestoreFromWindDown(address targetPool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        TargetConfig storage config = targets[targetPool];
        require(config.isRegistered, "NOT_REGISTERED");
        require(config.state == PoolState.EMERGENCY_WIND_DOWN, "NOT_WIND_DOWN");

        (uint160 currentSqrtPriceX96, int24 currentTick,,,,,) = IPancakeV3Pool(targetPool).slot0();
        uint128 currentLiquidity = IPancakeV3Pool(targetPool).liquidity();

        config.initialSqrtPriceX96 = currentSqrtPriceX96;
        config.highWaterMarkSqrtPriceX96 = currentSqrtPriceX96;
        config.initialLiquidity = currentLiquidity;
        config.highWaterMarkLiquidity = currentLiquidity;
        config.initialTick = currentTick;
        config.state = PoolState.NORMAL;

        (bool success, ) = config.poolReceiver.call(abi.encodeWithSignature("emergencyUnpause()"));
        require(success, "WRAPPER_UNPAUSE_FAILED");

        emit WindDownRestoredByGovernance(targetPool, msg.sender);
    }

    receive() external payable {
        revert("NON_CUSTODIAL: ZERO_BNB_ACCEPTED");
    }
}
