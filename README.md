# Oracle Network and DBLink HA Path Diagnostics

Kit de diagnostico para validar comportamiento por camino en escenarios Habitat / Cirion / OCI. El flujo actual ejecuta el mismo set de pruebas contra multiples targets, por ejemplo Santiago (`SCL`) y Valparaiso (`VLP`), guarda evidencia separada por path y genera una comparacion consolidada para revision tecnica.

El kit valida desde el host Linux/Oracle cliente:

- latencia IP con `ping`, `traceroute` o `tracepath`, `mtr` y checks rapidos de MTU;
- transporte Oracle/TCP con `oratcptest`;
- conectividad Oracle con `nc`, `tnsping` y `sqlplus`;
- latencia funcional DBLink con metricas acotadas a la sesion SQL*Plus bajo prueba;
- evidencia efectiva de path con `ip route get`, `ip rule show`, `ip addr`, `ip neigh show`, `ss -ti` y contadores de interfaz antes y despues de cada test;
- capturas `tcpdump` separadas para trafico de aplicacion y eventos de failover/conectividad;
- watch continuo de failover para medir cortes, recuperacion y errores con timestamps;
- evidencia de sincronizacion de tiempo en cliente y servidor.

## Archivos del kit

| Archivo | Uso actual |
|---|---|
| `targets.csv.example` | Plantilla para declarar los targets/caminos, por ejemplo `SCL` y `VLP`. |
| `06_run_targets.sh` | Wrapper principal. Ejecuta todos los targets del CSV y genera `comparison.csv` y `comparison.md`. Tambien puede refrescar solo el reporte con `--report-only`. |
| `02_oracle_client_diag.sh` | Ejecuta las pruebas de un target individual. Lo invoca `06_run_targets.sh`. |
| `03_dblink_latency_test.sql` | Benchmark DBLink con `SID/SERIAL#`, `DBMS_APPLICATION_INFO`, waits y `v$sesstat` acotados a la sesion del test. |
| `05_failover_watch.sh` | Watch continuo para switchover/link-down: `tnsping`, `sqlplus`, `dual@DBLINK` y `nc/ncat -z`. |
| `04_analyze_pcap.sh` | Analisis de pcaps en modo `app`, `failover` o `all`. |
| `01_oratcp_server.sh` | Levanta el servidor `oratcptest` en cada destino y registra evidencia de tiempo. |
| `00_prereq_check.sh` | Revisa herramientas necesarias y opcionales. |

## Requisitos

En el host cliente Oracle:

- Java y `oratcptest.jar` disponible localmente;
- `tcpdump`, `ping`, `traceroute` o `tracepath`, `mtr`, `nc` o `ncat`, `ip`, `ss`, `awk`;
- Oracle client con `sqlplus` y `tnsping`;
- permisos para ejecutar `tcpdump` con `sudo` o como root;
- opcional: `tshark` para retransmisiones, RTT y analisis enriquecido;
- opcional: `chronyc`, `ntpq` o `timedatectl` para evidencia completa de tiempo.

En cada host destino usado por `oratcptest`:

- Java;
- `oratcptest.jar`;
- puerto permitido para el servidor `oratcptest`, normalmente `4711`;
- reloj sincronizado o al menos evidencia de `date -Ins`.

Ejecuta:

```bash
./00_prereq_check.sh
```

## Obtencion de `oratcptest.jar`

`oratcptest.jar` es una herramienta de Oracle Support y no se incluye en este repositorio. El equipo on-prem o DBA debe descargarla desde My Oracle Support con una cuenta autorizada.

Pasos:

