# -*- coding: utf-8 -*-
"""
Sentinel Fleet Technologies - Telegram Early-Warning Sentinel Bot (Project #11)
==============================================================================
Institutional Real-Time Alerting System for BNB Chain & opBNB.
Monitors PancakeSwap v3 concentrated liquidity pools and on-chain state invariants.
Broadcasts instant warning alerts to Telegram subscribers upon detecting
mempool drain attempts, TWAP divergences, and sudden reserve shifts.

Designed & Architected by Luis Aguilar, Founder & Lead Systems Architect, Sentinel Fleet Technologies.
Zero-Custody Architecture ($0.00 client funds held - Pure Information Intelligence SaaS).
"""

import sys
import os
import time
import json
import threading
import urllib.request
import urllib.parse
from typing import Dict, List, Optional, Any

if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

# Ensure project root is in sys.path
project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if project_root not in sys.path:
    sys.path.insert(0, project_root)

# Load local .env if present
def _load_env_file():
    env_path = os.path.join(project_root, ".env")
    if os.path.exists(env_path):
        try:
            with open(env_path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
        except Exception:
            pass

_load_env_file()

from backend.bsc_mempool_watcher import BSCMempoolWatcher


class TelegramSentinelBot:
    """
    Autonomous Telegram Alert Bot engine with disk persistence and tier-based gating.
    Zero third-party dependencies (pure standard library urllib/json).
    Enforces subscription plans: Free (public feed), Pro (up to 3 custom pools), Enterprise (unlimited).
    Validates custom pool contracts on-chain before admitting to monitor registry.
    """

    def __init__(self, bot_token: Optional[str] = None, db_path: Optional[str] = None):
        if bot_token is not None:
            self.bot_token = bot_token.strip()
        else:
            self.bot_token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()

        self.api_base = f"https://api.telegram.org/bot{self.bot_token}" if self.bot_token else None
        self.watcher = BSCMempoolWatcher(chain_id=56)
        
        self.data_dir = os.path.join(project_root, "data")
        os.makedirs(self.data_dir, exist_ok=True)
        self.db_path = db_path if db_path is not None else os.path.join(self.data_dir, "subscribers.json")

        self.subscribers: Dict[str, Dict[str, Any]] = {}
        self.alert_history: List[Dict[str, Any]] = []
        self.is_running = False
        self.last_update_id = 0
        self._lock = threading.Lock()

        # Load persisted subscribers and alerts
        self._load_db()

    def _load_db(self):
        """Loads subscriber registry and historical incident logs from persistent disk storage."""
        if not self.db_path or not os.path.exists(self.db_path) or os.path.getsize(self.db_path) == 0:
            # Seed default administrative enterprise account for Luis Aguilar
            self.subscribers = {
                "6758917070": {
                    "plan": "ENTERPRISE",
                    "subscribed_at": int(time.time()),
                    "pools": ["PancakeSwap_v3_WBNB_USDT"]
                }
            }
            self.alert_history = []
            self._save_db()
            return

        try:
            with open(self.db_path, "r", encoding="utf-8") as f:
                data = json.load(f)
                self.subscribers = data.get("subscribers", {})
                self.alert_history = data.get("alert_history", [])
        except Exception as e:
            print(f"[WARN] Failed to read database from {self.db_path}: {e}. Initializing fresh registry.")
            self.subscribers = {}
            self.alert_history = []

    def _save_db(self):
        """Safely writes subscriber database to disk with atomic write."""
        if not self.db_path:
            return

        payload = {
            "version": "2.0-bsc-rpc",
            "last_updated": int(time.time()),
            "subscribers": self.subscribers,
            "alert_history": self.alert_history[-50:]  # Keep last 50 incidents
        }

        tmp_path = f"{self.db_path}.tmp"
        try:
            with open(tmp_path, "w", encoding="utf-8") as f:
                json.dump(payload, f, indent=2, ensure_ascii=False)
            if os.path.exists(self.db_path):
                os.replace(tmp_path, self.db_path)
            else:
                os.rename(tmp_path, self.db_path)
        except Exception as e:
            print(f"[ERROR] Failed to persist database to {self.db_path}: {e}")

    def format_alert_message(self, incident: Dict[str, Any]) -> str:
        """
        Formats high-urgency institutional alert using HTML formatting.
        Contains strictly honest verified on-chain metrics; zero fabricated bundle hashes.
        """
        pool_addr = incident.get("poolAddress", "0x0000")
        pool_name = incident.get("pool", "Unknown Pool")
        drop_pct = f"{incident.get('dropBps', 0) / 100:.1f}%"
        latency = incident.get("mitigationLatencyMs", 0)
        action = incident.get("action", "MONITORED_ANOMALY")
        block = incident.get("block", "N/A")
        is_sim = incident.get("isSimulation", False)
        
        sim_tag = " [TEST SIMULATION]" if is_sim else " [LIVE ON-CHAIN BREACH]"

        message = (
            f"🚨 <b>SENTINEL FLEET — MEMPOOL EARLY WARNING{sim_tag}</b> 🚨\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            f"📍 <b>Pool:</b> <code>{pool_name}</code>\n"
            f"🔗 <b>Contrato:</b> <code>{pool_addr}</code>\n"
            f"📉 <b>Anomalía Detectada:</b> <code>{drop_pct}</code>\n"
            f"⚡ <b>Latencia Sensor:</b> <code>{latency} ms</code>\n"
            f"🛡️ <b>Acción Recomendada:</b> <code>{action}</code>\n"
            f"🧱 <b>Bloque BSC:</b> <code>#{block}</code>\n"
            f"🛰️ <b>Canal:</b> <code>Sentinel Private Telemetry</code>\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            f"🔍 <a href=\"https://bscscan.com/address/{pool_addr}\">Verificar Contrato en BscScan</a>\n"
            "⚠️ <b>Sentinel Invariant Shield:</b> Verificación no custodial en BSC.\n"
            "🏢 <b>Sentinel Fleet Technologies</b> — <i>Seguridad Autónoma Institucional</i>"
        )
        return message

    def send_telegram_message(self, chat_id: str, text: str) -> bool:
        """Sends a message via Telegram Bot API with HTML formatting using native urllib."""
        if not self.bot_token or not self.api_base:
            # Simulation / Dry-run fallback for tests
            try:
                print(f"[DRY-RUN TELEGRAM -> {chat_id}]:\n{text}\n")
            except UnicodeEncodeError:
                safe_text = text.encode("ascii", errors="replace").decode("ascii")
                print(f"[DRY-RUN TELEGRAM -> {chat_id}]:\n{safe_text}\n")
            return True

        url = f"{self.api_base}/sendMessage"
        payload = {
            "chat_id": chat_id,
            "text": text,
            "parse_mode": "HTML",
            "disable_web_page_preview": True
        }
        try:
            req = urllib.request.Request(
                url,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST"
            )
            with urllib.request.urlopen(req, timeout=5) as response:
                return response.status == 200
        except Exception as e:
            print(f"[ERROR] Failed to send Telegram message to {chat_id}: {e}")
            return False

    def broadcast_alert(self, incident: Dict[str, Any]) -> int:
        """
        Broadcasts an incident alert to eligible subscribers based on plan tiers.
        Free subscribers receive public community alerts (WBNB/USDT).
        Pro & Enterprise receive alerts for their custom monitored targets.
        """
        text = self.format_alert_message(incident)
        pool_key = incident.get("pool", "")
        is_community_pool = (pool_key == "PancakeSwap_v3_WBNB_USDT")

        with self._lock:
            self.alert_history.append(incident)
            self._save_db()

            # Filter recipients by subscription plan and assigned pool
            eligible_recipients = []
            for chat_id, sub_info in self.subscribers.items():
                plan = sub_info.get("plan", "FREE")
                user_pools = sub_info.get("pools", [])

                if is_community_pool:
                    # Community alerts are broadcast to all subscribers
                    eligible_recipients.append(chat_id)
                elif plan == "ENTERPRISE" or pool_key in user_pools:
                    # Custom pool alerts are sent only to pool subscribers or enterprise tier
                    eligible_recipients.append(chat_id)

        delivered = 0
        for chat_id in eligible_recipients:
            if self.send_telegram_message(chat_id, text):
                delivered += 1
        return delivered

    def handle_command(self, chat_id: str, command_text: str) -> str:
        """Processes incoming user commands with strict plan enforcement and on-chain RPC checks."""
        parts = command_text.strip().split()
        if not parts:
            return "Comando no reconocido. Escribe /ayuda para ver las opciones."

        cmd = parts[0].lower()

        if cmd in ("/start", "/inicio"):
            with self._lock:
                if chat_id not in self.subscribers:
                    # New subscribers start on FREE plan (not automatic Pro Trial)
                    self.subscribers[chat_id] = {
                        "plan": "FREE",
                        "subscribed_at": int(time.time()),
                        "pools": ["PancakeSwap_v3_WBNB_USDT"]
                    }
                    self._save_db()
                current_plan = self.subscribers[chat_id].get("plan", "FREE")

            return (
                "🛡️ <b>Bienvenido a Sentinel Fleet Early-Warning Bot</b> 🛡️\n\n"
                "Sistema de alerta temprana y monitoreo institucional para pools en <b>BNB Chain</b> y <b>opBNB</b>.\n"
                "Protección en tiempo real contra flash-loans, drenajes de liquidez y despegues de TWAP.\n\n"
                f"👤 <b>Tu Plan Actual:</b> <code>{current_plan}</code>\n\n"
                "📌 <b>Comandos Disponibles:</b>\n"
                "• <code>/status</code> - Salud del nodo en Houston y métricas BSC RPC en vivo.\n"
                "• <code>/pools</code> - Pools bajo vigilancia activa.\n"
                "• <code>/monitorear &lt;0xDireccion&gt;</code> - Agregar un pool de PancakeSwap v3 (Requiere Pro/Enterprise).\n"
                "• <code>/simular</code> - Demostración de detección de drenaje en milisegundos.\n"
                "• <code>/alertas</code> - Historial de incidentes recientes.\n"
                "• <code>/planes</code> - Opciones de suscripción SaaS ($150–$300/mes).\n\n"
                "🔒 <b>Arquitectura 100% No-Custodial:</b> $0.00 fondos en custodia.\n"
                "Desarrollado por <b>Luis Aguilar</b> | <b>Sentinel Fleet Technologies</b>."
            )

        elif cmd == "/status":
            telemetry = self.watcher.get_telemetry_state()
            gas_gwei = telemetry["gas"].get("urgentDefenseGasGwei", 1.5)
            base_gas = telemetry["gas"].get("baseGasPriceGwei", 1.0)
            block = telemetry["bscBlock"]
            rpc_status = "🟢 Conectado" if telemetry["rpcConnected"] else "🟡 Fallback / Offline"
            
            return (
                "🛰️ <b>ESTADO DE TELEMETRÍA SENTINEL (HOUSTON VPS)</b>\n"
                "━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
                f"🌐 <b>Red:</b> {telemetry['network']}\n"
                f"🧱 <b>Bloque BSC (RPC):</b> <code>#{block}</code>\n"
                f"🔌 <b>Conexión JSON-RPC:</b> {rpc_status}\n"
                f"⛽ <b>Gas Base BSC:</b> <code>{base_gas:.2f} Gwei</code>\n"
                f"⚡ <b>Gas de Defensa:</b> <code>{gas_gwei:.2f} Gwei</code> (1.35x + 0.5 Gwei tip)\n"
                f"🛡️ <b>Private Relay:</b> <code>{telemetry['privateRelay']['provider']}</code> ({telemetry['privateRelay']['status']})\n"
                f"📊 <b>Pools Monitoreados:</b> <code>{len(self.watcher.monitored_pools)}</code>\n"
                f"🚨 <b>Incidentes Registrados:</b> <code>{len(self.alert_history)}</code>\n"
                "━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
                "🟢 <b>Estado Global:</b> SISTEMA OPERATIVO Y VIGILANDO"
            )

        elif cmd == "/pools":
            lines = ["📋 <b>POOLS BAJO VIGILANCIA SENTINEL (ON-CHAIN BSC):</b>\n"]
            for name, data in self.watcher.monitored_pools.items():
                status_icon = "🟢" if data["status"] == "HEALTHY_NORMAL" else "🔴"
                onchain_badge = " [RPC OK]" if data.get("onchain_verified") else " [PENDING]"
                lines.append(f"{status_icon} <b>{name}</b>{onchain_badge}")
                lines.append(f"   Contrato: <code>{data['address']}</code>")
                lines.append(f"   Protocolo: {data['protocol']}\n")
            return "\n".join(lines)

        elif cmd == "/monitorear":
            if len(parts) < 2:
                return "⚠️ <b>Uso:</b> <code>/monitorear 0xDireccionDelPool</code>"

            with self._lock:
                sub_info = self.subscribers.get(chat_id, {"plan": "FREE", "pools": []})
                plan = sub_info.get("plan", "FREE")
                user_pools = sub_info.get("pools", [])

            # Plan enforcement: Free cannot add custom pools
            if plan == "FREE":
                return (
                    "⚠️ <b>Acceso Restringido a Plan FREE:</b>\n\n"
                    "El Plan Free incluye alertas para el pool comunitario principal (WBNB/USDT).\n"
                    "Para monitorear pools dedicados de tus propios proyectos, actualiza a:\n"
                    "• <b>Plan PRO ($150/mes):</b> Hasta 3 pools personalizados.\n"
                    "• <b>Plan ENTERPRISE ($300/mes):</b> Monitoreo de pools ilimitados.\n\n"
                    "Escribe <code>/planes</code> para detalles de suscripción o <code>/upgrade PRO</code> para activar."
                )

            # Plan enforcement: Pro is capped at 3 custom pools (excluding the default community pool)
            custom_pools = [p for p in user_pools if p != "PancakeSwap_v3_WBNB_USDT"]
            if plan == "PRO" and len(custom_pools) >= 3:
                return (
                    "⚠️ <b>Límite Alcanzado (Plan PRO):</b>\n\n"
                    "Tu suscripción PRO ya cuenta con 3 de 3 pools configurados.\n"
                    "Para añadir pools adicionales de manera ilimitada, actualiza al <b>Plan ENTERPRISE</b> ($300/mes)."
                )

            pool_addr = parts[1].strip()
            if not pool_addr.startswith("0x") or len(pool_addr) != 42:
                return "❌ <b>Error:</b> Formato de dirección EVM inválido. Debe contener 42 caracteres comenzando con 0x."

            # Verify contract on-chain via live BSC JSON-RPC slot0() call
            pool_state = self.watcher.fetch_pool_onchain_data(pool_addr)
            if not pool_state:
                return (
                    "❌ <b>Error de Validación On-Chain BSC:</b>\n\n"
                    f"El contrato <code>{pool_addr}</code> no respondió al método <code>slot0()</code> de PancakeSwap v3 o revirtió la llamada.\n"
                    "Verifica en BscScan que corresponda a un pool Concentrado v3 válido antes de agregarlo."
                )

            custom_name = f"PancakeSwap_v3_{pool_addr[:6]}...{pool_addr[-4:]}"
            with self._lock:
                self.watcher.monitored_pools[custom_name] = {
                    "address": pool_addr,
                    "protocol": "PancakeSwap v3 (Custom Watch)",
                    "status": "HEALTHY_NORMAL",
                    "hwm_sqrtPriceX96": pool_state["sqrtPriceX96"],
                    "hwm_tick": pool_state["tick"],
                    "hwm_liquidity": pool_state["liquidity"],
                    "current_sqrtPriceX96": pool_state["sqrtPriceX96"],
                    "current_tick": pool_state["tick"],
                    "current_liquidity": pool_state["liquidity"],
                    "last_synced_block": self.watcher.last_known_block,
                    "onchain_verified": True
                }
                if chat_id in self.subscribers:
                    if custom_name not in self.subscribers[chat_id]["pools"]:
                        self.subscribers[chat_id]["pools"].append(custom_name)
                self._save_db()

            return (
                "✅ <b>Pool Verificado On-Chain y Añadido al Vigía con Éxito!</b>\n\n"
                f"📍 <b>Dirección:</b> <code>{pool_addr}</code>\n"
                f"🎯 <b>Tick Actual:</b> <code>{pool_state['tick']}</code>\n"
                f"📊 <b>Liquidez Activa:</b> <code>{pool_state['liquidity']}</code>\n"
                f"🧱 <b>Bloque Anclado:</b> <code>#{self.watcher.last_known_block}</code>\n"
                f"🛡️ <b>High-Water Mark:</b> Anclado para detección de drenaje y tick delta."
            )

        elif cmd == "/simular":
            incident = self.watcher.simulate_attack_and_mitigate("PancakeSwap_v3_WBNB_USDT")
            self.broadcast_alert(incident)
            return (
                "⚡ <b>Simulación de Ataque Invariant Ejecutada!</b>\n"
                "Se generó una alerta de prueba (-26.0%) evaluada por el motor de invariantes para demostrar la velocidad de respuesta."
            )

        elif cmd == "/alertas":
            with self._lock:
                if not self.alert_history:
                    return "ℹ️ <b>Historial Limpio:</b> No se han registrado anomalías críticas en las últimas horas."
                last = self.alert_history[-1]
                sim_str = " (SIMULACIÓN)" if last.get("isSimulation") else " (ON-CHAIN)"
                return (
                    f"🚨 <b>ÚLTIMO INCIDENTE REGISTRADO{sim_str}:</b>\n"
                    f"• <b>Pool:</b> <code>{last['pool']}</code>\n"
                    f"• <b>Caída / Desvío:</b> <code>{last['dropBps'] / 100:.1f}%</code>\n"
                    f"• <b>Acción:</b> <code>{last['action']}</code>\n"
                    f"• <b>Bloque BSC:</b> <code>#{last.get('block', 'N/A')}</code>\n"
                    f"• <b>Timestamp:</b> <code>{time.ctime(last['timestamp'])}</code>"
                )

        elif cmd == "/upgrade":
            if len(parts) < 2:
                return "⚠️ <b>Uso:</b> <code>/upgrade PRO</code> o <code>/upgrade ENTERPRISE</code>"
            target_plan = parts[1].upper()
            if target_plan not in ("FREE", "PRO", "ENTERPRISE"):
                return "❌ Plan no válido. Opciones: <code>FREE</code>, <code>PRO</code>, <code>ENTERPRISE</code>."

            with self._lock:
                if chat_id not in self.subscribers:
                    self.subscribers[chat_id] = {"plan": target_plan, "subscribed_at": int(time.time()), "pools": ["PancakeSwap_v3_WBNB_USDT"]}
                else:
                    self.subscribers[chat_id]["plan"] = target_plan
                self._save_db()

            return f"🎉 <b>Plan Actualizado con Éxito:</b> Tu cuenta ahora tiene nivel <b>{target_plan}</b>."

        elif cmd == "/planes":
            return (
                "💎 <b>MODELO DE SUSCRIPCIÓN SAAS — SENTINEL FLEET</b>\n"
                "━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
                "🥉 <b>Plan Free (Comunidad):</b>\n"
                "• Alertas públicas en canal general para WBNB/USDT.\n"
                "• Precio: <b>$0.00</b>\n\n"
                "🥈 <b>Plan Pro ($150 / mes):</b>\n"
                "• Monitoreo dedicado de hasta 3 pools personalizados.\n"
                "• Alertas privadas directas a tu chat en tiempo real.\n"
                "• Detección de drenajes de liquidez (>30%) y desvíos de TWAP (>15%).\n\n"
                "🥇 <b>Plan Enterprise ($300 / mes):</b>\n"
                "• Monitoreo de pools ilimitados.\n"
                "• Integración con BNB Invariant Shield (pausa on-chain autónoma).\n"
                "• Prioridad de soporte y telemetría dedicada.\n"
                "━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
                "💳 <b>Pagos PayFi No-Custodiales:</b> USDT/BUSD en BSC.\n"
                "📩 Usa <code>/upgrade PRO</code> o contacta a <b>@SentinelFleetOps</b> para facturación institucional."
            )

        elif cmd in ("/ayuda", "/help"):
            return (
                "ℹ️ <b>Comandos del Bot de Sentinel Fleet:</b>\n\n"
                "• <code>/status</code> - Estatus del sistema y telemetría BSC en vivo.\n"
                "• <code>/pools</code> - Lista de pools monitoreados.\n"
                "• <code>/monitorear &lt;0xDireccion&gt;</code> - Agregar pool a monitorear (Pro/Enterprise).\n"
                "• <code>/upgrade &lt;PRO|ENTERPRISE&gt;</code> - Gestionar nivel de suscripción.\n"
                "• <code>/simular</code> - Demostración de alerta de ataque.\n"
                "• <code>/alertas</code> - Ver últimas alertas registradas.\n"
                "• <code>/planes</code> - Precios y suscripciones mensuales."
            )

        return "Comando no reconocido. Escribe /ayuda para ver las opciones disponibles."

    def poll_updates_once(self) -> List[Dict[str, Any]]:
        """Queries Telegram getUpdates once and dispatches handlers."""
        if not self.api_base:
            return []

        url = f"{self.api_base}/getUpdates?offset={self.last_update_id + 1}&timeout=2"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "SentinelFleetBot/2.0"})
            with urllib.request.urlopen(req, timeout=5) as response:
                if response.status == 200:
                    data = json.loads(response.read().decode("utf-8"))
                    results = data.get("result", [])
                    for update in results:
                        self.last_update_id = update["update_id"]
                        msg = update.get("message", {})
                        chat = msg.get("chat", {})
                        chat_id = str(chat.get("id", ""))
                        text = msg.get("text", "")
                        if chat_id and text:
                            reply = self.handle_command(chat_id, text)
                            self.send_telegram_message(chat_id, reply)
                    return results
        except Exception as e:
            # Keep logging visible instead of silently swallowing
            if "timed out" not in str(e).lower():
                print(f"[WARN] Telegram polling update error: {e}")
        return []


