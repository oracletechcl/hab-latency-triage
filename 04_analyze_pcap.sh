#!/usr/bin/env bash
set -euo pipefail

PCAP=""
PORT="${PORT:-1521}"
MODE="${MODE:-app}"
MODE_SET=0
DB_HOST="${DB_HOST:-}"
CLIENT_HOST="${CLIENT_HOST:-}"
LIMIT="${LIMIT:-100}"

usage() {
  cat <<'USAGE'
Uso:
  ./04_analyze_pcap.sh --pcap archivo.pcap --port 1521 --mode app --host DB_HOST
  ./04_analyze_pcap.sh --pcap archivo.pcap --port 1521 --mode failover --host DB_HOST [--client-host CLIENT_HOST]
  ./04_analyze_pcap.sh --pcap archivo.pcap --port 1521 --mode all --host DB_HOST

Opciones:
  --pcap              Archivo .pcap/.pcapng
  --port, -p          Puerto TCP Oracle/listener. Default: 1521
  --mode              app | failover | all. Default: app
  --failover          Atajo para --mode failover
  --all               Atajo para --mode all
  --host, --db-host   Host DB a filtrar en tcpdump/tshark
  --client-host       Host cliente a filtrar junto con --host
  --limit             Lineas maximas para listados largos. Default: 100
  --help, -h          Mostrar esta ayuda
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pcap)
      [[ $# -ge 2 ]] || die "falta valor para $1"
      PCAP="$2"
      shift 2
      ;;
    --port|-p)
      [[ $# -ge 2 ]] || die "falta valor para $1"
      PORT="$2"
      shift 2
      ;;
    --mode)
      [[ $# -ge 2 ]] || die "falta valor para $1"
      MODE="$2"
      MODE_SET=1
      shift 2
      ;;
    --failover|--connectivity)
      MODE="failover"
      MODE_SET=1
      shift
      ;;
    --all)
      MODE="all"
      MODE_SET=1
      shift
      ;;
    --host|--db-host)
      [[ $# -ge 2 ]] || die "falta valor para $1"
      DB_HOST="$2"
      if [[ "$MODE_SET" -eq 0 ]]; then
        MODE="all"
      fi
      shift 2
      ;;
    --client-host|--client)
      [[ $# -ge 2 ]] || die "falta valor para $1"
      CLIENT_HOST="$2"
      if [[ "$MODE_SET" -eq 0 ]]; then
        MODE="all"
      fi
      shift 2
      ;;
    --limit)
      [[ $# -ge 2 ]] || die "falta valor para $1"
      LIMIT="$2"
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

if [[ -z "$PCAP" ]]; then
  usage >&2
  exit 1
fi
[[ -r "$PCAP" ]] || die "no puedo leer el archivo: $PCAP"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port debe ser numerico"
[[ "$LIMIT" =~ ^[0-9]+$ ]] || die "--limit debe ser numerico"
case "$MODE" in
  app|failover|all) ;;
  *) die "--mode debe ser app, failover o all" ;;
esac

have() {
  command -v "$1" >/dev/null 2>&1
}

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv6() {
  [[ "$1" == *:* ]]
}

tcp_host_bpf() {
  local filter="tcp port $PORT"
  if [[ -n "$DB_HOST" && -n "$CLIENT_HOST" ]]; then
    filter="${filter} and host ${DB_HOST} and host ${CLIENT_HOST}"
  elif [[ -n "$DB_HOST" ]]; then
    filter="${filter} and host ${DB_HOST}"
  elif [[ -n "$CLIENT_HOST" ]]; then
    filter="${filter} and host ${CLIENT_HOST}"
  fi
  printf '%s' "$filter"
}

arp_bpf() {
  local filter="arp"
  if [[ -n "$DB_HOST" && -n "$CLIENT_HOST" ]]; then
    filter="${filter} and (host ${DB_HOST} or host ${CLIENT_HOST})"
  elif [[ -n "$DB_HOST" ]]; then
    filter="${filter} and host ${DB_HOST}"
  elif [[ -n "$CLIENT_HOST" ]]; then
    filter="${filter} and host ${CLIENT_HOST}"
  fi
  printf '%s' "$filter"
}

icmp_bpf() {
  local filter="icmp or icmp6"
  if [[ -n "$DB_HOST" && -n "$CLIENT_HOST" ]]; then
    filter="(${filter}) and (host ${DB_HOST} or host ${CLIENT_HOST})"
  elif [[ -n "$DB_HOST" ]]; then
    filter="(${filter}) and host ${DB_HOST}"
  elif [[ -n "$CLIENT_HOST" ]]; then
    filter="(${filter}) and host ${CLIENT_HOST}"
  fi
  printf '%s' "$filter"
}

tcp_display_filter() {
  local filter="tcp.port == ${PORT}"
  for host in "$DB_HOST" "$CLIENT_HOST"; do
    if [[ -z "$host" ]]; then
      continue
    elif is_ipv4 "$host"; then
      filter="${filter} && ip.addr == ${host}"
    elif is_ipv6 "$host"; then
      filter="${filter} && ipv6.addr == ${host}"
    fi
  done
  printf '%s' "$filter"
}

icmp_display_filter() {
  local filter="icmp || icmpv6"
  local host_clauses=()
  for host in "$DB_HOST" "$CLIENT_HOST"; do
    if [[ -z "$host" ]]; then
      continue
    elif is_ipv4 "$host"; then
      host_clauses+=("ip.addr == ${host}")
    elif is_ipv6 "$host"; then
      host_clauses+=("ipv6.addr == ${host}")
    fi
  done
  if [[ ${#host_clauses[@]} -gt 0 ]]; then
    local joined="${host_clauses[0]}"
    local i
    for ((i = 1; i < ${#host_clauses[@]}; i++)); do
      joined="${joined} || ${host_clauses[$i]}"
    done
    filter="(${filter}) && (${joined})"
  fi
  printf '%s' "$filter"
}

arp_display_filter() {
  local filter="arp"
  local host_clauses=()
  for host in "$DB_HOST" "$CLIENT_HOST"; do
    if is_ipv4 "$host"; then
      host_clauses+=("arp.src.proto_ipv4 == ${host} || arp.dst.proto_ipv4 == ${host}")
    fi
  done
  if [[ ${#host_clauses[@]} -gt 0 ]]; then
    local joined="${host_clauses[0]}"
    local i
    for ((i = 1; i < ${#host_clauses[@]}; i++)); do
      joined="${joined} || ${host_clauses[$i]}"
    done
    filter="arp && (${joined})"
  fi
  printf '%s' "$filter"
}

section() {
  echo
  echo "$1"
}

tcpdump_sample() {
  local filter="$1"
  local limit="${2:-$LIMIT}"
  if have tcpdump; then
    tcpdump -nn -tttt -r "$PCAP" "$filter" 2>/dev/null | head -n "$limit" || true
  else
    echo "[INFO] tcpdump no esta instalado o no esta en PATH."
  fi
}

tshark_fields() {
  local filter="$1"
  local limit="$2"
  shift 2
  if have tshark; then
    tshark -r "$PCAP" -Y "$filter" -T fields -E header=y -E separator=, "$@" 2>/dev/null | head -n "$limit" || true
  else
    echo "[INFO] tshark no esta instalado; se omiten campos enriquecidos."
  fi
}

tshark_count() {
  local filter="$1"
  local count
  if ! have tshark; then
    printf 'NA'
    return
  fi
  set +e
  count="$(tshark -r "$PCAP" -Y "$filter" -T fields -e frame.number 2>/dev/null | wc -l | tr -d ' ')"
  set -e
  printf '%s' "${count:-0}"
}

run_app_analysis() {
  local tcp_bpf tcp_df
  tcp_bpf="$(tcp_host_bpf)"
  tcp_df="$(tcp_display_filter)"

  section "[1] Primeros paquetes"
  tcpdump_sample "$tcp_bpf" 40

  section "[2] SYN / FIN / RST"
  tcpdump_sample "${tcp_bpf} and (tcp[tcpflags] & (tcp-syn|tcp-fin|tcp-rst) != 0)" "$LIMIT"

  if have tshark; then
    section "[3] Retransmisiones"
    tshark -r "$PCAP" -Y "tcp.analysis.retransmission && ${tcp_df}" \
      -T fields -e frame.time -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e tcp.seq 2>/dev/null || true

    section "[4] RTT ACK"
    tshark -r "$PCAP" -Y "tcp.analysis.ack_rtt && ${tcp_df}" \
      -T fields -e frame.time -e ip.src -e ip.dst -e tcp.analysis.ack_rtt 2>/dev/null | head -n 50 || true

    section "[5] Zero Window / Window Full"
    tshark -r "$PCAP" -Y "(tcp.analysis.zero_window or tcp.analysis.window_full) && ${tcp_df}" \
      -T fields -e frame.time -e ip.src -e ip.dst -e tcp.window_size_value 2>/dev/null || true

    section "[6] Conversaciones TCP"
    tshark -r "$PCAP" -q -z conv,tcp 2>/dev/null || true
  else
    section "[INFO] tshark no esta instalado. Instalalo si quieres RTT ACK y retransmisiones mas claras."
  fi
}

run_failover_analysis() {
  local tcp_bpf tcp_df arp_filter icmp_filter
  tcp_bpf="$(tcp_host_bpf)"
  tcp_df="$(tcp_display_filter)"
  arp_filter="$(arp_display_filter)"
  icmp_filter="$(icmp_display_filter)"

  section "[F1] ARP / resolucion L2"
  tcpdump_sample "$(arp_bpf)" "$LIMIT"
  tshark_fields "$arp_filter" "$LIMIT" \
    -e frame.time -e eth.src -e eth.dst -e arp.opcode -e arp.src.proto_ipv4 -e arp.dst.proto_ipv4

  section "[F2] ICMP unreachable / administratively prohibited"
  tcpdump_sample "$(icmp_bpf)" "$LIMIT"
  tshark_fields "(${icmp_filter}) && (icmp.type == 3 || icmpv6.type == 1)" "$LIMIT" \
    -e frame.time -e ip.src -e ip.dst -e ipv6.src -e ipv6.dst -e icmp.type -e icmp.code -e icmpv6.type -e icmpv6.code

  section "[F3] TCP lifecycle SYN / FIN / RST"
  tcpdump_sample "${tcp_bpf} and (tcp[tcpflags] & (tcp-syn|tcp-fin|tcp-rst) != 0)" "$LIMIT"
  tshark_fields "(${tcp_df}) && (tcp.flags.syn == 1 || tcp.flags.fin == 1 || tcp.flags.reset == 1)" "$LIMIT" \
    -e frame.time -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e tcp.flags.syn -e tcp.flags.ack -e tcp.flags.fin -e tcp.flags.reset

  section "[F4] RST detalles"
  tcpdump_sample "${tcp_bpf} and (tcp[tcpflags] & tcp-rst != 0)" "$LIMIT"
  tshark_fields "(${tcp_df}) && tcp.flags.reset == 1" "$LIMIT" \
    -e frame.time -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e tcp.seq -e tcp.ack

  section "[F5] Retransmisiones / perdida / out-of-order"
  if have tshark; then
    tshark_fields "(${tcp_df}) && (tcp.analysis.retransmission || tcp.analysis.fast_retransmission || tcp.analysis.lost_segment || tcp.analysis.out_of_order || tcp.analysis.duplicate_ack)" "$LIMIT" \
      -e frame.time -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e tcp.seq -e tcp.analysis.retransmission -e tcp.analysis.fast_retransmission -e tcp.analysis.lost_segment -e tcp.analysis.out_of_order -e tcp.analysis.duplicate_ack
  else
    echo "[INFO] tshark no esta instalado; tcpdump no marca retransmisiones con precision."
  fi

  section "[F6] SYN retransmitidos / pistas de silent drop"
  if have tshark; then
    tshark_fields "(${tcp_df}) && tcp.flags.syn == 1 && tcp.flags.ack == 0" "$LIMIT" \
      -e frame.time -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e tcp.seq -e tcp.analysis.retransmission -e tcp.analysis.fast_retransmission

    local syn synack rst retrans syn_retrans icmp_unreach
    syn="$(tshark_count "(${tcp_df}) && tcp.flags.syn == 1 && tcp.flags.ack == 0")"
    synack="$(tshark_count "(${tcp_df}) && tcp.flags.syn == 1 && tcp.flags.ack == 1")"
    rst="$(tshark_count "(${tcp_df}) && tcp.flags.reset == 1")"
    retrans="$(tshark_count "(${tcp_df}) && (tcp.analysis.retransmission || tcp.analysis.fast_retransmission)")"
    syn_retrans="$(tshark_count "(${tcp_df}) && tcp.flags.syn == 1 && tcp.flags.ack == 0 && (tcp.analysis.retransmission || tcp.analysis.fast_retransmission)")"
    icmp_unreach="$(tshark_count "(${icmp_filter}) && (icmp.type == 3 || icmpv6.type == 1)")"

    echo
    echo "Resumen filtrado:"
    echo "  SYN iniciales             : ${syn}"
    echo "  SYN-ACK                   : ${synack}"
    echo "  RST                       : ${rst}"
    echo "  Retransmisiones TCP       : ${retrans}"
    echo "  SYN retransmitidos        : ${syn_retrans}"
    echo "  ICMP unreachable/prohibit : ${icmp_unreach}"
    if [[ "$syn_retrans" =~ ^[0-9]+$ && "$rst" =~ ^[0-9]+$ && "$icmp_unreach" =~ ^[0-9]+$ ]]; then
      if ((syn_retrans > 0 && rst == 0 && icmp_unreach == 0)); then
        echo "  Pista: SYN retransmitidos sin RST/ICMP en el filtro; revisar drops silenciosos, ACL/firewall o path asimetrico."
      fi
      if ((rst > 0)); then
        echo "  Pista: hay RST; revisar quien resetea la conexion y si coincide con failover/listener/service relocation."
      fi
      if ((icmp_unreach > 0)); then
        echo "  Pista: hay ICMP unreachable/prohibit; revisar ruta, ACL, firewall o gateway."
      fi
    fi
  else
    echo "[INFO] tshark no esta instalado; no se calculan conteos de SYN/retransmisiones."
  fi
}

echo "=================================================="
echo "Archivo     : $PCAP"
echo "Puerto      : $PORT"
echo "Modo        : $MODE"
echo "DB host     : ${DB_HOST:-<sin filtro>}"
echo "Client host : ${CLIENT_HOST:-<sin filtro>}"
echo "=================================================="

case "$MODE" in
  app)
    run_app_analysis
    ;;
  failover)
    run_failover_analysis
    ;;
  all)
    run_app_analysis
    run_failover_analysis
    ;;
esac
