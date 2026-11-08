-- 62: короткі збої лінії без шуму + журнал напруги Tuya + виправлення помилок cron (08.11.2026)
-- 1) outage_ev_new: порожній ключ більше не падає (причина 12 помилок cron: блок «bchg:» без наступного відключення)
-- 2) таблиця outage_tuya_volt (напруга й fault розетки, зберігається 30 днів), збір окремим запитом у outage_tuya_tick
-- 3) outage_blip: збій = напруга ≥250 В або fault біля події, АБО Світлобот не бачив відключення
-- 4) outage_pwr_tick: при збої без повідомлення «Вмикаю бойлери о…»; Edge outage-boilers пише лише якщо щось ввімкнув; у «Нестабільна напруга» є реальна напруга

create or replace function public.outage_ev_new(k text, p_dry boolean default false) returns boolean
language plpgsql security definer set search_path to 'public' as $f$
declare n int;
begin
  if k is null then return false; end if;
  if p_dry then return not exists (select 1 from public.outage_events where key = k); end if;
  insert into public.outage_events (key) values (k) on conflict (key) do nothing;
  get diagnostics n = row_count;
  return n = 1;
end $f$;

create table if not exists public.outage_tuya_volt (
  dev text not null, at timestamptz not null, code text not null, val numeric,
  primary key (dev, at, code)
);
create index if not exists outage_tuya_volt_at on public.outage_tuya_volt (at);
alter table public.outage_tuya_volt enable row level security;

create or replace function public.outage_blip(p_off timestamptz, p_on timestamptz, p_now timestamptz default now()) returns text
language plpgsql stable security definer set search_path to 'public' as $f$
declare mx numeric; fl numeric;
begin
  if p_off is null then return null; end if;
  select max(val) filter (where code = 'cur_voltage'), max(val) filter (where code = 'fault')
    into mx, fl from public.outage_tuya_volt
   where at between p_off - interval '15 minutes' and coalesce(p_on, p_now) + interval '2 minutes';
  if mx >= 2500 then return 'перенапруга ' || replace(round(mx / 10, 1)::text, '.', ',') || ' В'; end if;
  if coalesce(fl, 0) > 0 then return 'збій напруги'; end if;
  if not exists (select 1 from public.outage_log where kind = 'off' and at >= p_off - interval '10 minutes' and at <= p_now) then
    return 'Світлобот не бачив відключення';
  end if;
  return null;
end $f$;

-- outage_tuya_tick: окремий запит напруги/fault
do $do$
declare d text;
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'outage_tuya_tick';
  if position(E'        else\n          insert into public.outage_tuya_log (dev, at, kind)' in d) = 0
     or position(E'      perform public.outage_st_set(''tuya_fire'', p_now::text);\n    end if;' in d) = 0 then
    raise exception 'outage_tuya_tick: фрагмент не знайдено';
  end if;
  d := replace(d, E'        else\n          insert into public.outage_tuya_log (dev, at, kind)',
    E'        elsif kind = ''volt'' then\n          insert into public.outage_tuya_volt (dev, at, code, val)\n            select dv, to_timestamp((x->>''event_time'')::bigint / 1000.0), x->>''code'', nullif(regexp_replace(x->>''value'', ''[^0-9.-]'', '''', ''g''), '''')::numeric\n              from jsonb_array_elements(coalesce(j->''result''->''logs'', ''[]''::jsonb)) x\n             where x->>''code'' in (''cur_voltage'', ''fault'')\n            on conflict do nothing;\n          get diagnostics n = row_count;\n          lg := lg || ''напруга +'' || n || ''; '';\n        else\n          insert into public.outage_tuya_log (dev, at, kind)');
  d := replace(d, E'      perform public.outage_st_set(''tuya_fire'', p_now::text);\n    end if;',
    E'      perform public.outage_st_set(''tuya_fire'', p_now::text);\n    elsif nullif(public.outage_st_get(''tuya_vfire''), '''') is null or nullif(public.outage_st_get(''tuya_vfire''), '''')::timestamptz < p_now - interval ''110 seconds'' then\n      select max(v.at) into last_at from public.outage_tuya_volt v where v.dev = dv;\n      endms := (extract(epoch from p_now) * 1000)::bigint;\n      startms := case when last_at is null then endms - 3 * 86400000 else (extract(epoch from last_at) * 1000)::bigint - 600000 end;\n      rid := public.outage_tuya_get(''/v1.0/devices/'' || dv || ''/logs?codes=cur_voltage,fault&end_time='' || endms || ''&query_type=1&size=100&start_time='' || startms || ''&type=7'', tok);\n      kind := ''volt'';\n      perform public.outage_st_set(''tuya_vfire'', p_now::text);\n    end if;');
  execute d;
