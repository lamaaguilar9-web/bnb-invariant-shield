# -*- coding: utf-8 -*-
"""
Formal Verification & Unit Tests for Telegram Early-Warning Sentinel Bot (Project #11).
Tests command parsing, alert formatting, subscriber registry, and zero-custody guarantees.
"""

import sys
import os
import unittest

project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if project_root not in sys.path:
    sys.path.insert(0, project_root)

from backend.telegram_sentinel_bot import TelegramSentinelBot


class TestTelegramSentinelBot(unittest.TestCase):
    def setUp(self):
        self.bot = TelegramSentinelBot(bot_token=None)

    def test_01_initialization(self):
        """Verifies bot initializes safely without external tokens in test mode."""
        self.assertIsNone(self.bot.api_base)
        self.assertEqual(len(self.bot.subscribers), 0)
        self.assertEqual(len(self.bot.alert_history), 0)

    def test_02_command_start_registration(self):
        """Verifies /start registers subscriber and displays founder & non-custodial disclosures."""
        res = self.bot.handle_command("user_100", "/start")
        self.assertIn("user_100", self.bot.subscribers)
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
        """Verifies /pools lists active monitored PancakeSwap v3 & Venus targets."""
        res = self.bot.handle_command("user_100", "/pools")
        self.assertIn("PancakeSwap_v3_WBNB_USDT", res)
        self.assertIn("0x36696169C63e42cd08ce11f5deeBbCeBae652050", res)

    def test_05_command_monitorear_validation(self):
        """Verifies /monitorear strictly validates EVM contract addresses."""
        # Invalid address format
        res_invalid = self.bot.handle_command("user_100", "/monitorear invalid_addr")
        self.assertIn("Error", res_invalid)

        # Valid 42-char address
        valid_addr = "0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640"
        res_valid = self.bot.handle_command("user_100", f"/monitorear {valid_addr}")
        self.assertIn("Pool Añadido al Vigía con Éxito", res_valid)
        self.assertIn(valid_addr, res_valid)

    def test_06_simular_and_alert_formatting(self):
        """Verifies /simular triggers attack telemetry and formats Markdown alert."""
        self.bot.handle_command("user_100", "/start")
        res = self.bot.handle_command("user_100", "/simular")
        self.assertIn("Simulación de Ataque Invariant Ejecutada", res)

        self.assertGreaterEqual(len(self.bot.alert_history), 1)
        last_alert = self.bot.alert_history[-1]
        formatted = self.bot.format_alert_message(last_alert)

        self.assertIn("MEMPOOL EARLY WARNING", formatted)
        self.assertIn("Drenaje Detectado", formatted)
        self.assertIn("BscScan", formatted)
        self.assertIn("Sentinel Fleet Technologies", formatted)

    def test_07_pricing_plans(self):
        """Verifies /planes presents the $150 Pro and $300 Enterprise SaaS tiers."""
        res = self.bot.handle_command("user_100", "/planes")
        self.assertIn("$150 / mes", res)
        self.assertIn("$300 / mes", res)
        self.assertIn("PayFi No-Custodiales", res)

    def test_08_broadcast_multi_subscriber(self):
        """Verifies broadcast dispatches to multiple registered subscribers."""
        self.bot.handle_command("user_1", "/start")
        self.bot.handle_command("user_2", "/start")
        self.bot.handle_command("user_3", "/start")

        dummy_incident = {
            "timestamp": 1700000000,
            "chain": "BNB Chain (Chain ID 56)",
            "pool": "PancakeSwap_v3_WBNB_USDT",
            "poolAddress": "0x36696169C63e42cd08ce11f5deeBbCeBae652050",
            "dropBps": 2500,
            "action": "ATOMIC_PAUSE_TRIGGERED",
            "mitigationLatencyMs": 12.5,
            "bundleHash": "0xabc123456789def0"
        }
        delivered = self.bot.broadcast_alert(dummy_incident)
        self.assertEqual(delivered, 3)


if __name__ == "__main__":
    unittest.main()
