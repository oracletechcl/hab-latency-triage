# Oracle Network and DBLink Diagnostics

Este documento describe el procedimiento de diagnóstico de red y DBLink ejecutado por Oracle en el ambiente indicado. Su objetivo es dejar evidencia técnica suficiente para responder:

> ¿El problema de rendimiento está en la red IP, en el transporte Oracle/TCP, en el DBLink, o en una combinación de todo?

Las pruebas cubren cuatro capas:

1. **Latencia de red IP** — ping, traceroute, mtr
2. **Transporte Oracle/TCP** — `oratcptest` (latencia y throughput)
3. **Latencia funcional de DBLink** — roundtrips reales medidos desde SQL*Plus
4. **Evidencia TCP** — capturas `tcpdump` analizables en Wireshark

---

# Archivos del kit de diagnóstico

El kit utilizado para ejecutar las pruebas contiene los siguientes archivos:

| Archivo | Rol |
|---|---|
| `00_prereq_check.sh` | Verifica prerequisitos del ambiente |
| `01_oratcp_server.sh` | Levanta el servidor `oratcptest` en el host destino |
| `02_oracle_client_diag.sh` | Orquesta todas las pruebas desde el host cliente |
| `03_dblink_latency_test.sql` | Mide latencia funcional del DBLink desde SQL*Plus |
| `04_analyze_pcap.sh` | Analiza las capturas `.pcap` en el host de prueba |
| `oratcptest.jar` | Utilitario oficial Oracle (MOS Doc ID 2064368.1) |

---

# Detalle de los scripts

## `00_prereq_check.sh`
Valida que el ambiente de prueba cuente con:
- Java
- tcpdump
- ping
- traceroute / tracepath
- mtr
- nc
- sqlplus
- tnsping
- tshark
- `oratcptest.jar`

## `01_oratcp_server.sh`
Levanta el servidor de `oratcptest` en el host destino (receptor de las pruebas de transporte Oracle/TCP).

## `02_oracle_client_diag.sh`
Orquesta todas las pruebas desde el host cliente Oracle:
- ping
- traceroute
- mtr
- MTU check
- conectividad al listener Oracle
- tnsping
- sqlplus
- pruebas `oratcptest`
- prueba funcional de DBLink (llama a `03_dblink_latency_test.sql`)
- captura tcpdump

Recibe `DB_VERSION` como parámetro y lo pasa automáticamente al script SQL.

## `03_dblink_latency_test.sql`
Mide la latencia funcional del DBLink. Compatible con **Oracle 10g, 11g y 19c**.
Al ejecutarlo, SQL*Plus pide dos valores:

| Variable | Valores aceptados | Descripción |
|---|---|---|
| `DB_VERSION` | `10g` \| `11g` \| `19c` | Versión de la BD remota (destino del DBLink) |
| `DBLINK_NAME` | nombre del DBLink | Ej.: `MY_DBLINK` |

Secciones que ejecuta:

| # | Qué mide | Versiones |
|---|---|---|
| 1 | Test remoto simple | todas |
| 2 | 10 llamadas remotas secuenciales | todas |
| 3 | 100 llamadas remotas secuenciales | todas |
| 4 | Comparación local vs remoto 100 llamadas | todas |
| 5 | Waits de sesión relacionados con DBLink/SQL\*Net | todas |
| 6 | Top 20 SQL con referencia a DBLink por elapsed_time | todas |
| 7 | `v$session_longops` — operaciones largas activas | todas |
| 8 | `v$sesstat` — bytes y roundtrips por DBLink | 11g+ |
| 9 | Real-Time SQL Monitoring (`v$sql_monitor`) | 19c (requiere Tuning Pack) |

## `04_analyze_pcap.sh`
Analiza rápidamente los archivos `.pcap`:
- SYN / FIN / RST
- retransmisiones
- RTT ACK
- zero window
- conversaciones TCP

---

# Objetivo de las pruebas

Las pruebas están diseñadas para separar el problema en capas:

## Capa 1: Red IP
Esto responde:
- ¿hay latencia base alta?
- ¿hay pérdida?
- ¿hay jitter?
- ¿hay una ruta rara o indirecta?

## Capa 2: Transporte Oracle/TCP
Esto responde:
- ¿el canal Oracle/TCP está sano?
- ¿`oratcptest` muestra diferencia real entre rutas?
- ¿el problema es conectividad o desempeño del transporte?

## Capa 3: DBLink
Esto responde:
- ¿el DBLink es funcionalmente lento?
- ¿la lentitud se acumula por roundtrips?
- ¿el problema viene del patrón remoto del proceso?

