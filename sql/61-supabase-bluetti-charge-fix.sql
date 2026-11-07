-- 61: виправлення SQL 60 (07.11.2026): «наступне відключення» для зарядки Bluetti має братися за початком наступного планового відключення,
-- навіть якщо за графіком зараз іде інше (outage_home_next у такому разі повертає null).
create or replace function public.outage_next_start(p_now timestamptz default now()) returns integer
language plpgsql stable security definer set search_path to 'public' as $f$
declare g text; sn public.outage_snap%rowtype; tm public.outage_snap%rowtype; r jsonb; d date; m int; best int;
begin
  select grp into g from public.outage_subs where key = 'home';
  d := (p_now at time zone public.tg_tzn())::date;
  m := extract(hour from (p_now at time zone public.tg_tzn()))::int * 60 + extract(minute from (p_now at time zone public.tg_tzn()))::int;
  select * into sn from public.outage_snap where grp = g and day = d;
  if sn.grp is null or sn.status <> 'ScheduleApplies' then return null; end if;
  for r in select x from jsonb_array_elements(sn.rng) x loop
    if (r ->> 0)::int > m and (best is null or (r ->> 0)::int - m < best) then best := (r ->> 0)::int - m; end if;
  end loop;
  if best is null then
    select * into tm from public.outage_snap where grp = g and day = d + 1;
    if tm.grp is not null and tm.status = 'ScheduleApplies' and jsonb_array_length(tm.rng) > 0 then
      best := 1440 - m + (tm.rng -> 0 ->> 0)::int;
    end if;
  end if;
  return best;
end $f$;

do $do$
declare d text;
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'bluetti_charge_text';
  if position('nx int := public.outage_home_next(p_now)' in d) = 0 then raise exception 'bluetti_charge_text: фрагмент не знайдено'; end if;
  execute replace(d, 'nx int := public.outage_home_next(p_now)', 'nx int := public.outage_next_start(p_now)');
end $do$;

do $do$
declare d text;
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'outage_pwr_tick';
  if position('declare v_c jsonb := public.bluetti_charge(p_now); v_pred numeric;' in d) = 0
     or position('if src = ''city'' and v_c is not null and nx is not null and nx <= 180 and nx < (v_c ->> ''to100'')::int then' in d) = 0 then
    raise exception 'outage_pwr_tick: фрагмент не знайдено';
  end if;
  d := replace(d, 'declare v_c jsonb := public.bluetti_charge(p_now); v_pred numeric;', 'declare v_c jsonb := public.bluetti_charge(p_now); v_pred numeric; v_nx int := public.outage_next_start(p_now);');
  d := replace(d, 'if src = ''city'' and v_c is not null and nx is not null and nx <= 180 and nx < (v_c ->> ''to100'')::int then', 'if src = ''city'' and v_c is not null and v_nx is not null and v_nx <= 180 and v_nx < (v_c ->> ''to100'')::int then');
  d := replace(d, 'v_pred := least(100, (v_c ->> ''soc'')::numeric + (v_c ->> ''rate'')::numeric * nx);', 'v_pred := least(100, (v_c ->> ''soc'')::numeric + (v_c ->> ''rate'')::numeric * v_nx);');
  d := replace(d, 'outage_ev_new(''bslow:'' || to_char((p_now + make_interval(mins => nx)) at time zone tz,', 'outage_ev_new(''bslow:'' || to_char((p_now + make_interval(mins => v_nx)) at time zone tz,');
  d := replace(d, 'зарядиться до відключення о '' || to_char((p_now + make_interval(mins => nx)) at time zone tz,', 'зарядиться до відключення о '' || to_char((p_now + make_interval(mins => v_nx)) at time zone tz,');
  execute d;
end $do$;
