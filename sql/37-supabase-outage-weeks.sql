-- Бот відключень: перемикач тижнів ◀ ▶ у Mini App «📅 Графік» («Тиждень ДД.ММ–ДД.ММ»).
-- Supabase -> SQL Editor -> New query -> вставити весь файл -> Run. Можна запускати повторно. Виконувати після 36.
-- Таблиць не створює й не змінює. Після запуску задеплоїти Edge outage-app v5 (передає week).
--  * p_week: зсув у тижнях від поточного (0 — цей тиждень), дозволено −8…+1; поза межами обрізається.
--  * Даних раніше 01.11.2026 немає: такі дні порожні (nodata = true), і назад далі тижня з 01.11 не гортається (week_min).
--  * Розетки віддаються лише від 03.11.2026.
--  * У відповіді нові поля: week, week_min, week_max.
--  * outage_house_core(p_week), outage_house_data(init_data, p_week), outage_app_data(init_data, p_week);
--    старі версії без p_week видаляються (нові мають p_week default 0, тож старі виклики працюють).

drop function if exists public.outage_house_data(text);
drop function if exists public.outage_house_core();
drop function if exists public.outage_app_data(text);

create or replace function public.outage_house_core(p_week int default 0) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  tz text := public.tg_tzn();
  today date := (now() at time zone public.tg_tzn())::date;
  first_day constant date := date '2026-11-01';
  w0 date := today - (extract(isodow from today)::int - 1);              -- понеділок поточного тижня
  wmin int := greatest(-8, -((w0 - date '2026-10-26') / 7));             -- 26.10 — понеділок тижня з 01.11.2026
  w int := greatest(wmin, least(1, coalesce(p_week, 0)));
  wstart date := w0 + 7 * w;
  s public.outage_subs%rowtype; sn public.outage_snap%rowtype; pl public.outage_plan%rowtype;
  subs jsonb := '[]'::jsonb; days jsonb; d date; d0 timestamptz; d1 timestamptz;
  snf boolean; plf boolean; emerg boolean; known boolean; st text; rng jsonb; pos jsonb; emg jsonb; sbj jsonb;
begin
  for s in select * from public.outage_subs x where x.active and x.key = 'home' loop
    days := '[]'::jsonb;
    for i in 0 .. 6 loop
      d := wstart + i;
      if d < first_day then
        days := days || jsonb_build_array(jsonb_build_object(
          'date', d, 'status', 'none', 'known', false, 'emergency', false, 'nodata', true,
          'plan', '[]'::jsonb, 'pos', '[]'::jsonb, 'emerg', '[]'::jsonb, 'sock', '[]'::jsonb, 'sb', '[]'::jsonb));
        continue;
      end if;
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
        'date', d, 'status', st, 'known', known, 'emergency', emerg, 'nodata', false,
        'plan', rng, 'pos', pos, 'emerg', emg, 'sock', '[]'::jsonb, 'sb', sbj));
    end loop;
    subs := subs || jsonb_build_array(jsonb_build_object(
      'key', s.key, 'title', s.title, 'grp', s.grp, 'fact', true, 'days', days));
  end loop;
  return jsonb_build_object('ok', true, 'house', true, 'now', (extract(epoch from now()) * 1000)::bigint, 'today', today,
                            'week_start', wstart, 'week', w, 'week_min', wmin, 'week_max', 1, 'subs', subs);
end $fn$;
revoke all on function public.outage_house_core(int) from public, anon, authenticated;
grant execute on function public.outage_house_core(int) to service_role;

create or replace function public.outage_house_data(p_init text, p_week int default 0) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare hs public.outage_house%rowtype;
begin
  select * into hs from public.outage_house where id = 1;
  if not found or public.outage_app_check(p_init, hs.token) is null then return jsonb_build_object('ok', false); end if;
  return public.outage_house_core(p_week);
end $fn$;
revoke all on function public.outage_house_data(text, int) from public, anon, authenticated;
grant execute on function public.outage_house_data(text, int) to service_role;

