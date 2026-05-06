-- ==============================================================
--  DBLINK PATH-AWARE HA DIAGNOSTIC
-- ==============================================================
--  02_oracle_client_diag.sh define DB_VERSION y DBLINK_NAME antes de
--  invocar este archivo. Valores aceptados para DB_VERSION: 10g, 11g, 19c.
-- ==============================================================
DEFINE DB_VERSION  = &&DB_VERSION
DEFINE DBLINK_NAME = &&DBLINK_NAME

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

variable diag_sid number
variable diag_serial number

column local_ts  format a35
column username  format a20
column module    format a26
column action    format a26
column machine   format a35
column program   format a45

prompt ==================================================
prompt DBLINK PATH-AWARE HA DIAGNOSTIC
prompt VERSION = &&DB_VERSION
prompt DBLINK  = &&DBLINK_NAME
prompt ==================================================

select to_char(systimestamp, 'YYYY-MM-DD HH24:MI:SS.FF3 TZH:TZM') as local_ts
from dual;

prompt
prompt [0] Sesion SQL*Plus bajo prueba
declare
  v_sid    number;
  v_serial number;
  v_total_sent_delta  number := null;
  v_total_recv_delta  number := null;
  v_total_rtrip_delta number := null;
begin
  select sid
  into   v_sid
  from   v$mystat
  where  rownum = 1;

  select serial#
  into   v_serial
  from   v$session
  where  sid = v_sid;

  :diag_sid := v_sid;
  :diag_serial := v_serial;

  dbms_application_info.set_module(
    module_name => 'HAB_DBLINK_PATH_DIAG',
    action_name => 'session-captured');

  dbms_output.put_line('SQL*Plus test session SID=' || v_sid ||
                       ' SERIAL#=' || v_serial);
  dbms_output.put_line('Module=HAB_DBLINK_PATH_DIAG Action=session-captured');
end;
/

select sid,
       serial#,
       username,
       module,
       action,
       machine,
       program
from   v$session
where  sid = :diag_sid
  and  serial# = :diag_serial;

