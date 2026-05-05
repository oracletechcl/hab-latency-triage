-- ==============================================================
--  SELECTOR DE VERSION DE BASE DE DATOS
-- ==============================================================
--  Cuando SQL*Plus pregunte "Enter value for DB_VERSION:",
--  escribe UNA de las siguientes opciones:
--
--    10g  ->  Oracle Database 10.1 / 10.2
--    11g  ->  Oracle Database 11.1 / 11.2
--    19c  ->  Oracle Database 12c / 18c / 19c / 21c
--
--  Ejemplo:
--    @03_dblink_latency_test.sql
--    Enter value for DB_VERSION: 19c
--    Enter value for DBLINK_NAME: MY_DBLINK
-- ==============================================================
DEFINE DB_VERSION = &&DB_VERSION

-- 10g no soporta "unlimited" en serveroutput; derivamos el valor correcto.
COLUMN srvout_sz_ NEW_VALUE SRVOUT_SZ_ NOPRINT
SELECT DECODE(UPPER('&&DB_VERSION'),
              '10G', '1000000',
              'unlimited') AS srvout_sz_
FROM dual;

set serveroutput on size &&SRVOUT_SZ_
set timing on
set lines 200
set pages 100
whenever sqlerror continue

column local_ts  format a35
column remote_ts format a35

prompt ==================================================
prompt DBLINK LATENCY TEST
prompt VERSION = &&DB_VERSION
prompt DBLINK  = &&DBLINK_NAME
prompt ==================================================

select to_char(systimestamp, 'YYYY-MM-DD HH24:MI:SS.FF3 TZH:TZM') as local_ts from dual;

prompt
prompt [1] Test remoto simple
select to_char(systimestamp, 'YYYY-MM-DD HH24:MI:SS.FF3 TZH:TZM') as remote_ts
from dual@&DBLINK_NAME;

prompt
prompt [2] 10 llamadas remotas secuenciales
declare
  v_start timestamp;
  v_end   timestamp;
  v_dummy varchar2(128);
begin
  v_start := systimestamp;
  for i in 1..10 loop
    execute immediate
      'select to_char(systimestamp,''YYYY-MM-DD HH24:MI:SS.FF3'') from dual@&DBLINK_NAME'
      into v_dummy;
  end loop;
  v_end := systimestamp;
  dbms_output.put_line('10 llamadas remotas total: ' || to_char(v_end - v_start));
end;
/

prompt
prompt [3] 100 llamadas remotas secuenciales
declare
  v_start timestamp;
  v_end   timestamp;
  v_dummy varchar2(128);
begin
  v_start := systimestamp;
  for i in 1..100 loop
    execute immediate
      'select to_char(systimestamp,''YYYY-MM-DD HH24:MI:SS.FF3'') from dual@&DBLINK_NAME'
      into v_dummy;
  end loop;
  v_end := systimestamp;
  dbms_output.put_line('100 llamadas remotas total: ' || to_char(v_end - v_start));
end;
/

prompt
prompt [4] Comparación local vs remoto - 100 llamadas
declare
  v_start timestamp;
  v_end   timestamp;
  v_dummy varchar2(128);
begin
  -- local
  v_start := systimestamp;
  for i in 1..100 loop
    execute immediate
      'select to_char(systimestamp,''YYYY-MM-DD HH24:MI:SS.FF3'') from dual'
      into v_dummy;
  end loop;
  v_end := systimestamp;
  dbms_output.put_line('100 llamadas locales total:  ' || to_char(v_end - v_start));

  -- remoto
  v_start := systimestamp;
  for i in 1..100 loop
    execute immediate
      'select to_char(systimestamp,''YYYY-MM-DD HH24:MI:SS.FF3'') from dual@&DBLINK_NAME'
      into v_dummy;
  end loop;
  v_end := systimestamp;
  dbms_output.put_line('100 llamadas remotas total: ' || to_char(v_end - v_start));
end;
/

prompt
prompt [5] Vista de waits relacionados con DBLink / SQL*Net
column event format a50
select sid, serial#, username, event, seconds_in_wait, state
from v$session
where username is not null
  and (
       lower(event) like '%dblink%'
    or lower(event) like '%sql*net%'
  )
