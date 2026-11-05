-- Бот відключень: дані для Telegram Mini App «📅 Графік» (сторінка на GitHub Pages, репозиторій abohdanovskyi/outage-app).
-- Supabase -> SQL Editor -> New query -> вставити весь файл -> Run. Можна запускати повторно. Виконувати після 31.
-- Нових cron-завдань немає. Таблиці бюджету не змінює. Кнопка «📅 Графік» за замовчуванням ВИМКНЕНА:
-- вмикається після публікації сторінки командою
--   select public.outage_st_set('app_url', 'https://abohdanovskyi.github.io/outage-app/');
-- вимкнути: select public.outage_st_set('app_url', '');
--
-- Що з'являється:
--  * Таблиця outage_emerg(grp, start_at, end_at): періоди екстрених відключень по групах (наповнює outage_emerg_sync() з outage_extra_tick).
--  * outage_urldecode(), outage_app_user(init_data): перевірка підпису Telegram initData (HMAC із токена бота з tg_settings, до 24 год) і chat id.
--  * outage_app_data(init_data): JSON для сторінки; лише підписки, що доставляються цьому чату (адреси родичів нікому іншому не видно).
--    Викликається лише з Edge Function outage-app (service_role); anon/authenticated доступу не мають.
--  * outage_app_kb(): inline-кнопка Mini App (порожня, поки app_url не задано).
--  * outage_flush(): додає цю кнопку до всіх повідомлень бота відключень; /світло повертає її теж (tg_command, лише рядок для /світло).
--  * outage_extra_tick(): додано виклик outage_emerg_sync() (решта без змін).
-- Увага: у DO-блоках нижче функції tg_command і outage_extra_tick міняються через replace() над їхнім поточним текстом
-- (щоб не переписувати їх повністю); блок зупиниться з помилкою, якщо очікуваного рядка не знайдено.

create table if not exists public.outage_emerg (
  grp text not null,
  start_at timestamptz not null,
  end_at timestamptz
);
create index if not exists outage_emerg_grp_idx on public.outage_emerg (grp, start_at);
alter table public.outage_emerg enable row level security;
revoke all on public.outage_emerg from public, anon, authenticated;

create or replace function public.outage_emerg_sync() returns text
language plpgsql security definer set search_path = public as $fn$
declare
  g record; sn public.outage_snap%rowtype; emg boolean; opened boolean; n int := 0;
  today date := (now() at time zone public.tg_tzn())::date;
begin
  for g in select distinct grp from public.outage_subs where active loop
    select * into sn from public.outage_snap where grp = g.grp and day = today;
    emg := found and sn.status like 'Emergency%';
    opened := exists (select 1 from public.outage_emerg e where e.grp = g.grp and e.end_at is null);
    if emg and not opened then
      insert into public.outage_emerg (grp, start_at) values (g.grp, least(coalesce(sn.changed, now()), now()));
      n := n + 1;
    elsif not emg and opened then
      update public.outage_emerg set end_at = now() where grp = g.grp and end_at is null;
      n := n + 1;
    end if;
  end loop;
  return n::text;
end $fn$;
revoke all on function public.outage_emerg_sync() from public, anon, authenticated;

create or replace function public.outage_urldecode(t text) returns text
language sql immutable set search_path = public as $fn$
  select convert_from(coalesce((
    select string_agg(case when m[1] is not null then decode(substr(m[1], 2, 2), 'hex') else convert_to(m[2], 'UTF8') end, ''::bytea order by o)
      from regexp_matches(replace(coalesce(t, ''), '+', ' '), '(%[0-9A-Fa-f]{2})|([^%]+)', 'g') with ordinality as x(m, o)
  ), ''::bytea), 'UTF8')
$fn$;
revoke all on function public.outage_urldecode(text) from public, anon, authenticated;

create or replace function public.outage_app_user(p_init text) returns text
language plpgsql security definer set search_path = public, extensions as $fn$
declare
  tok text; kv text; k text; v text; h text; uj jsonb; ad bigint; chk text[] := '{}'; dcs text; sk bytea; calc text;
