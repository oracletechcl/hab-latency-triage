set serveroutput on size unlimited
set timing on
set lines 200
set pages 100
whenever sqlerror continue

column local_ts format a35
column remote_ts format a35

prompt ==================================================
prompt DBLINK LATENCY TEST
prompt ==================================================
prompt DBLINK = &DBLINK_NAME
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
    execute immediate 'select to_char(systimestamp,''YYYY-MM-DD HH24:MI:SS.FF3'') from dual@&DBLINK_NAME'
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
    execute immediate 'select to_char(systimestamp,''YYYY-MM-DD HH24:MI:SS.FF3'') from dual@&DBLINK_NAME'
      into v_dummy;
  end loop;
  v_end := systimestamp;
  dbms_output.put_line('100 llamadas remotas total: ' || to_char(v_end - v_start));
end;
/

prompt
prompt [4] Comparación local 100 llamadas
declare
  v_start timestamp;
  v_end   timestamp;
  v_dummy varchar2(128);
begin
  v_start := systimestamp;
  for i in 1..100 loop
    execute immediate 'select to_char(systimestamp,''YYYY-MM-DD HH24:MI:SS.FF3'') from dual'
      into v_dummy;
  end loop;
  v_end := systimestamp;
  dbms_output.put_line('100 llamadas locales total: ' || to_char(v_end - v_start));
end;
/

prompt
prompt [5] Vista de waits relacionados
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
prompt [6] SQL con referencia explicita a DBLink
column sql_id format a15
column sql_text format a120
select *
from (
  select sql_id, executions, elapsed_time, substr(sql_text,1,120) sql_text
  from v$sql
  where sql_text like '%@%'
  order by elapsed_time desc
)
where rownum <= 20;

prompt ==================================================
prompt FIN DBLINK LATENCY TEST
prompt ==================================================