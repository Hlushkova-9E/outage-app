-- 60: час до кінця зарядки Bluetti на сторінці й підказка в Telegram «не встигне зарядитись до відключення» (07.11.2026)
-- Таблиць не чіпає. Нові функції: bluetti_charge, bluetti_charge_text. Змінює: bluetti_app (поле eta), outage_pwr_tick (блок 13).
-- Швидкість зарядки: нахил заряду за останні ~20 хв, а якщо даних мало, то з потужності з мережі (ККД 0.92, ємність bluetti_wh = 2304 Вт·год).

create or replace function public.bluetti_charge(p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $f$
declare b jsonb := public.bluetti_now(); v_soc numeric; v_chg numeric; v_rate numeric; v_wh numeric := coalesce(nullif(public.outage_st_get('bluetti_wh'), '')::numeric, 2304);
  v_n int; v_span numeric; v_d numeric; v_slope numeric;
begin
  if not (coalesce((b ->> 'online')::boolean, false) and coalesce((b ->> 'fresh')::boolean, false)) then return null; end if;
  v_soc := (b ->> 'soc')::numeric;
  v_chg := coalesce((b ->> 'grid')::numeric, 0) - coalesce((b ->> 'acw')::numeric, 0);
  if v_soc is null or v_soc >= 100 or v_chg <= 200 then return null; end if;
  select count(*), extract(epoch from (max(at) - min(at))) / 60, max(soc) - min(soc), regr_slope(soc, extract(epoch from at) / 60)
    into v_n, v_span, v_d, v_slope
    from public.bluetti_log where sn is not null and online and at > p_now - interval '20 minutes' and coalesce(grid_w, 0) - coalesce(ac_w, 0) > 200;
  if v_n >= 6 and v_span >= 8 and v_d >= 2 and v_slope > 0.1 then v_rate := v_slope;
  else v_rate := v_chg * 0.92 / v_wh * 100 / 60; end if;
  if v_rate <= 0 then return null; end if;
  return jsonb_build_object('soc', v_soc, 'rate', round(v_rate, 3), 'to100', ceil((100 - v_soc) / v_rate)::int, 'grid', (b ->> 'grid')::numeric);
end $f$;

-- Текст для плашки сторінки: час до 100 % і попередження, якщо не встигне до відключення
create or replace function public.bluetti_charge_text(p_now timestamptz default now()) returns text
language plpgsql stable security definer set search_path to 'public' as $f$
declare c jsonb := public.bluetti_charge(p_now); nx int := public.outage_home_next(p_now); tz text := public.tg_tzn(); pred numeric; t text;
begin
  if c is null then return null; end if;
  t := 'зарядиться до 100% ≈ о ' || to_char((p_now + make_interval(mins => (c ->> 'to100')::int)) at time zone tz, 'HH24:MI')
       || ' (через ' || public.outage_dur((c ->> 'to100')::int) || ')';
  if nx is not null and nx < (c ->> 'to100')::int then
    pred := least(100, (c ->> 'soc')::numeric + (c ->> 'rate')::numeric * nx);
    t := t || E'\n⚠️ До відключення о ' || to_char((p_now + make_interval(mins => nx)) at time zone tz, 'HH24:MI') || ' (через ' || public.outage_dur(nx) || ') буде ≈ ' || round(pred)::int || '%'
         || case when (c ->> 'grid')::numeric <= 1600 then '. Можна перейти на «Турбо»' else '' end;
  end if;
  return t;
end $f$;

-- bluetti_app: поле eta для режиму «місто» (заряджається) бере цей текст
do $do$
declare d text;
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'bluetti_app';
  if position('''eta'', case when s ->> ''src'' = ''bluetti'' and' in d) = 0 then raise exception 'bluetti_app: фрагмент не знайдено'; end if;
  execute replace(d, '''eta'', case when s ->> ''src'' = ''bluetti'' and', '''eta'', case when s ->> ''src'' <> ''bluetti'' then public.bluetti_charge_text(now()) when s ->> ''src'' = ''bluetti'' and');
end $do$;

-- outage_pwr_tick: блок 13, раз на відключення «не встигне зарядитись до відключення»
do $do$
declare d text; blk text; anchor text := '  -- 10. сторож токена Bluetti (раз на добу, лише Антону)';
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'outage_pwr_tick';
  if position(anchor in d) = 0 then raise exception 'outage_pwr_tick: фрагмент не знайдено'; end if;
  blk := $b$  -- 13. заряджається, але до відключення за графіком не встигне зарядитись (SQL 60)
  declare v_c jsonb := public.bluetti_charge(p_now); v_pred numeric;
  begin
    if src = 'city' and v_c is not null and nx is not null and nx <= 180 and nx < (v_c ->> 'to100')::int then
      v_pred := least(100, (v_c ->> 'soc')::numeric + (v_c ->> 'rate')::numeric * nx);
      if v_pred < 90 and public.outage_ev_new('bslow:' || to_char((p_now + make_interval(mins => nx)) at time zone tz, 'YYYY-MM-DD HH24:MI'), p_dry) then
        out := out || jsonb_build_object('c', chats, 'q', quiet,
          't', '🐢 З поточною швидкістю Bluetti зарядиться до відключення о ' || to_char((p_now + make_interval(mins => nx)) at time zone tz, 'HH24:MI')
            || ' лише до ≈ ' || round(v_pred)::int || '% (до 100% ще ~' || public.outage_dur((v_c ->> 'to100')::int) || ').'
            || case when (v_c ->> 'grid')::numeric <= 1600 then E'\nПерейдіть у застосунку Bluetti на режим зарядки «Турбо».' else '' end);
      end if;
    end if;
  end;

$b$;
  execute replace(d, anchor, blk || anchor);
end $do$;