begin
  select token into tok from public.tg_settings where id = 1;
  if tok is null or tok like 'ВАШ_%' or p_init is null or length(p_init) > 4000 then return null; end if;
  foreach kv in array string_to_array(p_init, '&') loop
    k := split_part(kv, '=', 1);
    v := public.outage_urldecode(substr(kv, length(k) + 2));
    if k = 'hash' then h := lower(v);
    else
      chk := chk || (k || '=' || v);
      if k = 'user' then uj := v::jsonb; end if;
      if k = 'auth_date' then ad := v::bigint; end if;
    end if;
  end loop;
  if h is null or uj is null or ad is null then return null; end if;
  if extract(epoch from now()) - ad > 86400 then return null; end if;
  select string_agg(x, E'\n' order by x collate "C") into dcs from unnest(chk) x;
  sk := extensions.hmac(convert_to(tok, 'UTF8'), convert_to('WebAppData', 'UTF8'), 'sha256');
  calc := encode(extensions.hmac(convert_to(dcs, 'UTF8'), sk, 'sha256'), 'hex');
  if calc is distinct from h then return null; end if;
  return uj->>'id';
exception when others then
  return null;
end $fn$;
revoke all on function public.outage_app_user(text) from public, anon, authenticated;

create or replace function public.outage_app_min(p_ts timestamptz, p_d0 timestamptz) returns int
language sql immutable set search_path = public as $fn$
  select least(1440, greatest(0, floor(extract(epoch from (p_ts - p_d0)) / 60)::int))
$fn$;
revoke all on function public.outage_app_min(timestamptz, timestamptz) from public, anon, authenticated;

