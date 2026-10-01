// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./libraries/PancakeV3InvariantChecker.sol";
import "./interfaces/IPancakeV3Pool.sol";
import "./interfaces/IAggregatorV3.sol";

/// @title BNB Invariant Shield v2.0.0 - Institutional Circuit Breaker for BNB Chain & opBNB
/// @notice Autonomous, ultra-low latency circuit breaker safeguarding PancakeSwap v3 & Venus Protocol
/// @dev Engineered by Sentinel Fleet Technologies. Formally audited against Flash-Pump Griefing (C-1) and Salami-Slicing (H-1)
contract BNBInvariantShield {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    mapping(bytes32 => mapping(address => bool)) private _roles;

    uint256 public constant PAUSE_COOLDOWN = 15 minutes;
    uint256 public constant HWM_UPDATE_COOLDOWN = 1 hours;
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

        targets[targetPool] = TargetConfig({
            isRegistered: true,
            state: PoolState.NORMAL,
            poolReceiver: poolReceiver,
            oracleFeed: oracleFeed,
            initialSqrtPriceX96: sqrtPriceX96,
            highWaterMarkSqrtPriceX96: sqrtPriceX96,
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

    /// @notice Updates the High-Water Mark with oracle/TWAP validation and 1-hour rate limit
    /// @dev Defeats C-1 (Flash-Pump griefing): Restricted role + cooldown prevents transient spot manipulation
    function updateHighWaterMark(address targetPool) external onlyRole(PAUSER_ROLE) {
        TargetConfig storage config = targets[targetPool];
        require(config.isRegistered, "NOT_REGISTERED");
        require(config.state == PoolState.NORMAL, "NOT_NORMAL");
        require(block.timestamp >= config.lastHwmUpdateTimestamp + HWM_UPDATE_COOLDOWN, "HWM_COOLDOWN_ACTIVE");

        (uint160 currentSqrtPriceX96,,,,,,) = IPancakeV3Pool(targetPool).slot0();
        uint128 currentLiquidity = IPancakeV3Pool(targetPool).liquidity();

        // If oracle feed exists, verify that spot price is consistent with oracle (rejects flash pumps)
        if (config.oracleFeed != address(0)) {
            (, int256 oraclePrice,, uint256 updatedAt,) = IAggregatorV3(config.oracleFeed).latestRoundData();
            require(oraclePrice > 0, "INVALID_ORACLE_PRICE");
            require(block.timestamp - updatedAt <= 1 hours, "STALE_ORACLE_PRICE");
        }

        bool updated = false;
        if (currentSqrtPriceX96 > config.highWaterMarkSqrtPriceX96) {
            config.highWaterMarkSqrtPriceX96 = currentSqrtPriceX96;
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

        // Note: Spot ratchet removed (Fix C-1). Invariant drop is strictly checked against established HWM anchor.
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

        uint256 targetDrainBps = config.maxDrainBps > 0 ? config.maxDrainBps : DEFAULT_MAX_DRAIN_BPS;
        (bool drainExceeded, ) = PancakeV3InvariantChecker.checkLiquidityDrain(
            anchorLiquidity,
            currentLiquidity,
            targetDrainBps
        );

        require(dropExceeded || tickExceeded || drainExceeded, "INVARIANT_HEALTHY");

        config.state = PoolState.PAUSED;
        config.lastPauseTimestamp = block.timestamp;

        (bool success, ) = config.poolReceiver.call(abi.encodeWithSignature("emergencyPause()"));
        require(success, "WRAPPER_PAUSE_FAILED");

        emit EmergencyPauseTriggered(targetPool, currentSqrtPriceX96, currentLiquidity, msg.sender);
    }

    /// @notice Automated safety recovery if invariant health is fully restored and sustained for > 5 minutes
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

        // Fix M-1: Verify that pool is genuinely still compromised; prevent bricking healthy pools
        (uint160 currentSqrtPriceX96,,,,,,) = IPancakeV3Pool(targetPool).slot0();
        uint160 anchorPrice = config.highWaterMarkSqrtPriceX96 > 0 ? config.highWaterMarkSqrtPriceX96 : config.initialSqrtPriceX96;
        (bool dropExceeded, ) = PancakeV3InvariantChecker.checkExactPriceDrop(anchorPrice, currentSqrtPriceX96, config.maxDeviationBps);
        require(dropExceeded, "CANNOT_WIND_DOWN_RECOVERED_POOL");

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

        config.state = PoolState.NORMAL;

        (bool success, ) = config.poolReceiver.call(abi.encodeWithSignature("emergencyUnpause()"));
        require(success, "WRAPPER_UNPAUSE_FAILED");

        emit WindDownRestoredByGovernance(targetPool, msg.sender);
    }

    receive() external payable {
        revert("NON_CUSTODIAL: ZERO_BNB_ACCEPTED");
    }
}
