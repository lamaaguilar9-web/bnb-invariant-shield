# -*- coding: utf-8 -*-
"""
BNB Chain & opBNB Dynamic Gas Engine for Sentinel Fleet.
Reads real-time on-chain gas parameters via JSON-RPC eth_gasPrice and computes
protective priority pricing for accelerated mempool inclusion.
"""

import urllib.request
import json
from typing import Dict, Any, Optional

DEFAULT_BSC_RPC = "https://bsc-dataseed.binance.org/"


class BNBGasEngine:
    def __init__(self, chain_id: int = 56, priority_multiplier: float = 1.35, rpc_url: Optional[str] = None):
        self.chain_id = chain_id
        self.priority_multiplier = priority_multiplier
        self.rpc_url = rpc_url or DEFAULT_BSC_RPC
        # Minimum baseline fallback (1.0 Gwei for BSC, 0.001 Gwei for opBNB)
        self.min_gas_price_wei = int(1.0 * 1e9) if chain_id == 56 else int(0.001 * 1e9)

    def fetch_live_gas_price_wei(self) -> int:
        """Fetches live gas price from BNB Chain RPC via eth_gasPrice."""
        payload = json.dumps({"jsonrpc": "2.0", "method": "eth_gasPrice", "params": [], "id": 1}).encode("utf-8")
        try:
            req = urllib.request.Request(
                self.rpc_url,
                data=payload,
                headers={"Content-Type": "application/json", "User-Agent": "SentinelGasEngine/1.0"},
                method="POST"
            )
            with urllib.request.urlopen(req, timeout=3) as resp:
                if resp.status == 200:
                    data = json.loads(resp.read().decode("utf-8"))
                    gas_hex = data.get("result")
                    if gas_hex:
                        return max(int(gas_hex, 16), self.min_gas_price_wei)
        except Exception:
            pass
        return self.min_gas_price_wei

    def calculate_defense_gas(self, current_gas_price_wei: Optional[int] = None) -> Dict[str, Any]:
        """
        Computes dynamic gas pricing with priority buffer for frontrunning defense.
        Queries live network gas price via RPC if none provided.
        """
        if current_gas_price_wei is None:
            current_gas_price_wei = self.fetch_live_gas_price_wei()
        elif current_gas_price_wei < self.min_gas_price_wei:
            current_gas_price_wei = self.min_gas_price_wei

        # 35% priority buffer + 0.5 Gwei tip
        urgent_defense_gas_wei = int(current_gas_price_wei * self.priority_multiplier) + int(0.5 * 1e9)

        return {
            "chainId": self.chain_id,
            "network": "BNB Smart Chain (BSC)" if self.chain_id == 56 else "opBNB L2",
            "baseGasPriceGwei": round(current_gas_price_wei / 1e9, 3),
            "urgentDefenseGasGwei": round(urgent_defense_gas_wei / 1e9, 3),
            "urgentDefenseGasWei": urgent_defense_gas_wei,
            "overbidMultiplier": self.priority_multiplier,
            "priorityStatus": "BSC_PRIORITY_ACCELERATED"
        }
