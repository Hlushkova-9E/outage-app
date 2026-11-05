-- Бот відключень: будинковий бот «Глушкова, 9Є» для спільного чату + Mini App в режимі «будинок».
-- Supabase -> SQL Editor -> New query -> вставити весь файл -> Run. Можна запускати повторно. Виконувати після 32.
-- Нових cron-завдань немає. Існуючі таблиці й функції бюджету не змінює (лише outage_apply доповнюється одним блоком).
--
-- Що з'являється:
--  * outage_house(id=1, token, username, chat_id, enabled): налаштування будинкового бота (токен лише тут, у чат/базу знань не писати).
--    Задати: select public.outage_house_set('ТОКЕН_З_BOTFATHER', 'username_бота_без_@');  (виконує Антон у SQL Editor)
--    Чат: select public.outage_house_chat('-100...');  Вимкнути надсилання: select public.outage_house_enable(false);
--  * outage_house_post(text): надсилає текст у чат від будинкового бота з кнопкою «📅 Графік» (посилання t.me/<бот>/graph);
--    у тихі години 00:00–07:00 (київський час) надсилає БЕЗ ЗВУКУ (disable_notification).
--  * outage_apply: для підписки 'home' додатково дублює в чат повідомлення «графік на завтра», «змінився», «екстрені», «скасовано».
--    «Не підтверджено» (22:00) і «статус змінився» у чат не йдуть, ніщо про розетки теж.
--  * outage_app_check, outage_house_data(init_data): дані для Mini App, відкритого з будинкового бота (підпис його токена);
--    віддає лише підписку 'home', без розеток (поле house = true); лише service_role.
--  * outage_house_intro(): одноразове вступне повідомлення з кнопкою (щоб закріпити).

create table if not exists public.outage_house (
  id int primary key default 1 check (id = 1),
  token text,
  username text,
  chat_id text,
  enabled boolean not null default true
);
insert into public.outage_house (id) values (1) on conflict (id) do nothing;
alter table public.outage_house enable row level security;
revoke all on public.outage_house from public, anon, authenticated;

create or replace function public.outage_house_set(p_token text, p_username text) returns text
language plpgsql security definer set search_path = public as $fn$
begin
  update public.outage_house set token = nullif(trim(p_token), ''), username = nullif(regexp_replace(trim(p_username), '^@', ''), '') where id = 1;
  return 'ок: бот @' || coalesce((select username from public.outage_house where id = 1), '?');
end $fn$;
revoke all on function public.outage_house_set(text, text) from public, anon, authenticated;

create or replace function public.outage_house_chat(p_chat text) returns text
language plpgsql security definer set search_path = public as $fn$
begin
  update public.outage_house set chat_id = nullif(trim(p_chat), '') where id = 1;
  return 'ок: чат збережено';
end $fn$;
revoke all on function public.outage_house_chat(text) from public, anon, authenticated;

create or replace function public.outage_house_enable(p_on boolean) returns text
language plpgsql security definer set search_path = public as $fn$
begin
  update public.outage_house set enabled = p_on where id = 1;
  return case when p_on then 'надсилання в чат увімкнено' else 'надсилання в чат вимкнено' end;
end $fn$;
revoke all on function public.outage_house_enable(boolean) from public, anon, authenticated;

create or replace function public.outage_house_post(p_txt text) returns void
language plpgsql security definer set search_path = public, extensions as $fn$
declare h public.outage_house%rowtype; b jsonb; hr int; rid bigint;
begin
  select * into h from public.outage_house where id = 1;
  if not found or coalesce(h.token, '') = '' or coalesce(h.chat_id, '') = '' or not h.enabled then return; end if;
  hr := extract(hour from (now() at time zone public.tg_tzn()))::int;
  b := jsonb_build_object('chat_id', h.chat_id, 'text', left(p_txt, 4000), 'disable_web_page_preview', true, 'disable_notification', hr < 7)
    || case when coalesce(h.username, '') <> ''
         then jsonb_build_object('reply_markup', jsonb_build_object('inline_keyboard', jsonb_build_array(jsonb_build_array(
                jsonb_build_object('text', '📅 Графік', 'url', 'https://t.me/' || h.username || '/graph')))))
         else '{}'::jsonb end;
  select net.http_post(url := 'https://api.telegram.org/bot' || h.token || '/sendMessage', body := b, timeout_milliseconds := 15000) into rid;
exception when others then
  raise notice 'house: %', sqlerrm;
end $fn$;
revoke all on function public.outage_house_post(text) from public, anon, authenticated;

