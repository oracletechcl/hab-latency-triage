#!/usr/bin/env bash
set -euo pipefail

TNS_ALIAS="${TNS_ALIAS:-}"
DBLINK_NAME="${DBLINK_NAME:-${DBLINK:-}}"
INTERVAL="${INTERVAL_SECONDS:-${INTERVAL:-5}}"
DURATION="${DURATION_SECONDS:-${DURATION:-0}}"
ITERATIONS="${ITERATIONS:-0}"
DB_HOST="${DB_HOST:-}"
DB_PORT="${DB_PORT:-}"
OUTDIR="${OUTDIR:-}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-10}"

usage() {
  cat <<'USAGE'
Uso:
  ./05_failover_watch.sh --tns-alias TNS --dblink DBLINK [opciones]

Opciones:
  --tns-alias, -t   Alias TNS para tnsping/sqlplus. Env: TNS_ALIAS
  --dblink, -d      Nombre del DBLink para dual@DBLINK. Env: DBLINK_NAME o DBLINK
  --interval, -i    Segundos entre iteraciones. Env: INTERVAL_SECONDS o INTERVAL. Default: 5
  --duration        Duracion total en segundos. Env: DURATION_SECONDS o DURATION. Default: 0=infinito
  --iterations, -n  Numero maximo de iteraciones. Env: ITERATIONS. Default: 0=infinito
  --db-host         Host DB para prueba opcional nc -z. Env: DB_HOST
  --db-port         Puerto DB para prueba opcional nc -z. Env: DB_PORT
  --outdir, -o      Directorio de salida. Env: OUTDIR
  --timeout         Timeout por probe en segundos. Env: PROBE_TIMEOUT. Default: 10
  --help, -h        Mostrar esta ayuda

Probes:
  - tnsping TNS_ALIAS
  - sqlplus -L -S /@TNS_ALIAS con select systimestamp from dual
  - sqlplus -L -S /@TNS_ALIAS con select systimestamp from dual@DBLINK
  - nc/ncat -z DB_HOST DB_PORT cuando se entregan ambos valores
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

is_nonnegative_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tns-alias|-t)
      [[ $# -ge 2 ]] || die "falta valor para $1"
      TNS_ALIAS="$2"
      shift 2
      ;;
    --dblink|--dblink-name|-d)
      [[ $# -ge 2 ]] || die "falta valor para $1"
      DBLINK_NAME="$2"
      shift 2
      ;;
    --interval|-i)
      [[ $# -ge 2 ]] || die "falta valor para $1"
      INTERVAL="$2"
      shift 2
      ;;
    --duration)
      [[ $# -ge 2 ]] || die "falta valor para $1"
      DURATION="$2"
      shift 2
      ;;
    --iterations|-n)
      [[ $# -ge 2 ]] || die "falta valor para $1"
      ITERATIONS="$2"
      shift 2
      ;;
    --db-host)
      [[ $# -ge 2 ]] || die "falta valor para $1"
      DB_HOST="$2"
      shift 2
      ;;
    --db-port)
      [[ $# -ge 2 ]] || die "falta valor para $1"
      DB_PORT="$2"
      shift 2
      ;;
    --outdir|-o)
      [[ $# -ge 2 ]] || die "falta valor para $1"
      OUTDIR="$2"
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || die "falta valor para $1"
      PROBE_TIMEOUT="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      die "opcion desconocida: $1"
      ;;
    *)
      die "argumento no reconocido: $1"
      ;;
  esac
done

is_nonnegative_int "$INTERVAL" || die "--interval debe ser un entero >= 0"
is_nonnegative_int "$DURATION" || die "--duration debe ser un entero >= 0"
is_nonnegative_int "$ITERATIONS" || die "--iterations debe ser un entero >= 0"
is_nonnegative_int "$PROBE_TIMEOUT" || die "--timeout debe ser un entero >= 0"
if [[ "$INTERVAL" == "0" && "$DURATION" == "0" && "$ITERATIONS" == "0" ]]; then
  die "--interval 0 requiere --duration o --iterations para evitar un loop sin pausa"
fi

RUN_TS="$(date +%Y%m%d_%H%M%S)"
if [[ -z "$OUTDIR" ]]; then
  HOST_SHORT="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host)"
  OUTDIR="./failover_watch_${HOST_SHORT}_${RUN_TS}"
fi

mkdir -p "$OUTDIR"
CSV_LOG="${OUTDIR}/failover_watch_${RUN_TS}.csv"
HUMAN_LOG="${OUTDIR}/failover_watch_${RUN_TS}.log"
TIME_EVIDENCE="${OUTDIR}/time_sync_evidence_${RUN_TS}.txt"
SQL_CONNECT_FILE="${OUTDIR}/sqlplus_connect_probe.sql"
SQL_DBLINK_FILE="${OUTDIR}/sqlplus_dblink_probe.sql"

printf 'timestamp,iteration,probe,status,elapsed_ms,error_text\n' >"$CSV_LOG"
: >"$HUMAN_LOG"

log_human() {
  printf '%s %s\n' "$(date -Ins)" "$*" | tee -a "$HUMAN_LOG"
}

collect_time_sync_evidence() {
  {
    echo "=== date -Ins ==="
    date -Ins 2>&1 || true
    echo
    echo "=== date -u -Ins ==="
    date -u -Ins 2>&1 || true
    echo
    echo "=== timedatectl status ==="
    if command -v timedatectl >/dev/null 2>&1; then
      timedatectl status 2>&1 || true
    else
      echo "[unavailable] timedatectl"
    fi
    echo
    echo "=== chronyc tracking ==="
    if command -v chronyc >/dev/null 2>&1; then
      chronyc tracking 2>&1 || true
    else
      echo "[unavailable] chronyc"
    fi
    echo
    echo "=== chronyc sources -v ==="
    if command -v chronyc >/dev/null 2>&1; then
      chronyc sources -v 2>&1 || true
    else
      echo "[unavailable] chronyc"
    fi
    echo
    echo "=== ntpq -pn ==="
    if command -v ntpq >/dev/null 2>&1; then
      ntpq -pn 2>&1 || true
    else
      echo "[unavailable] ntpq"
    fi
    echo
    echo "=== ntpstat ==="
    if command -v ntpstat >/dev/null 2>&1; then
      ntpstat 2>&1 || true
    else
      echo "[unavailable] ntpstat"
    fi
  } >"$TIME_EVIDENCE"
}

cat >"$SQL_CONNECT_FILE" <<'SQL'
whenever oserror exit 9
whenever sqlerror exit sql.sqlcode
set echo off feedback off heading off pagesize 0 verify off trimspool on timing off
select 'OK ' || to_char(systimestamp, 'YYYY-MM-DD"T"HH24:MI:SS.FF3 TZH:TZM') from dual;
exit success
SQL

if [[ -n "$DBLINK_NAME" ]]; then
  cat >"$SQL_DBLINK_FILE" <<SQL
whenever oserror exit 9
whenever sqlerror exit sql.sqlcode
set echo off feedback off heading off pagesize 0 verify off trimspool on timing off
select 'OK ' || to_char(systimestamp, 'YYYY-MM-DD"T"HH24:MI:SS.FF3 TZH:TZM') from dual@${DBLINK_NAME};
exit success
SQL
fi

epoch_ms() {
  local ms
  ms="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$ms" =~ ^[0-9]+$ ]]; then
    printf '%s' "$ms"
  else
    printf '%s000' "$(date +%s)"
  fi
}

compact_text() {
  local text="$1"
  text="${text//$'\r'/ }"
  text="${text//$'\n'/ | }"
  text="${text//$'\t'/ }"
  while [[ "$text" == *"  "* ]]; do
    text="${text//  / }"
  done
  if ((${#text} > 500)); then
    text="${text:0:500}..."
  fi
  printf '%s' "$text"
}

csv_field() {
  local text="$1"
  text="${text//$'\r'/ }"
  text="${text//$'\n'/ | }"
  text="${text//\"/\"\"}"
  printf '"%s"' "$text"
}

run_with_timeout() {
  local seconds="$1"
  shift
  if [[ "$seconds" != "0" ]] && command -v timeout >/dev/null 2>&1; then
    timeout "${seconds}s" "$@"
  else
    "$@"
  fi
}

skip_probe() {
  echo "$1"
  return 77
}

probe_tnsping() {
  [[ -n "$TNS_ALIAS" ]] || { skip_probe "TNS_ALIAS no fue entregado"; return $?; }
  command -v tnsping >/dev/null 2>&1 || { skip_probe "tnsping no esta instalado o no esta en PATH"; return $?; }
  run_with_timeout "$PROBE_TIMEOUT" tnsping "$TNS_ALIAS" 1
}

probe_sqlplus_connect() {
  [[ -n "$TNS_ALIAS" ]] || { skip_probe "TNS_ALIAS no fue entregado"; return $?; }
  command -v sqlplus >/dev/null 2>&1 || { skip_probe "sqlplus no esta instalado o no esta en PATH"; return $?; }
  run_with_timeout "$PROBE_TIMEOUT" sqlplus -L -S "/@${TNS_ALIAS}" @"$SQL_CONNECT_FILE"
}

probe_dblink_systimestamp() {
  [[ -n "$TNS_ALIAS" ]] || { skip_probe "TNS_ALIAS no fue entregado"; return $?; }
  [[ -n "$DBLINK_NAME" ]] || { skip_probe "DBLINK_NAME no fue entregado"; return $?; }
  command -v sqlplus >/dev/null 2>&1 || { skip_probe "sqlplus no esta instalado o no esta en PATH"; return $?; }
  run_with_timeout "$PROBE_TIMEOUT" sqlplus -L -S "/@${TNS_ALIAS}" @"$SQL_DBLINK_FILE"
}

probe_tcp_connect() {
  [[ -n "$DB_HOST" && -n "$DB_PORT" ]] || { skip_probe "DB_HOST y DB_PORT deben estar presentes para nc -z"; return $?; }
  local nc_bin=""
  if command -v nc >/dev/null 2>&1; then
    nc_bin="nc"
  elif command -v ncat >/dev/null 2>&1; then
    nc_bin="ncat"
  else
    skip_probe "nc/ncat no esta instalado o no esta en PATH"
    return $?
  fi
  run_with_timeout "$PROBE_TIMEOUT" "$nc_bin" -z -w "$PROBE_TIMEOUT" "$DB_HOST" "$DB_PORT"
}

run_probe() {
  local iteration="$1"
  local name="$2"
  shift 2
  local ts start end elapsed output rc status error

  ts="$(date -Ins)"
  start="$(epoch_ms)"
  set +e
  output="$("$@" 2>&1)"
  rc=$?
  set -e
  end="$(epoch_ms)"
  elapsed=$((end - start))

  if [[ "$rc" -eq 0 ]]; then
    status="success"
    error=""
  elif [[ "$rc" -eq 77 ]]; then
    status="skipped"
    error="$(compact_text "$output")"
  else
    status="failure"
    error="$(compact_text "$output")"
    if [[ "$rc" -eq 124 ]]; then
      error="timeout after ${PROBE_TIMEOUT}s${error:+: ${error}}"
    elif [[ -z "$error" ]]; then
      error="exit_code=${rc}"
    else
      error="exit_code=${rc}: ${error}"
    fi
  fi

  {
    csv_field "$ts"; printf ','
    csv_field "$iteration"; printf ','
    csv_field "$name"; printf ','
    csv_field "$status"; printf ','
    csv_field "$elapsed"; printf ','
    csv_field "$error"; printf '\n'
  } >>"$CSV_LOG"

  if [[ "$status" == "success" ]]; then
    log_human "[iter=${iteration}] ${name}: success (${elapsed} ms)"
  else
    log_human "[iter=${iteration}] ${name}: ${status} (${elapsed} ms) ${error}"
  fi
}

ENABLED_PROBES=()
if [[ -n "$TNS_ALIAS" ]]; then
  ENABLED_PROBES+=("tnsping" "sqlplus_connect")
fi
if [[ -n "$TNS_ALIAS" && -n "$DBLINK_NAME" ]]; then
  ENABLED_PROBES+=("dblink_systimestamp")
fi
if [[ -n "$DB_HOST" && -n "$DB_PORT" ]]; then
  ENABLED_PROBES+=("tcp_connect")
fi

if [[ ${#ENABLED_PROBES[@]} -eq 0 ]]; then
  usage >&2
  die "no hay probes habilitados; entrega al menos --tns-alias o --db-host + --db-port"
fi

collect_time_sync_evidence

log_human "=================================================="
log_human "Failover watch"
log_human "TNS alias : ${TNS_ALIAS:-<no entregado>}"
log_human "DBLink    : ${DBLINK_NAME:-<no entregado>}"
log_human "DB host   : ${DB_HOST:-<no entregado>}"
log_human "DB port   : ${DB_PORT:-<no entregado>}"
log_human "Interval  : ${INTERVAL}s"
log_human "Duration  : ${DURATION}s (0=infinito)"
log_human "Iterations: ${ITERATIONS} (0=infinito)"
log_human "Timeout   : ${PROBE_TIMEOUT}s por probe"
log_human "CSV       : ${CSV_LOG}"
log_human "Log       : ${HUMAN_LOG}"
log_human "Time sync : ${TIME_EVIDENCE}"
log_human "Probes    : ${ENABLED_PROBES[*]}"
log_human "=================================================="

if [[ ( -n "$DB_HOST" && -z "$DB_PORT" ) || ( -z "$DB_HOST" && -n "$DB_PORT" ) ]]; then
  log_human "[WARN] nc -z deshabilitado: DB_HOST y DB_PORT deben estar presentes juntos"
fi
if [[ -n "$DBLINK_NAME" && -z "$TNS_ALIAS" ]]; then
  log_human "[WARN] DBLink probe deshabilitado: requiere TNS_ALIAS para sqlplus"
fi

stop_requested() {
  log_human "Stop solicitado; cerrando watch"
  exit 130
}
trap stop_requested INT TERM

START_EPOCH="$(date +%s)"
END_EPOCH=0
if [[ "$DURATION" != "0" ]]; then
  END_EPOCH=$((START_EPOCH + DURATION))
fi

iteration=0
while true; do
  iteration=$((iteration + 1))
  log_human "---- iteracion ${iteration} ----"

  for probe in "${ENABLED_PROBES[@]}"; do
    case "$probe" in
      tnsping)
        run_probe "$iteration" "tnsping" probe_tnsping
        ;;
      sqlplus_connect)
        run_probe "$iteration" "sqlplus_connect" probe_sqlplus_connect
        ;;
      dblink_systimestamp)
        run_probe "$iteration" "dblink_systimestamp" probe_dblink_systimestamp
        ;;
      tcp_connect)
        run_probe "$iteration" "tcp_connect" probe_tcp_connect
        ;;
    esac
  done

  if [[ "$ITERATIONS" != "0" && "$iteration" -ge "$ITERATIONS" ]]; then
    break
  fi

  if [[ "$END_EPOCH" != "0" ]]; then
    now_epoch="$(date +%s)"
    remaining=$((END_EPOCH - now_epoch))
    if ((remaining <= 0)); then
      break
    fi
    sleep_for="$INTERVAL"
    if ((sleep_for > remaining)); then
      sleep_for="$remaining"
    fi
    sleep "$sleep_for"
  else
    sleep "$INTERVAL"
  fi
done

log_human "Watch finalizado"
