#!/usr/bin/env bash
set -euo pipefail

PCAP="${1:-}"
PORT="${2:-1521}"

if [[ -z "$PCAP" ]]; then
  echo "Uso: $0 <archivo.pcap> <puerto>"
  exit 1
fi

echo "=================================================="
echo "Archivo: $PCAP"
echo "Puerto : $PORT"
echo "=================================================="

echo
echo "[1] Primeros paquetes"
tcpdump -nn -tttt -r "$PCAP" "tcp port $PORT" 2>/dev/null | head -n 40 || true

echo
echo "[2] SYN / FIN / RST"
tcpdump -nn -tttt -r "$PCAP" \
  "tcp port $PORT and (tcp[tcpflags] & (tcp-syn|tcp-fin|tcp-rst) != 0)" 2>/dev/null || true

if command -v tshark >/dev/null 2>&1; then
  echo
  echo "[3] Retransmisiones"
  tshark -r "$PCAP" -Y "tcp.analysis.retransmission && tcp.port == $PORT" \
    -T fields -e frame.time -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e tcp.seq 2>/dev/null || true

  echo
  echo "[4] RTT ACK"
  tshark -r "$PCAP" -Y "tcp.analysis.ack_rtt && tcp.port == $PORT" \
    -T fields -e frame.time -e ip.src -e ip.dst -e tcp.analysis.ack_rtt 2>/dev/null | head -n 50 || true

  echo
  echo "[5] Zero Window / Window Full"
  tshark -r "$PCAP" -Y "(tcp.analysis.zero_window or tcp.analysis.window_full) && tcp.port == $PORT" \
    -T fields -e frame.time -e ip.src -e ip.dst -e tcp.window_size_value 2>/dev/null || true

  echo
  echo "[6] Conversaciones TCP"
  tshark -r "$PCAP" -q -z conv,tcp 2>/dev/null || true
else
  echo
  echo "[INFO] tshark no está instalado. Instálalo si quieres RTT ACK y retransmisiones más claras."
fi