## Capa 4: TCP real
Esto responde:
- ¿hay retransmisiones?
- ¿hay pausas entre request/response?
- ¿hay zero windows?
- ¿el handshake está lento?

---

# Requisitos del ambiente de prueba

## En ambos hosts (cliente y destino)

- Linux con bash
- Java instalado
- `tcpdump`
- `ping`
- `oratcptest.jar`

## En el host cliente Oracle además
- `sqlplus`
- `tnsping`

## Opcionales (mejoran la evidencia)
- `mtr`
- `traceroute`
- `tshark`

---

# Preparación del ambiente

## 0. Obtención de `oratcptest.jar`

`oratcptest.jar` es un utilitario oficial de Oracle que no se redistribuye. Oracle lo obtuvo desde My Oracle Support (MOS):

- Documento **Doc ID 2064368.1**: _"Assessing and Tuning Network Performance for Data Guard and RMAN"_.

---

## 1. Directorio de trabajo

Se creó un directorio de trabajo y se copiaron todos los archivos del kit:

```bash
mkdir -p ~/oracle_net_diag
cd ~/oracle_net_diag
chmod +x *.sh
```

---

# Procedimiento a ejecutar

A continuación se documenta cada paso del diagnóstico: el comando ejecutado y la salida obtenida como referencia.

## Paso 1 — Verificación de prerequisitos

Se verificó que el ambiente contara con todas las herramientas necesarias:

```bash
./00_prereq_check.sh
```

**Salida de referencia — ambiente completo:**

```
=== PREREQ CHECK ===
[OK]      java
[OK]      tcpdump
[OK]      ping
[OK]      traceroute
[OK]      tracepath
[OK]      mtr
[OK]      nc
[OK]      sqlplus
[OK]      tnsping
[OK]      tshark

=== JAVA VERSION ===
openjdk version "11.0.22" 2024-01-16
OpenJDK Runtime Environment ...

=== ORATCPTEST CHECK ===
[OK]      ./oratcptest.jar existe
Probando help...
Usage: oratcptest [<host>] [options]
  ...

=== FIN ===
```

**Salida de referencia — prerequisitos faltantes y cómo se resolvieron:**

```
=== PREREQ CHECK ===
[OK]      java
[OK]      tcpdump
[OK]      ping
[MISSING] traceroute
          Como resolver: sudo yum install -y traceroute    (RHEL/OEL/CentOS)
          o bien:  sudo apt-get install -y traceroute  (Debian/Ubuntu)
          Alternativa si no está disponible: usa 'tracepath' (incluido en iputils)

[MISSING] mtr
          Como resolver: sudo yum install -y mtr           (RHEL/OEL/CentOS)
          o bien:  sudo apt-get install -y mtr-tiny  (Debian/Ubuntu)
...

=== ORATCPTEST CHECK ===
[MISSING] ./oratcptest.jar
          Como resolver:
          1. Entra a https://support.oracle.com con una cuenta MOS.
          2. Busca el Doc ID 2064368.1 ...
          4. Copia el archivo a este mismo directorio: cp /ruta/a/oratcptest.jar /home/user/oracle_net_diag/

=== FIN ===
```

> Los prerequisitos marcados `[MISSING]` se resolvieron antes de continuar. `tshark` es opcional.

---

## Paso 2 — Inicio del servidor oratcptest en el host destino

Se levantó el servidor `oratcptest` en el host destino para recibir las pruebas de transporte Oracle/TCP:

```bash
# Ejecutado en el HOST DESTINO:
./01_oratcp_server.sh
```

**Salida al iniciar el servidor:**
Puerto : 4711
Jar    : ./oratcptest.jar
Log    : ./oratcp_server_logs/oratcp_server_20260505_103000.log
==================================================
[INFO] Verificando ayuda del jar
[INFO] Iniciando servidor
[INFO] Déjalo corriendo. No cierres esta terminal.
[INFO] Para detenerlo: Ctrl+C

oratcptest server listening on port 4711
```

> El servidor se mantuvo activo en sesión `screen`/`tmux` durante toda la prueba. El log quedó registrado en `./oratcp_server_logs/`.

---

## Paso 3 — Diagnóstico completo desde el host cliente

Desde el host cliente Oracle se ejecutó el script principal con los parámetros del ambiente:

```bash
./02_oracle_client_diag.sh \
  <DEST_HOST> \
  <DEST_ORATCP_PORT> \
  <DB_HOST> \
  <DB_PORT> \
  <TNS_ALIAS> \
  <DBLINK_NAME> \
  <DB_VERSION> \
  <IFACE> \
  <CAPTURE_SECONDS>
