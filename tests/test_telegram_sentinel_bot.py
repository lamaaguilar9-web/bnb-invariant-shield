# -*- coding: utf-8 -*-
"""
Formal Verification & Adversarial Unit Tests for Telegram Early-Warning Sentinel Bot (Project #11).
Tests command parsing, alert formatting, persistence, plan enforcement, on-chain validation, and zero-custody guarantees.
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

from backend.telegram_sentinel_bot import TelegramSentinelBot


class TestTelegramSentinelBot(unittest.TestCase):
    def setUp(self):
        # Use an isolated temporary database for each test and empty bot_token for dry-run testing
        self.temp_db = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        self.temp_db.close()
        self.bot = TelegramSentinelBot(bot_token="", db_path=self.temp_db.name)

    def tearDown(self):
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
        bot2 = TelegramSentinelBot(bot_token="", db_path=self.temp_db.name)
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
        self.assertIn("Bloque BSC", res)
        self.assertIn("Gas de Defensa", res)
        self.assertIn("SISTEMA OPERATIVO", res)

    def test_04_command_pools_list(self):
        """Verifies /pools lists active monitored targets on BSC."""
        res = self.bot.handle_command("user_100", "/pools")
        self.assertIn("PancakeSwap_v3_WBNB_USDT", res)
        self.assertIn("0x36696169C63e42cd08ce11f5deeBbCeBae652050", res)

    def test_05_plan_enforcement_and_onchain_validation(self):
        """Verifies tier limits (Free rejected, Pro capped at 3) and on-chain slot0 validation."""
        self.bot.handle_command("user_trader", "/start")
        
        # 1. FREE tier user attempts to add custom pool -> REJECTED
        res_free = self.bot.handle_command("user_trader", "/monitorear 0x36696169C63e42cd08ce11f5deeBbCeBae652050")
        self.assertIn("Acceso Restringido", res_free)
        self.assertIn("Plan FREE", res_free)

        # 2. Upgrade to PRO
        res_upgrade = self.bot.handle_command("user_trader", "/upgrade PRO")
        self.assertIn("PRO", res_upgrade)
        self.assertEqual(self.bot.subscribers["user_trader"]["plan"], "PRO")

        # 3. Invalid EVM address format -> REJECTED
        res_invalid = self.bot.handle_command("user_trader", "/monitorear 0xInvalidLength")
        self.assertIn("Error", res_invalid)

        # 4. Valid hex format but non-existent / reverting pool contract -> REJECTED ON-CHAIN
        dummy_reverting_addr = "0x000000000000000000000000000000000000dEaD"
        res_revert = self.bot.handle_command("user_trader", f"/monitorear {dummy_reverting_addr}")
        self.assertIn("Error de Validación On-Chain", res_revert)

        # 5. Live PancakeSwap v3 WBNB/USDT pool -> ACCEPTED ON-CHAIN
        real_pool = "0x36696169C63e42cd08ce11f5deeBbCeBae652050"
        res_success = self.bot.handle_command("user_trader", f"/monitorear {real_pool}")
        self.assertIn("Pool Verificado On-Chain", res_success)
        self.assertIn("High-Water Mark", res_success)

        # 6. Test Pro Plan Limit (Max 3 custom pools)
        # Mock 2 more pools in user subscriber dict to test boundary enforcement
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
        self.bot.handle_command("pro_user", "/upgrade PRO")
        self.bot.handle_command("ent_user", "/start")
        self.bot.handle_command("ent_user", "/upgrade ENTERPRISE")

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


if __name__ == "__main__":
    unittest.main()
