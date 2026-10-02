# DEPLOY CHECKLIST — Telegram Sentinel Bot (backend BSC)
**Versión:** 1.0 · **Fecha:** 2026-10-01 · **Preparado por:** Auditor GLM · **Destinatario:** CTO (Antigravity)
**Base:** commit `bd2d466` (spec de auditoría 4/4 verificado, 30/30 tests OK en local)

---

## 1. Alcance

Este checklist cubre **solo el backend Python del bot de Telegram** (`backend/telegram_sentinel_bot.py` y módulos: `bsc_mempool_watcher.py`, `bnb_gas_engine.py`, `bnb_private_relay.py`). Los contratos Solidity ya están certificados y desplegados por separado (`scripts/deploy_bsc.py`) — no se tocan aquí.

## 2. Requisitos del host

- [ ] Linux (Ubuntu 22.04+ recomendado) con Python **3.11+**
- [ ] Salida HTTPS abierta hacia: `api.telegram.org` y endpoints BSC RPC (wss/https)
- [ ] Usuario de servicio dedicado (no root), p. ej. `sentinel`
- [ ] Directorio de trabajo con permisos de escritura para `data/` (estado persistente del bot)
- [ ] `certifi` instalable (CA bundle para TLS saliente verificado)

## 3. Variables de entorno (archivo `.env` en la raíz)

El bot carga `.env` automáticamente al arrancar (loader propio + python-dotenv). Variables **confirmadas en el código**:

| Variable | Obligatoria | Uso | Referencia |
|---|---|---|---|
| `TELEGRAM_BOT_TOKEN` | **SÍ** | Token del bot (de @BotFather). Sin él no arranca el modo Telegram | `telegram_sentinel_bot.py:92,573` |
| `APPROVED_ADMINS` | **SÍ** | IDs de Telegram autorizados para `/setplan`, separados por coma | `telegram_sentinel_bot.py:110` |
| `SSL_CERT_FILE` | Opcional | Ruta a CA bundle custom; si no, usa `certifi.where()` | `telegram_sentinel_bot.py:60`, `bsc_mempool_watcher.py:35` |
| `BLOXROUTE_AUTH_KEY` | Opcional | Relay privado Bloxroute; sin key queda en modo standby honesto | `bnb_private_relay.py:18` |
| `PUISSANT_API_KEY` | Opcional | Relay alternativo 48 Club | `bnb_private_relay.py:18` |

- [ ] `.env` creado con `TELEGRAM_BOT_TOKEN` y `APPROVED_ADMINS` **explícitos** (el default hardcodeado `6758917070` debe quedar cubierto por la env var en producción)
- [ ] Permisos del `.env`: `chmod 600` y propietario `sentinel`
- [ ] `.env` **NO** está en git (verificar `.gitignore`)

## 4. Instalación

```bash
sudo useradd -r -s /usr/sbin/nologin sentinel
sudo mkdir -p /opt/sentinelfleet && sudo chown sentinel:sentinel /opt/sentinelfleet
# clonar/copiar el repo en /opt/sentinelfleet
cd /opt/sentinelfleet
python3.11 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

- [ ] Dependencias instaladas sin errores (`web3`, `websockets`, `requests`, `python-dotenv`, `eth-account`)

## 5. Validación pre-arranque (en el host)

```bash
.venv/bin/python -m unittest tests.test_telegram_sentinel_bot -v   # esperar: 10 tests, OK
.venv/bin/python tests/test_bsc_invariant_shield.py                # esperar: 20/20 PASS
```

- [ ] 30/30 tests OK **en el host de producción** (no solo en local)
- [ ] Confirmar que los tests corren sin tocar red pública (mock hermético) — si tardan >2s, algo cambió

## 6. Arranque como servicio (systemd)

Crear `/etc/systemd/system/sentinelfleet.service`:

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
sudo journalctl -u sentinelfleet -f
```

- [ ] Servicio `active (running)` y **sobrevive a reboot** (`Restart=always` + `enable`)
- [ ] El daemon de escaneo de invariantes arranca con el bot (se inicia en `__main__`, línea ~579 — confirmar en logs que el hilo `SentinelSensorLoop` está vivo)

## 7. Smoke tests post-despliegue (por Telegram)

- [ ] El bot responde a `/help` y lista los comandos sin error
- [ ] `/status` responde con telemetría viva (bloque actual, gas 1.35x + 0.5 Gwei tip)
- [ ] `/upgrade` muestra datos de tesorería y contacto — **no** cambia el plan self-service
- [ ] `/setplan` con un ID **no** admin → rechazado
- [ ] `/setplan` desde un ID en `APPROVED_ADMINS` → aplica el plan
- [ ] Una alerta de incidente real llega al suscriptor sin intervención manual (daemon escaneando)
- [ ] TLS: conectar contra un endpoint con certificado válido funciona (si falla, revisar `SSL_CERT_FILE` — **prohibido** regresar a contexto no verificado)

## 8. Seguridad operativa

- [ ] `APPROVED_ADMINS` contiene **solo** IDs reales del equipo
- [ ] Claves de relay (`BLOXROUTE_AUTH_KEY`) solo si hay plan de uso; sin key el sistema degrada de forma honesta (standby)
- [ ] Backups: `data/` (estado de suscriptores) incluido en rutina de backup
- [ ] Monitoreo del propio servicio: alerta si el proceso cae (systemd lo reinicia; avisar vía segundo canal si falla repeatedly)
- [ ] Actualizaciones: PR → revisión del diff → tests → deploy. Sin despliegues directos a main

## 9. Criterios de aceptación (firma)

El despliegue se considera **completo** cuando: servicio corriendo bajo systemd con restart automático, 30/30 tests OK en host, smoke tests de Telegram pasando, y daemon de escaneo activo en logs. Cualquier desviación se documenta aquí mismo antes de firmar.

**Firma CTO:** ______________  **Fecha:** ______________