end $do$;

-- outage_pwr_tick
do $do$
declare d text;
  a1 text := E'    if not p_dry then\n      perform public.outage_st_set(''boil_cd'', (p_now + interval ''5 minutes'')::text);';
  a2 text := E'    out := out || jsonb_build_object(''c'', chats, ''q'', quiet, ''kb'', kbcd,';
  a3 text := E'(через 5 хв).'');\n    lg := lg || ''бойлери: старт відліку; '';';
  a4 text := 'body := jsonb_build_object(''silent'', quiet),';
  a5 text := 'if public.outage_ev_new(''bhold:'' || cyc, p_dry) then';
  a6 text := '''⚡ Нестабільна напруга: за 15 хв квартира знеструмлювалась '' || nv || '' ''';
  a7 text := E'  -- надсилання\n';
  a8 text := 'blsince timestamptz := nullif(public.outage_st_get(''bl_since''), '''')::timestamptz; ldm numeric; nx int; nv int;';
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'outage_pwr_tick';
  if position(a1 in d) = 0 or position(a2 in d) = 0 or position(a3 in d) = 0 or position(a4 in d) = 0
     or position(a5 in d) = 0 or position(a6 in d) = 0 or position(a7 in d) = 0 or position(a8 in d) = 0 then
    raise exception 'outage_pwr_tick: фрагмент не знайдено';
  end if;
  d := replace(d, a8, replace(a8, 'nv int;', 'nv int; v_blip text;'));
  d := replace(d, a1, E'    v_blip := public.outage_blip(offat, onat, p_now);\n    if not p_dry then\n      perform public.outage_st_set(''boil_cd_note'', coalesce(v_blip, ''''));\n      perform public.outage_st_set(''boil_cd'', (p_now + case when v_blip is null then interval ''5 minutes'' else interval ''1 minute'' end)::text);');
  d := replace(d, a2, E'    if v_blip is null then\n' || a2);
  d := replace(d, a3, E'(через 5 хв).'');\n    end if;\n    lg := lg || ''бойлери: старт відліку'' || coalesce('' (збій: '' || v_blip || '')'', '''') || ''; '';');
  d := replace(d, a4, 'body := jsonb_build_object(''silent'', quiet, ''note'', nullif(public.outage_st_get(''boil_cd_note''), '''')),');
  d := replace(d, a5, 'if nullif(public.outage_st_get(''boil_cd_note''), '''') is null and public.outage_ev_new(''bhold:'' || cyc, p_dry) then');
  d := replace(d, a6, '''⚡ Нестабільна напруга'' || coalesce('' (до '' || (select replace(round(max(v.val) / 10, 1)::text, ''.'', '','') from public.outage_tuya_volt v where v.code = ''cur_voltage'' and v.at > p_now - interval ''20 minutes'') || '' В)'', '''') || '': за 15 хв квартира знеструмлювалась '' || nv || '' ''');
  d := replace(d, a7, E'  if not p_dry then delete from public.outage_tuya_volt where at < p_now - interval ''30 days''; end if;\n\n' || a7);
  execute d;
end $do$;
