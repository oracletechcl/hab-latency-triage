#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# USO ACTUAL:
#   ./06_run_targets.sh targets.csv diag_paths_HAB
#
# Este script ejecuta un target/path individual y normalmente lo invoca
# 06_run_targets.sh para SCL, VLP y cualquier otro camino definido en el CSV.
#
# EJECUCION POR TARGET:
#   TARGET_NAME=SCL OUTDIR=diag_paths_HAB/SCL ./02_oracle_client_diag.sh <DEST_HOST> <DEST_ORATCP_PORT> <DB_HOST> <DB_PORT> <TNS_ALIAS> <DBLINK_NAME> <DB_VERSION> <IFACE> <CAPTURE_SECONDS>
#
# PARAMETROS:
# DEST_HOST         = host donde corre el servidor oratcptest
# DEST_ORATCP_PORT  = puerto del servidor oratcptest (ej: 4711)
# DB_HOST           = host del listener Oracle real
# DB_PORT           = puerto Oracle real (ej: 1521)
# TNS_ALIAS         = alias TNS que funciona en este host
# DBLINK_NAME       = nombre del DBLink a probar desde SQL*Plus
# DB_VERSION        = version de la BD remota: 10g | 11g | 19c
# IFACE             = interfaz para tcpdump (ej: any o eth0)
# CAPTURE_SECONDS   = segundos de captura tcpdump adicional
###############################################################################

DEST_HOST="${1:-}"
DEST_ORATCP_PORT="${2:-4711}"
DB_HOST="${3:-}"
DB_PORT="${4:-1521}"
TNS_ALIAS="${5:-}"
DBLINK_NAME="${6:-}"
DB_VERSION="${7:-19c}"
IFACE="${8:-any}"
CAPTURE_SECONDS="${9:-90}"

JAR="${ORATCPTEST_JAR:-./oratcptest.jar}"
TARGET_NAME="${TARGET_NAME:-}"
OUT_ROOT="${OUT_ROOT:-.}"
PATH_SNAPSHOT="${PATH_SNAPSHOT:-1}"
CAPTURE_MODE="${CAPTURE_MODE:-both}"  # app | failover | both | none

if [[ -z "$DEST_HOST" || -z "$DB_HOST" || -z "$TNS_ALIAS" || -z "$DBLINK_NAME" ]]; then
  echo "Uso:"
  echo "./06_run_targets.sh targets.csv diag_paths_HAB"
  echo
  echo "Ejecucion por target:"
  echo "TARGET_NAME=SCL OUTDIR=diag_paths_HAB/SCL ./02_oracle_client_diag.sh <DEST_HOST> <DEST_ORATCP_PORT> <DB_HOST> <DB_PORT> <TNS_ALIAS> <DBLINK_NAME> <DB_VERSION> <IFACE> <CAPTURE_SECONDS>"
  echo
  echo "Variables opcionales:"
  echo "  TARGET_NAME=SCL|VLP|..."
  echo "  OUT_ROOT=directorio_padre_de_salida"
  echo "  CAPTURE_MODE=app|failover|both|none"
  echo "  PATH_SNAPSHOT=1|0"
  echo "  ORATCPTEST_JAR=/ruta/oratcptest.jar"
  echo
  echo "DB_VERSION: 10g | 11g | 19c  (version de la BD REMOTA del DBLink)"
  exit 1
fi

case "${DB_VERSION,,}" in
  10g|11g|19c) ;;
  *)
    echo "ERROR: DB_VERSION debe ser 10g, 11g o 19c (recibido: '$DB_VERSION')"
    exit 1
    ;;
esac

if [[ ! -f "$JAR" ]]; then
  echo "ERROR: falta $JAR"
  exit 1
fi

sanitize_name() {
  local value="$1"
  value="${value//[^A-Za-z0-9_.-]/_}"
  value="${value##_}"
  value="${value%%_}"
  [[ -n "$value" ]] || value="target"
  printf '%s' "$value"
}