order by seconds_in_wait desc;

prompt
prompt [6] SQL con referencia explicita a DBLink (top 20 por elapsed_time)
column sql_id   format a15
column sql_text format a120
select *
from (
  select sql_id,
         executions,
         elapsed_time,
         substr(sql_text, 1, 120) sql_text
  from   v$sql
  where  sql_text like '%@%'
  order  by elapsed_time desc
)
where rownum <= 20;

-- ==============================================================
--  SECCIONES ESPECIFICAS POR VERSION
-- ==============================================================

prompt
prompt [7] Long operations con referencia remota (11g+)
-- v$session_longops existe en 10g pero la columna SQL_PLAN_OPERATION
-- es mas util a partir de 11g.  Ejecutamos en todas las versiones,
-- pero la salida es mas rica en 11g/19c.
column opname    format a40
column target    format a30
column units     format a10
select sid,
       serial#,
       opname,
       target,
       sofar,
       totalwork,
       units,
       elapsed_seconds,
       time_remaining
from   v$session_longops
where  totalwork > 0
  and  sofar < totalwork
order  by elapsed_seconds desc;

-- ==============================================================
--  SOLO 11g y 19c: estadisticas de sesion por DBLink
-- ==============================================================
declare
  v_ver varchar2(10) := UPPER('&&DB_VERSION');
begin
  if v_ver in ('11G', '19C') then
    dbms_output.put_line('');
    dbms_output.put_line('[8] Estadisticas de sesion relacionadas con red (11g+)');
    for r in (
      select ss.sid,
             sn.name,
             ss.value
      from   v$sesstat  ss
      join   v$statname sn on sn.statistic# = ss.statistic#
      where  sn.name in (
               'bytes sent via SQL*Net to dblink',
               'bytes received via SQL*Net from dblink',
               'SQL*Net roundtrips to/from dblink'
             )
        and  ss.value > 0
      order  by ss.sid, sn.name
    ) loop
      dbms_output.put_line('  SID=' || r.sid
                           || '  ' || rpad(r.name, 45)
                           || '  ' || r.value);
    end loop;
  else
    dbms_output.put_line('[8] Estadisticas de sesion por DBLink: omitido (requiere 11g+)');
  end if;
end;
/

-- ==============================================================
--  SOLO 19c: Real-Time SQL Monitoring por DBLink
--  Requiere Oracle Tuning Pack.
-- ==============================================================
declare
  v_ver varchar2(10) := UPPER('&&DB_VERSION');
begin
  if v_ver = '19C' then
    dbms_output.put_line('');
    dbms_output.put_line('[9] Real-Time SQL Monitoring - sentencias con DBLink (19c)');
    dbms_output.put_line('    NOTA: requiere licencia Oracle Tuning Pack.');
    for r in (
      select sql_id,
             status,
             elapsed_time / 1e6          elapsed_sec,
             cpu_time     / 1e6          cpu_sec,
             buffer_gets,
             disk_reads,
             substr(sql_text, 1, 100)    sql_text
      from   v$sql_monitor
      where  sql_text like '%@%'
        and  last_refresh_time > sysdate - 1/24
      order  by elapsed_time desc
      fetch  first 10 rows only
    ) loop
      dbms_output.put_line('  SQL_ID=' || r.sql_id
                           || '  status='   || r.status
                           || '  elapsed='  || to_char(r.elapsed_sec,  'FM9999990.000') || 's'
                           || '  cpu='      || to_char(r.cpu_sec,      'FM9999990.000') || 's'
                           || '  buf_gets=' || r.buffer_gets
                           || '  disk_rd='  || r.disk_reads);
      dbms_output.put_line('    ' || r.sql_text);
    end loop;
  else
    dbms_output.put_line('[9] Real-Time SQL Monitoring: omitido (requiere 19c + Tuning Pack)');
  end if;
end;
/

prompt ==================================================
prompt FIN DBLINK LATENCY TEST
prompt ==================================================