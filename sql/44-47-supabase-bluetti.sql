-- SQL 44–47: Bluetti з хмари (копія міграцій Supabase, вивантажено 07.11.2026).
-- Міграції bluetti_44, bluetti_cron_45, bluetti_line_46, bluetti_cmd_47. bluetti_line/bluetti_text пізніше замінено в SQL 48a і 52; розклад bluetti-poll змінено на */2 у SQL 49.
-- Секретів тут немає: client_secret і app-key лише в Edge Secrets (BLUETTI_CLIENT_SECRET, BLUETTI_APP_KEY). Опис: claude/outage/tech-overview-bluetti.md.

-- ===== bluetti_44 =====
create table if not exists public.bluetti_auth (
  id int primary key default 1 check (id = 1),
  access_token text,
  refresh_token text,
  expires_at timestamptz,
  state text,
  state_exp timestamptz,
  updated timestamptz default now()
);
create table if not exists public.bluetti_log (
  at timestamptz not null default now(),
  sn text,
  soc numeric,
  grid_w numeric,
  ac_w numeric,
  online boolean,
  raw jsonb
);
create index if not exists bluetti_log_at_idx on public.bluetti_log (at desc);
alter table public.bluetti_auth enable row level security;
alter table public.bluetti_log enable row level security;
revoke all on public.bluetti_auth, public.bluetti_log from public, anon, authenticated;

create or replace function public.bluetti_state_new() returns text
language plpgsql security definer set search_path = public, extensions as $$
declare s text := encode(gen_random_bytes(12), 'hex');
begin
  insert into public.bluetti_auth (id, state, state_exp) values (1, s, now() + interval '15 minutes')
  on conflict (id) do update set state = s, state_exp = now() + interval '15 minutes';
  return s;
end $$;
revoke all on function public.bluetti_state_new() from public, anon, authenticated;

-- ===== bluetti_cron_45 =====
select cron.schedule('bluetti-poll', '*/5 * * * *',
  $$select net.http_post(url := 'https://hikzqzdulvekuplolymw.supabase.co/functions/v1/bluetti-poll', body := '{}'::jsonb, timeout_milliseconds := 20000)$$);

-- ===== bluetti_line_46 =====
create or replace function public.bluetti_line() returns text
language plpgsql stable security definer set search_path = public, extensions as $fn$
declare r record; age int; tz text := public.tg_tzn();
begin
  select at, online, soc, grid_w, ac_w into r from public.bluetti_log where soc is not null order by at desc limit 1;
  if not found then return ''; end if;
  age := greatest(0, extract(epoch from (now() - r.at))::int / 60);
  if age > 10 then
    return E'\n\n🔋 Bluetti: дані недоступні (останні ' || age || ' хв тому)';
  elsif r.online is distinct from true then
    return E'\n\n🔋 Bluetti: не в мережі (остання відповідь ' || to_char(r.at at time zone tz, 'HH24:MI') || ')';
  end if;
  return E'\n\n🔋 Bluetti: ' || r.soc::int || '% · від мережі ' || r.grid_w::int || ' Вт · навантаження ' || r.ac_w::int || ' Вт'
    || case when r.grid_w > 0 then ' (заряджається від мережі)' else '' end
    || ' · ' || to_char(r.at at time zone tz, 'HH24:MI');
end $fn$;
revoke all on function public.bluetti_line() from public, anon, authenticated;

do $do$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'outage_now_text' and pg_get_function_arguments(p.oid) = 'p_chat text';
  if d is null then raise exception 'outage_now_text not found'; end if;
  if position('bluetti_line' in d) = 0 then
    if position('return out || sock || fact || warn;' in d) = 0 then raise exception 'return fragment not found'; end if;
    d := replace(d, 'return out || sock || fact || warn;', 'return out || sock || fact || warn || public.bluetti_line();');
    execute d;
  end if;
end $do$;

-- ===== bluetti_cmd_47 =====
create or replace function public.bluetti_text() returns text
language plpgsql stable security definer set search_path = public, extensions as $fn$
declare r record; l jsonb; age int; tz text := public.tg_tzn(); o text; wm text;
  v text; sw text[]; fv text;
  function_dummy int;
