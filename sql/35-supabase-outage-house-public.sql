-- Бот відключень: публічна версія Mini App для будинкового чату (відкривається у звичайному браузері без входу через Telegram)
-- і друга кнопка «🌐 У браузері» під повідомленнями будинкового бота.
-- Supabase -> SQL Editor -> New query -> вставити весь файл -> Run. Можна запускати повторно. Виконувати після 34.
-- Таблиць не створює й не змінює. Дані ті самі, що в режимі «будинок» (лише підписка 'home', без розеток), графік і так публічний.
--  * outage_house_core(): віддає дані режиму «будинок» без перевірки підпису (execute лише service_role, викликає Edge outage-app
--    для запиту {"public":"house"}).
--  * outage_house_data(init_data): як раніше (перевірка підпису токена будинкового бота), але дані бере з outage_house_core().
--  * outage_house_post(): під повідомленням дві кнопки: «📅 Графік» (Direct Link бота) і «🌐 У браузері»
--    (https://abohdanovskyi.github.io/outage-app/?house=1).

create or replace function public.outage_house_core() returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  tz text := public.tg_tzn();
  today date := (now() at time zone public.tg_tzn())::date;
  wstart date;
  s public.outage_subs%rowtype; sn public.outage_snap%rowtype; pl public.outage_plan%rowtype;
  subs jsonb := '[]'::jsonb; days jsonb; d date; d0 timestamptz; d1 timestamptz;
  snf boolean; plf boolean; emerg boolean; known boolean; st text; rng jsonb; pos jsonb; emg jsonb; sbj jsonb;
begin
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
revoke all on function public.outage_house_core() from public, anon, authenticated;
grant execute on function public.outage_house_core() to service_role;

create or replace function public.outage_house_data(p_init text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare hs public.outage_house%rowtype;
begin
  select * into hs from public.outage_house where id = 1;
  if not found or public.outage_app_check(p_init, hs.token) is null then return jsonb_build_object('ok', false); end if;
  return public.outage_house_core();
end $fn$;
revoke all on function public.outage_house_data(text) from public, anon, authenticated;
grant execute on function public.outage_house_data(text) to service_role;

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
                jsonb_build_object('text', '📅 Графік', 'url', 'https://t.me/' || h.username || '/graph'),
                jsonb_build_object('text', '🌐 У браузері', 'url', 'https://abohdanovskyi.github.io/outage-app/?house=1')))))
         else '{}'::jsonb end;
  select net.http_post(url := 'https://api.telegram.org/bot' || h.token || '/sendMessage', body := b, timeout_milliseconds := 15000) into rid;
exception when others then
  raise notice 'house: %', sqlerrm;
end $fn$;
revoke all on function public.outage_house_post(text) from public, anon, authenticated;