TS="$(date +%Y%m%d_%H%M%S)"
HOST="$(hostname -s 2>/dev/null || hostname)"
TARGET_LABEL="${TARGET_NAME:-single}"
TARGET_SAFE="$(sanitize_name "$TARGET_LABEL")"
OUT_ROOT="${OUT_ROOT%/}"

if [[ -n "${OUTDIR:-}" ]]; then
  OUTDIR="${OUTDIR%/}"
elif [[ -n "$TARGET_NAME" ]]; then
  OUTDIR="${OUT_ROOT}/diag_${TARGET_SAFE}_${HOST}_${TS}"
else
  OUTDIR="${OUT_ROOT}/diag_${HOST}_${TS}"
fi

mkdir -p "$OUTDIR"
PATHDIR="${OUTDIR}/path_evidence"
mkdir -p "$PATHDIR"

PCAP_ORATCP="${OUTDIR}/oratcptest_${DEST_HOST}_${DEST_ORATCP_PORT}.pcap"
PCAP_DB="${OUTDIR}/oracle_${DB_HOST}_${DB_PORT}.pcap"
PCAP_FAILOVER="${OUTDIR}/failover_connectivity_${TARGET_SAFE}.pcap"
SUMMARY="${OUTDIR}/SUMMARY.txt"
METRICS_ENV="${OUTDIR}/metrics.env"
METRICS_CSV="${OUTDIR}/metrics.csv"
RUN_COUNT=0

tcpdump_prefix() {
  if [[ "${EUID}" -eq 0 ]]; then
    printf 'tcpdump'
  else
    printf 'sudo tcpdump'
  fi
}

kill_prefix() {
  if [[ "${EUID}" -eq 0 ]]; then
    printf 'kill'
  else
    printf 'sudo kill'
  fi
}

capture_time_sync() {
  local outfile="${OUTDIR}/08_time_sync.txt"
  {
    echo "=================================================="
    echo "TIME SYNC EVIDENCE"
    echo "TARGET: $TARGET_LABEL"
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
  } > "$outfile" 2>&1 || true
}

capture_path_snapshot() {
  local label="$1"
  local phase="$2"

  [[ "$PATH_SNAPSHOT" == "1" ]] || return 0

  local safe_label
  safe_label="$(sanitize_name "$label")"
  local outfile="${PATHDIR}/${safe_label}_${phase}.txt"

  {
    echo "=================================================="
    echo "PATH EVIDENCE"
    echo "TARGET      : $TARGET_LABEL"
    echo "TEST        : $label"
    echo "PHASE       : $phase"
    echo "DATE_INS    : $(date -Ins)"
    echo "DEST_ORATCP : $DEST_HOST:$DEST_ORATCP_PORT"
    echo "DB_LISTENER : $DB_HOST:$DB_PORT"
    echo "IFACE       : $IFACE"
    echo "=================================================="
    echo
    echo "[ip route get DB_HOST]"
    ip route get "$DB_HOST" 2>&1 || true
    echo
    echo "[ip route get DEST_HOST]"
    ip route get "$DEST_HOST" 2>&1 || true
    echo
    echo "[ip rule show]"
    ip rule show 2>&1 || true
    echo
    echo "[ip addr]"
    ip addr 2>&1 || true
    echo
    echo "[ip neigh show]"
    ip neigh show 2>&1 || true
    echo
    echo "[ss -ti for DB_HOST:DB_PORT]"
    ss -ti "dst $DB_HOST:$DB_PORT" 2>&1 || ss -ti 2>&1 || true
    echo
    echo "[ss -ti for DEST_HOST:DEST_ORATCP_PORT]"
    ss -ti "dst $DEST_HOST:$DEST_ORATCP_PORT" 2>&1 || true
    echo
    echo "[interface counters]"
    ip -s link 2>&1 || true
  } > "$outfile" 2>&1 || true
}