prompt
prompt [1] Benchmarks acotados a la sesion SQL*Plus
declare
  c_module     constant varchar2(48) := 'HAB_DBLINK_PATH_DIAG';
  c_fetch_rows constant pls_integer  := 1000;
  c_call_count constant pls_integer  := 100;

  c_stat_sent  constant varchar2(64) := 'bytes sent via SQL*Net to dblink';
  c_stat_recv  constant varchar2(64) := 'bytes received via SQL*Net from dblink';
  c_stat_rtrip constant varchar2(64) := 'SQL*Net roundtrips to/from dblink';

  type t_stats is record (
    sent       number,
    received   number,
    roundtrips number,
    found      pls_integer,
    ok         boolean,
    err        varchar2(200)
  );

  v_sid    number;
  v_serial number;

  procedure read_dblink_stats(p_stats out t_stats) is
  begin
    p_stats.sent := null;
    p_stats.received := null;
    p_stats.roundtrips := null;
    p_stats.found := 0;
    p_stats.ok := false;
    p_stats.err := null;

    for r in (
      select sn.name,
             ss.value
      from   v$sesstat ss,
             v$statname sn
      where  ss.sid = v_sid
        and  sn.statistic# = ss.statistic#
        and  sn.name in (c_stat_sent, c_stat_recv, c_stat_rtrip)
    ) loop
      p_stats.found := p_stats.found + 1;

      if r.name = c_stat_sent then
        p_stats.sent := r.value;
      elsif r.name = c_stat_recv then
        p_stats.received := r.value;
      elsif r.name = c_stat_rtrip then
        p_stats.roundtrips := r.value;
      end if;
    end loop;

    p_stats.ok := (p_stats.found > 0);
  exception
    when others then
      p_stats.ok := false;
      p_stats.err := substr(sqlerrm, 1, 200);
  end read_dblink_stats;

  function fmt_value(p_value number) return varchar2 is
  begin
    if p_value is null then
      return 'n/a';
    end if;

    return trim(to_char(p_value));
  end fmt_value;

  function fmt_delta(p_before number, p_after number) return varchar2 is
  begin
    if p_before is null or p_after is null then
      return 'n/a';
    end if;

    return trim(to_char(p_after - p_before));
  end fmt_delta;

  function metric_text(p_value number) return varchar2 is
  begin
    if p_value is null then
      return 'NA';
    end if;

    return trim(to_char(p_value,
                        'FM999999999999999990.000',
                        'NLS_NUMERIC_CHARACTERS = ''.,'''));
  end metric_text;

  function delta_number(p_before number, p_after number) return number is
  begin
    if p_before is null or p_after is null then
      return null;
    end if;

    return p_after - p_before;
  end delta_number;

  procedure emit_metric(p_name varchar2, p_value number) is
  begin
    dbms_output.put_line('DBLINK_METRIC|' || p_name || '|' ||
                         metric_text(p_value));
  end emit_metric;

  procedure add_total(p_total in out number, p_delta number) is
  begin
    if p_delta is not null then
      if p_total is null then
        p_total := 0;
      end if;
      p_total := p_total + p_delta;
    end if;
  end add_total;

  function elapsed_seconds(p_start timestamp, p_end timestamp) return number is
    v_delta interval day to second;
  begin
    v_delta := p_end - p_start;

    return extract(day from v_delta) * 86400
         + extract(hour from v_delta) * 3600
         + extract(minute from v_delta) * 60
         + extract(second from v_delta);
  end elapsed_seconds;

  procedure print_metric(
    p_name   varchar2,
    p_before number,
    p_after  number
  ) is
  begin
    dbms_output.put_line('    ' || rpad(p_name, 43) ||
                         lpad(fmt_value(p_before), 14) ||
                         lpad(fmt_value(p_after), 14) ||
                         lpad(fmt_delta(p_before, p_after), 14));
  end print_metric;

  procedure print_stats_delta(
    p_metric_prefix varchar2,
    p_before        t_stats,
    p_after         t_stats
  ) is
    v_sent_delta  number;
    v_recv_delta  number;
    v_rtrip_delta number;
  begin
    v_sent_delta := delta_number(p_before.sent, p_after.sent);
    v_recv_delta := delta_number(p_before.received, p_after.received);
    v_rtrip_delta := delta_number(p_before.roundtrips, p_after.roundtrips);

    if not p_before.ok and not p_after.ok then
      dbms_output.put_line('    DBLink v$sesstat: n/a');
      if p_before.err is not null then
        dbms_output.put_line('    v$sesstat error: ' || p_before.err);
      elsif p_after.err is not null then
        dbms_output.put_line('    v$sesstat error: ' || p_after.err);
      else
        dbms_output.put_line('    DBLink stat names were not visible in this session/version.');
      end if;
      emit_metric(p_metric_prefix || '_bytes_sent_delta', null);
      emit_metric(p_metric_prefix || '_bytes_received_delta', null);
      emit_metric(p_metric_prefix || '_roundtrips_delta', null);
      return;
    end if;

    dbms_output.put_line('    DBLink v$sesstat snapshots and deltas');
    dbms_output.put_line('    ' || rpad('Statistic', 43) ||
                         lpad('Before', 14) ||
                         lpad('After', 14) ||
                         lpad('Delta', 14));
    print_metric(c_stat_sent, p_before.sent, p_after.sent);
    print_metric(c_stat_recv, p_before.received, p_after.received);
    print_metric(c_stat_rtrip, p_before.roundtrips, p_after.roundtrips);
    emit_metric(p_metric_prefix || '_bytes_sent_delta', v_sent_delta);
    emit_metric(p_metric_prefix || '_bytes_received_delta', v_recv_delta);
    emit_metric(p_metric_prefix || '_roundtrips_delta', v_rtrip_delta);

    add_total(v_total_sent_delta, v_sent_delta);
    add_total(v_total_recv_delta, v_recv_delta);
    add_total(v_total_rtrip_delta, v_rtrip_delta);

    if p_after.found < 3 then
      dbms_output.put_line('    Note: only ' || p_after.found ||
                           ' of 3 DBLink counters were visible.');
    end if;
  end print_stats_delta;

  procedure print_elapsed(
    p_metric_name varchar2,
    p_start       timestamp,
    p_end         timestamp
  ) is
    v_elapsed_sec number;
  begin
    v_elapsed_sec := elapsed_seconds(p_start, p_end);
    dbms_output.put_line('    Elapsed seconds: ' ||
                         to_char(v_elapsed_sec,
                                 'FM9999999990.000'));
    emit_metric(p_metric_name, v_elapsed_sec * 1000);
  end print_elapsed;

  procedure start_subtest(
    p_title  varchar2,
    p_action varchar2,
    p_before out t_stats,
    p_start  out timestamp
  ) is
  begin
    dbms_application_info.set_action(p_action);
    dbms_output.put_line('');
    dbms_output.put_line(p_title);
    dbms_output.put_line('    SID=' || v_sid || ' SERIAL#=' || v_serial ||
                         ' Action=' || p_action);
    read_dblink_stats(p_before);
    p_start := systimestamp;
  end start_subtest;

  procedure run_single_roundtrip is
    v_before   t_stats;
    v_after    t_stats;
    v_start    timestamp;
    v_end      timestamp;
    v_remote   varchar2(64);
    v_ok       boolean := true;
    v_err      varchar2(4000);
  begin
    start_subtest('[1.1] Single-row remote roundtrip',
                  'single-row-roundtrip',
                  v_before,
                  v_start);

    begin
      execute immediate
        'select to_char(systimestamp, ''YYYY-MM-DD HH24:MI:SS.FF3 TZH:TZM'') from dual@&&DBLINK_NAME'
        into v_remote;
    exception
      when others then
        v_ok := false;
        v_err := sqlerrm;
    end;

    v_end := systimestamp;
    read_dblink_stats(v_after);

    if v_ok then
      dbms_output.put_line('    Remote timestamp: ' || v_remote);
    else
      dbms_output.put_line('    Result: ERROR ' || substr(v_err, 1, 180));
    end if;

    print_elapsed('single_row_elapsed_ms', v_start, v_end);
    print_stats_delta('single_row', v_before, v_after);
  end run_single_roundtrip;

  procedure run_multi_row_fetch is
    v_before  t_stats;
    v_after   t_stats;
    v_start   timestamp;
    v_end     timestamp;
    v_cur     sys_refcursor;
    v_payload varchar2(128);
    v_rows    number := 0;
    v_bytes   number := 0;
    v_open    boolean := false;
    v_ok      boolean := true;
    v_err     varchar2(4000);
  begin
    start_subtest('[1.2] Multi-row remote fetch',
                  'multi-row-fetch',
                  v_before,
                  v_start);

    begin
      open v_cur for
        'select /* HAB_DBLINK_MULTI_FETCH */ rpad(''x'', 128, ''x'') payload ' ||
        'from dual@&&DBLINK_NAME connect by level <= ' || c_fetch_rows;
      v_open := true;

      loop
        fetch v_cur into v_payload;
        exit when v_cur%notfound;
        v_rows := v_rows + 1;
        v_bytes := v_bytes + length(v_payload);
      end loop;

      close v_cur;
      v_open := false;
    exception
      when others then
        v_ok := false;
        v_err := sqlerrm;
        if v_open then
          close v_cur;
        end if;
    end;

    v_end := systimestamp;
    read_dblink_stats(v_after);

    if v_ok then
      dbms_output.put_line('    Rows fetched: ' || v_rows ||
                           ' Payload bytes observed: ' || v_bytes);
    else
      dbms_output.put_line('    Result: ERROR ' || substr(v_err, 1, 180));
    end if;

    print_elapsed('multi_row_fetch_elapsed_ms', v_start, v_end);
    print_stats_delta('multi_row_fetch', v_before, v_after);
  end run_multi_row_fetch;

  procedure run_sustained_calls is
    v_before t_stats;
    v_after  t_stats;
    v_start  timestamp;
    v_end    timestamp;
    v_dummy  number;
    v_ok     boolean := true;
    v_err    varchar2(4000);
  begin
    start_subtest('[1.3] Sustained repeated remote calls',
                  'sustained-remote-calls',
                  v_before,
                  v_start);

    begin
      for i in 1..c_call_count loop
        execute immediate
          'select /* HAB_DBLINK_SUSTAINED_CALL */ 1 from dual@&&DBLINK_NAME'
          into v_dummy;
      end loop;
    exception
      when others then
        v_ok := false;
        v_err := sqlerrm;
    end;

    v_end := systimestamp;
    read_dblink_stats(v_after);

    if v_ok then
      dbms_output.put_line('    Remote calls completed: ' || c_call_count);
    else
      dbms_output.put_line('    Result: ERROR ' || substr(v_err, 1, 180));
    end if;

    print_elapsed('repeated_remote_calls_elapsed_ms', v_start, v_end);
    print_stats_delta('repeated_remote_calls', v_before, v_after);
  end run_sustained_calls;
