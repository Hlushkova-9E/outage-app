-- 55: підсумок учорашнього дня в ранковому графіку, попередження про нестабільну напругу,
--     точність графіка й порівняння СвітлоБота з розетками у звітах, дані Bluetti для сторінки (лише Антон і Ксенія).
-- Таблиць не створює й не змінює. Бюджетні функції: лише tg_command (рядок /світло звіт), як у SQL 54.

-- 1. Вчорашній день для ранкового повідомлення (дім, СвітлоБот; Bluetti; автовмикання бойлерів)
create or replace function public.outage_yday_text(p_today date) returns text
language plpgsql stable security definer set search_path = public as $fn$
declare tz text := public.tg_tzn(); y date := p_today - 1;
  t0 timestamptz := (p_today - 1)::timestamp at time zone public.tg_tzn();
  t1 timestamptz := p_today::timestamp at time zone public.tg_tzn();
  fl timestamptz; fm int; pm int; secs numeric; kwh numeric; n int; o text := '';
begin
  select min(at) into fl from public.outage_log;
  if fl is not null and fl <= t0 then
    with ev as (select at, kind, lead(at) over (order by at) nat from public.outage_log)
    select coalesce(sum(extract(epoch from (least(coalesce(nat, now()), t1) - greatest(at, t0)))), 0)::int / 60 into fm
      from ev where kind = 'off' and at < t1 and coalesce(nat, now()) > t0;
    select p.minutes into pm from public.outage_plan p where p.day = y;
    o := E'\n\n📊 Вчора: ' || case when fm = 0 then 'світло було весь день' else 'без світла ' || public.outage_dur(fm) end
      || case when pm is not null then ' (за графіком ' || case when pm = 0 then 'без відключень' else public.outage_dur(pm) end || ')' else '' end;
  end if;
  with r as (
    select at, ac, coalesce(ac_w, 0) w, lead(at) over (order by at) nat
      from public.bluetti_log where sn is not null and online and at >= t0 - interval '10 minutes' and at < t1)
  select sum(least(extract(epoch from (least(nat, t1) - greatest(at, t0))), 300)) filter (where ac and nat > t0),
         sum(w * least(extract(epoch from (least(nat, t1) - greatest(at, t0))), 300)) filter (where ac and nat > t0) / 3600000.0
    into secs, kwh from r where nat is not null;
  if coalesce(secs, 0) >= 60 then
    o := o || case when o = '' then E'\n\n' else E'\n' end || '🔋 На Bluetti ' || public.outage_dur(secs::int / 60)
      || ', віддано ' || round(coalesce(kwh, 0), 1) || ' кВт·год';
  end if;
  select count(*) into n from public.outage_events where key like 'bauto:%' and at >= t0 and at < t1;
  if n > 0 then
    o := o || case when o = '' then E'\n\n' else E'\n' end || '🔌 Бойлери вмикались автоматично: ' || n || ' '
      || case when n % 10 = 1 and n % 100 <> 11 then 'раз' when n % 10 between 2 and 4 and n % 100 not between 12 and 14 then 'рази' else 'разів' end;
  end if;
  return o;
end $fn$;

-- 2. Точність графіка й порівняння СвітлоБота з розетками за місяць
create or replace function public.outage_acc_text(p_month date default null) returns text
language plpgsql stable security definer set search_path = public as $fn$
declare tz text := public.tg_tzn(); nowl date := (now() at time zone public.tg_tzn())::date;
  d0 date := date_trunc('month', coalesce(p_month, (now() at time zone public.tg_tzn())::date))::date;
  d1 date := (date_trunc('month', coalesce(p_month, (now() at time zone public.tg_tzn())::date)) + interval '1 month')::date;
  fl timestamptz; t0 timestamptz; t1 timestamptz; s0 timestamptz; m0 timestamptz; m1 timestamptz;
  sbr tstzmultirange; pmr tstzmultirange; skr tstzmultirange; blr tstzmultirange;
  n_all int; n_ok int; c int; lt timestamptz; s_all int; s_ok int; miss int; fls int; o text := '';
