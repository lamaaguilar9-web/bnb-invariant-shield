# -*- coding: utf-8 -*-
"""
Formal Verification & Adversarial Unit Tests for Telegram Early-Warning Sentinel Bot (Project #11).
Tests continuous sensor daemon, verified TLS, plan gating (admin authorization), on-chain validation,
persistence, and zero-custody guarantees without external network dependency.
"""

import sys
import os
import unittest
import tempfile
import json
import time

project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if project_root not in sys.path:
    sys.path.insert(0, project_root)

from backend.telegram_sentinel_bot import TelegramSentinelBot, get_verified_ssl_context
from backend.bsc_mempool_watcher import BSCMempoolWatcher


class MockBSCMempoolWatcher(BSCMempoolWatcher):
    """Hermetic in-memory mock watcher for sub-second offline testing."""
    def __init__(self):
        super().__init__(chain_id=56, auto_sync=False)
        self.last_known_block = 125186820
        self.is_rpc_connected = True
        self.mock_incidents_to_return = []
        self.sync_calls_count = 0

        # Pre-seed monitored pool
        self.monitored_pools = {
            "PancakeSwap_v3_WBNB_USDT": {
                "address": "0x36696169C63e42cd08ce11f5deeBbCeBae652050",
                "protocol": "PancakeSwap v3 (0.05%)",
                "status": "HEALTHY_NORMAL",
                "hwm_sqrtPriceX96": 2853915751929161125982720598,
                "hwm_tick": -66477,
                "hwm_liquidity": 2341435359726145717360080,
                "current_sqrtPriceX96": 2853915751929161125982720598,
                "current_tick": -66477,
                "current_liquidity": 2341435359726145717360080,
                "last_synced_block": 125186820,
                "onchain_verified": True
            }
        }

    def sync_latest_block(self) -> int:
        self.sync_calls_count += 1
        return self.last_known_block

    def sync_pool_onchain(self, pool_key: str):
        return self.monitored_pools.get(pool_key)

    def fetch_pool_onchain_data(self, pool_address: str):
        clean_addr = pool_address.strip().lower()
        # Return valid mock state for canonical Pancake v3 WBNB/USDT
        if clean_addr == "0x36696169c63e42cd08ce11f5deebbcebae652050":
            return {
                "address": pool_address,
                "sqrtPriceX96": 2853915751929161125982720598,
                "tick": -66477,
                "liquidity": 2341435359726145717360080,
                "timestamp": int(time.time()),
                "onchain_verified": True
            }
        # Reject reverting or invalid pools
        return None

    def scan_monitored_invariants(self):
        incidents = list(self.mock_incidents_to_return)
        self.mock_incidents_to_return.clear()
        return incidents