run_cmd() {
  local name="$1"
  shift

  RUN_COUNT=$((RUN_COUNT + 1))
  local label
  label="$(printf '%02d_%s' "$RUN_COUNT" "$name")"
  local outfile="${OUTDIR}/${name}.txt"

  capture_path_snapshot "$label" "before"

  {
    local rc=0
    local start_ns end_ns elapsed_ms
    start_ns="$(date +%s%N)"
    echo "=================================================="
    echo "TEST       : $name"
    echo "TARGET     : $TARGET_LABEL"
    echo "DATE       : $(date '+%F %T')"
    echo "DATE_INS   : $(date -Ins)"
    echo "CMD        : $*"
    echo "=================================================="
    "$@" || rc=$?
    end_ns="$(date +%s%N)"
    elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    echo
    echo "EXIT_CODE  : $rc"
    echo "ELAPSED_MS : $elapsed_ms"
  } > "$outfile" 2>&1 || true

  capture_path_snapshot "$label" "after"
}

start_tcpdump() {
  local outfile="$1"
  local filter="$2"
  local pidfile="$3"
  local prefix
  prefix="$(tcpdump_prefix)"

  echo "[INFO] Iniciando tcpdump -> $outfile"
  echo "[INFO] Filtro: $filter"
  # shellcheck disable=SC2086
  $prefix -i "$IFACE" -nn -s 0 -tttt "$filter" -w "$outfile" >/dev/null 2>&1 &
  echo $! > "$pidfile"
  sleep 2
}

stop_tcpdump() {
  local pidfile="$1"
  if [[ -f "$pidfile" ]]; then
    local pid
    local prefix
    pid="$(cat "$pidfile")"
    prefix="$(kill_prefix)"
    # shellcheck disable=SC2086
    $prefix -2 "$pid" >/dev/null 2>&1 || true
    sleep 2
  fi
}

start_captures() {
  case "${CAPTURE_MODE,,}" in
    app|both)
      start_tcpdump "$PCAP_ORATCP" "host $DEST_HOST and tcp port $DEST_ORATCP_PORT" "${OUTDIR}/tcpdump_oratcp.pid"
      start_tcpdump "$PCAP_DB" "host $DB_HOST and tcp port $DB_PORT" "${OUTDIR}/tcpdump_db.pid"
      ;;
  esac

  case "${CAPTURE_MODE,,}" in
    failover|both)
      start_tcpdump "$PCAP_FAILOVER" "((host $DB_HOST or host $DEST_HOST) and (tcp port $DB_PORT or tcp port $DEST_ORATCP_PORT or icmp)) or arp" "${OUTDIR}/tcpdump_failover.pid"
      ;;
  esac
}

stop_captures() {
  stop_tcpdump "${OUTDIR}/tcpdump_oratcp.pid"
  stop_tcpdump "${OUTDIR}/tcpdump_db.pid"
  stop_tcpdump "${OUTDIR}/tcpdump_failover.pid"
}

csv_escape() {
  local value="${1:-}"
  value="${value//$'\n'/ }"
  value="${value//\"/\"\"}"
  printf '"%s"' "$value"
}

metric_value() {
  local key="$1"
  local value="${2:-}"
  printf '%s=%q\n' "$key" "$value" >> "$METRICS_ENV"
  printf '%s,' "$key" >> "$METRICS_CSV"
  csv_escape "$value" >> "$METRICS_CSV"
  printf '\n' >> "$METRICS_CSV"
}

first_match() {
  local pattern="$1"
  local file="$2"
  [[ -f "$file" ]] || return 0
  grep -E "$pattern" "$file" 2>/dev/null | head -n 1 || true
}

paste_matches() {
  local pattern="$1"
  local file="$2"
  [[ -f "$file" ]] || return 0
  grep -E "$pattern" "$file" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g;s/[[:space:]]$//' || true
}

parse_route_field() {
  local route_line="$1"
  local field="$2"
  awk -v key="$field" '{
    for (i = 1; i <= NF; i++) {
      if ($i == key && (i + 1) <= NF) {
        print $(i + 1)
        exit
      }
    }
  }' <<< "$route_line"
}

count_retransmissions() {
  local pcap="$1"
  local port="$2"
  if [[ -f "$pcap" && -s "$pcap" ]] && command -v tshark >/dev/null 2>&1; then
    tshark -r "$pcap" -Y "tcp.analysis.retransmission && tcp.port == $port" 2>/dev/null | wc -l | awk '{print $1}'
  else
    printf ''
  fi
}