begin
  select min(at) into fl from public.outage_log;
  if fl is null then return ''; end if;
  t0 := greatest(d0, (fl at time zone tz)::date + 1)::timestamp at time zone tz;
  t1 := least(d1::timestamp at time zone tz, now());
  if t1 <= t0 then return ''; end if;
  select range_agg(tstzrange(e.at, coalesce(e.nat, now()))) into sbr
    from (select at, kind, lead(at) over (order by at) nat from public.outage_log) e where e.kind = 'off';
  select range_agg(tstzrange((p.day::timestamp + make_interval(mins => (r ->> 0)::int)) at time zone tz,
                             (p.day::timestamp + make_interval(mins => (r ->> 1)::int)) at time zone tz)) into pmr
    from public.outage_plan p cross join lateral jsonb_array_elements(p.rng) r
   where p.day >= (t0 at time zone tz)::date and p.day < d1;
  select count(*), count(*) filter (where coalesce(pmr @> g, false) = coalesce(sbr @> g, false)) into n_all, n_ok
    from generate_series(t0, t1 - interval '1 minute', interval '1 minute') g
   where exists (select 1 from public.outage_plan p where p.day = (g at time zone tz)::date);
  if n_all >= 60 then
    o := E'\n\n🎯 Графік YASNO збігся з фактом (СвітлоБот) на ' || round(100.0 * n_ok / n_all) || '% часу';
  end if;

  m0 := d0::timestamp at time zone tz; m1 := d1::timestamp at time zone tz;
  select count(*) into c from public.outage_events where key like 'ychg:%' and at >= m0 and at < m1;
  if c > 0 then
    select at into lt from public.outage_events where key like 'ychg:%' and at >= m0 and at < m1
     order by (at at time zone tz)::time desc limit 1;
    o := o || case when o = '' then E'\n\n' else E'\n' end || '🔄 Змін графіка: ' || c
      || ' · найпізніша о ' || to_char(lt at time zone tz, 'HH24:MI') || ' (' || to_char(lt at time zone tz, 'DD.MM') || ')'
      || case when d0 < date '2026-11-07' then ' (облік з 07.11)' else '' end;
  end if;

  s0 := greatest(t0, nullif(public.outage_st_get('tuya_from'), '')::timestamptz, (select min(at) from public.bluetti_log));
  if s0 is not null and t1 - s0 >= interval '1 hour' then
    select range_agg(tstzrange(v.st, coalesce(v.en, now()))) into skr from public.outage_sock_intervals(s0, t1) v;
    select range_agg(tstzrange(q.at, least(q.nat, q.at + interval '5 minutes'))) into blr
      from (select at, ac, online, lead(at) over (order by at) nat from public.bluetti_log where sn is not null) q
     where q.online and q.ac and q.nat is not null;
    select count(*), count(*) filter (where coalesce(sbr @> g, false) = coalesce(skr @> g, false)) into s_all, s_ok
      from generate_series(s0, t1 - interval '1 minute', interval '1 minute') g
     where not coalesce(blr @> g, false);
    select count(*) into miss from public.outage_sock_intervals(s0, t1) v
     where coalesce(v.en, now()) - v.st >= interval '10 minutes'
       and not coalesce(sbr && tstzmultirange(tstzrange(v.st, coalesce(v.en, now()))), false);
    select count(*) into fls
      from (select at st, coalesce(lead(at) over (order by at), now()) en, kind from public.outage_log) e
     where e.kind = 'off' and e.st >= s0 and e.st < t1 and e.en - e.st >= interval '10 minutes'
       and not coalesce(skr && tstzmultirange(tstzrange(e.st, e.en)), false);
    if s_all >= 60 then
      o := o || E'\n👥 СвітлоБот і розетки (ваша лінія) збіглися на ' || round(100.0 * s_ok / s_all) || '% часу'
        || case when s0 > m0 then ' (з ' || to_char(s0 at time zone tz, 'DD.MM') || ', без часу на Bluetti)' else ' (без часу на Bluetti)' end
        || case when miss > 0 then E'\n   СвітлоБот пропустив відключень лінії: ' || miss else '' end
        || case when fls > 0 then E'\n   СвітлоБот показав відключення, яких на лінії не було: ' || fls else '' end;
    end if;
  end if;
  return o;
end $fn$;

-- 3. Дані Bluetti для сторінки (лише для людей з tg_people)
create or replace function public.bluetti_app(p_wstart date) returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare tz text := public.tg_tzn(); b jsonb := public.bluetti_now(); s jsonb := public.outage_pwr_src(now());
  dj jsonb := '{}'::jsonb; dd date;
begin
  if not coalesce((b ->> 'has')::boolean, false) then return null; end if;
  for i in 0 .. 6 loop
    dd := p_wstart + i;
    dj := dj || jsonb_build_object(dd::text, coalesce((
      select jsonb_agg(jsonb_build_array(q.m, q.soc, q.acn, q.w) order by q.m) from (
        select (floor((extract(hour from l.at at time zone tz) * 60 + extract(minute from l.at at time zone tz)) / 10) * 10)::int m,
               round(avg(l.soc))::int soc, max(case when l.ac then 1 else 0 end) acn, round(avg(coalesce(l.ac_w, 0)))::int w
          from public.bluetti_log l
         where l.sn is not null and l.online and l.soc > 0
           and l.at >= dd::timestamp at time zone tz and l.at < (dd + 1)::timestamp at time zone tz
         group by 1) q), '[]'::jsonb));
  end loop;
  return jsonb_build_object('soc', b -> 'soc', 'last_soc', b -> 'last_soc', 'online', b -> 'online', 'fresh', b -> 'fresh',
    'ac', b -> 'ac', 'acw', b -> 'acw', 'grid', b -> 'grid',
    'at', (extract(epoch from (b ->> 'at')::timestamptz) * 1000)::bigint, 'src', s ->> 'src',
    'eta', case when s ->> 'src' = 'bluetti' and (b ->> 'soc') is not null
                then public.bluetti_eta((b ->> 'soc')::numeric, greatest(coalesce((b ->> 'acw')::numeric, 0), 30), now()) end,
    'days', dj);