create or replace function public.outage_app_data(p_init text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  tz text := public.tg_tzn();
  chat text := public.outage_app_user(p_init);
  today date := (now() at time zone public.tg_tzn())::date;
  wstart date;
  s public.outage_subs%rowtype; sn public.outage_snap%rowtype; pl public.outage_plan%rowtype;
  subs jsonb := '[]'::jsonb; days jsonb; d date; d0 timestamptz; d1 timestamptz;
  snf boolean; plf boolean; emerg boolean; known boolean; st text; rng jsonb; pos jsonb; emg jsonb; sock jsonb; sbj jsonb;
begin
  if chat is null then return jsonb_build_object('ok', false); end if;
  wstart := today - (extract(isodow from today)::int - 1);
  for s in select * from public.outage_subs x where x.active and chat = any (public.outage_chats(x)) order by x.key loop
    days := '[]'::jsonb;
    for i in 0 .. 6 loop
      d := wstart + i;
      d0 := d::timestamp at time zone tz;
      d1 := (d + 1)::timestamp at time zone tz;
      select * into sn from public.outage_snap where grp = s.grp and day = d; snf := found;
      select * into pl from public.outage_plan where grp = s.grp and day = d; plf := found;
      emerg := snf and sn.status like 'Emergency%' and d >= today;
      st := case when snf then sn.status when plf then 'ScheduleApplies' else 'none' end;
      rng := '[]'::jsonb; pos := '[]'::jsonb; known := false;
      if snf and not emerg and (sn.status = 'ScheduleApplies' or jsonb_array_length(sn.rng) > 0) then
        rng := sn.rng; pos := coalesce(sn.pos, '[]'::jsonb); known := true;
      elsif plf then
        rng := pl.rng; known := true;
      end if;
      emg := coalesce((select jsonb_agg(jsonb_build_array(q.a, q.b) order by q.a)
                         from (select public.outage_app_min(greatest(e.start_at, d0), d0) a,
                                      public.outage_app_min(least(coalesce(e.end_at, now()), d1), d0) b
                                 from public.outage_emerg e
                                where e.grp = s.grp and e.start_at < d1 and coalesce(e.end_at, now()) > d0) q
                        where q.b > q.a), '[]'::jsonb);
      sock := '[]'::jsonb; sbj := '[]'::jsonb;
      if s.svitlo and d <= today then
        sock := coalesce((select jsonb_agg(jsonb_build_array(q.a, q.b) order by q.a)
                            from (select public.outage_app_min(greatest(v.st, d0), d0) a,
                                         public.outage_app_min(least(coalesce(v.en, now()), d1), d0) b
                                    from public.outage_sock_intervals(d0, d1) v) q
                           where q.b > q.a), '[]'::jsonb);
        sbj := coalesce((select jsonb_agg(jsonb_build_array(q.a, q.b) order by q.a)
                           from (with ev as (select at, kind, lead(kind) over (order by at) nk, lead(at) over (order by at) nat from public.outage_log),
                                      iv as (select at as st, coalesce(nat, now()) as en from ev where kind = 'off' and (nk = 'on' or nk is null))
                                 select public.outage_app_min(greatest(iv.st, d0), d0) a, public.outage_app_min(least(iv.en, d1), d0) b
                                   from iv where iv.st < d1 and iv.en > d0) q
                          where q.b > q.a), '[]'::jsonb);
      end if;
      days := days || jsonb_build_array(jsonb_build_object(
        'date', d, 'status', st, 'known', known, 'emergency', emerg,
        'plan', rng, 'pos', pos, 'emerg', emg, 'sock', sock, 'sb', sbj));
    end loop;
    subs := subs || jsonb_build_array(jsonb_build_object(
      'key', s.key, 'title', s.title, 'grp', s.grp, 'fact', coalesce(s.svitlo, false), 'days', days));
  end loop;
  return jsonb_build_object('ok', true, 'now', (extract(epoch from now()) * 1000)::bigint, 'today', today,
                            'week_start', wstart, 'subs', subs);
end $fn$;
revoke all on function public.outage_app_data(text) from public, anon, authenticated;
grant execute on function public.outage_app_data(text) to service_role;

create or replace function public.outage_app_kb() returns jsonb
language sql stable security definer set search_path = public as $fn$
  select case when coalesce(public.outage_st_get('app_url'), '') = '' then null
    else jsonb_build_array(jsonb_build_array(jsonb_build_object('text', '📅 Графік', 'web_app', jsonb_build_object('url', public.outage_st_get('app_url'))))) end
$fn$;
revoke all on function public.outage_app_kb() from public, anon, authenticated;

create or replace function public.outage_flush(msgs jsonb, prefix text default '') returns integer
language plpgsql security definer set search_path to 'public' as $fn$
declare r record; n int := 0; kb jsonb := public.outage_app_kb();
begin
  for r in select key as chat, value #>> '{}' as txt from jsonb_each(msgs) loop
    perform public.tg_send(r.chat, prefix || r.txt, kb);
    n := n + 1;
  end loop;
  return n;
end $fn$;

do $do$
declare d text; d2 text;
begin
  -- /світло повертає кнопку
  d := pg_get_functiondef('public.tg_command(text,text)'::regprocedure);
  if position('outage_app_kb' in d) = 0 then
    d2 := replace(d, $q$'text', public.outage_now_text(p_chat));$q$, $q$'text', public.outage_now_text(p_chat), 'kb', public.outage_app_kb());$q$);
    if d2 = d then raise exception 'tg_command: не знайдено рядок для /світло'; end if;
    execute d2;
  end if;
  -- outage_extra_tick: синхронізація періодів екстрених
  d := pg_get_functiondef('public.outage_extra_tick(timestamptz)'::regprocedure);
  if position('outage_emerg_sync' in d) = 0 then
    d2 := replace(d, $q$  begin lg := lg || public.outage_tuya_tick(p_now);$q$,
                     $q$  begin perform public.outage_emerg_sync(); exception when others then lg := lg || 'екстрені: ' || sqlerrm || '; '; end;
  begin lg := lg || public.outage_tuya_tick(p_now);$q$);
    if d2 = d then raise exception 'outage_extra_tick: не знайдено рядок виклику outage_tuya_tick'; end if;
    execute d2;
  end if;
end $do$;