begin
  v_sid := :diag_sid;
  v_serial := :diag_serial;

  dbms_application_info.set_module(c_module, 'benchmark-start');
  dbms_output.put_line('All benchmark waits/statistics are scoped to SID=' ||
                       v_sid || ' SERIAL#=' || v_serial || '.');
  dbms_output.put_line('First remote call may include DBLink open/authentication cost.');

  run_single_roundtrip;
  run_multi_row_fetch;
  run_sustained_calls;

  emit_metric('total_bytes_sent_delta', v_total_sent_delta);
  emit_metric('total_bytes_received_delta', v_total_recv_delta);
  emit_metric('total_roundtrips_delta', v_total_rtrip_delta);

  dbms_application_info.set_action('post-run-review');
end;
/

prompt
prompt [2] Estado de espera actual de esta sesion
column event format a55
column state format a20
select sid,
       serial#,
       module,
       action,
       event,
       seconds_in_wait,
       state
from   v$session
where  sid = :diag_sid
  and  serial# = :diag_serial;

prompt
prompt [3] Wait events DBLink / SQL*Net acumulados para esta sesion
column event format a55
select se.event,
       se.total_waits,
       se.total_timeouts,
       se.time_waited,
       se.average_wait,
       se.max_wait
from   v$session_event se,
       v$session s
