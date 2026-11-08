-- 66: домашній бот (08.11.2026): облік і вартість бойлерів (день/ніч), попередження про високу напругу,
-- напруга на сторінці, без хибного «Bluetti мовчить 3 год», коли станцію вимкнули.
-- Тариф з 01.11.2026: 4,32 грн/кВт·год день (07–23), 2,16 ніч (23–07); змінювати через outage_st_set.

select public.outage_st_set('tuya_dev2', 'bfc5c1707e31e4b5d3fi6q');   -- «Бойлер кухня»
select public.outage_st_set('tariff_day', '4.32');
select public.outage_st_set('tariff_night', '2.16');
select public.outage_st_set('volt_warn', '2460');                      -- 246,0 В (у 0,1 В)

-- Енергія бойлерів за проміжок: add_ele (0,001 кВт·год) обох розеток, зона за годиною звіту
create or replace function public.outage_boil_energy(t0 timestamptz, t1 timestamptz) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $f$
declare tz text := public.tg_tzn(); kd numeric; kn numeric;
  td numeric := coalesce(nullif(public.outage_st_get('tariff_day'), '')::numeric, 4.32);
  tn numeric := coalesce(nullif(public.outage_st_get('tariff_night'), '')::numeric, 2.16);
begin
  select coalesce(sum(val) filter (where extract(hour from at at time zone tz) between 7 and 22), 0) / 1000.0,
         coalesce(sum(val) filter (where not (extract(hour from at at time zone tz) between 7 and 22)), 0) / 1000.0
    into kd, kn from public.outage_tuya_volt where code = 'add_ele' and at >= t0 and at < t1;
  return jsonb_build_object('kwh', kd + kn, 'day', kd, 'night', kn, 'cost', round(kd * td + kn * tn, 2));
end $f$;

create or replace function public.outage_boil_line(t0 timestamptz, t1 timestamptz) returns text
language plpgsql stable security definer set search_path to 'public' as $f$
declare e jsonb := public.outage_boil_energy(t0, t1);
begin
  if (e ->> 'kwh')::numeric < 0.05 then return ''; end if;
  return '🚿 Бойлери: ' || replace(round((e ->> 'kwh')::numeric, 1)::text, '.', ',') || ' кВт·год ≈ '
    || replace(round((e ->> 'cost')::numeric, 0)::text, '.', ',') || ' грн (день ' || replace(round((e ->> 'day')::numeric, 1)::text, '.', ',')
    || ' · ніч ' || replace(round((e ->> 'night')::numeric, 1)::text, '.', ',') || ' кВт·год)';
end $f$;

