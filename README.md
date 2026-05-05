# Oracle Network and DBLink Diagnostics

Este documento explica, paso a paso y sin ambigüedades, cómo ejecutar el kit de diagnóstico para validar:

1. **latencia de red IP**
2. **latencia de transporte Oracle/TCP con `oratcptest`**
3. **latencia funcional de DBLink**
4. **evidencia TCP con `tcpdump`**

La idea es dejar evidencia suficiente para responder esta pregunta:

> ¿El problema está en la red, en el transporte Oracle, en el DBLink, o en una combinación de todo?

---

# Archivos incluidos

Debes tener estos archivos en el mismo directorio:

- `00_prereq_check.sh`
- `01_oratcp_server.sh`
- `02_oracle_client_diag.sh`
- `03_dblink_latency_test.sql`
- `04_analyze_pcap.sh`
- `oratcptest.jar`

---

# Qué hace cada archivo

## `00_prereq_check.sh`
Valida prerequisitos:
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
Levanta el servidor de `oratcptest` en el host destino.

## `02_oracle_client_diag.sh`
Ejecuta todo desde el cliente:
- ping
- traceroute
- mtr
- MTU check
- conectividad al listener Oracle
- tnsping
- sqlplus
- pruebas `oratcptest`
- prueba funcional de DBLink
- captura tcpdump

## `03_dblink_latency_test.sql`
Mide la latencia funcional del DBLink:
- prueba remota simple
- 10 llamadas remotas
- 100 llamadas remotas
- comparación local vs remota
- waits de Oracle
- SQL con referencia a DBLink

## `04_analyze_pcap.sh`
Analiza rápidamente los archivos `.pcap`:
- SYN / FIN / RST
- retransmisiones
- RTT ACK
- zero window
- conversaciones TCP

---

# Objetivo de la prueba

Queremos separar el problema en capas:

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

# Antes de empezar

## Requisitos mínimos

En ambos hosts debes tener:

- Linux con bash
- Java instalado
- `tcpdump`
- `ping`
- `oratcptest.jar`

En el cliente Oracle además:
- `sqlplus`
- `tnsping`

Idealmente también:
- `mtr`
- `traceroute`
- `tshark`

---

# Preparación

## 0. Obtén `oratcptest.jar`

`oratcptest.jar` es un utilitario oficial de Oracle que **no se distribuye en este repositorio**. Debes obtenerlo directamente desde My Oracle Support (MOS):

1. Entra a [support.oracle.com](https://support.oracle.com) con una cuenta que tenga acceso a MOS.
2. Busca el documento **Doc ID 2064368.1** o el título _"Assessing and Tuning Network Performance for Data Guard and RMAN"_.
3. Desde ese documento, descarga `oratcptest.jar` o sigue las instrucciones del documento para obtenerlo.
4. Copia el archivo `oratcptest.jar` al mismo directorio donde vas a ejecutar los scripts.

---

## 1. Copia todos los archivos al mismo directorio

Ejemplo:

```bash
mkdir -p ~/oracle_net_diag
cd ~/oracle_net_diag