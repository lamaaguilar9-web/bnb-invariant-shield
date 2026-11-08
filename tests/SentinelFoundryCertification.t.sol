// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/libraries/PancakeV3InvariantChecker.sol";

/// @title SentinelFoundryCertification - BNB Invariant Shield Fuzzing & Mathematical Suite (256 Runs)
contract SentinelFoundryCertification is Test {
    function test_Invariant_QuadraticPriceDropPrecision() public pure {
        uint160 initSqrtP = 1_000_000;
        uint160 currSqrtP = 905_538; // ~18% quadratic price drop
        (bool dropExceeded, uint256 dropBps) = PancakeV3InvariantChecker.checkExactPriceDrop(
            initSqrtP,
            currSqrtP,
            1500
        );
        assertTrue(dropExceeded, "18% drop must exceed 15% threshold");
        assertGe(dropBps, 1800, "Exact quadratic drop must be >= 1800 bps");
    }

    function testFuzz_PancakeV3LiquidityDrainageInvariant(uint128 initLiq, uint128 currLiq) public pure {
        vm.assume(initLiq > 10_000 && currLiq <= initLiq);
        (bool drainExceeded, uint256 drainBps) = PancakeV3InvariantChecker.checkLiquidityDrain(
            initLiq,
            currLiq,
            3000
        );
        uint256 expectedBps = (uint256(initLiq - currLiq) * 10000) / uint256(initLiq);
        assertEq(drainBps, expectedBps, "Drainage BPS must match exact FullMath mulDiv");
        assertEq(drainExceeded, expectedBps >= 3000, "Threshold trigger must be exact");
    }
}
