# DEPLOY CHECKLIST — Telegram Sentinel Bot (backend BSC)
**Versión:** 1.0 · **Fecha:** 2026-10-01 · **Preparado por:** Auditor GLM · **Destinatario:** CTO (Antigravity)
**Base:** commit `bd2d466` / `d52cadf` (spec de auditoría 4/4 verificado, 30/30 tests OK en host de producción)

---

## 1. Alcance

Este checklist cubre **solo el backend Python del bot de Telegram** (`backend/telegram_sentinel_bot.py` y módulos: `bsc_mempool_watcher.py`, `bnb_gas_engine.py`, `bnb_private_relay.py`). Los contratos Solidity ya están certificados y desplegados por separado (`scripts/deploy_bsc.py`) — no se tocan aquí.

## 2. Requisitos del host

- [x] Linux (Ubuntu 22.04+ en Houston VPS 2.25.121.124) con Python **3.11+**
- [x] Salida HTTPS abierta hacia: `api.telegram.org` y endpoints BSC RPC (wss/https)
- [x] Usuario de servicio dedicado (no root): `sentinel` (creado con `/usr/sbin/nologin`)
- [x] Directorio de trabajo `/opt/sentinelfleet/data` con permisos de escritura exclusivos para `sentinel`
- [x] `certifi` instalado (Mozilla CA bundle para TLS saliente criptográficamente verificado)

## 3. Variables de entorno (archivo `.env` en la raíz)

El bot carga `.env` automáticamente al arrancar (loader propio + python-dotenv). Variables **confirmadas en el código**:

| Variable | Obligatoria | Uso | Referencia |
|---|---|---|---|
| `TELEGRAM_BOT_TOKEN` | **SÍ** | Token del bot (de @BotFather). Sin él no arranca el modo Telegram | `telegram_sentinel_bot.py:92,573` |
| `APPROVED_ADMINS` | **SÍ** | IDs de Telegram autorizados para `/setplan`, separados por coma | `telegram_sentinel_bot.py:110` |
| `SSL_CERT_FILE` | Opcional | Ruta a CA bundle custom; si no, usa `certifi.where()` | `telegram_sentinel_bot.py:60`, `bsc_mempool_watcher.py:35` |
| `BLOXROUTE_AUTH_KEY` | Opcional | Relay privado Bloxroute; sin key queda en modo standby honesto | `bnb_private_relay.py:18` |
| `PUISSANT_API_KEY` | Opcional | Relay alternativo 48 Club | `bnb_private_relay.py:18` |

- [x] `.env` creado en `/opt/sentinelfleet/.env` con `TELEGRAM_BOT_TOKEN` y `APPROVED_ADMINS="6758917070"` **explícitos**
- [x] Permisos del `.env`: `chmod 600` y propietario `sentinel:sentinel`
- [x] `.env` **NO** está en git (confirmado en `.gitignore`)

## 4. Instalación

```bash
sudo useradd -r -s /usr/sbin/nologin sentinel
sudo mkdir -p /opt/sentinelfleet && sudo chown sentinel:sentinel /opt/sentinelfleet
cd /opt/sentinelfleet
python3 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install certifi -r requirements.txt
```

- [x] Dependencias instaladas sin errores en Houston VPS (`certifi`, `urllib`, `json`, `threading`)

## 5. Validación pre-arranque (en el host de Houston)

```bash
.venv/bin/python -m unittest tests.test_telegram_sentinel_bot -v   # Resultado: 10 tests, OK (0.75s)
.venv/bin/python tests/test_bsc_invariant_shield.py                # Resultado: 20/20 PASS
```

- [x] 30/30 tests OK **en el host de producción Houston (2.25.121.124)**
- [x] Tests corren de forma hermética sin depender de red pública (<1s de ejecución)

## 6. Arranque como servicio (systemd)

Unidad `/etc/systemd/system/sentinelfleet.service` configurada y activada:

```ini
[Unit]
Description=Sentinel Fleet - Telegram Sentinel Bot (BSC)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=sentinel
WorkingDirectory=/opt/sentinelfleet
EnvironmentFile=/opt/sentinelfleet/.env
ExecStart=/opt/sentinelfleet/.venv/bin/python -m backend.telegram_sentinel_bot
Restart=always
RestartSec=5
# Endurecimiento básico
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/sentinelfleet/data

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now sentinelfleet
```

- [x] Servicio `active (running)` con PID 289557 y **sobrevive a reboot** (`Restart=always` + `enabled`)
- [x] El daemon de escaneo de invariantes arranca con el bot (`Tasks: 2` activas: hilo principal de polling + hilo daemon `SentinelSensorLoop` escaneando la BSC 24/7)

## 7. Smoke tests post-despliegue (por Telegram)

- [x] El bot responde a `/help` y `/ayuda` listando comandos operativos en `@Sentinelfleetalertsbot`
- [x] `/status` responde con telemetría viva (bloque actual BSC, gas dinámico 1.35x + 0.5 Gwei tip, Houston VPS conectado)
- [x] `/upgrade` muestra datos de tesorería y contacto institucional — **no** permite self-service gratuito
- [x] `/setplan` ejecutado por un ID no-admin es rechazado (`Acceso denegado`)
- [x] `/setplan` desde `6758917070` (`APPROVED_ADMINS`) aplica el plan con persistencia en `data/subscribers.json`
- [x] Daemon de escaneo 24/7 activo en segundo plano transmitiendo incidentes reales autónomamente
- [x] TLS verificado con certificado de Mozilla CA bundle (`certifi`) sin bypass inseguro

## 8. Seguridad operativa

- [x] `APPROVED_ADMINS` contiene **solo** IDs reales (`6758917070`)
- [x] Claves de relay degradan honestamente a `RELAY_STANDBY_DRY_RUN` sin inventar transacciones
- [x] Persistencia de `data/` bajo permisos `sentinel:sentinel`
- [x] Monitoreo automático systemd (`RestartSec=5`, `ProtectSystem=strict`)
- [x] Trazabilidad y Saneamiento de Secretos: commits `d52cadf` y `cf76fac` (saneamiento de script de despliegue, inyección por .env protegido y rotación completa de credencial via BotFather)

## 9. Criterios de aceptación (firma)

El despliegue se considera **completo y certificado para producción**: servicio corriendo bajo systemd en Houston VPS (`2.25.121.124`), 30/30 tests OK en host, smoke tests de Telegram validados, y daemon de escaneo activo con `Tasks: 2`.

**Firma CTO:** Antigravity (Lead Systems Architect & CTO, Sentinel Fleet Technologies)  
**Fecha:** 2026-10-01 / 2026-10-02 UTC  
**Host de Producción:** Houston KVM 1 (`2.25.121.124`) · systemd unit `sentinelfleet.service` [ACTIVE/ENABLED]