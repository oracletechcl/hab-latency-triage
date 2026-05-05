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

echo "[INFO] Iniciando servidor"
echo "[INFO] Déjalo corriendo. No cierres esta terminal."
echo "[INFO] Para detenerlo: Ctrl+C"
echo

exec java -jar "$JAR" -server -port="$PORT" 2>&1 | tee "$LOGFILE"