-- Збір: запит напруги по черзі для двох розеток, коди add_ele, cur_voltage, fault
do $do$
declare d text;
  h1 text := E'        elsif kind = ''volt'' then\n          insert into public.outage_tuya_volt (dev, at, code, val)\n            select dv,';
  h2 text := E'             where x->>''code'' in (''cur_voltage'', ''fault'')';
  r1 text := E'      select max(v.at) into last_at from public.outage_tuya_volt v where v.dev = dv;';
  r2 text := E'''/logs?codes=cur_voltage,fault&end_time=''';
  r3 text := E'      kind := ''volt'';';
  r0 text := E'    elsif nullif(public.outage_st_get(''tuya_vfire''), '''') is null';
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'outage_tuya_tick';
  if position(h1 in d) = 0 or position(h2 in d) = 0 or position(r1 in d) = 0 or position(r2 in d) = 0 or position(r3 in d) = 0 or position(r0 in d) = 0 then
    raise exception 'outage_tuya_tick: фрагмент не знайдено';
  end if;
  d := replace(d, 'last_at timestamptz;', 'last_at timestamptz; vd text;');
  d := replace(d, h1, replace(h1, 'select dv,', 'select coalesce(nullif(split_part(req, ''|'', 3), ''''), dv),'));
  d := replace(d, h2, replace(h2, '(''cur_voltage'', ''fault'')', '(''add_ele'', ''cur_voltage'', ''fault'')'));
  d := replace(d, r1, E'      vd := case when public.outage_st_get(''tuya_vlast'') = dv and nullif(public.outage_st_get(''tuya_dev2''), '''') is not null then public.outage_st_get(''tuya_dev2'') else dv end;\n      perform public.outage_st_set(''tuya_vlast'', vd);\n      select max(v.at) into last_at from public.outage_tuya_volt v where v.dev = vd;');
  d := replace(d, r2, '''/logs?codes=add_ele,cur_voltage,fault&end_time=''');
  d := replace(d, '''/v1.0/devices/'' || dv || ''/logs?codes=add_ele', '''/v1.0/devices/'' || vd || ''/logs?codes=add_ele');
  d := replace(d, r3, E'      kind := ''volt|'' || vd;');
  execute d;
end $do$;

-- outage_pwr_tick: блок 15 «висока напруга», чистка (add_ele зберігається 400 днів)
do $do$
declare d text; anchor text := '  -- 10. сторож токена Bluetti (раз на добу, лише Антону)';
  c1 text := 'delete from public.outage_tuya_volt where at < p_now - interval ''30 days'';';
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'outage_pwr_tick';
  if position(anchor in d) = 0 or position(c1 in d) = 0 then raise exception 'outage_pwr_tick: фрагмент не знайдено'; end if;
  d := replace(d, c1, 'delete from public.outage_tuya_volt where (code <> ''add_ele'' and at < p_now - interval ''30 days'') or at < p_now - interval ''400 days'';');
  d := replace(d, anchor, $b$  -- 15. висока напруга до спрацювання ЗУБР (SQL 66)
  declare v_hv numeric;
  begin
    select max(v.val) into v_hv from public.outage_tuya_volt v where v.code = 'cur_voltage' and v.at > p_now - interval '10 minutes';
    if src = 'city' and v_hv >= coalesce(nullif(public.outage_st_get('volt_warn'), '')::numeric, 2460)
       and public.outage_ev_new('bhv:' || to_char(p_now at time zone tz, 'YYYY-MM-DD HH24'), p_dry) then
      out := out || jsonb_build_object('c', chats, 'q', quiet,
        't', '⚠️ Висока напруга в мережі: ' || replace(round(v_hv / 10, 1)::text, '.', ',') || E' В.\nРеле ЗУБР вимикає квартиру приблизно від 250 В, тож можливі короткі відключення. Чутливу техніку краще вимкнути.');
    end if;
  end;

$b$ || anchor);
  execute d;
end $do$;

-- Ранковий підсумок і місячний звіт: рядок про бойлери
do $do$
declare d text; a text := E'  return o;\nend';
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'outage_yday_text';
  if position(a in d) = 0 then raise exception 'outage_yday_text: фрагмент не знайдено'; end if;
  execute replace(d, a, E'  if public.outage_boil_line(t0, t1) <> '''' then\n    o := o || case when o = '''' then E''\\n\\n'' else E''\\n'' end || public.outage_boil_line(t0, t1);\n  end if;\n' || a);
end $do$;

do $do$
declare d text; a text := '|| E''\n🔌 Бойлери ввімкнено автоматично: '' || n || '' раз(и)'';';
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'bluetti_month';
  if position(a in d) = 0 then raise exception 'bluetti_month: фрагмент не знайдено'; end if;
  execute replace(d, a, '|| E''\n🔌 Бойлери ввімкнено автоматично: '' || n || '' раз(и)'' || case when public.outage_boil_line(d0, d1) <> '''' then E''\n'' || public.outage_boil_line(d0, d1) else '''' end;');
end $do$;

-- Сторож «Bluetti мовчить 3 год»: мовчить, якщо останній відомий стан «AC вимкнено» (станцію, ймовірно, вимкнули)
do $do$
declare d text; a text := E'  if hr < 8 or hr >= 22 then return ''quiet''; end if;';
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'bluetti_stale_tick';
  if position(a in d) = 0 then raise exception 'bluetti_stale_tick: фрагмент не знайдено'; end if;
  execute replace(d, a, a || E'\n  if (select l.ac from public.bluetti_log l where l.soc is not null order by l.at desc limit 1) is not true then return ''off''; end if;');
end $do$;

-- Сторінка: поле volt — максимум напруги «Бойлер основний» по 10 хв за кожен день тижня [хв, 0,1 В]
do $do$
declare d text; a text := '''days'', dj);';
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'bluetti_app';
  if position(a in d) = 0 then raise exception 'bluetti_app: фрагмент не знайдено'; end if;
  execute replace(d, a, '''days'', dj, ''volt'', (select jsonb_object_agg(dd2::text, coalesce((select jsonb_agg(jsonb_build_array(q.m, q.v) order by q.m) from (
      select (floor((extract(hour from v.at at time zone tz) * 60 + extract(minute from v.at at time zone tz)) / 10) * 10)::int m, max(v.val)::int v
        from public.outage_tuya_volt v where v.code = ''cur_voltage'' and v.dev = public.outage_st_get(''tuya_dev'')
         and v.at >= dd2::timestamp at time zone tz and v.at < (dd2 + 1)::timestamp at time zone tz group by 1) q), ''[]''::jsonb))
      from generate_series(p_wstart, p_wstart + 6, interval ''1 day'') g(x), lateral (select g.x::date dd2) z));');
end $do$;