extract_dblink_metric() {
  local metric="$1"
  local file="${OUTDIR}/30_dblink_test.txt"
  [[ -f "$file" ]] || return 0
  awk -F'|' -v wanted="$metric" '$1 == "DBLINK_METRIC" && $2 == wanted { value=$3 } END { print value }' "$file"
}

write_metrics() {
  : > "$METRICS_ENV"
  printf 'metric,value\n' > "$METRICS_CSV"

  local route_line route_dev route_via route_src
  route_line="$(ip route get "$DB_HOST" 2>/dev/null | head -n 1 || true)"
  route_dev="$(parse_route_field "$route_line" "dev")"
  route_via="$(parse_route_field "$route_line" "via")"
  route_src="$(parse_route_field "$route_line" "src")"

  local ping_line ping_rtt ping_loss ping_avg
  ping_line="$(first_match 'packets transmitted' "${OUTDIR}/10_ping_dbhost.txt")"
  ping_loss="$(sed -n 's/.* \([0-9.]\+\)% packet loss.*/\1/p' <<< "$ping_line" | head -n 1)"
  ping_rtt="$(first_match 'min/avg/max|round-trip' "${OUTDIR}/10_ping_dbhost.txt")"
  ping_avg="$(awk -F'=' '/min\/avg\/max|round-trip/ { gsub(/^[[:space:]]+/, "", $2); split($2, a, "/"); print a[2]; exit }' "${OUTDIR}/10_ping_dbhost.txt" 2>/dev/null || true)"

  local tnsping_ms nc_status small_summary medium_summary retrans_db retrans_oratcp retrans_failover
  tnsping_ms="$(sed -n 's/.*OK (\([0-9.]\+\) msec).*/\1/p' "${OUTDIR}/16_tnsping.txt" 2>/dev/null | tail -n 1 || true)"
  if grep -q 'EXIT_CODE  : 0' "${OUTDIR}/15_nc_db_port.txt" 2>/dev/null || grep -q 'EXIT_CODE  : 0' "${OUTDIR}/15_bash_db_port.txt" 2>/dev/null; then
    nc_status="success"
  else
    nc_status="failed_or_unknown"
  fi
  small_summary="$(paste_matches 'Avg\. throughput|Latency|Throughput|Test finished|Transport mode' "${OUTDIR}/22_oratcptest_small_payload.txt")"
  medium_summary="$(paste_matches 'Avg\. throughput|Latency|Throughput|Test finished|Transport mode' "${OUTDIR}/23_oratcptest_medium_payload.txt")"
  retrans_db="$(count_retransmissions "$PCAP_DB" "$DB_PORT")"
  retrans_oratcp="$(count_retransmissions "$PCAP_ORATCP" "$DEST_ORATCP_PORT")"
  retrans_failover="$(count_retransmissions "$PCAP_FAILOVER" "$DB_PORT")"

  metric_value "target_name" "$TARGET_LABEL"
  metric_value "outdir" "$OUTDIR"
  metric_value "host_origin" "$HOST"
  metric_value "dest_oratcp" "$DEST_HOST:$DEST_ORATCP_PORT"
  metric_value "db_listener" "$DB_HOST:$DB_PORT"
  metric_value "tns_alias" "$TNS_ALIAS"
  metric_value "dblink_name" "$DBLINK_NAME"
  metric_value "db_version" "$DB_VERSION"
  metric_value "iface" "$IFACE"
  metric_value "capture_mode" "$CAPTURE_MODE"
  metric_value "route_get_db" "$route_line"
  metric_value "route_dev" "$route_dev"
  metric_value "route_via" "$route_via"
  metric_value "route_src" "$route_src"
  metric_value "ping_loss_pct" "$ping_loss"
  metric_value "ping_avg_ms" "$ping_avg"
  metric_value "ping_rtt_line" "$ping_rtt"
  metric_value "tnsping_ms" "$tnsping_ms"
  metric_value "nc_status" "$nc_status"
  metric_value "oratcp_small_summary" "$small_summary"
  metric_value "oratcp_medium_summary" "$medium_summary"
  metric_value "dblink_single_row_elapsed_ms" "$(extract_dblink_metric single_row_elapsed_ms)"
  metric_value "dblink_multi_row_elapsed_ms" "$(extract_dblink_metric multi_row_fetch_elapsed_ms)"
  metric_value "dblink_repeated_calls_elapsed_ms" "$(extract_dblink_metric repeated_remote_calls_elapsed_ms)"
  metric_value "dblink_total_roundtrips_delta" "$(extract_dblink_metric total_roundtrips_delta)"
  metric_value "dblink_total_bytes_sent_delta" "$(extract_dblink_metric total_bytes_sent_delta)"
  metric_value "dblink_total_bytes_received_delta" "$(extract_dblink_metric total_bytes_received_delta)"
  metric_value "tcp_retransmissions_db" "$retrans_db"
  metric_value "tcp_retransmissions_oratcp" "$retrans_oratcp"
  metric_value "tcp_retransmissions_failover" "$retrans_failover"
  metric_value "pcap_oratcp" "$PCAP_ORATCP"
  metric_value "pcap_db" "$PCAP_DB"
  metric_value "pcap_failover" "$PCAP_FAILOVER"
}