begin
  select at, online, raw into r from public.bluetti_log where soc is not null order by at desc limit 1;
  if not found then return 'Даних Bluetti ще немає.'; end if;
  l := coalesce(r.raw -> 'product' -> 'stateList', '[]'::jsonb);
  age := greatest(0, extract(epoch from (now() - r.at))::int / 60);
  wm := (select x ->> 'fnValue' from jsonb_array_elements(l) x where x ->> 'fnCode' = 'SetCtrlWorkMode' limit 1);
  wm := case wm when 'workmode_0' then 'PV Priority UPS' when 'workmode_1' then 'Standard UPS' when 'workmode_2' then 'Time Control UPS' when 'workmode_3' then 'Customized UPS' else coalesce(wm, '—') end;
  o := '🔋 Bluetti AC200PL' || E'\n'
    || 'Статус: ' || case when age > 10 then '⚠️ дані недоступні (останні ' || age || ' хв тому)' when r.online then 'онлайн' else '⚠️ не в мережі' end
    || ' · оновлено ' || to_char(r.at at time zone tz, 'DD.MM HH24:MI') || E'\n'
    || 'Заряд: ' || coalesce((select x ->> 'fnValue' from jsonb_array_elements(l) x where x ->> 'fnCode' = 'SOC'), '—') || ' %' || E'\n'
    || 'Вхід: мережа ' || coalesce((select x ->> 'fnValue' from jsonb_array_elements(l) x where x ->> 'fnCode' = 'GridAllTotalPower'), '—') || ' Вт, сонце ' || coalesce((select x ->> 'fnValue' from jsonb_array_elements(l) x where x ->> 'fnCode' = 'PVAllTotalPower'), '—') || ' Вт' || E'\n'
    || 'Вихід: AC ' || coalesce((select x ->> 'fnValue' from jsonb_array_elements(l) x where x ->> 'fnCode' = 'ACLoadAllTotalPower'), '—') || ' Вт, DC ' || coalesce((select x ->> 'fnValue' from jsonb_array_elements(l) x where x ->> 'fnCode' = 'DCLoadAllTotalPower'), '—') || ' Вт' || E'\n'
    || 'Перемикачі: AC ' || case (select x ->> 'fnValue' from jsonb_array_elements(l) x where x ->> 'fnCode' = 'SetCtrlAc') when '1' then 'увімк.' else 'вимк.' end
    || ', DC ' || case (select x ->> 'fnValue' from jsonb_array_elements(l) x where x ->> 'fnCode' = 'SetCtrlDc') when '1' then 'увімк.' else 'вимк.' end
    || ', AC ECO ' || case (select x ->> 'fnValue' from jsonb_array_elements(l) x where x ->> 'fnCode' = 'SetACECO') when '1' then 'увімк.' else 'вимк.' end
    || ', DC ECO ' || case (select x ->> 'fnValue' from jsonb_array_elements(l) x where x ->> 'fnCode' = 'SetDCECO') when '1' then 'увімк.' else 'вимк.' end || E'\n'
    || 'Режим: ' || wm;
  return o;
end $fn$;
revoke all on function public.bluetti_text() from public, anon, authenticated;

do $do$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tg_command' and pg_get_function_arguments(p.oid) = 'p_chat text, p_text text';
  if d is null then raise exception 'tg_command not found'; end if;
  if position('bluetti_text' in d) = 0 then
    if position($q$elsif cmd in ('світло',$q$ in d) = 0 then raise exception 'fragment not found'; end if;
    d := replace(d, $q$elsif cmd in ('світло',$q$,
      $q$elsif cmd in ('bluetti', 'блюетті', 'блуетті', 'bluetty') then
    return jsonb_build_object('ok', true, 'text', public.bluetti_text());
  elsif cmd in ('світло',$q$);
    execute d;
  end if;

  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tg_set_menu';
  if d is null then raise exception 'tg_set_menu not found'; end if;
  if position('bluetti' in d) = 0 then
    if position($q$jsonb_build_object('command', 'boilers',$q$ in d) = 0 then raise exception 'menu fragment not found'; end if;
    d := replace(d, $q$jsonb_build_object('command', 'boilers',$q$,
      $q$jsonb_build_object('command', 'bluetti', 'description', 'Bluetti: заряд, вхід, вихід, режим'),
      jsonb_build_object('command', 'boilers',$q$);
    execute d;
  end if;
end $do$;
