#!/usr/bin/env bash
set -euo pipefail

echo "=== PREREQ CHECK ==="

# need_cmd <comando> <hint de como instalarlo>
need_cmd() {
  local c="$1"
  local hint="$2"
  if command -v "$c" >/dev/null 2>&1; then
    echo "[OK]      $c"
  else
    echo "[MISSING] $c"
    echo "          Como resolver: $hint"
    echo
  fi
}

need_cmd java \
  "Instala Java: sudo yum install -y java-11-openjdk  (RHEL/OEL/CentOS)
          o bien:  sudo apt-get install -y default-jdk  (Debian/Ubuntu)"

need_cmd tcpdump \
  "sudo yum install -y tcpdump       (RHEL/OEL/CentOS)
          o bien:  sudo apt-get install -y tcpdump  (Debian/Ubuntu)"

need_cmd ping \
  "sudo yum install -y iputils       (RHEL/OEL/CentOS)
          o bien:  sudo apt-get install -y iputils-ping  (Debian/Ubuntu)"

need_cmd traceroute \
  "sudo yum install -y traceroute    (RHEL/OEL/CentOS)
          o bien:  sudo apt-get install -y traceroute  (Debian/Ubuntu)
          Alternativa si no está disponible: usa 'tracepath' (incluido en iputils)"

need_cmd tracepath \
  "sudo yum install -y iputils       (RHEL/OEL/CentOS)
          o bien:  sudo apt-get install -y iputils-tracepath  (Debian/Ubuntu)"

need_cmd mtr \
  "sudo yum install -y mtr           (RHEL/OEL/CentOS)
          o bien:  sudo apt-get install -y mtr-tiny  (Debian/Ubuntu)"

need_cmd nc \
  "sudo yum install -y nmap-ncat     (RHEL/OEL/CentOS)
          o bien:  sudo apt-get install -y netcat-openbsd  (Debian/Ubuntu)
          Nota: en algunos sistemas el binario se llama 'ncat'; verifica con: which ncat"

need_cmd sqlplus \
  "Instala Oracle Instant Client + sqlplus:
            https://www.oracle.com/database/technologies/instant-client/downloads.html
          O asegúrate de que \$ORACLE_HOME/bin esté en el PATH:
            export PATH=\$ORACLE_HOME/bin:\$PATH"

need_cmd tnsping \
  "tnsping es parte de Oracle Instant Client (paquete instantclient-tools) o del Oracle Home.
          Descarga el paquete 'tools' del Instant Client desde:
            https://www.oracle.com/database/technologies/instant-client/downloads.html
          O agrega \$ORACLE_HOME/bin al PATH:
            export PATH=\$ORACLE_HOME/bin:\$PATH"

need_cmd tshark \
  "sudo yum install -y wireshark-cli  (RHEL/OEL/CentOS)
          o bien:  sudo apt-get install -y tshark  (Debian/Ubuntu)
          Nota: es opcional; solo se usa en 04_analyze_pcap.sh"

echo
echo "=== JAVA VERSION ==="
java -version 2>&1 || echo "[AVISO] java no disponible; instálalo antes de continuar."

echo
echo "=== ORATCPTEST CHECK ==="
if [[ -f ./oratcptest.jar ]]; then
  echo "[OK]      ./oratcptest.jar existe"
  echo "Probando help..."
  java -jar ./oratcptest.jar -help >/tmp/oratcptest_help.txt 2>&1 || true
  head -n 20 /tmp/oratcptest_help.txt || true
else
  echo "[MISSING] ./oratcptest.jar"
  echo "          Como resolver:"
  echo "          1. Entra a https://support.oracle.com con una cuenta MOS."
  echo "          2. Busca el Doc ID 2064368.1:"
  echo "             'Assessing and Tuning Network Performance for Data Guard and RMAN'."
  echo "          3. Desde ese documento descarga oratcptest.jar."
  echo "          4. Copia el archivo a este mismo directorio:"
  echo "             cp /ruta/a/oratcptest.jar $(pwd)/"
fi

echo
echo "=== FIN ==="