write_summary() {
  {
    echo "================ SUMMARY ================"
    echo "Target/path      : $TARGET_LABEL"
    echo "Host origen      : $HOST"
    echo "Host oratcptest  : $DEST_HOST:$DEST_ORATCP_PORT"
    echo "Host Oracle      : $DB_HOST:$DB_PORT"
    echo "TNS alias        : $TNS_ALIAS"
    echo "DBLink           : $DBLINK_NAME"
    echo "DB version       : $DB_VERSION"
    echo "Capture mode     : $CAPTURE_MODE"
    echo

    echo "[PATH ROUTING DECISION]"
    grep '^route_' "$METRICS_ENV" || true
    echo "Path snapshots   : $PATHDIR"
    echo

    echo "[TIME SYNC]"
    sed -n '1,40p' "${OUTDIR}/08_time_sync.txt" || true
    echo

    echo "[PING]"
    grep -E 'packets transmitted|packet loss|min/avg/max|round-trip' "${OUTDIR}/10_ping_dbhost.txt" || true
    echo

    echo "[TNSPING]"
    grep -E 'OK|Attempting to contact|msec' "${OUTDIR}/16_tnsping.txt" || true
    echo

    echo "[ORATCPTEST]"
    grep -E 'Avg\. throughput|Latency|Throughput|Test finished|Transport mode' "${OUTDIR}"/2*.txt || true
    echo

    echo "[DBLINK METRICS]"
    grep '^DBLINK_METRIC|' "${OUTDIR}/30_dblink_test.txt" || true
    echo

    echo "[TCP RETRANSMISSIONS]"
    grep '^tcp_retransmissions_' "$METRICS_ENV" || true
    echo

    echo "[PCAPS]"
    ls -lh "$PCAP_ORATCP" "$PCAP_DB" "$PCAP_FAILOVER" 2>/dev/null || true
    echo

    echo "[METRICS]"
    echo "$METRICS_ENV"
    echo "$METRICS_CSV"
  } > "$SUMMARY"
}

trap stop_captures EXIT

echo "[INFO] Target/path: $TARGET_LABEL"
echo "[INFO] Output: $OUTDIR"

{
  echo "target_name=$TARGET_LABEL"
  echo "host_origin=$HOST"
  echo "date_ins=$(date -Ins)"
  echo "dest_oratcp=$DEST_HOST:$DEST_ORATCP_PORT"
  echo "db_listener=$DB_HOST:$DB_PORT"
  echo "tns_alias=$TNS_ALIAS"
  echo "dblink_name=$DBLINK_NAME"
  echo "db_version=$DB_VERSION"
  echo "iface=$IFACE"
  echo "capture_mode=$CAPTURE_MODE"
} > "${OUTDIR}/00_target_context.txt"

capture_time_sync
capture_path_snapshot "00_initial" "before"

