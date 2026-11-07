-- 57: вкладка «📊 Історія» на сторінці (лише Антон і Ксенія: FamilyBot або особисте посилання).
-- Таблиць не створює; бере outage_log (СвітлоБот), outage_plan, outage_tuya_log (розетки), bluetti_log, outage_events (ychg:, bauto:), outage_emerg.

-- тривалість мультидіапазону в хвилинах
create or replace function public.outage_mr_min(m tstzmultirange) returns int
language sql immutable set search_path = public as $$
  select coalesce(sum(extract(epoch from (upper(x) - lower(x)))), 0)::int / 60 from unnest(coalesce(m, '{}'::tstzmultirange)) x;
$$;

create or replace function public.outage_history(p_chat text, p_month date default null) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $fn$
declare
  tz text := public.tg_tzn();
  nowl date := (now() at time zone public.tg_tzn())::date;
  mmin constant date := date '2026-11-01';
  mmax date := date_trunc('month', (now() at time zone public.tg_tzn())::date)::date;
  d0 date; d1 date; dl date; t0 timestamptz; t1 timestamptz; d date; a timestamptz; b timestamptz;
  g text; sbf timestamptz; skf timestamptz; blf timestamptz;
  sbr tstzmultirange; pmr tstzmultirange; skr tstzmultirange; blr tstzmultirange; emr tstzmultirange;
  dr tstzmultirange; pr tstzmultirange; r2 tstzmultirange;
  days jsonb := '[]'::jsonb; hrs jsonb; h int; hm int;
  pl int; known boolean; heat int[] := array_fill(0, array[24]); hdays int := 0;
  cnt int; lng int; lng_at timestamptz; offm int; planm int; accm int; acc_all int; ssm int; ss_all int;
  chg int; lt timestamptz; blm int; kwh numeric; boil int; bld jsonb;