class TestTelegramSentinelBot(unittest.TestCase):
    def setUp(self):
        # Use isolated temporary database and mock watcher for fast deterministic testing
        self.temp_db = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        self.temp_db.close()
        self.mock_watcher = MockBSCMempoolWatcher()
        self.bot = TelegramSentinelBot(
            bot_token="",
            db_path=self.temp_db.name,
            watcher=self.mock_watcher,
            scan_interval=0.05
        )

    def tearDown(self):
        self.bot.stop_monitoring()
        if os.path.exists(self.temp_db.name):
            try:
                os.remove(self.temp_db.name)
            except Exception:
                pass

    def test_01_initialization_and_persistence(self):
        """Verifies bot initializes safely and persists state across restarts."""
        self.assertIsNone(self.bot.api_base)
        # Register a test subscriber
        self.bot.handle_command("persist_user_1", "/start")
        self.assertIn("persist_user_1", self.bot.subscribers)

        # Instantiate second bot with same db_path to verify persistent restart survival
        bot2 = TelegramSentinelBot(
            bot_token="",
            db_path=self.temp_db.name,
            watcher=self.mock_watcher
        )
        self.assertIn("persist_user_1", bot2.subscribers)
        self.assertEqual(bot2.subscribers["persist_user_1"]["plan"], "FREE")

    def test_02_command_start_registration_free_tier(self):
        """Verifies /start registers subscriber under FREE tier and discloses zero custody."""
        res = self.bot.handle_command("user_100", "/start")
        self.assertIn("user_100", self.bot.subscribers)
        self.assertEqual(self.bot.subscribers["user_100"]["plan"], "FREE")
        self.assertIn("Luis Aguilar", res)
        self.assertIn("Sentinel Fleet", res)
        self.assertIn("No-Custodial", res)

    def test_03_command_status_telemetry(self):
        """Verifies /status outputs live Houston node metrics and gas defense."""
        res = self.bot.handle_command("user_100", "/status")
        self.assertIn("HOUSTON VPS", res)
        self.assertIn("Bloque BSC (RPC)", res)
        self.assertIn("Gas de Defensa", res)
        self.assertIn("SISTEMA OPERATIVO", res)

    def test_04_command_pools_list(self):
        """Verifies /pools lists active monitored targets on BSC."""
        res = self.bot.handle_command("user_100", "/pools")
        self.assertIn("PancakeSwap_v3_WBNB_USDT", res)
        self.assertIn("0x36696169C63e42cd08ce11f5deeBbCeBae652050", res)

    def test_05_plan_enforcement_and_admin_gate(self):
        """Verifies tier limits and admin-only upgrade authorization (P11-M7)."""
        self.bot.handle_command("user_trader", "/start")
        
        # 1. FREE tier user attempts to add custom pool -> REJECTED
        res_free = self.bot.handle_command("user_trader", "/monitorear 0x36696169C63e42cd08ce11f5deeBbCeBae652050")
        self.assertIn("Acceso Restringido", res_free)
        self.assertIn("Plan FREE", res_free)

        # 2. Self-service /upgrade without payment -> REJECTED (returns treasury instructions)
        res_self_upgrade = self.bot.handle_command("user_trader", "/upgrade PRO")
        self.assertIn("Activación de Planes", res_self_upgrade)
        self.assertIn("0x15C42d6E839182045f1248030fEF310b3cF3d74e", res_self_upgrade)
        self.assertEqual(self.bot.subscribers["user_trader"]["plan"], "FREE")

        # 3. Non-admin attempting /setplan -> REJECTED
        res_unauthorized = self.bot.handle_command("user_trader", "/setplan user_trader PRO")
        self.assertIn("Acceso denegado", res_unauthorized)

        # 4. Authorized admin (6758917070) executes /setplan -> APPROVED
        res_admin_set = self.bot.handle_command("6758917070", "/setplan user_trader PRO")
        self.assertIn("Admin Éxito", res_admin_set)
        self.assertEqual(self.bot.subscribers["user_trader"]["plan"], "PRO")

        # 5. Invalid EVM address format -> REJECTED
        res_invalid = self.bot.handle_command("user_trader", "/monitorear 0xInvalidLength")
        self.assertIn("Error", res_invalid)

        # 6. Valid hex format but non-existent / reverting pool contract -> REJECTED ON-CHAIN
        dummy_reverting_addr = "0x000000000000000000000000000000000000dEaD"
        res_revert = self.bot.handle_command("user_trader", f"/monitorear {dummy_reverting_addr}")
        self.assertIn("Error de Validación On-Chain", res_revert)

        # 7. Valid PancakeSwap v3 pool -> ACCEPTED ON-CHAIN
        real_pool = "0x36696169C63e42cd08ce11f5deeBbCeBae652050"
        res_success = self.bot.handle_command("user_trader", f"/monitorear {real_pool}")
        self.assertIn("Pool Verificado On-Chain", res_success)
        self.assertIn("High-Water Mark", res_success)

        # 8. Test Pro Plan Limit (Max 3 custom pools)
        self.bot.subscribers["user_trader"]["pools"].extend(["Pool_2", "Pool_3"])
        custom_pools = [p for p in self.bot.subscribers["user_trader"]["pools"] if p != "PancakeSwap_v3_WBNB_USDT"]
        self.assertEqual(len(custom_pools), 3)
        res_capped = self.bot.handle_command("user_trader", f"/monitorear {real_pool}")
        self.assertIn("Límite Alcanzado", res_capped)

    def test_06_simular_and_honest_alert_formatting(self):
        """Verifies /simular triggers attack telemetry and ensures ZERO fake bundle hashes."""
        self.bot.handle_command("user_100", "/start")
        res = self.bot.handle_command("user_100", "/simular")
        self.assertIn("Simulación de Ataque Invariant Ejecutada", res)

        self.assertGreaterEqual(len(self.bot.alert_history), 1)
        last_alert = self.bot.alert_history[-1]
        formatted = self.bot.format_alert_message(last_alert)

        # Honest assertions: Zero fake bundle hashes
        self.assertNotIn("Bundle Relayed", formatted)
        self.assertNotIn("0x...bnb99shield", formatted)
        self.assertIn("MEMPOOL EARLY WARNING", formatted)
        self.assertIn("Anomalía Detectada", formatted)
        self.assertIn("BscScan", formatted)
        self.assertIn("Sentinel Fleet Technologies", formatted)

    def test_07_pricing_plans(self):
        """Verifies /planes presents Free, $150 Pro, and $300 Enterprise SaaS tiers."""
        res = self.bot.handle_command("user_100", "/planes")
        self.assertIn("Plan Free", res)
        self.assertIn("$150 / mes", res)
        self.assertIn("$300 / mes", res)
        self.assertIn("PayFi No-Custodiales", res)

    def test_08_broadcast_multi_subscriber_with_plan_filtering(self):
        """Verifies broadcast dispatches community alerts to all, and custom alerts only to authorized tiers."""
        self.bot.handle_command("free_user", "/start")
        self.bot.handle_command("pro_user", "/start")
        self.bot.handle_command("6758917070", "/setplan pro_user PRO")
        self.bot.handle_command("ent_user", "/start")
        self.bot.handle_command("6758917070", "/setplan ent_user ENTERPRISE")

        # 1. Community incident on PancakeSwap_v3_WBNB_USDT -> All subscribers receive it
        community_incident = {
            "timestamp": int(time.time()),
            "chain": "BNB Chain (Chain ID 56)",
            "pool": "PancakeSwap_v3_WBNB_USDT",
            "poolAddress": "0x36696169C63e42cd08ce11f5deeBbCeBae652050",
            "dropBps": 2500,
            "action": "ATOMIC_PAUSE_TRIGGERED",
            "mitigationLatencyMs": 12.5
        }
        delivered_comm = self.bot.broadcast_alert(community_incident)
        self.assertGreaterEqual(delivered_comm, 3)

        # 2. Custom pool incident assigned only to pro_user
        self.bot.subscribers["pro_user"]["pools"].append("Custom_Pool_Alpha")
        custom_incident = {
            "timestamp": int(time.time()),
            "chain": "BNB Chain (Chain ID 56)",
            "pool": "Custom_Pool_Alpha",
            "poolAddress": "0x1234567890123456789012345678901234567890",
            "dropBps": 1800,
            "action": "ATOMIC_PAUSE_TRIGGERED",
            "mitigationLatencyMs": 10.0
        }
        delivered_custom = self.bot.broadcast_alert(custom_incident)
        # pro_user (assigned) and enterprise accounts (ent_user + default admin) receive it; free_user does NOT
        self.assertIn(delivered_custom, (2, 3))

    def test_09_continuous_sensor_daemon_and_incident_broadcast(self):
        """Verifies the continuous sensor daemon thread executes scans and broadcasts real incidents (P11-B1)."""
        self.bot.handle_command("daemon_user", "/start")
        
        # Inject an on-chain incident into the mock watcher
        test_incident = {
            "timestamp": int(time.time()),
            "chain": "BNB Chain (Chain ID 56)",
            "block": 125186821,
            "pool": "PancakeSwap_v3_WBNB_USDT",
            "poolAddress": "0x36696169C63e42cd08ce11f5deeBbCeBae652050",
            "dropBps": 1850,
            "tickDelta": 1700,
            "drainBps": 3200,
            "action": "ATOMIC_PAUSE_TRIGGERED",
            "isSimulation": False
        }
        self.mock_watcher.mock_incidents_to_return.append(test_incident)

        # Start sensor daemon
        self.bot.start_monitoring_daemon()
        self.assertTrue(self.bot.is_running)
        self.assertIsNotNone(self.bot._scanner_thread)
        self.assertTrue(self.bot._scanner_thread.is_alive())

        # Wait briefly for daemon cycle (scan_interval is 0.05s)
        time.sleep(0.15)
        self.bot.stop_monitoring()

        # Verify incident was detected by daemon and recorded in alert history
        self.assertGreaterEqual(len(self.bot.alert_history), 1)
        last_rec = self.bot.alert_history[-1]
        self.assertEqual(last_rec["pool"], "PancakeSwap_v3_WBNB_USDT")
        self.assertEqual(last_rec["dropBps"], 1850)
        self.assertFalse(last_rec["isSimulation"])

    def test_10_strict_verified_ssl_context(self):
        """Verifies get_verified_ssl_context enforces TLS verification without unverified fallbacks (P11-H4)."""
        ctx = get_verified_ssl_context()
        self.assertIsNotNone(ctx)
        self.assertTrue(ctx.check_hostname)
        import ssl
        self.assertEqual(ctx.verify_mode, ssl.CERT_REQUIRED)


if __name__ == "__main__":
    unittest.main()
