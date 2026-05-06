#!/usr/bin/env bash
set -euo pipefail

PORT="${1:-4711}"
JAR="${2:-./oratcptest.jar}"
LOGDIR="${3:-./oratcp_server_logs}"

mkdir -p "$LOGDIR"
TS="$(date +%Y%m%d_%H%M%S)"
LOGFILE="$LOGDIR/oratcp_server_${TS}.log"

if [[ ! -f "$JAR" ]]; then
  echo "ERROR: no existe $JAR"
  exit 1
fi

echo "=================================================="
echo "Servidor oratcptest"
echo "Puerto : $PORT"
echo "Jar    : $JAR"
echo "Log    : $LOGFILE"
echo "=================================================="

echo "[INFO] Verificando ayuda del jar"
java -jar "$JAR" -help >/dev/null 2>&1 || true

{
  echo "=================================================="
  echo "TIME SYNC EVIDENCE"
  echo "DATE_INS: $(date -Ins)"
  echo "=================================================="
  echo
  echo "[date]"
  date
  echo
  echo "[date -Ins]"
  date -Ins
  echo
  echo "[timedatectl]"
  timedatectl status 2>&1 || echo "timedatectl no disponible"
  echo
  echo "[chronyc tracking]"
  chronyc tracking 2>&1 || echo "chronyc no disponible"
  echo
  echo "[chronyc sources -v]"
  chronyc sources -v 2>&1 || true
  echo
  echo "[ntpq -p]"
  ntpq -p 2>&1 || echo "ntpq no disponible"
  echo
} | tee -a "$LOGFILE"

echo "[INFO] Iniciando servidor"
echo "[INFO] Déjalo corriendo. No cierres esta terminal."
echo "[INFO] Para detenerlo: Ctrl+C"
echo

exec java -jar "$JAR" -server -port="$PORT" 2>&1 | tee -a "$LOGFILE"
