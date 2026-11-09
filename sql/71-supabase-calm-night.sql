-- 71: менше шуму при стрибках напруги (09.11.2026), разом з Edge outage-boilers v5.
-- 12: одне повідомлення «⚡ Стрибки напруги…» на епізод (≥3 знеструмлення розеток за 15 хв або напруга ≥ volt_warn на місті),
--     повтор лише після 2 год без стрибків (ключ стану volt_bad_at); блок 15 «висока напруга» вимкнено (увійшов у 12).
-- 16: бойлери після захисту розетки лише коли 15 хв напруга < 245 В, не частіше раз на 30 хв, поки після останнього fault не було
--     повного успіху (boil_last_ok від Edge v5).
-- 17: якщо Edge записав невдачу (boil_fail) і за годину успіху немає, одне «⚠️ Бойлери не вдалося ввімкнути…» з кнопкою.
-- 6: «у сусідів світло є, а у вас напруги немає» лише після 10 хв без живлення (було 5).
-- 8: «Bluetti заряджено до 100%» не частіше раз на 6 год.
do $do$
declare d text; i12 int; i11 int; i15 int; i16 int; i10 int;
  b12 text := $b$  -- 12. стрибки напруги: одне повідомлення на епізод, повтор після 2 год тиші (SQL 71)
  declare v_hv numeric; v_prev timestamptz := nullif(public.outage_st_get('volt_bad_at'), '')::timestamptz;
  begin
    select count(*) into nv from public.outage_tuya_log t where t.kind = 'off' and t.at > p_now - interval '15 minutes' and t.at <= p_now;
    select max(v.val) into v_hv from public.outage_tuya_volt v where v.code = 'cur_voltage' and v.at > p_now - interval '15 minutes';
    if nv >= 3 or (src = 'city' and v_hv >= coalesce(nullif(public.outage_st_get('volt_warn'), '')::numeric, 2460)) then
      if v_prev is null or v_prev < p_now - interval '2 hours' then
        out := out || jsonb_build_object('c', chats, 'q', quiet,
          't', '⚡ Стрибки напруги' || coalesce(' до ' || replace(round(v_hv / 10, 1)::text, '.', ',') || ' В', '')
            || case when nv >= 3 then ': за 15 хв квартира знеструмлювалась ' || nv || ' ' || case when nv % 10 between 2 and 4 and nv % 100 not between 12 and 14 then 'рази' else 'разів' end else '' end
            || E'.\nРозетки бойлерів вимикаються самі приблизно від 250 В, ЗУБР вимикає квартиру від 255 В. Потужну й чутливу техніку краще не вмикати, доки не стабілізується.'
            || case when autoon then ' Бойлери ввімкну сам, коли напруга 15 хв буде нормальною.' else '' end);
      end if;
      if not p_dry then perform public.outage_st_set('volt_bad_at', p_now::text); end if;
    end if;
  end;

$b$;
  b17 text := $b$  -- 17. автовмикання не вдалося за годину (SQL 71, стан boil_fail від Edge v5)
  declare v_bf timestamptz := nullif(public.outage_st_get('boil_fail'), '')::timestamptz;
  begin
    if v_bf is not null and v_bf < p_now - interval '60 minutes' and public.outage_boil_on() then
      if public.outage_ev_new('bfail:' || v_bf::text, p_dry) then
        out := out || jsonb_build_object('c', chats, 'q', quiet, 'kb', kbon,
          't', E'⚠️ Бойлери не вдалося ввімкнути автоматично вже годину: розетки не відповідають або вимикаються від напруги.\nПеревірте Smart Life або натисніть кнопку.');
      end if;
      if not p_dry then perform public.outage_st_set('boil_fail', ''); end if;
    end if;
  end;

$b$;
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'outage_pwr_tick';
  i12 := position('  -- 12. ' in d); i11 := position('  -- 11. ' in d);
  if i12 = 0 or i11 = 0 or i11 < i12 then raise exception 'блок 12/11 не знайдено'; end if;
  d := substr(d, 1, i12 - 1) || b12 || substr(d, i11);
  i15 := position('  -- 15. ' in d); i16 := position('  -- 16. ' in d);
  if i15 = 0 or i16 = 0 or i16 < i15 then raise exception 'блок 15/16 не знайдено'; end if;
  d := substr(d, 1, i15 - 1) || E'  -- 15. (SQL 71: увійшов у блок 12)\n\n' || substr(d, i16);
  -- 16: стабільність 15 хв, раз на 30 хв, лише поки після fault не було успіху
  if position('and p_now >= v_fa + interval ''5 minutes''' in d) = 0
     or position('and v.val >= 2450 and v.at > greatest(v_fa, p_now - interval ''5 minutes''))' in d) = 0
     or position('and public.outage_ev_new(''bfault:'' || v_fa::text, p_dry) then' in d) = 0 then raise exception 'блок 16: фрагмент не знайдено'; end if;
  d := replace(d, 'and p_now >= v_fa + interval ''5 minutes''', 'and p_now >= v_fa + interval ''15 minutes''');
  d := replace(d, 'and v.val >= 2450 and v.at > greatest(v_fa, p_now - interval ''5 minutes''))', 'and v.val >= 2450 and v.at > p_now - interval ''15 minutes'')');
  d := replace(d, 'and public.outage_ev_new(''bfault:'' || v_fa::text, p_dry) then',
    'and coalesce(nullif(public.outage_st_get(''boil_last_ok''), '''')::timestamptz, ''-infinity'') < v_fa'
    || E'\n       and not exists (select 1 from public.outage_events e where e.key like ''bfault:%'' and e.at > p_now - interval ''30 minutes'')'
    || E'\n       and public.outage_ev_new(''bfault:'' || p_now::text, p_dry) then');
  -- 17 перед блоком 10
  i10 := position('  -- 10. сторож токена Bluetti' in d);
  if i10 = 0 then raise exception 'блок 10 не знайдено'; end if;
  d := substr(d, 1, i10 - 1) || b17 || substr(d, i10);
  -- 6 і 8
  if position('and p_now >= offat + interval ''5 minutes'' and bat > offat + interval ''3 minutes''' in d) = 0
     or position('and public.outage_ev_new(''bfull:'' || cyc, p_dry) then' in d) = 0 then raise exception 'блок 6/8: фрагмент не знайдено'; end if;
  d := replace(d, 'and p_now >= offat + interval ''5 minutes'' and bat > offat + interval ''3 minutes''', 'and p_now >= offat + interval ''10 minutes'' and bat > offat + interval ''3 minutes''');
  d := replace(d, 'and public.outage_ev_new(''bfull:'' || cyc, p_dry) then',
    'and not exists (select 1 from public.outage_events e where e.key like ''bfull:%'' and e.at > p_now - interval ''6 hours'') and public.outage_ev_new(''bfull:'' || cyc, p_dry) then');
  execute d;
end $do$;