begin
  if p_chat is null or not exists (select 1 from public.tg_people where chat_id = p_chat) then return jsonb_build_object('ok', false); end if;
  d0 := date_trunc('month', coalesce(p_month, nowl))::date;
  d0 := greatest(mmin, least(mmax, d0));
  d1 := (d0 + interval '1 month')::date;
  dl := least(d1, nowl + 1);
  t0 := d0::timestamp at time zone tz;
  t1 := least(d1::timestamp at time zone tz, now());
  select grp into g from public.outage_subs where key = 'home';
  select min(at) into sbf from public.outage_log;
  skf := nullif(public.outage_st_get('tuya_from'), '')::timestamptz;
  select min(at) into blf from public.bluetti_log where sn is not null;

  select range_agg(tstzrange(e.at, coalesce(e.nat, now()))) into sbr
    from (select at, kind, lead(at) over (order by at) nat from public.outage_log) e where e.kind = 'off';
  select range_agg(tstzrange((p.day::timestamp + make_interval(mins => (x ->> 0)::int)) at time zone tz,
                             (p.day::timestamp + make_interval(mins => (x ->> 1)::int)) at time zone tz)) into pmr
    from public.outage_plan p cross join lateral jsonb_array_elements(p.rng) x where p.day >= d0 and p.day < d1;
  if skf is not null then
    select range_agg(tstzrange(v.st, coalesce(v.en, now()))) into skr from public.outage_sock_intervals(greatest(t0, skf), t1) v;
  end if;
  select range_agg(tstzrange(q.at, least(q.nat, q.at + interval '5 minutes'))) into blr
    from (select at, ac, online, lead(at) over (order by at) nat from public.bluetti_log where sn is not null and at < t1 + interval '5 minutes') q
   where q.online and q.ac and q.nat is not null;
  select range_agg(tstzrange(e.start_at, coalesce(e.end_at, now()))) into emr from public.outage_emerg e where e.grp = g;

  -- Bluetti по днях: хвилини роботи й кВт·год
  with r as (
    select at, ac, coalesce(ac_w, 0) w, lead(at) over (order by at) nat
      from public.bluetti_log where sn is not null and online and at >= t0 - interval '10 minutes' and at < t1)
  select coalesce(jsonb_object_agg(x.dd, jsonb_build_array(x.m, x.k)), '{}'::jsonb) into bld from (
    select (r.at at time zone tz)::date::text dd,
           (sum(least(extract(epoch from (r.nat - r.at)), 300)) filter (where r.ac) / 60)::int m,
           round(coalesce(sum(r.w * least(extract(epoch from (r.nat - r.at)), 300)) filter (where r.ac), 0) / 3600000.0, 2) k
      from r where r.nat is not null and r.at >= t0 group by 1) x;

  for d in select generate_series(d0, dl - 1, interval '1 day')::date loop
    a := d::timestamp at time zone tz;
    b := least((d + 1)::timestamp at time zone tz, now());
    if b <= a then continue; end if;
    dr := tstzmultirange(tstzrange(a, b));
    select p.minutes into pl from public.outage_plan p where p.day = d;
    known := found;
    hrs := '[]'::jsonb;
    if sbf is not null and a >= date_trunc('day', sbf at time zone tz) at time zone tz then
      for h in 0 .. 23 loop
        if (d::timestamp + make_interval(hours => h)) at time zone tz >= b then hrs := hrs || to_jsonb(-1); continue; end if;
        hm := public.outage_mr_min(sbr * tstzmultirange(tstzrange((d::timestamp + make_interval(hours => h)) at time zone tz,
                                                              least((d::timestamp + make_interval(hours => h + 1)) at time zone tz, b))));
        hrs := hrs || to_jsonb(hm);
        heat[h + 1] := heat[h + 1] + hm;
      end loop;
      if b = (d + 1)::timestamp at time zone tz then hdays := hdays + 1; end if;
    end if;
    days := days || jsonb_build_array(jsonb_build_object(
      'date', d,
      'plan', case when known then pl end,
      'sb', case when sbf is not null and b > sbf then public.outage_mr_min(sbr * dr) end,
      'sock', case when skf is not null and b > skf then public.outage_mr_min(skr * dr) end,
      'bl', case when blf is not null and b > blf then coalesce((bld -> d::text ->> 0)::int, 0) end,
      'kwh', case when blf is not null and b > blf then coalesce((bld -> d::text ->> 1)::numeric, 0) end,
      'emerg', coalesce(emr && dr, false),
      'chg', (select count(*) from public.outage_events where key like 'ychg:%' and at >= a and at < (d + 1)::timestamp at time zone tz),
      'h', hrs));
  end loop;

  -- підсумки
  select count(*), coalesce(max(extract(epoch from (upper(x) - lower(x)))::int / 60), 0) into cnt, lng
    from unnest(sbr * tstzmultirange(tstzrange(t0, t1))) x where upper(x) - lower(x) >= interval '5 minutes';
  select lower(x) into lng_at from unnest(sbr * tstzmultirange(tstzrange(t0, t1))) x order by upper(x) - lower(x) desc limit 1;
  offm := public.outage_mr_min(sbr * tstzmultirange(tstzrange(t0, t1)));
  select coalesce(sum(minutes), 0) into planm from public.outage_plan where day >= d0 and day < dl;
  select range_agg(tstzrange(p.day::timestamp at time zone tz, least((p.day + 1)::timestamp at time zone tz, now())))
    into pr from public.outage_plan p where p.day >= d0 and p.day < dl and p.day::timestamp at time zone tz >= coalesce(sbf, 'infinity'::timestamptz);
  acc_all := public.outage_mr_min(pr);
  accm := acc_all - public.outage_mr_min((coalesce(pmr, '{}') - coalesce(sbr, '{}')) * pr) - public.outage_mr_min((coalesce(sbr, '{}') - coalesce(pmr, '{}')) * pr);
  if skf is not null and blf is not null and greatest(t0, skf, blf) < t1 then
    r2 := tstzmultirange(tstzrange(greatest(t0, skf, blf), t1)) - coalesce(blr, '{}');
    ss_all := public.outage_mr_min(r2);
    ssm := ss_all - public.outage_mr_min((coalesce(sbr, '{}') - coalesce(skr, '{}')) * r2) - public.outage_mr_min((coalesce(skr, '{}') - coalesce(sbr, '{}')) * r2);
  end if;
  select count(*) into chg from public.outage_events where key like 'ychg:%' and at >= t0 and at < t1;
  select at into lt from public.outage_events where key like 'ychg:%' and at >= t0 and at < t1 order by (at at time zone tz)::time desc limit 1;
  blm := public.outage_mr_min(blr * tstzmultirange(tstzrange(t0, t1)));
  select coalesce(sum((v ->> 1)::numeric), 0) into kwh from jsonb_each(bld) e(k, v);
  select count(*) into boil from public.outage_events where key like 'bauto:%' and at >= t0 and at < t1;

  return jsonb_build_object('ok', true,
    'month', to_char(d0, 'YYYY-MM'), 'mmin', to_char(mmin, 'YYYY-MM'), 'mmax', to_char(mmax, 'YYYY-MM'), 'today', nowl,
    'since', jsonb_build_object('sb', (sbf at time zone tz)::date, 'sock', (skf at time zone tz)::date, 'bl', (blf at time zone tz)::date, 'chg', date '2026-11-07'),
    'kpi', jsonb_build_object(
      'count', cnt, 'off', offm, 'plan', planm, 'longest', lng,
      'longest_at', case when lng_at is not null then (extract(epoch from lng_at) * 1000)::bigint end,
      'acc', case when acc_all >= 60 then round(100.0 * accm / acc_all) end,
      'sbsock', case when ss_all >= 60 then round(100.0 * ssm / ss_all) end,
      'chg', chg, 'chg_late', case when lt is not null then to_char(lt at time zone tz, 'HH24:MI DD.MM') end,
      'bl', blm, 'kwh', round(kwh, 1), 'boil', boil),
    'heat', to_jsonb(heat), 'hdays', hdays,
    'days', days);
