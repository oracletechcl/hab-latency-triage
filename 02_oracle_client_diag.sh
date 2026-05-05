#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# USO:
# ./02_oracle_client_diag.sh <DEST_HOST> <DEST_ORATCP_PORT> <DB_HOST> <DB_PORT> <TNS_ALIAS> <DBLINK_NAME> <IFACE> <CAPTURE_SECONDS>
#
# EJEMPLO:
# ./02_oracle_client_diag.sh 10.10.10.20 4711 10.10.10.20 1521 EXPLDB MI_DBLINK any 90
#
# PARAMETROS:
# DEST_HOST         = host donde corre el servidor oratcptest
# DEST_ORATCP_PORT  = puerto del servidor oratcptest (ej: 4711)
# DB_HOST           = host del listener Oracle real
# DB_PORT           = puerto Oracle real (ej: 1521)
# TNS_ALIAS         = alias TNS que funciona en este host
# DBLINK_NAME       = nombre del DBLink a probar desde SQL*Plus
# IFACE             = interfaz para tcpdump (ej: any o eth0)
# CAPTURE_SECONDS   = segundos de captura tcpdump
###############################################################################

DEST_HOST="${1:-}"
DEST_ORATCP_PORT="${2:-4711}"
DB_HOST="${3:-}"
DB_PORT="${4:-1521}"
TNS_ALIAS="${5:-}"
DBLINK_NAME="${6:-}"
IFACE="${7:-any}"
CAPTURE_SECONDS="${8:-90}"
JAR="./oratcptest.jar"

if [[ -z "$DEST_HOST" || -z "$DB_HOST" || -z "$TNS_ALIAS" || -z "$DBLINK_NAME" ]]; then
  echo "Uso:"
  echo "./02_oracle_client_diag.sh <DEST_HOST> <DEST_ORATCP_PORT> <DB_HOST> <DB_PORT> <TNS_ALIAS> <DBLINK_NAME> <IFACE> <CAPTURE_SECONDS>"
  exit 1
fi

if [[ ! -f "$JAR" ]]; then
  echo "ERROR: falta ./oratcptest.jar"
  exit 1
fi

TS="$(date +%Y%m%d_%H%M%S)"
HOST="$(hostname -s 2>/dev/null || hostname)"
OUTDIR="diag_${HOST}_${TS}"
mkdir -p "$OUTDIR"

PCAP_ORATCP="${OUTDIR}/oratcptest_${DEST_HOST}_${DEST_ORATCP_PORT}.pcap"
PCAP_DB="${OUTDIR}/oracle_${DB_HOST}_${DB_PORT}.pcap"
SUMMARY="${OUTDIR}/SUMMARY.txt"

run_cmd() {
  local name="$1"
  shift
  {
    echo "=================================================="
    echo "TEST: $name"
    echo "DATE: $(date '+%F %T')"
    echo "CMD : $*"
    echo "=================================================="
    "$@"
    echo
  } > "${OUTDIR}/${name}.txt" 2>&1 || true
}

start_tcpdump() {
  local outfile="$1"
  local filter="$2"
  local pidfile="$3"
  echo "[INFO] Iniciando tcpdump -> $outfile"
  sudo tcpdump -i "$IFACE" -nn -s 0 -tttt "$filter" -w "$outfile" >/dev/null 2>&1 &
  echo $! > "$pidfile"
  sleep 2
}

stop_tcpdump() {
  local pidfile="$1"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid="$(cat "$pidfile")"
    sudo kill -2 "$pid" >/dev/null 2>&1 || true
    sleep 2
  fi
}

echo "[INFO] Output: $OUTDIR"

run_cmd "01_hostname" hostname
run_cmd "02_uname" uname -a
run_cmd "03_ip_addr" ip addr
run_cmd "04_ip_route" ip route
run_cmd "05_java_version" java -version
run_cmd "06_oratcptest_help" java -jar "$JAR" -help

echo "[INFO] Iniciando capturas"
start_tcpdump "$PCAP_ORATCP" "host $DEST_HOST and tcp port $DEST_ORATCP_PORT" "${OUTDIR}/tcpdump_oratcp.pid"
start_tcpdump "$PCAP_DB" "host $DB_HOST and tcp port $DB_PORT" "${OUTDIR}/tcpdump_db.pid"

echo "[INFO] Pruebas de red base"
run_cmd "10_ping_dbhost" ping -c 20 -i 0.2 "$DB_HOST"

if command -v traceroute >/dev/null 2>&1; then
  run_cmd "11_traceroute_db_tcp" traceroute -T -p "$DB_PORT" "$DB_HOST"