create or replace function public.outage_app_data(p_init text, p_week int default 0) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  tz text := public.tg_tzn();
  chat text := public.outage_app_user(p_init);
  today date := (now() at time zone public.tg_tzn())::date;
  first_day constant date := date '2026-11-01';
  sock_from constant date := date '2026-11-03';
  w0 date := today - (extract(isodow from today)::int - 1);              -- понеділок поточного тижня
  wmin int := greatest(-8, -((w0 - date '2026-10-26') / 7));             -- 26.10 — понеділок тижня з 01.11.2026
  w int := greatest(wmin, least(1, coalesce(p_week, 0)));
  wstart date := w0 + 7 * w;
  s public.outage_subs%rowtype; sn public.outage_snap%rowtype; pl public.outage_plan%rowtype;
  subs jsonb := '[]'::jsonb; days jsonb; d date; d0 timestamptz; d1 timestamptz;
  snf boolean; plf boolean; emerg boolean; known boolean; st text; rng jsonb; pos jsonb; emg jsonb; sock jsonb; sbj jsonb;
begin
  if chat is null then return jsonb_build_object('ok', false); end if;
  for s in select * from public.outage_subs x where x.active and chat = any (public.outage_chats(x)) order by x.key loop
    days := '[]'::jsonb;
    for i in 0 .. 6 loop
      d := wstart + i;
      if d < first_day then
        days := days || jsonb_build_array(jsonb_build_object(
          'date', d, 'status', 'none', 'known', false, 'emergency', false, 'nodata', true,
          'plan', '[]'::jsonb, 'pos', '[]'::jsonb, 'emerg', '[]'::jsonb, 'sock', '[]'::jsonb, 'sb', '[]'::jsonb));
        continue;
      end if;
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
        if d >= sock_from then
          sock := coalesce((select jsonb_agg(jsonb_build_array(q.a, q.b) order by q.a)
                              from (select public.outage_app_min(greatest(v.st, d0), d0) a,
                                           public.outage_app_min(least(coalesce(v.en, now()), d1), d0) b
                                      from public.outage_sock_intervals(d0, d1) v) q
                             where q.b > q.a), '[]'::jsonb);
        end if;
        sbj := coalesce((select jsonb_agg(jsonb_build_array(q.a, q.b) order by q.a)
                           from (with ev as (select at, kind, lead(kind) over (order by at) nk, lead(at) over (order by at) nat from public.outage_log),
                                      iv as (select at as st, coalesce(nat, now()) as en from ev where kind = 'off' and (nk = 'on' or nk is null))
                                 select public.outage_app_min(greatest(iv.st, d0), d0) a, public.outage_app_min(least(iv.en, d1), d0) b
                                   from iv where iv.st < d1 and iv.en > d0) q
                          where q.b > q.a), '[]'::jsonb);
      end if;
      days := days || jsonb_build_array(jsonb_build_object(
        'date', d, 'status', st, 'known', known, 'emergency', emerg, 'nodata', false,
        'plan', rng, 'pos', pos, 'emerg', emg, 'sock', sock, 'sb', sbj));
    end loop;
    subs := subs || jsonb_build_array(jsonb_build_object(
      'key', s.key, 'title', s.title, 'grp', s.grp, 'fact', coalesce(s.svitlo, false), 'days', days));
  end loop;
  return jsonb_build_object('ok', true, 'now', (extract(epoch from now()) * 1000)::bigint, 'today', today,
                            'week_start', wstart, 'week', w, 'week_min', wmin, 'week_max', 1, 'subs', subs);
end $fn$;
revoke all on function public.outage_app_data(text, int) from public, anon, authenticated;
grant execute on function public.outage_app_data(text, int) to service_role;

-- перевірка (без підпису Telegram): поточний тиждень і на тиждень назад
select (public.outage_house_core(0) ->> 'week_start') as this_week, (public.outage_house_core(-1) ->> 'week_start') as prev_week,
       (public.outage_house_core(0) ->> 'week_min') as week_min;