end $fn$;

create or replace function public.outage_key_history(p_key text, p_month date default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $fn$
declare r public.outage_keys%rowtype;
begin
  if p_key is null or length(p_key) < 20 or length(p_key) > 100 then return jsonb_build_object('ok', false); end if;
  select * into r from public.outage_keys where hash = encode(digest(p_key, 'sha256'), 'hex') and revoked is null;
  if not found then return jsonb_build_object('ok', false); end if;
  update public.outage_keys set last_used = now(), uses = uses + 1 where id = r.id;
  return public.outage_history(r.chat_id, p_month);
end $fn$;

create or replace function public.outage_app_history(p_init text, p_month date default null) returns jsonb
language sql security definer set search_path = public as $$
  select public.outage_history(public.outage_app_user(p_init), p_month);
$$;

revoke all on function public.outage_mr_min(tstzmultirange) from public, anon, authenticated;
revoke all on function public.outage_history(text, date) from public, anon, authenticated;
revoke all on function public.outage_key_history(text, date) from public, anon, authenticated;
revoke all on function public.outage_app_history(text, date) from public, anon, authenticated;
grant execute on function public.outage_key_history(text, date) to service_role;
grant execute on function public.outage_app_history(text, date) to service_role;

-- прапорець для сторінки: показувати вкладку «Історія» (лише tg_people)
do $do$
declare d text; f text;
begin
  d := pg_get_functiondef('public.outage_app_data_for(text, integer)'::regprocedure);
  if position('''hist''' in d) = 0 then
    f := $q$'bl', case when exists$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'hist'; end if;
    d := replace(d, f, $q$'hist', exists (select 1 from public.tg_people tp where tp.chat_id = chat), 'bl', case when exists$q$);
    execute d;
  end if;
end $do$;