1. Entrar a [My Oracle Support](https://support.oracle.com/).
2. Buscar el documento `Doc ID 2064368.1`: `Assessing and Tuning Network Performance for Data Guard and RMAN`.
3. Descargar el adjunto `oratcptest.jar` desde ese documento.
4. Copiar el archivo al directorio del kit en el host cliente Oracle.
5. Copiar el mismo archivo al directorio del kit en cada host destino donde se ejecutara `01_oratcp_server.sh`.
6. Validar que Java puede abrir el jar:

```bash
java -jar ./oratcptest.jar -help
```

Ubicacion esperada por defecto:

```text
/ruta/del/kit/oratcptest.jar
```

Si el archivo queda en otra ruta, usa estas opciones:

```bash
ORATCPTEST_JAR=/opt/oracle/tools/oratcptest.jar ./06_run_targets.sh targets.csv diag_paths_HAB
./01_oratcp_server.sh 4711 /opt/oracle/tools/oratcptest.jar ./oratcp_server_logs
```

Recomendaciones:

- usar la misma version de `oratcptest.jar` en cliente y destinos;
- no subir `oratcptest.jar` al repositorio Git;
- si el cliente tiene un repositorio interno de binarios aprobado, guardar alli una copia controlada y distribuirla desde ese punto;
- confirmar que el firewall permite TCP hacia el puerto configurado para `oratcptest`, normalmente `4711`.

## Requisitos para el equipo on-prem

Antes de ejecutar la recoleccion, el equipo on-prem debe confirmar conectividad, permisos de host y permisos Oracle. Si alguno de estos puntos falta, el kit puede seguir generando archivos, pero la comparacion quedara incompleta o no podra probar el path real.

### Flujos de red y puertos

Permitir estos flujos desde el host cliente donde se ejecuta `06_run_targets.sh`:

| Origen | Destino | Protocolo/puerto | Para que se usa |
|---|---|---|---|
| Cliente Oracle | `dest_host` de cada target `SCL`/`VLP` | TCP `dest_oratcp_port`, normalmente `4711` | Benchmark `oratcptest`. |
| Cliente Oracle | `db_host` de cada target `SCL`/`VLP` | TCP `db_port`, normalmente `1521` | `nc/ncat`, `tnsping`, `sqlplus`, pcaps de trafico Oracle. |
| Cliente Oracle | `db_host` y `dest_host` | ICMP echo request/reply | `ping` y checks MTU con DF. |
| Cliente Oracle | Saltos intermedios de red | ICMP time exceeded / unreachable | Evidencia de `traceroute`, `tracepath` y `mtr`. |
| Cliente Oracle | `db_host` | TCP `db_port` con TTL variable | `traceroute -T` y `mtr --tcp`. |
| Base de datos origen del DBLink | Base de datos remota del DBLink | TCP listener remoto, normalmente `1521` | Ejecucion real de `select ... from dual@DBLINK`. |

Permitir estos flujos hacia cada host donde se levanta `01_oratcp_server.sh`:

- entrada TCP al puerto `dest_oratcp_port`, normalmente `4711`, desde el host cliente;
- salida de respuesta TCP hacia el host cliente;
- acceso administrativo para copiar el kit, copiar `oratcptest.jar` e iniciar el proceso Java.

Si el ambiente bloquea ICMP, el kit aun puede medir TCP/Oracle, pero no podra validar perdida, MTU ni path IP con la misma claridad. Si `tracepath` se usa como fallback, la red debe permitir las respuestas ICMP generadas por los saltos intermedios.

### Permisos Linux

En el host cliente:

- usuario con permiso de ejecucion sobre los scripts del kit;
- permiso para ejecutar `tcpdump` como root o via `sudo`;
- si se usa `sudo`, idealmente permitir sin password estos comandos para evitar prompts durante la recoleccion: `tcpdump` y `kill`;
- permiso de escritura en el directorio de salida, por ejemplo `diag_paths_HAB`;
- `PATH` con Java, Oracle client, `sqlplus`, `tnsping`, `ip`, `ss`, `ping`, `mtr`, `traceroute` o `tracepath`, `nc` o `ncat`;
- espacio en disco suficiente para pcaps. Como referencia, reservar al menos 2 GB por ventana de captura si hay trafico alto o se usa `capture_seconds` largo.

Ejemplo de politica `sudoers` ajustada por el administrador Linux, usando las rutas reales del host:

```text
oracle_diag_user ALL=(root) NOPASSWD: /usr/sbin/tcpdump, /usr/bin/kill, /bin/kill
```

Alternativa posible, si la politica local lo permite: otorgar capabilities a `tcpdump` con `setcap cap_net_raw,cap_net_admin=eip /usr/sbin/tcpdump`. El equipo Linux debe decidir entre `sudo` y capabilities segun sus controles internos.

En cada host destino de `oratcptest`:

- usuario con permiso para ejecutar Java;
- permiso para abrir el puerto `dest_oratcp_port`;
- firewall local liberado para ese puerto;
- directorio de logs escribible para `./oratcp_server_logs`;
- reloj sincronizado con NTP/chrony o evidencia clara de offset.

### Permisos Oracle y datos de conexion

El equipo DBA debe preparar:

- alias TNS funcional para cada target, por ejemplo `EXPLDB_SCL` y `EXPLDB_VLP`;
- autenticacion valida para `sqlplus -L /@TNS_ALIAS`, ya sea wallet, external authentication o el mecanismo local aprobado;
- DBLink existente y valido para cada path declarado en `targets.csv`;
- usuario con permiso para ejecutar `select systimestamp from dual` y `select systimestamp from dual@DBLINK`;
- acceso de lectura a vistas dinamicas usadas por el diagnostico: `v$session`, `v$mystat`, `v$sesstat`, `v$statname`, `v$session_event` y `v$session_longops`;
- opcional para Oracle 19c: acceso a `v$sql_monitor` solo si existe licencia y aprobacion para Oracle Tuning Pack.

El DBLink se ejecuta desde la base de datos origen, no desde el shell Linux directamente. Por eso el equipo on-prem debe confirmar tambien que el servidor de base de datos origen puede abrir conexion TCP hacia el listener de la base remota del DBLink.

### Coordinacion durante failover

Para una prueba de switchover o link-down:

- definir hora exacta de inicio y fin del evento;
- confirmar que cliente, servidores DB y equipos de red tienen relojes sincronizados;
- iniciar `05_failover_watch.sh` antes del cambio;
- mantener `tcpdump` habilitado durante la ventana;
- registrar quien ejecuta el cambio de red y el timestamp exacto;
- evitar cambios paralelos no relacionados durante la medicion.

## Guia tecnica de recoleccion controlada

Esta seccion es el procedimiento operativo. Ejecutalo en orden y no cambies nombres, targets, aliases ni ventanas de captura a mitad de corrida. El objetivo es que `SCL` y `VLP` queden medidos con el mismo kit, la misma configuracion y un solo directorio raiz de salida.

Reglas para evitar drift en la data collection:

- ejecutar todos los paths con `06_run_targets.sh`; no recolectar `SCL` y `VLP` manualmente con comandos distintos;
- usar un solo `targets.csv` por ventana de prueba;
- no editar `targets.csv` despues de iniciar la corrida;
- no mover, renombrar ni editar archivos dentro del directorio de salida;
- no mezclar resultados de distintas ventanas en el mismo `OUT_ROOT`;
- registrar hora de inicio, hora de fin y cualquier cambio de red ejecutado durante la ventana;
- si un paso critico falla, detenerse y corregir antes de continuar.

### Fase 0 - Definir la ventana y responsables

Antes de tocar el shell, completar esta informacion en el bridge operativo o ticket de cambio:

| Campo | Valor requerido |
|---|---|
| Ventana de prueba | Fecha, hora inicio, hora fin y zona horaria. |
| Host cliente Oracle | Host donde se ejecutara `06_run_targets.sh`. |
| Target `SCL` | `dest_host`, `db_host`, puertos, TNS alias y DBLink. |
| Target `VLP` | `dest_host`, `db_host`, puertos, TNS alias y DBLink. |
| DBA responsable | Persona que valida TNS, DBLink y permisos Oracle. |
| Linux/on-prem responsable | Persona que valida paquetes, permisos y sudo/tcpdump. |
| Red responsable | Persona que valida firewall, rutas, BGP/HSRP/VLAN y cambios de failover. |
| Cambio esperado | Sin cambio, switchover, link-down, routing preference change u otro. |

Resultado esperado: todos los equipos usan los mismos valores para IPs, puertos, aliases y DBLinks. Si algun valor no esta confirmado, no iniciar la recoleccion.

### Fase 1 - Preparar el kit en el host cliente

Ejecutar desde el host cliente Oracle:

```bash
cd /ruta/del/kit
pwd
git rev-parse --short HEAD 2>/dev/null || true
chmod +x ./*.sh
date -Ins
```

Salida esperada:

```text
/ruta/del/kit
<commit_id>
2026-05-06T...
```

Validar:

```bash
ls -1 \
  00_prereq_check.sh \
  01_oratcp_server.sh \
  02_oracle_client_diag.sh \
  03_dblink_latency_test.sql \
  04_analyze_pcap.sh \
  05_failover_watch.sh \
  06_run_targets.sh \
  targets.csv.example \
  README.md
```

Resultado esperado: todos los archivos listados existen. Si falta alguno, detener la recoleccion y corregir la copia del kit.

### Fase 2 - Preparar `oratcptest.jar`

Validar en el host cliente:

```bash
ls -lh ./oratcptest.jar
java -jar ./oratcptest.jar -help | head -n 20
```

Salida esperada:

```text
-rw-r--r-- ... ./oratcptest.jar
Usage: oratcptest ...
```

Si el jar esta en otra ruta:

```bash
export ORATCPTEST_JAR=/opt/oracle/tools/oratcptest.jar
ls -lh "$ORATCPTEST_JAR"
java -jar "$ORATCPTEST_JAR" -help | head -n 20
```

Resultado esperado: Java imprime la ayuda del jar. Si Java no puede abrir el jar, corregir Java, permisos o ruta antes de continuar.

### Fase 3 - Crear un identificador unico de corrida

En el host cliente:

```bash
export RUN_ID="HAB_$(date -u +%Y%m%dT%H%M%SZ)"
export OUT_ROOT="diag_paths_${RUN_ID}"
mkdir -p "$OUT_ROOT"
printf 'RUN_ID=%s\nOUT_ROOT=%s\nSTART_UTC=%s\n' "$RUN_ID" "$OUT_ROOT" "$(date -u -Ins)" | tee "$OUT_ROOT/collection_context.txt"
```

Salida esperada:

```text
RUN_ID=HAB_YYYYMMDDTHHMMSSZ
OUT_ROOT=diag_paths_HAB_YYYYMMDDTHHMMSSZ
START_UTC=...
```

Usar este mismo `OUT_ROOT` hasta terminar la ventana. No crear otro directorio para el mismo evento.

### Fase 4 - Ejecutar prerequisitos del cliente

En el host cliente:

```bash
./00_prereq_check.sh | tee "$OUT_ROOT/00_prereq_client.txt"
```

Salida esperada:

```text
=== PREREQ CHECK ===
[OK]      java
[OK]      tcpdump
[OK]      ping
...
=== ORATCPTEST CHECK ===
[OK]      ./oratcptest.jar existe
```

Validacion:

- `java`, `tcpdump`, `ping`, `ip`, `ss`, `sqlplus` y `tnsping` deben estar disponibles;
- `tshark`, `chronyc`, `ntpq` y `timedatectl` mejoran la evidencia, pero pueden faltar si la politica local no los permite;
- si `tcpdump` requiere `sudo`, confirmar que no pedira password durante la corrida.

Comando de prueba para `tcpdump`:

```bash
timeout 5 sudo tcpdump -i any -c 1 -nn >/tmp/hab_tcpdump_test.txt 2>&1 || true
cat /tmp/hab_tcpdump_test.txt
```

Resultado esperado: no debe quedar esperando password. Si aparece un prompt de `sudo` o un error de permisos, corregir antes de continuar.

### Fase 5 - Crear y congelar `targets.csv`

Crear el archivo:

```bash
cp targets.csv.example targets.csv
vi targets.csv
```

Formato obligatorio:

```csv
target_name,dest_host,dest_oratcp_port,db_host,db_port,tns_alias,dblink_name,db_version,iface,capture_seconds,capture_mode
SCL,10.10.10.20,4711,10.10.10.20,1521,EXPLDB_SCL,MI_DBLINK_SCL,19c,any,90,both
VLP,10.20.10.20,4711,10.20.10.20,1521,EXPLDB_VLP,MI_DBLINK_VLP,19c,any,90,both
```

Columnas:

| Columna | Descripcion | Regla |
|---|---|---|
| `target_name` | Nombre del path en reportes. | Usar `SCL`, `VLP` u otro nombre corto sin espacios. |
| `dest_host` | Host donde corre `01_oratcp_server.sh`. | IP o hostname resoluble desde el cliente. |
| `dest_oratcp_port` | Puerto `oratcptest`. | Normalmente `4711`; debe coincidir con el servidor. |
| `db_host` | Listener Oracle real. | IP o hostname del listener usado para ese path. |
| `db_port` | Puerto listener Oracle. | Normalmente `1521`. |
| `tns_alias` | Alias TNS local. | Debe funcionar con `tnsping` y `sqlplus -L /@ALIAS`. |
| `dblink_name` | DBLink a probar. | Debe existir desde la base origen. |
| `db_version` | Version remota. | `10g`, `11g` o `19c`. |
| `iface` | Interfaz para captura. | `any` si no se conoce la interfaz exacta. |
| `capture_seconds` | Ventana extra post-test. | Recomendado `90` o mas en HA. |
| `capture_mode` | Tipo de captura. | Para HA usar `both`. |

Validar sintaxis del CSV:

```bash
awk -F, '
  NR == 1 { next }
  /^#/ || NF == 0 { next }
  NF != 11 { print "BAD_FIELD_COUNT line " NR ": " NF " fields"; bad=1 }
  END { exit bad }
' targets.csv
```

Salida esperada: sin salida y exit code `0`.

Guardar una copia congelada:

```bash
cp targets.csv "$OUT_ROOT/targets.csv.used"
sha256sum targets.csv | tee "$OUT_ROOT/targets.csv.sha256"
cat targets.csv
```

Resultado esperado: `targets.csv.used` existe dentro del `OUT_ROOT`. Desde este punto no editar `targets.csv` para esta corrida.

### Fase 6 - Validar TNS, DBLink y puertos antes de la corrida

Ejecutar desde el host cliente. Sustituir los aliases reales:

```bash
tnsping EXPLDB_SCL 3 | tee "$OUT_ROOT/pre_tnsping_SCL.txt"
tnsping EXPLDB_VLP 3 | tee "$OUT_ROOT/pre_tnsping_VLP.txt"
```

Salida esperada:

```text
OK (... msec)
```

Probar SQL local via alias:

```bash
sqlplus -L /@EXPLDB_SCL <<'SQL' | tee "$OUT_ROOT/pre_sqlplus_SCL.txt"
set heading off feedback off pages 0
select 'SCL_OK ' || to_char(systimestamp, 'YYYY-MM-DD HH24:MI:SS.FF3 TZH:TZM') from dual;
exit
SQL

sqlplus -L /@EXPLDB_VLP <<'SQL' | tee "$OUT_ROOT/pre_sqlplus_VLP.txt"
set heading off feedback off pages 0
select 'VLP_OK ' || to_char(systimestamp, 'YYYY-MM-DD HH24:MI:SS.FF3 TZH:TZM') from dual;
exit
SQL
```

Salida esperada:

```text
SCL_OK ...
VLP_OK ...
```

Probar DBLink funcional. Sustituir el DBLink real:

```bash
sqlplus -L /@EXPLDB_SCL <<'SQL' | tee "$OUT_ROOT/pre_dblink_SCL.txt"
set heading off feedback off pages 0
select 'SCL_DBLINK_OK ' || to_char(systimestamp, 'YYYY-MM-DD HH24:MI:SS.FF3 TZH:TZM') from dual@MI_DBLINK_SCL;
exit
SQL

sqlplus -L /@EXPLDB_VLP <<'SQL' | tee "$OUT_ROOT/pre_dblink_VLP.txt"
set heading off feedback off pages 0
select 'VLP_DBLINK_OK ' || to_char(systimestamp, 'YYYY-MM-DD HH24:MI:SS.FF3 TZH:TZM') from dual@MI_DBLINK_VLP;
exit
SQL
```

Salida esperada:

```text
SCL_DBLINK_OK ...
VLP_DBLINK_OK ...
```

Si estas pruebas fallan, no ejecutar `06_run_targets.sh`. Corregir TNS, wallet/autenticacion, DBLink o permisos Oracle primero.

### Fase 7 - Iniciar servidores `oratcptest`

En cada host destino declarado como `dest_host`, abrir una terminal y ejecutar:

```bash
cd /ruta/del/kit
chmod +x ./01_oratcp_server.sh
./01_oratcp_server.sh 4711 ./oratcptest.jar ./oratcp_server_logs
```

Si el jar esta en otra ruta:

```bash
./01_oratcp_server.sh 4711 /opt/oracle/tools/oratcptest.jar ./oratcp_server_logs
```

Salida esperada:

```text
==================================================
Servidor oratcptest
Puerto : 4711
Jar    : ./oratcptest.jar
Log    : ./oratcp_server_logs/oratcp_server_YYYYMMDD_HHMMSS.log
==================================================
[INFO] Verificando ayuda del jar
...
[INFO] Iniciando servidor
```

Mantener esta terminal abierta hasta terminar toda la recoleccion. El archivo esperado en cada destino es:

```text
./oratcp_server_logs/oratcp_server_YYYYMMDD_HHMMSS.log
```

Validar desde el host cliente que cada puerto responde:

```bash
nc -vz -w 5 10.10.10.20 4711 | tee "$OUT_ROOT/pre_oratcp_port_SCL.txt"
nc -vz -w 5 10.20.10.20 4711 | tee "$OUT_ROOT/pre_oratcp_port_VLP.txt"
```

Salida esperada:

```text
Connection ... succeeded
```

Si `nc` falla, corregir firewall, puerto, IP, ruta o servidor `oratcptest` antes de continuar.

### Fase 8 - Ejecutar la recoleccion multi-path

Desde el host cliente:

```bash
date -Ins | tee -a "$OUT_ROOT/collection_context.txt"
./06_run_targets.sh targets.csv "$OUT_ROOT"
date -Ins | tee -a "$OUT_ROOT/collection_context.txt"
```

Salida esperada:

```text
[INFO] Output root: diag_paths_HAB_YYYYMMDDTHHMMSSZ
[INFO] Comparison: diag_paths_HAB_YYYYMMDDTHHMMSSZ/comparison.csv
[INFO] Comparison: diag_paths_HAB_YYYYMMDDTHHMMSSZ/comparison.md
[INFO] Ejecutando target SCL -> diag_paths_.../SCL
...
[INFO] Ejecutando target VLP -> diag_paths_.../VLP
...
[OK] Targets ejecutados: 2
[OK] Comparacion CSV: ...
[OK] Comparacion MD : ...
```

No interrumpir la corrida salvo que haya un error operativo claro, por ejemplo password de `sudo`, TNS alias incorrecto, falta de `oratcptest.jar` o puerto cerrado. Si se interrumpe, conservar el directorio parcial y crear un `OUT_ROOT` nuevo para la recoleccion corregida.

### Fase 9 - Validar outputs obligatorios

Ejecutar:

```bash
find "$OUT_ROOT" -maxdepth 2 -type f | sort | tee "$OUT_ROOT/file_manifest.txt"
ls -lh "$OUT_ROOT"
ls -lh "$OUT_ROOT"/SCL "$OUT_ROOT"/VLP
```

Archivos obligatorios a nivel raiz:

| Archivo | Debe existir | Uso |
|---|---|---|
| `comparison.md` | Si | Reporte principal para revision humana. |
| `comparison.csv` | Si | Reporte tabular para filtros o Excel. |
| `run_targets.log` | Si | Log del wrapper multi-target. |
| `targets.csv.used` | Si | Configuracion congelada usada durante la corrida. |
| `targets.csv.sha256` | Si | Huella de la configuracion. |
| `collection_context.txt` | Si | Contexto y timestamps de la corrida. |
| `file_manifest.txt` | Si | Inventario final de archivos. |

Archivos obligatorios por target:

| Archivo/directorio | Debe existir | Uso |
|---|---|---|
| `SUMMARY.txt` | Si | Resumen inicial del target. |
| `metrics.env` | Si | Metricas parseables por el consolidado. |
| `metrics.csv` | Si | Metricas por target en CSV. |
| `00_target_context.txt` | Si | Parametros usados por target. |
| `08_time_sync.txt` | Si | Evidencia de reloj del cliente. |
| `10_ping_dbhost.txt` | Si | Latencia IP basica. |
| `11_traceroute_db_tcp.txt` o `11_tracepath_db.txt` | Si | Path IP/TCP. |
| `12_mtr_db_tcp.txt` | Si, si `mtr` esta instalado | Reporte MTR. |
| `15_nc_db_port.txt` o `15_bash_db_port.txt` | Si | Conexion TCP al listener. |
| `16_tnsping.txt` | Si | Resolucion/conexion TNS. |
| `17_sqlplus_connect.txt` | Si | Conexion SQL local al alias. |
| `22_oratcptest_small_payload.txt` | Si | Benchmark TCP payload chico. |
| `23_oratcptest_medium_payload.txt` | Si | Benchmark TCP payload mediano. |
| `30_dblink_test.txt` | Si | DBLink benchmark y metricas `DBLINK_METRIC`. |
| `path_evidence/` | Si | Snapshots before/after de routing e interfaces. |
| `oracle_HOST_PORT.pcap` | Si, si `capture_mode=app` o `both` | Captura Oracle real. |
| `oratcptest_HOST_PORT.pcap` | Si, si `capture_mode=app` o `both` | Captura `oratcptest`. |
| `failover_connectivity_TARGET.pcap` | Si, si `capture_mode=failover` o `both` | Captura ARP/ICMP/TCP de HA. |

Validar rapidamente metricas clave:

```bash
grep -R '^DBLINK_METRIC|' "$OUT_ROOT"/SCL "$OUT_ROOT"/VLP | tee "$OUT_ROOT/dblink_metric_lines.txt"
grep -R '^route_' "$OUT_ROOT"/SCL/metrics.env "$OUT_ROOT"/VLP/metrics.env | tee "$OUT_ROOT/route_metric_lines.txt"
sed -n '1,80p' "$OUT_ROOT/comparison.md"
```

Salida esperada:

```text
DBLINK_METRIC|single_row_elapsed_ms|...
DBLINK_METRIC|multi_row_fetch_elapsed_ms|...
DBLINK_METRIC|repeated_remote_calls_elapsed_ms|...
route_dev=...
route_src=...
```

Si no aparecen lineas `DBLINK_METRIC`, revisar `30_dblink_test.txt`. Normalmente indica problema de permisos Oracle, DBLink invalido o error SQL.

### Fase 10 - Recoleccion durante failover o switchover

Si la ventana incluye failover, iniciar el watcher antes de ejecutar el cambio. Usar una terminal separada en el host cliente:

```bash
./05_failover_watch.sh \
  --tns-alias EXPLDB_SCL \
  --dblink MI_DBLINK_SCL \
  --db-host 10.10.10.20 \
  --db-port 1521 \
  --interval 2 \
  --duration 900 \
  --outdir "$OUT_ROOT/failover_SCL"
```

Para VLP, si aplica:

```bash
./05_failover_watch.sh \
  --tns-alias EXPLDB_VLP \
  --dblink MI_DBLINK_VLP \
  --db-host 10.20.10.20 \
  --db-port 1521 \
  --interval 2 \
  --duration 900 \
  --outdir "$OUT_ROOT/failover_VLP"
```

Salida esperada en pantalla:

```text
2026-05-06T... [iter=1] tnsping: success (... ms)
2026-05-06T... [iter=1] sqlplus_connect: success (... ms)
2026-05-06T... [iter=1] dblink_systimestamp: success (... ms)
2026-05-06T... [iter=1] tcp_connect: success (... ms)
```

Archivos esperados:

```text
$OUT_ROOT/failover_SCL/failover_watch_YYYYMMDD_HHMMSS.csv
$OUT_ROOT/failover_SCL/failover_watch_YYYYMMDD_HHMMSS.log
$OUT_ROOT/failover_SCL/time_sync_evidence_YYYYMMDD_HHMMSS.txt
```

Durante el cambio de red, el CSV debe registrar transiciones como:

```text
"timestamp","iteration","probe","status","elapsed_ms","error_text"
"...","15","tnsping","failure","10001","timeout after 10s..."
"...","16","tnsping","success","32",""
```

Despues del evento, refrescar el reporte sin repetir la corrida base:

```bash
./06_run_targets.sh --report-only "$OUT_ROOT"
```

Salida esperada:

```text
[OK] Targets consolidados: 2
[OK] Comparacion CSV: ...
[OK] Comparacion MD : ...
```

Validar que `comparison.md` tenga la seccion `Failover Watch Files`:

```bash
grep -n 'Failover Watch Files' -A20 "$OUT_ROOT/comparison.md"
```

### Fase 11 - Analisis de pcaps

El runner ejecuta analisis automatico cuando encuentra `04_analyze_pcap.sh`, pero estos comandos sirven para repetir el analisis manualmente:

```bash
./04_analyze_pcap.sh \
  --pcap "$OUT_ROOT/SCL/oracle_10.10.10.20_1521.pcap" \
  --port 1521 \
  --mode app \
  --host 10.10.10.20 \
  | tee "$OUT_ROOT/SCL/manual_pcap_app_SCL.txt"

./04_analyze_pcap.sh \
  --pcap "$OUT_ROOT/SCL/failover_connectivity_SCL.pcap" \
  --port 1521 \
  --mode failover \
  --host 10.10.10.20 \
  | tee "$OUT_ROOT/SCL/manual_pcap_failover_SCL.txt"
```

Salida esperada:

```text
[1] Primeros paquetes
[2] SYN / FIN / RST
[3] Retransmisiones
...
[F1] ARP / resolucion L2
[F2] ICMP unreachable / administratively prohibited
[F3] TCP lifecycle SYN / FIN / RST
```

Si `tshark` no esta instalado, el analisis mostrara menos detalle. El pcap sigue siendo valido y puede analizarse luego en Wireshark.

### Fase 12 - Empaquetar evidencia

Al finalizar:

```bash
printf 'END_UTC=%s\n' "$(date -u -Ins)" | tee -a "$OUT_ROOT/collection_context.txt"
find "$OUT_ROOT" -type f | sort > "$OUT_ROOT/file_manifest.txt"
tar -czf "${OUT_ROOT}.tar.gz" "$OUT_ROOT"
sha256sum "${OUT_ROOT}.tar.gz" | tee "${OUT_ROOT}.tar.gz.sha256"
ls -lh "${OUT_ROOT}.tar.gz" "${OUT_ROOT}.tar.gz.sha256"
```

Salida esperada:

```text
-rw-r--r-- ... diag_paths_HAB_YYYYMMDDTHHMMSSZ.tar.gz
-rw-r--r-- ... diag_paths_HAB_YYYYMMDDTHHMMSSZ.tar.gz.sha256
```

Entregar al equipo de analisis:

- `${OUT_ROOT}.tar.gz`;
- `${OUT_ROOT}.tar.gz.sha256`;
- hora exacta de cualquier switchover/link-down;
- evidencia manual de red indicada en el checklist final.

### Criterios de completitud

La recoleccion se considera completa solamente si se cumple todo lo siguiente:

- existe un unico `OUT_ROOT` para la ventana;
- `targets.csv.used` contiene al menos `SCL` y `VLP`;
- `comparison.md` y `comparison.csv` existen;
- cada target tiene `SUMMARY.txt`, `metrics.env`, `30_dblink_test.txt` y `path_evidence/`;
- cada target tiene pcaps si `capture_mode=both`;
- `comparison.md` muestra valores de route/path para cada target;
- `30_dblink_test.txt` contiene `SID`, `SERIAL#` y lineas `DBLINK_METRIC`;
- si hubo failover, existe al menos un `failover_watch_*.csv` y se ejecuto `06_run_targets.sh --report-only`;
- el tarball y su `sha256` fueron generados despues de finalizar la ventana.

## DBLink

`03_dblink_latency_test.sql` se ejecuta desde el runner y trabaja sobre la sesion SQL*Plus exacta del test:

- captura y muestra `SID` y `SERIAL#`;
- marca la sesion con `DBMS_APPLICATION_INFO` (`MODULE=HAB_DBLINK_PATH_DIAG`) y cambia `ACTION` por sub-test;
- separa `single-row remote roundtrip`, `multi-row remote fetch` y `sustained repeated remote calls`;
- toma snapshots before/after de `v$sesstat` para bytes enviados, bytes recibidos y roundtrips DBLink;
- emite lineas `DBLINK_METRIC|...|...` que alimentan el reporte consolidado;
- consulta waits DBLink/SQL*Net solamente para el `SID/SERIAL#` capturado.

## Capturas

El runner crea capturas separadas cuando `capture_mode=both`:

- `oratcptest_HOST_PORT.pcap`: trafico del benchmark Oracle/TCP;
- `oracle_HOST_PORT.pcap`: trafico Oracle real hacia el listener;
- `failover_connectivity_TARGET.pcap`: ARP, ICMP y TCP relevante para failover.

Analisis manual:

```bash
./04_analyze_pcap.sh --pcap diag_paths_HAB/SCL/oracle_10.10.10.20_1521.pcap --port 1521 --mode app --host 10.10.10.20
./04_analyze_pcap.sh --pcap diag_paths_HAB/SCL/failover_connectivity_SCL.pcap --port 1521 --mode failover --host 10.10.10.20
```

El modo `failover` busca ARP, ICMP unreachable, SYN/FIN/RST, resets, retransmisiones, perdida, out-of-order y pistas de silent drop.

## Como leer la comparacion

Revisa primero `comparison.md`. Las columnas principales son:

- `Route dev`, `Via`, `Src`: decision local de routing hacia el `db_host`;
- `Ping loss %`, `Ping avg ms`, `TNS ms`: latencia basica por path;
- `DBLink single/fetch/repeated ms`: costo funcional por sub-test DBLink;
- `DB retr` y `Failover retr`: retransmisiones observadas con `tshark` cuando esta instalado;
- `Output`: carpeta con evidencia completa.

Para probar que el trafico sigue usando Santiago o que ya distribuye entre Santiago y Valparaiso, compara `route_dev`, `route_via`, `route_src`, traceroute/mtr, pcaps y los snapshots en `path_evidence/`.

## Lo que este kit no valida por si solo

Este kit observa lo que el host Linux/Oracle cliente puede medir. No rediseña ni confirma por si solo decisiones de red de Cirion, Ascenty u OCI. En particular quedan fuera:

- decision de topologia HA active-active, active-passive o failover automatico;
- cambios de ruteo en Cirion, OCI o Ascenty;
- cambio de mascara de interconexion de `/30` a `/29`;
- implementacion de HSRP en ASR920;
- confirmacion de comunicacion inter-site entre data centers;
- preferencia de ruta o politicas BGP fuera del host cliente.

## Checklist manual para red

Pide al equipo de red evidencia para cada data center y para el momento de failover:

- tablas de ruta y rutas efectivas hacia las IPs Oracle y `oratcptest`;
- estado BGP, vecinos, prefijos anunciados/recibidos y cambios durante el evento;
- estado HSRP/VRRP si aplica, incluyendo active/standby y timers;
- estado de interfaces, VLANs, subinterfaces y cross-connects;
- errores, drops, discards y counters before/after en ASR920, Cirion, Ascenty y OCI;
- evidencia de preferencia de link o policy routing;
- ARP/MAC tables para los endpoints relevantes;
- confirmacion explicita de si existe comunicacion inter-site para HA;
- confirmacion de que la configuracion pendiente del lado Ascenty fue aplicada antes de esperar trafico por VLP.

La revision final debe cruzar esa evidencia de red con `comparison.md`, `path_evidence/`, pcaps y `failover_watch_*.csv`.
