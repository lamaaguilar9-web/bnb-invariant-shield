#!/usr/bin/env bash
# ==============================================================================
# Sentinel Fleet Technologies - Houston VPS (2.25.121.124) Production Deployer
# Follows GLM-5.3 DEPLOY_CHECKLIST.md v1.0 specifications for Project #11
# ==============================================================================

set -euo pipefail

echo "==============================================================================="
echo "  SENTINEL FLEET — DESPLIEGUE EN PRODUCCIÓN (HOUSTON VPS 2.25.121.124)"
echo "  Servicio: Telegram Early-Warning Sentinel Bot (systemd: sentinelfleet)"
echo "==============================================================================="

# 1. Crear usuario de servicio dedicado
echo "[1/7] Verificando usuario de servicio seguro 'sentinel'..."
if ! id -u sentinel >/dev/null 2>&1; then
    useradd -r -s /usr/sbin/nologin sentinel
    echo "[+] Usuario 'sentinel' creado con éxito."
else
    echo "[+] Usuario 'sentinel' ya existe."
fi

# 2. Preparar directorios de trabajo
echo "[2/7] Preparando directorio institucional /opt/sentinelfleet..."
mkdir -p /opt/sentinelfleet/data
chown -R sentinel:sentinel /opt/sentinelfleet

# 3. Sincronizar código desde repositorio oficial
echo "[3/7] Sincronizando código desde GitHub (main)..."
if [ -d /opt/sentinelfleet/.git ]; then
    cd /opt/sentinelfleet
    git fetch origin
    git reset --hard origin/main
else
    cd /opt
    rm -rf /opt/sentinelfleet_tmp
    git clone https://github.com/lamaaguilar9-web/bnb-invariant-shield.git /opt/sentinelfleet_tmp
    cp -r /opt/sentinelfleet_tmp/. /opt/sentinelfleet/
    rm -rf /opt/sentinelfleet_tmp
    cd /opt/sentinelfleet
fi

# 4. Configurar entorno virtual Python y dependencias
echo "[4/7] Configurando entorno virtual Python 3 y certifi..."
if [ ! -d /opt/sentinelfleet/.venv ]; then
    python3 -m venv /opt/sentinelfleet/.venv
fi
/opt/sentinelfleet/.venv/bin/pip install --upgrade pip
/opt/sentinelfleet/.venv/bin/pip install certifi -r requirements.txt

# 5. Configurar .env con variables de entorno (chmod 600)
echo "[5/7] Verificando variables de entorno en /opt/sentinelfleet/.env..."
if [ ! -f /opt/sentinelfleet/.env ]; then
    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
        echo "[-] ERROR: TELEGRAM_BOT_TOKEN no definido en el entorno. No se puede configurar .env sin token." >&2
        exit 1
    fi
    cat << EOF > /opt/sentinelfleet/.env
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
APPROVED_ADMINS="${APPROVED_ADMINS:-6758917070}"
EOF
else
    echo "[+] /opt/sentinelfleet/.env ya existe en el servidor. Preservando secretos sin exponerlos en el script."
fi

chmod 600 /opt/sentinelfleet/.env
chown -R sentinel:sentinel /opt/sentinelfleet

# 6. Ejecutar validación pre-arranque (30/30 tests) en el host
echo "[6/7] Ejecutando validación formal (30 tests) en el host de producción..."
cd /opt/sentinelfleet
/opt/sentinelfleet/.venv/bin/python tests/test_bsc_invariant_shield.py
/opt/sentinelfleet/.venv/bin/python -m unittest tests.test_telegram_sentinel_bot -v

# 7. Configurar e iniciar servicio systemd
echo "[7/7] Configurando y arrancando sentinelfleet.service bajo systemd..."
cat << 'EOF' > /etc/systemd/system/sentinelfleet.service
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
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/sentinelfleet/data

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sentinelfleet
sleep 2

echo "==============================================================================="
echo "  ESTADO DEL SERVICIO SYSTEMD EN PRODUCCIÓN:"
echo "==============================================================================="
systemctl status sentinelfleet --no-pager

echo ""
echo "==============================================================================="
echo "  ÚLTIMOS LOGS DE ARRANQUE DEL BOT Y SENSOR DAEMON:"
echo "==============================================================================="
journalctl -u sentinelfleet -n 25 --no-pager

echo ""
echo "==============================================================================="
echo "  DESPLIEGUE EN PRODUCCIÓN COMPLETADO CON ÉXITO AL 100%"
echo "==============================================================================="
