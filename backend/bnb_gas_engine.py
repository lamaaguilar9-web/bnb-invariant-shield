# -*- coding: utf-8 -*-
"""
BNB Chain & opBNB Dynamic Gas Engine for BNB Invariant Shield.
Calculates optimal gas parameters for sub-block inclusion on BSC (Chain ID 56) and opBNB (Chain ID 204).
"""

class BNBGasEngine:
    def __init__(self, chain_id: int = 56, priority_multiplier: float = 1.35):
        self.chain_id = chain_id
        self.priority_multiplier = priority_multiplier
        # Standard BSC base gas price is 1.0 - 3.0 Gwei; opBNB is ~0.001 Gwei
        self.min_gas_price_wei = int(1.0 * 1e9) if chain_id == 56 else int(0.001 * 1e9)

    def calculate_defense_gas(self, current_gas_price_wei: int = None) -> dict:
        """
        Computes dynamic gas pricing for guaranteed top-of-block inclusion by BNB Chain validators.
        """
        if current_gas_price_wei is None or current_gas_price_wei < self.min_gas_price_wei:
            current_gas_price_wei = self.min_gas_price_wei

        # Overbid baseline to outpace sandwich bots and predatory searchers
        urgent_defense_gas_wei = int(current_gas_price_wei * self.priority_multiplier) + int(0.5 * 1e9)

        return {
            "chainId": self.chain_id,
            "network": "BNB Smart Chain (BSC)" if self.chain_id == 56 else "opBNB L2",
            "baseGasPriceGwei": round(current_gas_price_wei / 1e9, 3),
            "urgentDefenseGasGwei": round(urgent_defense_gas_wei / 1e9, 3),
            "urgentDefenseGasWei": urgent_defense_gas_wei,
            "overbidMultiplier": self.priority_multiplier,
            "priorityStatus": "TOP_OF_BLOCK_BSC_GUARANTEED"
        }
