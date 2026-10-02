# -*- coding: utf-8 -*-
"""
===============================================================================
  SENTINEL FLEET TECHNOLOGIES — GEMINI FLASH FORENSICS TESTS
===============================================================================
Formal verification suite for AI-powered and deterministic DeFi forensic
anomaly analysis on BNB Chain & opBNB.
"""

import unittest
from backend.gemini_forensics_layer import GeminiForensicsEngine
from backend.telegram_sentinel_bot import TelegramSentinelBot


class MockMempoolWatcher:
    def __init__(self, chain_id=56):
        self.chain_id = chain_id
        self.last_known_block = 125210787
        self.monitored_pools = {}

    def get_latest_block(self):
        return 125210787

    def get_dynamic_gas_price(self):
        return 3_500_000_000, 3_000_000_000

    def get_full_telemetry(self):
        return {"liveBlock": 125210787, "privateRelay": {"provider": "Bloxroute", "status": "STANDBY"}}


class TestGeminiForensics(unittest.TestCase):

    def setUp(self):
        self.engine = GeminiForensicsEngine(api_key="")  # Offline/deterministic mode
        self.sample_incident = {
            "pool": "PancakeSwap_v3_WBNB_USDT",
            "poolAddress": "0x36696169C63e42cd08ce11f5deeBbCeBae652050",
            "dropBps": 2200,  # 22.0% drop
            "mitigationLatencyMs": 9.4,
            "action": "ATOMIC_PAUSE_TRIGGERED",
            "block": 125210787,
            "isSimulation": False
        }

    def test_deterministic_forensics_brief_es(self):
        brief = self.engine.generate_forensic_brief(self.sample_incident, lang="es")
        self.assertIn("ANÁLISIS FORENSE — GEMINI FLASH FORENSICS LAYER", brief)
        self.assertIn("CRÍTICA", brief)
        self.assertIn("22.0%", brief)
        self.assertIn("0x36696169", brief)
        self.assertIn("ATOMIC_PAUSE_TRIGGERED", brief)
        self.assertIn("$0.00 pérdida", brief)

    def test_deterministic_forensics_brief_en(self):
        brief = self.engine.generate_forensic_brief(self.sample_incident, lang="en")
        self.assertIn("FORENSIC BRIEF — GEMINI FLASH FORENSICS LAYER", brief)
        self.assertIn("CRITICAL", brief)
        self.assertIn("22.0%", brief)
        self.assertIn("$0.00 loss", brief)

    def test_bot_command_forense(self):
        mock_watcher = MockMempoolWatcher()
        bot = TelegramSentinelBot(bot_token="", db_path=":memory:", watcher=mock_watcher)
        response = bot.handle_command("6758917070", "/forense")
        self.assertIn("GEMINI FLASH FORENSICS", response)
        self.assertIn("ATOMIC_PAUSE_TRIGGERED", response)

    def test_bot_ayuda_includes_forense(self):
        mock_watcher = MockMempoolWatcher()
        bot = TelegramSentinelBot(bot_token="", db_path=":memory:", watcher=mock_watcher)
        help_response = bot.handle_command("6758917070", "/ayuda")
        self.assertIn("/forense", help_response)


if __name__ == "__main__":
    unittest.main()