where  se.sid = :diag_sid
  and  s.sid = se.sid
  and  s.serial# = :diag_serial
  and  (
         lower(se.event) like '%dblink%'
      or lower(se.event) like '%sql*net%'
      or lower(se.event) like '%sql net%'
       )
order  by se.time_waited desc, se.total_waits desc;

prompt
prompt [4] Valores finales v$sesstat DBLink para esta sesion
column name format a45
column value format 999999999999999999
select sn.name,
       ss.value
from   v$sesstat ss,
       v$statname sn,
       v$session s
where  ss.sid = :diag_sid
  and  s.sid = ss.sid
  and  s.serial# = :diag_serial
  and  sn.statistic# = ss.statistic#
  and  sn.name in (
         'bytes sent via SQL*Net to dblink',
         'bytes received via SQL*Net from dblink',
         'SQL*Net roundtrips to/from dblink'
       )
order  by decode(sn.name,
                 'bytes sent via SQL*Net to dblink', 1,
                 'bytes received via SQL*Net from dblink', 2,
                 'SQL*Net roundtrips to/from dblink', 3,
                 4);

prompt
prompt [5] Long operations de esta sesion
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
where  sid = :diag_sid
  and  serial# = :diag_serial
  and  totalwork > 0
  and  sofar < totalwork
order  by elapsed_seconds desc;

-- ==============================================================
--  SOLO 19c: Real-Time SQL Monitoring por DBLink
--  Requiere Oracle Tuning Pack. Se deja como seccion opcional y
--  acotada al SID/SERIAL# de esta sesion.
-- ==============================================================
prompt
prompt [6] Real-Time SQL Monitoring opcional para esta sesion (19c)
declare
  v_ver      varchar2(10) := UPPER('&&DB_VERSION');
  v_cur      sys_refcursor;
  v_sql_id   varchar2(15);
  v_status   varchar2(30);
  v_elapsed  number;
  v_cpu      number;
  v_gets     number;
  v_reads    number;
  v_sql_text varchar2(100);
  v_rows     number := 0;
  v_open     boolean := false;
begin
  if v_ver = '19C' then
    dbms_application_info.set_action('optional-sql-monitor');
    dbms_output.put_line('NOTA: requiere licencia Oracle Tuning Pack.');

    begin
      open v_cur for
        'select sql_id, status, elapsed_time / 1e6, cpu_time / 1e6, ' ||
        '       buffer_gets, disk_reads, substr(sql_text, 1, 100) ' ||
        'from (select sql_id, status, elapsed_time, cpu_time, buffer_gets, ' ||
        '             disk_reads, sql_text ' ||
        '      from   v$sql_monitor ' ||
        '      where  sid = :sid ' ||
        '        and  session_serial# = :serial ' ||
        '        and  last_refresh_time > sysdate - 1/24 ' ||
        '      order  by elapsed_time desc) ' ||
        'where rownum <= 10'
        using :diag_sid, :diag_serial;
      v_open := true;

      loop
        fetch v_cur
        into  v_sql_id, v_status, v_elapsed, v_cpu, v_gets, v_reads, v_sql_text;
        exit when v_cur%notfound;

        v_rows := v_rows + 1;
        dbms_output.put_line('  SQL_ID=' || v_sql_id ||
                             ' status=' || v_status ||
                             ' elapsed=' ||
                             to_char(v_elapsed, 'FM9999990.000') || 's' ||
                             ' cpu=' ||
                             to_char(v_cpu, 'FM9999990.000') || 's' ||
                             ' buf_gets=' || v_gets ||
                             ' disk_rd=' || v_reads);
        dbms_output.put_line('    ' || v_sql_text);
      end loop;

      close v_cur;
      v_open := false;

      if v_rows = 0 then
        dbms_output.put_line('No SQL Monitor rows found for this SID/SERIAL#.');
      end if;
    exception
      when others then
        if v_open then
          close v_cur;
        end if;
        dbms_output.put_line('SQL Monitor optional section unavailable: ' ||
                             substr(sqlerrm, 1, 180));
    end;
  else
    dbms_output.put_line('Omitido: requiere DB_VERSION=19c y Tuning Pack.');
  end if;
end;
/

begin
  dbms_application_info.set_module(null, null);
end;
/

prompt ==================================================
prompt FIN DBLINK PATH-AWARE HA DIAGNOSTIC
prompt ==================================================