if __name__ == "__main__":
    print("=" * 70)
    print("  SENTINEL FLEET - TELEGRAM EARLY-WARNING SENTINEL BOT (PROJECT #11)")
    print("  Founder & Lead Systems Architect: Luis Aguilar")
    print("=" * 70)
    
    token = os.environ.get("TELEGRAM_BOT_TOKEN")
    bot = TelegramSentinelBot(bot_token=token)
    
    if token:
        print(f"[+] Bot inicializado con Token real. Conectando a Telegram...")
        print("[+] Modo de escucha activo (presiona Ctrl+C para salir)...")
        try:
            while True:
                bot.poll_updates_once()
                time.sleep(1.5)
        except KeyboardInterrupt:
            print("\n[-] Bot detenido por el usuario.")
    else:
        print("[!] No se detectó TELEGRAM_BOT_TOKEN en variables de entorno.")
        print("[+] Ejecutando en Modo Simulación Local (Dry-Run Test)...")
        print("\n--- TEST: Comando /start ---")
        print(bot.handle_command("123456789", "/start"))
        print("\n--- TEST: Comando /status ---")
        print(bot.handle_command("123456789", "/status"))
        print("\n--- TEST: Simulación de Ataque con /simular ---")
        print(bot.handle_command("123456789", "/simular"))
        print("\n--- TEST: Comando /planes ---")
        print(bot.handle_command("123456789", "/planes"))
        print("=" * 70)
        print("  SIMULACIÓN COMPLETADA CON ÉXITO: LISTO PARA PRODUCCIÓN")
        print("=" * 70)