elif command -v tracepath >/dev/null 2>&1; then
  run_cmd "11_tracepath_db" tracepath "$DB_HOST"
fi

if command -v mtr >/dev/null 2>&1; then
  run_cmd "12_mtr_db_tcp" mtr --report --report-cycles 30 --tcp --port "$DB_PORT" "$DB_HOST"
fi

echo "[INFO] MTU quick check"
run_cmd "13_mtu_1472" ping -c 3 -M do -s 1472 "$DB_HOST"
run_cmd "14_mtu_1400" ping -c 3 -M do -s 1400 "$DB_HOST"

echo "[INFO] Listener connectivity"
if command -v nc >/dev/null 2>&1; then
  run_cmd "15_nc_db_port" nc -vz -w 5 "$DB_HOST" "$DB_PORT"
else
  run_cmd "15_bash_db_port" bash -lc "timeout 5 bash -c '</dev/tcp/$DB_HOST/$DB_PORT' && echo OK || echo FAIL"
fi

echo "[INFO] TNSPING"
run_cmd "16_tnsping" tnsping "$TNS_ALIAS" 10

echo "[INFO] SQL*Plus conexión simple"
cat > "${OUTDIR}/sqlplus_connect_test.sql" <<'SQL'
set pages 100 lines 200 timing on echo on
select systimestamp as local_db_time from dual;
exit
SQL

run_cmd "17_sqlplus_connect" bash -lc "sqlplus -L /@${TNS_ALIAS} @${OUTDIR}/sqlplus_connect_test.sql"

echo "[INFO] ORATCPTEST sync"
run_cmd "20_oratcptest_sync" java -jar "$JAR" "$DEST_HOST" -port="$DEST_ORATCP_PORT" -duration=20s -interval=5s

echo "[INFO] ORATCPTEST async"
run_cmd "21_oratcptest_async" java -jar "$JAR" "$DEST_HOST" -port="$DEST_ORATCP_PORT" -mode=async -duration=20s -interval=5s

echo "[INFO] ORATCPTEST payload chico"
run_cmd "22_oratcptest_small_payload" java -jar "$JAR" "$DEST_HOST" -port="$DEST_ORATCP_PORT" -mode=async -length=8192 -duration=20s -interval=5s

echo "[INFO] ORATCPTEST payload mediano"
run_cmd "23_oratcptest_medium_payload" java -jar "$JAR" "$DEST_HOST" -port="$DEST_ORATCP_PORT" -mode=async -length=65536 -duration=20s -interval=5s

echo "[INFO] DBLINK test via SQL*Plus"
cat > "${OUTDIR}/run_dblink_test.sql" <<SQL
define DBLINK_NAME='${DBLINK_NAME}'
@03_dblink_latency_test.sql
SQL

run_cmd "30_dblink_test" bash -lc "sqlplus -L /@${TNS_ALIAS} @${OUTDIR}/run_dblink_test.sql"

echo "[INFO] Esperando ventana extra de captura: ${CAPTURE_SECONDS}s"
sleep "$CAPTURE_SECONDS"

echo "[INFO] Deteniendo capturas"
stop_tcpdump "${OUTDIR}/tcpdump_oratcp.pid"
stop_tcpdump "${OUTDIR}/tcpdump_db.pid"

{
  echo "================ SUMMARY ================"
  echo "Host origen      : $HOST"
  echo "Host oratcptest  : $DEST_HOST:$DEST_ORATCP_PORT"
  echo "Host Oracle      : $DB_HOST:$DB_PORT"
  echo "TNS alias        : $TNS_ALIAS"
  echo "DBLink           : $DBLINK_NAME"
  echo

  echo "[PING]"
  grep -E 'packets transmitted|packet loss|min/avg/max' "${OUTDIR}/10_ping_dbhost.txt" || true
  echo

  echo "[TNSPING]"
  grep -E 'OK|Attempting to contact|msec' "${OUTDIR}/16_tnsping.txt" || true
  echo

  echo "[ORATCPTEST]"
  grep -E 'Avg\. throughput|Latency|Throughput|Test finished|Transport mode' "${OUTDIR}"/2*.txt || true
  echo

  echo "[PCAPS]"
  ls -lh "$PCAP_ORATCP" "$PCAP_DB" 2>/dev/null || true
  echo
} > "$SUMMARY"

echo
echo "[OK] Diagnóstico completo en: $OUTDIR"
echo "[OK] Lee primero: $SUMMARY"