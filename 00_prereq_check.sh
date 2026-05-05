#!/usr/bin/env bash
set -euo pipefail

echo "=== PREREQ CHECK ==="

need_cmd() {
  local c="$1"
  if command -v "$c" >/dev/null 2>&1; then
    echo "[OK] $c"
  else
    echo "[MISSING] $c"
  fi
}

need_cmd java
need_cmd tcpdump
need_cmd ping
need_cmd traceroute || true
need_cmd tracepath || true
need_cmd mtr || true
need_cmd nc || true
need_cmd sqlplus || true
need_cmd tnsping || true
need_cmd tshark || true

echo
echo "=== JAVA VERSION ==="
java -version || true

echo
echo "=== ORATCPTEST CHECK ==="
if [[ -f ./oratcptest.jar ]]; then
  echo "[OK] ./oratcptest.jar existe"
  echo "Probando help..."
  java -jar ./oratcptest.jar -help >/tmp/oratcptest_help.txt 2>&1 || true
  head -n 20 /tmp/oratcptest_help.txt || true
else
  echo "[MISSING] ./oratcptest.jar"
  echo "Copia el jar descargado desde MOS Doc ID 2064368.1 a este directorio"
fi

echo
echo "=== FIN ==="