run_cmd "01_hostname" hostname
run_cmd "02_uname" uname -a
run_cmd "03_ip_addr" ip addr
run_cmd "04_ip_route" ip route
run_cmd "05_ip_rule" ip rule show
run_cmd "06_ip_neigh" ip neigh show
run_cmd "07_interface_counters" ip -s link
run_cmd "09_java_version" java -version
run_cmd "09_oratcptest_help" java -jar "$JAR" -help

echo "[INFO] Iniciando capturas (${CAPTURE_MODE})"
start_captures

echo "[INFO] Pruebas de red base"
run_cmd "10_ping_dbhost" ping -c 20 -i 0.2 "$DB_HOST"

if command -v traceroute >/dev/null 2>&1; then
  run_cmd "11_traceroute_db_tcp" traceroute -T -p "$DB_PORT" "$DB_HOST"
elif command -v tracepath >/dev/null 2>&1; then
  run_cmd "11_tracepath_db" tracepath "$DB_HOST"
else
  run_cmd "11_traceroute_unavailable" bash -lc "echo 'traceroute/tracepath no disponible'"
fi

if command -v mtr >/dev/null 2>&1; then
  run_cmd "12_mtr_db_tcp" mtr --report --report-cycles 30 --tcp --port "$DB_PORT" "$DB_HOST"
else
  run_cmd "12_mtr_unavailable" bash -lc "echo 'mtr no disponible'"
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

echo "[INFO] SQL*Plus conexion simple"
cat > "${OUTDIR}/sqlplus_connect_test.sql" <<'SQL'
set pages 100 lines 200 timing on echo on
select systimestamp as local_db_time from dual;
exit
SQL

run_cmd "17_sqlplus_connect" bash -lc "sqlplus -L /@${TNS_ALIAS} @${OUTDIR}/sqlplus_connect_test.sql"

echo "[INFO] ORATCPTEST payload chico"
run_cmd "22_oratcptest_small_payload" java -jar "$JAR" "$DEST_HOST" -port="$DEST_ORATCP_PORT" -mode=async -length=8192 -duration=20s -interval=5s

echo "[INFO] ORATCPTEST payload mediano"
run_cmd "23_oratcptest_medium_payload" java -jar "$JAR" "$DEST_HOST" -port="$DEST_ORATCP_PORT" -mode=async -length=65536 -duration=20s -interval=5s

echo "[INFO] DBLINK test via SQL*Plus (DB_VERSION=${DB_VERSION})"
cat > "${OUTDIR}/run_dblink_test.sql" <<SQL
define DB_VERSION=${DB_VERSION}
define DBLINK_NAME=${DBLINK_NAME}
@03_dblink_latency_test.sql
SQL

run_cmd "30_dblink_test" bash -lc "sqlplus -L /@${TNS_ALIAS} @${OUTDIR}/run_dblink_test.sql"

echo "[INFO] Esperando ventana extra de captura: ${CAPTURE_SECONDS}s"
sleep "$CAPTURE_SECONDS"

echo "[INFO] Deteniendo capturas"
stop_captures
trap - EXIT

if [[ -x ./04_analyze_pcap.sh ]]; then
  [[ -f "$PCAP_DB" ]] && run_cmd "40_pcap_db_analysis" ./04_analyze_pcap.sh --pcap "$PCAP_DB" --port "$DB_PORT" --mode app --host "$DB_HOST"
  [[ -f "$PCAP_ORATCP" ]] && run_cmd "41_pcap_oratcp_analysis" ./04_analyze_pcap.sh --pcap "$PCAP_ORATCP" --port "$DEST_ORATCP_PORT" --mode app --host "$DEST_HOST"
  [[ -f "$PCAP_FAILOVER" ]] && run_cmd "42_pcap_failover_analysis" ./04_analyze_pcap.sh --pcap "$PCAP_FAILOVER" --port "$DB_PORT" --mode failover --host "$DB_HOST"
fi

write_metrics
write_summary
capture_path_snapshot "99_final" "after"

echo
echo "[OK] Diagnostico completo en: $OUTDIR"
echo "[OK] Lee primero: $SUMMARY"