create or replace function public.outage_house_intro() returns text
language plpgsql security definer set search_path = public as $fn$
begin
  perform public.outage_house_post(E'💡 Графік відключень світла\n🏠 Глушкова, 9Є · група 29.1\n\nСюди приходять графік на завтра, зміни графіка й екстрені відключення (вночі, 00:00–07:00, без звуку). Кнопка «📅 Графік» відкриває графік тижня.');
  return 'надіслано';
end $fn$;
revoke all on function public.outage_house_intro() from public, anon, authenticated;

create or replace function public.outage_app_check(p_init text, p_tok text) returns text
language plpgsql security definer set search_path = public, extensions as $fn$
declare
  kv text; k text; v text; h text; uj jsonb; ad bigint; chk text[] := '{}'; dcs text; sk bytea; calc text;
begin
  if p_tok is null or p_tok = '' or p_init is null or length(p_init) > 4000 then return null; end if;
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
  sk := extensions.hmac(convert_to(p_tok, 'UTF8'), convert_to('WebAppData', 'UTF8'), 'sha256');
  calc := encode(extensions.hmac(convert_to(dcs, 'UTF8'), sk, 'sha256'), 'hex');
  if calc is distinct from h then return null; end if;
  return uj->>'id';
exception when others then
  return null;
end $fn$;
revoke all on function public.outage_app_check(text, text) from public, anon, authenticated;

create or replace function public.outage_house_data(p_init text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  tz text := public.tg_tzn();
  hs public.outage_house%rowtype;
  today date := (now() at time zone public.tg_tzn())::date;
  wstart date;
  s public.outage_subs%rowtype; sn public.outage_snap%rowtype; pl public.outage_plan%rowtype;
  subs jsonb := '[]'::jsonb; days jsonb; d date; d0 timestamptz; d1 timestamptz;
  snf boolean; plf boolean; emerg boolean; known boolean; st text; rng jsonb; pos jsonb; emg jsonb; sbj jsonb;
begin
  select * into hs from public.outage_house where id = 1;
  if not found or public.outage_app_check(p_init, hs.token) is null then return jsonb_build_object('ok', false); end if;
  wstart := today - (extract(isodow from today)::int - 1);
  for s in select * from public.outage_subs x where x.active and x.key = 'home' loop
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
      sbj := '[]'::jsonb;
      if d <= today then
        sbj := coalesce((select jsonb_agg(jsonb_build_array(q.a, q.b) order by q.a)
                           from (with ev as (select at, kind, lead(kind) over (order by at) nk, lead(at) over (order by at) nat from public.outage_log),
                                      iv as (select at as st, coalesce(nat, now()) as en from ev where kind = 'off' and (nk = 'on' or nk is null))
                                 select public.outage_app_min(greatest(iv.st, d0), d0) a, public.outage_app_min(least(iv.en, d1), d0) b
                                   from iv where iv.st < d1 and iv.en > d0) q
                          where q.b > q.a), '[]'::jsonb);
      end if;
      days := days || jsonb_build_array(jsonb_build_object(
        'date', d, 'status', st, 'known', known, 'emergency', emerg,
        'plan', rng, 'pos', pos, 'emerg', emg, 'sock', '[]'::jsonb, 'sb', sbj));
    end loop;
    subs := subs || jsonb_build_array(jsonb_build_object(
      'key', s.key, 'title', s.title, 'grp', s.grp, 'fact', true, 'days', days));
  end loop;
  return jsonb_build_object('ok', true, 'house', true, 'now', (extract(epoch from now()) * 1000)::bigint, 'today', today,
                            'week_start', wstart, 'subs', subs);
end $fn$;
revoke all on function public.outage_house_data(text) from public, anon, authenticated;
grant execute on function public.outage_house_data(text) to service_role;

-- outage_apply: дублювання повідомлень про графік дому в будинковий чат (одним блоком перед записом у журнал)
do $do$
declare d text; d2 text;
begin
  d := pg_get_functiondef('public.outage_apply(jsonb,boolean,timestamptz)'::regprocedure);
  if position('outage_house_post' in d) = 0 then
    d2 := replace(d, $q$lg := lg || g.grp || ' ' || d || ' ' || kind || '; ';$q$,
$q$begin
          if kind in ('new', 'chg', 'emg', 'back') and exists (select 1 from public.outage_subs hs where hs.active and hs.key = 'home' and hs.grp = g.grp) then
            select * into s from public.outage_subs where key = 'home';
            perform public.outage_house_post(public.outage_msg(kind, s.title, s.grp, s.show_grp, d, today, st, rng, pos, case when had then old.rng else null end));
          end if;
        exception when others then null; end;
        lg := lg || g.grp || ' ' || d || ' ' || kind || '; ';$q$);
    if d2 = d then raise exception 'outage_apply: не знайдено рядок для вставки'; end if;
    execute d2;
  end if;
end $do$;
