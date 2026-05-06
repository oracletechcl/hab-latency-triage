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

## Configuracion de targets

Crea el archivo de targets desde la plantilla:

```bash
cp targets.csv.example targets.csv
```

Edita `targets.csv` con los valores reales:

```csv
target_name,dest_host,dest_oratcp_port,db_host,db_port,tns_alias,dblink_name,db_version,iface,capture_seconds,capture_mode
SCL,10.10.10.20,4711,10.10.10.20,1521,EXPLDB_SCL,MI_DBLINK_SCL,19c,any,90,both
VLP,10.20.10.20,4711,10.20.10.20,1521,EXPLDB_VLP,MI_DBLINK_VLP,19c,any,90,both
```

Columnas:

| Columna | Descripcion |
|---|---|
| `target_name` | Nombre del path en reportes, por ejemplo `SCL` o `VLP`. |
| `dest_host` / `dest_oratcp_port` | Host y puerto donde corre `01_oratcp_server.sh`. |
| `db_host` / `db_port` | Listener Oracle real usado para red, TCP y pcaps. |
| `tns_alias` | Alias TNS local para `tnsping` y `sqlplus -L /@ALIAS`. |
| `dblink_name` | DBLink que se consulta con `dual@DBLINK`. |
| `db_version` | `10g`, `11g` o `19c`. |
| `iface` | Interfaz para `tcpdump`, por ejemplo `any`, `eth0` o `ens3`. |
| `capture_seconds` | Ventana adicional de captura despues de las pruebas. |
| `capture_mode` | `app`, `failover`, `both` o `none`. Para HA usa `both`. |

## Ejecucion

### 1. Iniciar `oratcptest` en cada destino

En cada host destino declarado en el CSV:

```bash
./01_oratcp_server.sh 4711 ./oratcptest.jar ./oratcp_server_logs
```

Dejalo corriendo durante la recoleccion. El log incluye `date -Ins`, `timedatectl`, `chronyc` y `ntpq` cuando estan disponibles.

### 2. Ejecutar todos los paths

Desde el host cliente Oracle:

```bash
./06_run_targets.sh targets.csv diag_paths_HAB
```

El wrapper ejecuta cada fila del CSV, crea un subdirectorio por target y produce:

| Salida | Contenido |
|---|---|
| `diag_paths_HAB/SCL/` | Evidencia completa del path `SCL`. |
| `diag_paths_HAB/VLP/` | Evidencia completa del path `VLP`. |
| `diag_paths_HAB/comparison.csv` | Comparacion machine-readable. |
| `diag_paths_HAB/comparison.md` | Comparacion para revision de ingenieria. |
| `diag_paths_HAB/run_targets.log` | Log del wrapper. |

Dentro de cada target veras `SUMMARY.txt`, `metrics.env`, `metrics.csv`, pcaps, salida de cada prueba y `path_evidence/` con snapshots before/after por test.

### 3. Medir failover o switchover

Antes de forzar el evento, inicia el watcher en una terminal separada. Usa un `--outdir` dentro del output root para que el reporte consolidado pueda encontrarlo:

```bash
./05_failover_watch.sh \
  --tns-alias EXPLDB_SCL \
  --dblink MI_DBLINK_SCL \
  --db-host 10.10.10.20 \
  --db-port 1521 \
  --interval 2 \
  --duration 900 \
  --outdir diag_paths_HAB/failover_SCL
```

El watcher registra:

- `failover_watch_YYYYMMDD_HHMMSS.csv`: `timestamp`, `iteration`, `probe`, `status`, `elapsed_ms`, `error_text`;
- `failover_watch_YYYYMMDD_HHMMSS.log`: lectura humana del mismo loop;
- `time_sync_evidence_YYYYMMDD_HHMMSS.txt`: evidencia de reloj local.

Despues del evento, refresca la comparacion sin repetir las pruebas base:

```bash
./06_run_targets.sh --report-only diag_paths_HAB
```

El `comparison.md` incluira un resumen de archivos `failover_watch_*.csv`, primera falla y primera recuperacion observada.

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