end $fn$;

revoke all on function public.outage_yday_text(date) from public, anon, authenticated;
revoke all on function public.outage_acc_text(date) from public, anon, authenticated;
revoke all on function public.bluetti_app(date) from public, anon, authenticated;

do $do$
declare d text; f text;
begin
  -- outage_apply: журнал змін графіка дому (для звіту)
  d := pg_get_functiondef('public.outage_apply(jsonb, boolean, timestamptz)'::regprocedure);
  if position('ychg:' in d) = 0 then
    f := $q$        lg := lg || g.grp || ' ' || d || ' ' || kind || '; ';$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'apply'; end if;
    d := replace(d, f, $q$        if kind = 'chg' and exists (select 1 from public.outage_subs hs where hs.key = 'home' and hs.grp = g.grp) then
          insert into public.outage_events (key) values ('ychg:' || d || ':' || p_now::text) on conflict (key) do nothing;
        end if;
$q$ || f);
    execute d;
  end if;

  -- outage_pwr_tick: нестабільна напруга (≥3 знеструмлення розеток за 15 хв), раз на годину
  d := pg_get_functiondef('public.outage_pwr_tick(timestamptz, boolean)'::regprocedure);
  if position('bvolt:' in d) = 0 then
    f := $q$ldm numeric; nx int;$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'decl'; end if;
    d := replace(d, f, $q$ldm numeric; nx int; nv int;$q$);
    f := $q$  -- 11. за ~1 год до відключення$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'b11'; end if;
    d := replace(d, f, $q$  -- 12. нестабільна напруга: розетки знеструмлювались 3+ рази за 15 хв
  select count(*) into nv from public.outage_tuya_log t where t.kind = 'off' and t.at > p_now - interval '15 minutes' and t.at <= p_now;
  if nv >= 3 and public.outage_ev_new('bvolt:' || to_char(p_now at time zone tz, 'YYYY-MM-DD HH24'), p_dry) then
    out := out || jsonb_build_object('c', chats, 'q', quiet,
      't', '⚡ Нестабільна напруга: за 15 хв квартира знеструмлювалась ' || nv || ' '
        || case when nv between 2 and 4 then 'рази' else 'разів' end
        || E'.\nЙмовірно, спрацьовує реле напруги (ЗУБР) або миготить мережа. Потужну техніку краще не вмикати, доки не стабілізується.');
  end if;

$q$ || f);
    d := replace(d, $q$btok|bchg):$q$, $q$btok|bchg|bvolt):$q$);
    execute d;
  end if;

  -- ранковий графік: вчорашній день; місячний звіт: точність
  d := pg_get_functiondef('public.outage_extra_tick(timestamptz)'::regprocedure);
  if position('outage_yday_text' in d) = 0 then
    f := $q$|| body || public.bluetti_morning(today));$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'morning'; end if;
    d := replace(d, f, $q$|| body || public.bluetti_morning(today) || public.outage_yday_text(today));$q$);
    f := $q$c := public.outage_month_text(pm) || public.bluetti_month(pm);$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'month'; end if;
    d := replace(d, f, $q$c := public.outage_month_text(pm) || public.outage_acc_text(pm) || public.bluetti_month(pm);$q$);
    execute d;
  end if;

  -- /світло звіт
  d := pg_get_functiondef('public.tg_command(text, text)'::regprocedure);
  if position('outage_acc_text' in d) = 0 then
    f := $q$public.outage_month_text(null) || public.bluetti_month(null))$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'cmd'; end if;
    d := replace(d, f, $q$public.outage_month_text(null) || public.outage_acc_text(null) || public.bluetti_month(null))$q$);
    execute d;
  end if;

  -- сторінка (версія FamilyBot): блок Bluetti для Антона й Ксенії
  d := pg_get_functiondef('public.outage_app_data(text, integer)'::regprocedure);
  if position('bluetti_app' in d) = 0 then
    f := $q$'week_max', 1, 'subs', subs);$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'app'; end if;
    d := replace(d, f, $q$'week_max', 1, 'subs', subs,
                            'bl', case when exists (select 1 from public.tg_people tp where tp.chat_id = chat) then public.bluetti_app(wstart) end);$q$);
    execute d;
  end if;
end $do$;

-- 55b_fix: відключення СвітлоБота, під час яких квартира перейшла на Bluetti, не рахувати «хибними» (розетки тоді живить Bluetti)
do $do$
declare d text; f text;
begin
  d := pg_get_functiondef('public.outage_acc_text(date)'::regprocedure);
  f := $q$       and not coalesce(skr && tstzmultirange(tstzrange(e.st, e.en)), false);$q$;
  if position(f in d) > 0 then
    d := replace(d, f, $q$       and not coalesce(skr && tstzmultirange(tstzrange(e.st, e.en)), false)
       and not coalesce(blr && tstzmultirange(tstzrange(e.st, e.en)), false);$q$);
    execute d;
  end if;
end $do$;
