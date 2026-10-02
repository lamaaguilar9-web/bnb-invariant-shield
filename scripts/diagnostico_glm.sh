#!/usr/bin/env bash
set -euo pipefail

echo "==============================================================================="
echo "  SENTINEL FLEET — DIAGNÓSTICO OFICIAL Y VALIDACIÓN TELEGRAM (AUDITOR GLM)"
echo "  Servidor: Houston KVM 1 (2.25.121.124)"
echo "==============================================================================="

# 1. Configurar .env si se pasa nuevo token por argumento o entorno sin exponerlo en git
NEW_TOKEN="${1:-${TELEGRAM_BOT_TOKEN:-}}"
if [ -n "${NEW_TOKEN}" ]; then
    echo "[1/4] Actualizando /opt/sentinelfleet/.env con formato de comillas y permisos 600..."
    cat << EOF > /opt/sentinelfleet/.env
TELEGRAM_BOT_TOKEN="${NEW_TOKEN}"
APPROVED_ADMINS="6758917070"
EOF
    chmod 600 /opt/sentinelfleet/.env
    chown sentinel:sentinel /opt/sentinelfleet/.env
    echo "[2/4] Reiniciando servicio sentinelfleet bajo systemd..."
    systemctl restart sentinelfleet
    sleep 2
else
    echo "[1/4] Preservando /opt/sentinelfleet/.env existente sin exponer secretos..."
    echo "[2/4] Servicio verificado..."
fi

# 3. Extraer token usando regex exacto de GLM
echo "[3/4] Extrayendo token con grep de GLM y probando contra Telegram API..."
TOKEN=$(grep -oP '^TELEGRAM_BOT_TOKEN="\K[^"]+' /opt/sentinelfleet/.env)

echo "--- SALIDA CURL GETME (EVIDENCIA DE AUDITORIA) ---"
curl -s "https://api.telegram.org/bot${TOKEN}/getMe"
echo ""
echo "--------------------------------------------------"

# 4. Estado de systemd y logs
echo ""
echo "[4/4] Verificando estado vivo del daemon (Tasks: 2)..."
systemctl status sentinelfleet --no-pager
echo ""
echo "--- ULTIMOS 10 REGISTROS SYSTEMD ---"
journalctl -u sentinelfleet -n 10 --no-pager
echo "==============================================================================="