```

| Parámetro | Descripción | Ejemplo |
|---|---|---|
| `DEST_HOST` | Host donde corre oratcptest | `10.10.10.20` |
| `DEST_ORATCP_PORT` | Puerto oratcptest | `4711` |
| `DB_HOST` | Host del listener Oracle | `10.10.10.20` |
| `DB_PORT` | Puerto Oracle | `1521` |
| `TNS_ALIAS` | Alias TNS local | `EXPLDB` |
| `DBLINK_NAME` | Nombre del DBLink | `MI_DBLINK` |
| `DB_VERSION` | Versión de la BD **remota** del DBLink | `10g` \| `11g` \| `19c` |
| `IFACE` | Interfaz tcpdump | `any` \| `eth0` |
| `CAPTURE_SECONDS` | Segundos extra de captura tcpdump | `90` |

Ejemplo de la invocación realizada:

```bash
./02_oracle_client_diag.sh 10.10.10.20 4711 10.10.10.20 1521 EXPLDB MI_DBLINK 19c any 90
```

**Salida en pantalla durante la ejecución:**

```
[INFO] Output: diag_myhost_20260505_103015
[INFO] Iniciando capturas
[INFO] Iniciando tcpdump -> diag_myhost_.../oratcptest_10.10.10.20_4711.pcap
[INFO] Iniciando tcpdump -> diag_myhost_.../oracle_10.10.10.20_1521.pcap
[INFO] Pruebas de red base
[INFO] MTU quick check
[INFO] Listener connectivity
[INFO] TNSPING
[INFO] SQL*Plus conexión simple
[INFO] ORATCPTEST sync
[INFO] ORATCPTEST async
[INFO] ORATCPTEST payload chico
[INFO] ORATCPTEST payload mediano
[INFO] DBLINK test via SQL*Plus (DB_VERSION=19c)
[INFO] Esperando ventana extra de captura: 90s
[INFO] Deteniendo capturas

[OK] Diagnóstico completo en: diag_myhost_20260505_103015
[OK] Lee primero: diag_myhost_20260505_103015/SUMMARY.txt
```

Cada prueba quedó registrada en su propio archivo `.txt` dentro del directorio de resultados:

```
diag_myhost_20260505_103015/
├── SUMMARY.txt                  <- empieza aquí
├── 01_hostname.txt
├── 02_uname.txt
├── 03_ip_addr.txt
├── 04_ip_route.txt
├── 05_java_version.txt
├── 06_oratcptest_help.txt
├── 10_ping_dbhost.txt
├── 11_traceroute_db_tcp.txt
├── 12_mtr_db_tcp.txt
├── 13_mtu_1472.txt
├── 14_mtu_1400.txt
├── 15_nc_db_port.txt
├── 16_tnsping.txt
├── 17_sqlplus_connect.txt
├── 20_oratcptest_sync.txt
├── 21_oratcptest_async.txt
├── 22_oratcptest_small_payload.txt
├── 23_oratcptest_medium_payload.txt
├── 30_dblink_test.txt
├── oratcptest_10.10.10.20_4711.pcap
└── oracle_10.10.10.20_1521.pcap
```

**Contenido típico de `SUMMARY.txt`:**

```
================ SUMMARY ================
Host origen      : myhost
Host oratcptest  : 10.10.10.20:4711
Host Oracle      : 10.10.10.20:1521
TNS alias        : EXPLDB
DBLink           : MI_DBLINK
DB version       : 19c

[PING]
20 packets transmitted, 20 received, 0% packet loss
rtt min/avg/max/mdev = 0.412/0.534/1.102/0.148 ms

[TNSPING]
Attempting to contact (DESCRIPTION= ...)
OK (10 msec)

[ORATCPTEST]
20_oratcptest_sync.txt:  Avg. latency:   0.540 ms
21_oratcptest_async.txt: Avg. throughput: 945.3 Mbps
22_oratcptest_small_payload.txt: ...
23_oratcptest_medium_payload.txt: ...

[PCAPS]
-rw-r--r-- 1 opc opc 1.2M May  5 10:31 oratcptest_10.10.10.20_4711.pcap
-rw-r--r-- 1 opc opc 4.5M May  5 10:31 oracle_10.10.10.20_1521.pcap
```

---

## Paso 4 — Test SQL de DBLink

Se ejecutó el script SQL de latencia de DBLink directamente para obtener evidencia detallada de la capa funcional:

```bash
sqlplus /@<TNS_ALIAS> @03_dblink_latency_test.sql
# SQL*Plus solicita:
#   Enter value for DB_VERSION:  19c
#   Enter value for DBLINK_NAME: MI_DBLINK
```

Para evitar prompts interactivos:

```bash
echo "define DB_VERSION=19c
define DBLINK_NAME=MI_DBLINK
@03_dblink_latency_test.sql" | sqlplus /@<TNS_ALIAS>
```

**Salida obtenida:**

```
==================================================
DBLINK LATENCY TEST
VERSION = 19c
DBLINK  = MI_DBLINK
==================================================

LOCAL_TS
-----------------------------------
2026-05-05 10:30:15.123 -06:00

[1] Test remoto simple

REMOTE_TS
-----------------------------------
2026-05-05 16:30:15.456 +00:00

[2] 10 llamadas remotas secuenciales
10 llamadas remotas total: +000000000 00:00:00.534218000

[3] 100 llamadas remotas secuenciales
100 llamadas remotas total: +000000000 00:00:05.218743000

[4] Comparación local vs remoto - 100 llamadas
100 llamadas locales total:  +000000000 00:00:00.041200000
100 llamadas remotas total: +000000000 00:00:05.231100000

[5] Vista de waits relacionados con DBLink / SQL*Net
       SID    SERIAL# USERNAME   EVENT                                              SECONDS_IN_WAIT STATE
---------- ---------- ---------- -------------------------------------------------- --------------- -------
       143       4821 MYAPP      SQL*Net message from dblink                                      0 WAITING

[6] SQL con referencia explicita a DBLink (top 20 por elapsed_time)
 SQL_ID          EXECUTIONS ELAPSED_TIME SQL_TEXT
 --------------- ---------- ------------ --------------------------------------------------------
 3xkp7fqng4wg2          42    123456789 SELECT * FROM ORDERS@MI_DBLINK WHERE ...

[7] Long operations con referencia remota (11g+)
  no rows selected

[8] Estadisticas de sesion relacionadas con red (11g+)
  SID=143  bytes received via SQL*Net from dblink    8192
  SID=143  bytes sent via SQL*Net to dblink          1024
  SID=143  SQL*Net roundtrips to/from dblink           10

[9] Real-Time SQL Monitoring - sentencias con DBLink (19c)
  NOTA: requiere licencia Oracle Tuning Pack.
  SQL_ID=3xkp7fqng4wg2  status=DONE  elapsed=5.218s  cpu=0.031s  buf_gets=42  disk_rd=0
    SELECT * FROM ORDERS@MI_DBLINK WHERE ...

==================================================
FIN DBLINK LATENCY TEST
==================================================
```

> **Interpretación:** la diferencia entre `100 llamadas locales` y `100 llamadas remotas` muestra el overhead de red por roundtrip. Un ratio > 10x señala latencia de red significativa o SDU de DBLink mal configurado.

---

# Resultados entregados

Se entrega el directorio completo de resultados comprimido para su análisis.

## Paquete entregado

```
diag_<hostname>_<timestamp>.tar.gz
```

## Contenido del paquete

El `.tar.gz` contiene al menos los siguientes archivos:

| Archivo | Qué contiene |
|---|---|
| `SUMMARY.txt` | Resumen ejecutivo: ping, tnsping, oratcptest |
| `10_ping_dbhost.txt` | Latencia y pérdida de paquetes ICMP |
| `11_traceroute_db_tcp.txt` o `11_tracepath_db.txt` | Ruta de red al host Oracle |
| `12_mtr_db_tcp.txt` | Pérdida por salto (si mtr estaba disponible) |
| `13_mtu_1472.txt` / `14_mtu_1400.txt` | Fragmentación MTU |
| `15_nc_db_port.txt` | Conectividad TCP al listener |
| `16_tnsping.txt` | Tiempo de respuesta TNS |
| `17_sqlplus_connect.txt` | Conectividad SQL*Plus básica |
| `20_oratcptest_sync.txt` | Latencia Oracle/TCP en modo síncrono |
| `21_oratcptest_async.txt` | Throughput Oracle/TCP en modo asíncrono |
| `22_oratcptest_small_payload.txt` | Throughput con payload 8 KB |
| `23_oratcptest_medium_payload.txt` | Throughput con payload 64 KB |
| `30_dblink_test.txt` | Latencia funcional del DBLink (secciones 1–9) |
| `*.pcap` | Capturas TCP de oratcptest y del listener Oracle |

