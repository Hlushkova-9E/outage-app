-- Копія міграцій 48–54 (живлення квартири: бойлери, Bluetti, пришвидшення). Вже застосовано в Supabase 07.11.2026; повторно не запускати.

-- ===== outage_power_48a =====
-- 48a: допоміжні функції автоматики живлення (Bluetti + розетки)
create or replace function public.outage_tg(p_chats text[], p_msg text, p_kb jsonb default null, p_silent boolean default false) returns int
language plpgsql security definer set search_path = public, extensions as $fn$
declare tok text; c text; b jsonb; rid bigint; n int := 0;
begin
  select token into tok from public.tg_settings where id = 1;
  if tok is null or tok like 'ВАШ_%' then return 0; end if;
  foreach c in array coalesce(p_chats, '{}'::text[]) loop
    b := jsonb_build_object('chat_id', c, 'text', left(p_msg, 4000), 'disable_web_page_preview', true, 'disable_notification', coalesce(p_silent, false))
      || case when p_kb is not null then jsonb_build_object('reply_markup', jsonb_build_object('inline_keyboard', p_kb)) else '{}'::jsonb end;
    select net.http_post(url := 'https://api.telegram.org/bot' || tok || '/sendMessage', body := b, timeout_milliseconds := 15000) into rid;
    begin insert into public.tg_outbox (req_id, body) values (rid, b); exception when others then null; end;
    n := n + 1;
  end loop;
  return n;
exception when others then
  raise notice 'outage_tg: %', sqlerrm;
  return n;
end $fn$;

create or replace function public.bluetti_now(p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $fn$
declare r record; k record; l jsonb; dcw numeric;
begin
  select at, online, soc, grid_w, ac_w, raw into r from public.bluetti_log where sn is not null order by at desc limit 1;
  if not found then return jsonb_build_object('has', false); end if;
  select at, soc into k from public.bluetti_log where soc is not null order by at desc limit 1;
  l := coalesce(r.raw -> 'product' -> 'stateList', '[]'::jsonb);
  begin
    dcw := (select nullif(x ->> 'fnValue', '')::numeric from jsonb_array_elements(l) x where x ->> 'fnCode' = 'DCLoadAllTotalPower' limit 1);
  exception when others then dcw := null; end;
  return jsonb_build_object('has', true, 'at', r.at, 'fresh', r.at > p_now - interval '10 minutes',
    'online', coalesce(r.online, false), 'soc', r.soc, 'grid', r.grid_w, 'acw', r.ac_w, 'dcw', dcw,
    'ac', coalesce((select x ->> 'fnValue' from jsonb_array_elements(l) x where x ->> 'fnCode' = 'SetCtrlAc' limit 1) = '1', false),
    'last_soc', k.soc, 'last_soc_at', k.at);
end $fn$;

-- хвилин до кінця поточного відключення за графіком дому (або null)
create or replace function public.outage_home_end(p_now timestamptz default now()) returns int
language plpgsql stable security definer set search_path = public as $fn$
declare g text; sn public.outage_snap%rowtype; tm public.outage_snap%rowtype; r jsonb; d date; m int; a int; b int;
begin
  select grp into g from public.outage_subs where key = 'home';
  d := (p_now at time zone public.tg_tzn())::date;
  m := extract(hour from (p_now at time zone public.tg_tzn()))::int * 60 + extract(minute from (p_now at time zone public.tg_tzn()))::int;
  select * into sn from public.outage_snap where grp = g and day = d;
  if sn.grp is null or sn.status <> 'ScheduleApplies' then return null; end if;
  for r in select x from jsonb_array_elements(sn.rng) x loop
    a := (r ->> 0)::int; b := (r ->> 1)::int;
    if m >= a and m < b then
      if b = 1440 then
        select * into tm from public.outage_snap where grp = g and day = d + 1;
        if tm.grp is not null and tm.status = 'ScheduleApplies' and jsonb_array_length(tm.rng) > 0 and (tm.rng -> 0 ->> 0)::int = 0 then
          b := 1440 + (tm.rng -> 0 ->> 1)::int;
        end if;
      end if;
      return b - m;
    end if;
  end loop;
  return null;
end $fn$;

-- оцінка часу роботи на Bluetti
create or replace function public.bluetti_eta(p_soc numeric, p_load numeric, p_now timestamptz default now()) returns text
language plpgsql stable security definer set search_path = public as $fn$
declare wh numeric := coalesce(nullif(public.outage_st_get('bluetti_wh'), '')::numeric, 2304); mins int; e int;
begin
  if p_soc is null then return ''; end if;
  if coalesce(p_load, 0) < 15 then return ' · навантаження мале, вистачить надовго'; end if;
  mins := floor(p_soc / 100.0 * wh * 0.9 / p_load * 60);
  e := public.outage_home_end(p_now);
  return ' · вистачить ≈ ' || public.outage_dur(mins)
    || case when e is null then ''
            when mins >= e then E'\n🟢 За графіком світло через ' || public.outage_dur(e) || ', має вистачити.'
            else E'\n⚠️ За графіком світло лише через ' || public.outage_dur(e) || ', може не вистачити. Вимкніть зайве.' end;
end $fn$;

-- звідки живиться квартира: dark | bluetti | city | unknown
create or replace function public.outage_pwr_src(p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $fn$
declare dv text := nullif(public.outage_st_get('tuya_dev'), ''); e record; offat timestamptz; onat timestamptz; b jsonb; acon timestamptz; src text; why text;
begin
  select kind, at into e from public.outage_tuya_log where dev = dv order by at desc limit 1;
  select max(at) into offat from public.outage_tuya_log where dev = dv and kind = 'off';
  select min(at) into onat from public.outage_tuya_log where dev = dv and kind = 'on' and at > coalesce(offat, '-infinity'::timestamptz);
  b := public.bluetti_now(p_now);
  if e.kind is null then src := 'unknown'; why := 'немає журналу розеток';
  elsif e.kind = 'off' then src := 'dark'; why := 'розетки без живлення';
  elsif not coalesce((b ->> 'has')::boolean, false) or not coalesce((b ->> 'fresh')::boolean, false) then src := 'unknown'; why := 'немає свіжих даних Bluetti';
  elsif (b ->> 'online')::boolean and (b ->> 'ac')::boolean then src := 'bluetti'; why := 'Bluetti AC увімкнено';
  elsif not (b ->> 'online')::boolean then
    select max(at) into acon from public.bluetti_log
     where online and raw -> 'product' -> 'stateList' @> '[{"fnCode":"SetCtrlAc","fnValue":"1"}]'::jsonb;
    if acon is not null and acon > coalesce(offat, '-infinity'::timestamptz) then
      src := 'unknown'; why := 'Bluetti зник із мережі з увімкненим AC';
    else
      src := 'city'; why := 'Bluetti вимкнено';
    end if;
  else
    src := 'city';
    why := case when coalesce((b ->> 'grid')::numeric, 0) > 0 then 'Bluetti заряджається ' || (b ->> 'grid')::numeric::int || ' Вт' else 'Bluetti AC вимкнено' end;
  end if;
  return jsonb_build_object('src', src, 'why', why, 'off_at', offat, 'on_at', onat, 'b', b);
end $fn$;

-- кнопки бойлерів: b:on, b:now, b:force, b:cancel, b:cmd (команда /boilers)
create or replace function public.outage_boil_action(p_chat text, p_data text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $fn$
declare s jsonb; res jsonb; who text; kbf jsonb; msg text; others text[];
begin
  select name into who from public.tg_people where chat_id = p_chat;
  if p_data = 'b:cancel' then
    if coalesce(public.outage_st_get('boil_cd'), '') = '' then
      return jsonb_build_object('ok', false, 'answer', 'Відлік уже неактивний');
    end if;
    perform public.outage_st_set('boil_cycle', coalesce(nullif(public.outage_st_get('boil_cd_cycle'), ''), public.outage_st_get('boil_cycle')));
    perform public.outage_st_set('boil_cd', '');
    others := array(select chat_id from public.tg_people where chat_id <> p_chat);
    perform public.outage_tg(others, '✖️ Автовмикання бойлерів скасовано' || coalesce(' (' || who || ')', '') || '.', null, true);
    return jsonb_build_object('ok', true, 'answer', 'Скасовано',
      'line', '✖️ Скасовано' || coalesce(' (' || who || ')', '') || '. Коли треба: /boilers');
  end if;
  if p_data <> 'b:force' then
    s := public.outage_pwr_src();
    if s ->> 'src' = 'bluetti' then
      kbf := jsonb_build_array(jsonb_build_array(jsonb_build_object('text', '⚠️ Все одно увімкнути', 'callback_data', 'b:force')));
      msg := E'⛔ Квартира зараз на Bluetti (AC увімкнено, ' || coalesce((s -> 'b' ->> 'acw')::numeric::int, 0) || E' Вт).\nБойлери перевантажать станцію. Вимкніть AC, перемкніть щиток на мережу й поставте Bluetti заряджатись: бойлери ввімкну сам.';
      if p_data = 'b:cmd' then return jsonb_build_object('ok', false, 'text', msg, 'kb', kbf); end if;
      perform public.outage_tg(array[p_chat], msg, kbf, false);
      return jsonb_build_object('ok', false, 'answer', '⛔ Квартира на Bluetti');
    end if;
  end if;
  res := public.tg_boilers_start();
  if coalesce((res ->> 'ok')::boolean, false) then
    perform public.outage_st_set('boil_cycle', coalesce(s ->> 'off_at', (public.outage_pwr_src() ->> 'off_at'), public.outage_st_get('boil_cycle')));
    perform public.outage_st_set('boil_cd', '');
  end if;
  return res;
end $fn$;

-- рядок Bluetti для /світло
create or replace function public.bluetti_line() returns text
language plpgsql stable security definer set search_path = public, extensions as $fn$
declare b jsonb := public.bluetti_now(); tz text := public.tg_tzn(); age int; soc int; ld numeric;
begin
  if not coalesce((b ->> 'has')::boolean, false) then return ''; end if;
  age := greatest(0, extract(epoch from (now() - (b ->> 'at')::timestamptz))::int / 60);
  if not (b ->> 'fresh')::boolean then return E'\n\n🔋 Bluetti: дані недоступні (останні ' || age || ' хв тому)'; end if;
  if not (b ->> 'online')::boolean then
    return E'\n\n🔋 Bluetti вимкнено' || coalesce(' · останній заряд ' || (b ->> 'last_soc')::numeric::int || '% (' || to_char((b ->> 'last_soc_at')::timestamptz at time zone tz, 'DD.MM HH24:MI') || ')', '');
  end if;
  soc := (b ->> 'soc')::numeric::int;
  ld := coalesce((b ->> 'acw')::numeric, 0) + coalesce((b ->> 'dcw')::numeric, 0);
  if (b ->> 'ac')::boolean then
    return E'\n\n🔋 Bluetti живить квартиру: ' || soc || '% · ' || ld::int || ' Вт' || public.bluetti_eta(soc, ld);
  elsif coalesce((b ->> 'grid')::numeric, 0) > 0 then
    return E'\n\n🔋 Bluetti заряджається: ' || soc || '% · +' || (b ->> 'grid')::numeric::int || ' Вт';
  end if;
  return E'\n\n🔋 Bluetti: ' || soc || '% · AC вимкнено';
end $fn$;

-- повна картка /bluetti
create or replace function public.bluetti_text() returns text
language plpgsql stable security definer set search_path = public, extensions as $fn$
declare r record; l jsonb; age int; tz text := public.tg_tzn(); wm text; b jsonb := public.bluetti_now(); st text;
  fv text; sw text;
begin
  if not coalesce((b ->> 'has')::boolean, false) then return 'Даних Bluetti ще немає.'; end if;
  select at, raw into r from public.bluetti_log where soc is not null order by at desc limit 1;
  l := coalesce(r.raw -> 'product' -> 'stateList', '[]'::jsonb);
  age := greatest(0, extract(epoch from (now() - (b ->> 'at')::timestamptz))::int / 60);
  st := case when not (b ->> 'fresh')::boolean then '⚠️ дані недоступні (останні ' || age || ' хв тому)'
             when not (b ->> 'online')::boolean then 'вимкнено (нижче останні відомі дані)'
             when (b ->> 'ac')::boolean then 'живить квартиру'
             when coalesce((b ->> 'grid')::numeric, 0) > 0 then 'заряджається'
             else 'онлайн, AC вимкнено' end;
  wm := (select x ->> 'fnValue' from jsonb_array_elements(l) x where x ->> 'fnCode' = 'SetCtrlWorkMode' limit 1);
  wm := case wm when 'workmode_0' then 'PV Priority UPS' when 'workmode_1' then 'Standard UPS' when 'workmode_2' then 'Time Control UPS' when 'workmode_3' then 'Customized UPS' else coalesce(wm, '—') end;
  if r.at is null then return '🔋 Bluetti AC200PL' || E'\nСтатус: ' || st; end if;
  return '🔋 Bluetti AC200PL' || E'\n'
    || 'Статус: ' || st || ' · дані на ' || to_char(r.at at time zone tz, 'DD.MM HH24:MI') || E'\n'
    || 'Заряд: ' || coalesce((select x ->> 'fnValue' from jsonb_array_elements(l) x where x ->> 'fnCode' = 'SOC'), '—') || ' %' || E'\n'
    || 'Вхід: мережа ' || coalesce((select x ->> 'fnValue' from jsonb_array_elements(l) x where x ->> 'fnCode' = 'GridAllTotalPower'), '—') || ' Вт, сонце ' || coalesce((select x ->> 'fnValue' from jsonb_array_elements(l) x where x ->> 'fnCode' = 'PVAllTotalPower'), '—') || ' Вт' || E'\n'
    || 'Вихід: AC ' || coalesce((select x ->> 'fnValue' from jsonb_array_elements(l) x where x ->> 'fnCode' = 'ACLoadAllTotalPower'), '—') || ' Вт, DC ' || coalesce((select x ->> 'fnValue' from jsonb_array_elements(l) x where x ->> 'fnCode' = 'DCLoadAllTotalPower'), '—') || ' Вт' || E'\n'
    || 'Перемикачі: AC ' || case (select x ->> 'fnValue' from jsonb_array_elements(l) x where x ->> 'fnCode' = 'SetCtrlAc') when '1' then 'увімк.' else 'вимк.' end
    || ', DC ' || case (select x ->> 'fnValue' from jsonb_array_elements(l) x where x ->> 'fnCode' = 'SetCtrlDc') when '1' then 'увімк.' else 'вимк.' end
    || ', AC ECO ' || case (select x ->> 'fnValue' from jsonb_array_elements(l) x where x ->> 'fnCode' = 'SetACECO') when '1' then 'увімк.' else 'вимк.' end
    || ', DC ECO ' || case (select x ->> 'fnValue' from jsonb_array_elements(l) x where x ->> 'fnCode' = 'SetDCECO') when '1' then 'увімк.' else 'вимк.' end || E'\n'
    || 'Режим: ' || wm || E'\n'
    || 'Автовмикання бойлерів: ' || case when coalesce(public.outage_st_get('boil_auto'), 'on') = 'off' then 'вимкнено' else 'увімкнено' end
    || ' · зараз: ' || case public.outage_pwr_src() ->> 'src' when 'city' then '🏙 місто' when 'bluetti' then '🔋 Bluetti' when 'dark' then '⚫ без живлення' else '❔ невідомо' end;
end $fn$;

-- рядок для нагадування «через 30 хв відключення»
create or replace function public.bluetti_remind() returns text
language plpgsql stable security definer set search_path = public as $fn$
declare b jsonb := public.bluetti_now(); s int;
begin
  if not coalesce((b ->> 'has')::boolean, false) or (b ->> 'last_soc') is null then return ''; end if;
  s := (b ->> 'last_soc')::numeric::int;
  return E'\n🔋 Bluetti: ' || case when (b ->> 'online')::boolean and (b ->> 'fresh')::boolean then '' else 'останній ' end || 'заряд ' || s || '%'
    || case when s < 90 then ', варто дозарядити' else '' end;
end $fn$;

revoke all on function public.outage_tg(text[], text, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.bluetti_now(timestamptz) from public, anon, authenticated;
revoke all on function public.outage_home_end(timestamptz) from public, anon, authenticated;
revoke all on function public.bluetti_eta(numeric, numeric, timestamptz) from public, anon, authenticated;
revoke all on function public.outage_pwr_src(timestamptz) from public, anon, authenticated;
revoke all on function public.outage_boil_action(text, text) from public, anon, authenticated;
revoke all on function public.bluetti_remind() from public, anon, authenticated;

-- ===== outage_power_48b =====
-- 48b: щохвилинна автоматика живлення (бойлери + підказки Bluetti). p_dry = true: лише показати, що зробила б.
create or replace function public.outage_ev_new(k text, p_dry boolean default false) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare n int;
begin
  if p_dry then return not exists (select 1 from public.outage_events where key = k); end if;
  insert into public.outage_events (key) values (k) on conflict (key) do nothing;
  get diagnostics n = row_count;
  return n = 1;
end $fn$;
revoke all on function public.outage_ev_new(text, boolean) from public, anon, authenticated;

create or replace function public.outage_pwr_tick(p_now timestamptz default now(), p_dry boolean default false) returns text
language plpgsql security definer set search_path = public, extensions as $fn$
declare
  tz text := public.tg_tzn();
  m int := extract(hour from (p_now at time zone public.tg_tzn()))::int * 60 + extract(minute from (p_now at time zone public.tg_tzn()))::int;
  quiet boolean; chats text[]; admin text[];
  s jsonb; b jsonb; src text; why text; offat timestamptz; onat timestamptz; bat timestamptz; prev text; cyc text;
  autoon boolean; cd timestamptz; cdfrom timestamptz; hold timestamptz;
  soc numeric; ld numeric; online boolean; acon boolean; grid numeric; fresh boolean;
  res jsonb; fn text; sec text; msg text; sv record; lg text := ''; out jsonb := '[]'::jsonb; o jsonb;
  kbcd jsonb := jsonb_build_array(jsonb_build_array(
    jsonb_build_object('text', '⚡ Увімкнути зараз', 'callback_data', 'b:now'),
    jsonb_build_object('text', '✖️ Скасувати', 'callback_data', 'b:cancel')));
  kbon jsonb := jsonb_build_array(jsonb_build_array(jsonb_build_object('text', '🔌 Увімкнути бойлери', 'callback_data', 'b:on')));
begin
  quiet := m < 420;
  chats := array(select chat_id from public.tg_people where public.tg_pref(prefs, 'bluetti', true) order by name);
  admin := array(select chat_id from public.tg_people where name = 'Антон');
  s := public.outage_pwr_src(p_now);
  src := s ->> 'src'; why := s ->> 'why'; b := s -> 'b';
  offat := (s ->> 'off_at')::timestamptz; onat := (s ->> 'on_at')::timestamptz; bat := (b ->> 'at')::timestamptz;
  cyc := coalesce(offat::text, '');
  prev := coalesce(public.outage_st_get('pwr_last'), '');
  autoon := coalesce(public.outage_st_get('boil_auto'), 'on') <> 'off';
  cd := nullif(public.outage_st_get('boil_cd'), '')::timestamptz;
  cdfrom := nullif(public.outage_st_get('boil_cd_from'), '')::timestamptz;
  hold := nullif(public.outage_st_get('boil_hold'), '')::timestamptz;
  fresh := coalesce((b ->> 'fresh')::boolean, false);
  online := coalesce((b ->> 'online')::boolean, false) and fresh;
  acon := coalesce((b ->> 'ac')::boolean, false);
  soc := (b ->> 'soc')::numeric; grid := coalesce((b ->> 'grid')::numeric, 0);
  ld := coalesce((b ->> 'acw')::numeric, 0) + coalesce((b ->> 'dcw')::numeric, 0);
  lg := 'src=' || src || ' (' || why || '); ';

  -- 1. відлік бойлерів: завершення
  if cd is not null then
    if p_now >= cd then
      if (bat is null or bat <= cdfrom) and p_now < cd + interval '4 minutes' then
        lg := lg || 'чекаю свіжих даних Bluetti; ';
      elsif src = 'city' then
        if not p_dry then
          perform public.outage_st_set('boil_cycle', coalesce(nullif(public.outage_st_get('boil_cd_cycle'), ''), cyc));
          perform public.outage_st_set('boil_cd', '');
          res := public.tg_boilers_start();
          if coalesce((res ->> 'ok')::boolean, false) then
            select fn_url, secret into fn, sec from public.tg_settings where id = 1;
            perform net.http_post(url := replace(fn, '/telegram-bot', '/outage-boilers'),
              body := jsonb_build_object('silent', quiet),
              headers := jsonb_build_object('Content-Type', 'application/json', 'X-Telegram-Bot-Api-Secret-Token', sec),
              timeout_milliseconds := 5000);
            out := out || jsonb_build_object('c', chats, 't', '🤖 Автоматично. ' || (res ->> 'text'), 'q', quiet);
          end if;
        end if;
        lg := lg || 'бойлери: вмикаю; ';
      else
        if not p_dry then
          perform public.outage_st_set('boil_cd', '');
          perform public.outage_st_set('boil_hold', (p_now + interval '10 minutes')::text);
        end if;
        if public.outage_ev_new('bhold:' || cyc, p_dry) then
          out := out || jsonb_build_object('c', chats, 'q', quiet, 'kb', case when src = 'bluetti' then null else kbon end,
            't', '⏸ Бойлери поки не вмикаю: ' || why || case src
              when 'bluetti' then '. Ввімкну сам, щойно квартира перейде на мережу.'
              when 'dark' then '. Ввімкну, коли живлення повернеться.'
              else '. Спробую ще раз за 10 хв або натисніть кнопку.' end);
        end if;
        lg := lg || 'бойлери: відкладено; ';
      end if;
    else
      lg := lg || 'відлік до ' || to_char(cd at time zone tz, 'HH24:MI') || '; ';
    end if;
  -- 2. відлік бойлерів: старт
  elsif autoon and src = 'city' and offat is not null and onat is not null
        and onat > p_now - interval '12 hours'
        and cyc <> coalesce(public.outage_st_get('boil_cycle'), '')
        and p_now >= onat + interval '3 minutes' and bat >= onat + interval '3 minutes'
        and (hold is null or p_now >= hold) then
    if not p_dry then
      perform public.outage_st_set('boil_cd', (p_now + interval '5 minutes')::text);
      perform public.outage_st_set('boil_cd_from', p_now::text);
      perform public.outage_st_set('boil_cd_cycle', cyc);
      perform net.http_post(url := 'https://hikzqzdulvekuplolymw.supabase.co/functions/v1/bluetti-poll?force=1', body := '{}'::jsonb, timeout_milliseconds := 20000);
    end if;
    out := out || jsonb_build_object('c', chats, 'q', quiet, 'kb', kbcd,
      't', '🔌 Квартира на мережі (' || why || E').\nВмикаю бойлери о ' || to_char((p_now + interval '5 minutes') at time zone tz, 'HH24:MI') || ' (через 5 хв).');
    lg := lg || 'бойлери: старт відліку; ';
  end if;

  -- 3. квартира перейшла на Bluetti
  if src = 'bluetti' and prev <> 'bluetti' and offat is not null and public.outage_ev_new('bon:' || cyc, p_dry) then
    out := out || jsonb_build_object('c', chats, 'q', quiet,
      't', '🔋 Квартира на Bluetti: ' || coalesce(soc::int::text, '?') || '% · ' || ld::int || ' Вт' || public.bluetti_eta(soc, ld, p_now));
  end if;

  -- 4. низький заряд
  if src = 'bluetti' and soc is not null then
    if soc <= 15 and public.outage_ev_new('b15:' || cyc, p_dry) then
      out := out || jsonb_build_object('c', chats, 'q', false, 't', '🪫 Bluetti ' || soc::int || '% · ' || ld::int || ' Вт' || public.bluetti_eta(soc, ld, p_now) || E'\nВимкніть усе зайве.');
    elsif soc <= 30 and soc > 15 and public.outage_ev_new('b30:' || cyc, p_dry) then
      out := out || jsonb_build_object('c', chats, 'q', quiet, 't', '🔋 Bluetti вже ' || soc::int || '% · ' || ld::int || ' Вт' || public.bluetti_eta(soc, ld, p_now));
    end if;
  end if;

  -- 5. у будинку світло 20 хв, а квартира ще на Bluetti
  select kind, at into sv from public.outage_log order by at desc limit 1;
  if src = 'bluetti' and sv.kind = 'on' and sv.at > coalesce(offat, '-infinity'::timestamptz) and p_now >= sv.at + interval '20 minutes'
     and public.outage_ev_new('brem:' || sv.at, p_dry) then
    out := out || jsonb_build_object('c', chats, 'q', quiet,
      't', '⏰ У будинку світло вже ' || public.outage_dur(extract(epoch from (p_now - sv.at))::int / 60) || E' (СвітлоБот), а квартира ще на Bluetti.\nВимкніть AC → щиток на мережу → Bluetti на зарядку. Бойлери ввімкну сам.');
  end if;

  -- 6. «півбудинку»: щиток на мережі, у сусідів світло, а на вводі напруги немає
  if src = 'dark' and sv.kind = 'on' and online and not acon and grid <= 5 and offat is not null
     and p_now >= offat + interval '5 minutes' and bat > offat + interval '3 minutes'
     and public.outage_ev_new('bhalf:' || cyc, p_dry) then
    out := out || jsonb_build_object('c', chats, 'q', quiet,
      't', E'⚠️ У сусідів світло є, а у вас на вводі напруги немає: розетки без живлення, Bluetti не заряджається.\nСхоже, на вашу половину будинку міська ЕЕ ще не прийшла. Якщо потрібне світло, поверніться на Bluetti.');
  end if;

  -- 7. після перемикання Bluetti не заряджається
  if src = 'city' and online and not acon and soc is not null and soc < 100 and onat is not null and onat <= p_now - interval '15 minutes'
     and (select count(*) from public.bluetti_log where sn is not null and at > p_now - interval '15 minutes') >= 4
     and not exists (select 1 from public.bluetti_log where sn is not null and at > p_now - interval '15 minutes' and (coalesce(grid_w, 0) > 5 or not coalesce(online, false)))
     and public.outage_ev_new('bnochg:' || cyc, p_dry) then
    out := out || jsonb_build_object('c', chats, 'q', quiet, 't', '🔌 Bluetti не заряджається (' || soc::int || '%). Вставте вилку зарядки.');
  end if;

  -- 8. заряджено
  if src = 'city' and online and not acon and soc >= 100 and grid <= 5 and offat is not null
     and exists (select 1 from public.bluetti_log where at > offat and grid_w > 50)
     and public.outage_ev_new('bfull:' || cyc, p_dry) then
    out := out || jsonb_build_object('c', chats, 'q', true, 't', '✅ Bluetti заряджено до 100%. Можна від''єднати від зарядки й вимкнути.');
  end if;

  -- 9. сторож опитування Bluetti (раз на добу, лише Антону)
  if exists (select 1 from public.bluetti_auth where access_token is not null)
     and not exists (select 1 from public.bluetti_log where at > p_now - interval '30 minutes')
     and public.outage_ev_new('bstale:' || (p_now at time zone tz)::date, p_dry) then
    out := out || jsonb_build_object('c', admin, 'q', quiet, 't', '⚠️ Bluetti не опитується понад 30 хв (Edge bluetti-poll або токен). Автовмикання бойлерів чекає даних.');
  end if;

  -- надсилання
  for o in select x from jsonb_array_elements(out) x loop
    if p_dry then
      lg := lg || E'\nMSG' || case when (o ->> 'q')::boolean then ' (тихо)' else '' end || ': ' || (o ->> 't');
    else
      perform public.outage_tg(array(select jsonb_array_elements_text(o -> 'c')), o ->> 't',
        case when jsonb_typeof(o -> 'kb') = 'array' then o -> 'kb' else null end, coalesce((o ->> 'q')::boolean, false));
    end if;
  end loop;

  if not p_dry then
    perform public.outage_st_set('pwr_last', src);
    -- раз на добу чистимо старий журнал Bluetti (30 днів)
    if m between 270 and 275 then
      begin delete from public.bluetti_log where at < p_now - interval '30 days'; exception when others then null; end;
    end if;
  end if;
  return lg;
end $fn$;
revoke all on function public.outage_pwr_tick(timestamptz, boolean) from public, anon, authenticated;

-- ===== outage_power_48b_fix =====
do $do$
declare d text;
begin
  d := pg_get_functiondef('public.outage_pwr_tick(timestamptz, boolean)'::regprocedure);
  if position('#variable_conflict' in d) = 0 then
    d := replace(d, E'AS $function$\ndeclare', E'AS $function$\n#variable_conflict use_column\ndeclare');
    if position('#variable_conflict' in d) = 0 then raise exception 'header not found'; end if;
    execute d;
  end if;
end $do$;

-- ===== outage_power_48c =====
-- 48c: кнопки бойлерів через outage_boil_action, /boilers із запобіжником, текст СвітлоБота, Bluetti в нагадуванні
do $do$
declare d text; f text;
begin
  -- tg_action: усі кнопки b:* іде через запобіжник
  d := pg_get_functiondef('public.tg_action(text, text)'::regprocedure);
  if position('outage_boil_action' in d) = 0 then
    f := $q$if p_data = 'b:on' then return public.tg_boilers_start(); end if;$q$;
    if position(f in d) = 0 then raise exception 'tg_action fragment not found'; end if;
    d := replace(d, f, $q$if p_data like 'b:%' then return public.outage_boil_action(p_chat, p_data); end if;$q$);
    execute d;
  end if;

  -- tg_command: /boilers із запобіжником і кнопкою «Все одно увімкнути»
  d := pg_get_functiondef('public.tg_command(text, text)'::regprocedure);
  if position('outage_boil_action' in d) = 0 then
    f := $q$res := public.tg_boilers_start();$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'tg_command fragment 1 count'; end if;
    d := replace(d, f, $q$res := public.outage_boil_action(p_chat, 'b:cmd');$q$);
    f := $q$'tuya', coalesce((res ->> 'tuya')::boolean, false));$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'tg_command fragment 2 count'; end if;
    d := replace(d, f, $q$'tuya', coalesce((res ->> 'tuya')::boolean, false), 'kb', res -> 'kb');$q$);
    execute d;
  end if;

  -- outage_extra_tick: рядок Bluetti в нагадуванні «через 30 хв» (лише для дому)
  d := pg_get_functiondef('public.outage_extra_tick(timestamptz)'::regprocedure);
  if position('bluetti_remind' in d) = 0 then
    f := $q$' (' || public.outage_dur(b - a) || ')');$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'outage_extra_tick fragment count'; end if;
    d := replace(d, f, $q$' (' || public.outage_dur(b - a) || ')' || case when s.key = 'home' then public.bluetti_remind() else '' end);$q$);
    execute d;
  end if;
end $do$;

-- текст «світло з'явилося» (СвітлоБот): з автовмиканням бойлерів
create or replace function public.tg_svitlo_msg(kind text, txt text) returns text
language sql stable set search_path to 'public', 'extensions' as $fn$
  select case when kind = 'on'
    then E'✅ Світло в будинку з\'явилося.\n' || public.tg_svitlo_rest(txt)
      || E'\n⚠️ Якщо ви на Bluetti: вимкніть AC, перемкніть щиток на мережу й поставте Bluetti заряджатись.'
      || case when coalesce(public.outage_st_get('boil_auto'), 'on') <> 'off'
              then E'\n🔌 Бойлери ввімкну сам, щойно побачу, що квартира на мережі.'
              else E'\n🔌 Кнопку «Увімкнути бойлери» натискайте ТІЛЬКИ ПІСЛЯ цього! ❗️' end
    else E'❌ Світло в будинку зникло.\n' || public.tg_svitlo_rest(txt)
      || E'\n🔋 Якщо треба світло: вийміть вилку зарядки Bluetti, перемкніть щиток на Bluetti, увімкніть AC.' end
$fn$;

-- ===== outage_power_cron_49 =====
select public.outage_st_set('boil_auto', coalesce(nullif(public.outage_st_get('boil_auto'), ''), 'on'));
select public.outage_st_set('bluetti_wh', coalesce(nullif(public.outage_st_get('bluetti_wh'), ''), '2304'));
select public.outage_st_set('pwr_last', public.outage_pwr_src() ->> 'src');
select cron.schedule('bluetti-poll', '*/2 * * * *',
  $$select net.http_post(url := 'https://hikzqzdulvekuplolymw.supabase.co/functions/v1/bluetti-poll', body := '{}'::jsonb, timeout_milliseconds := 20000)$$);
select cron.schedule('outage-power', '* * * * *', $$select public.outage_pwr_tick()$$);

-- ===== outage_power_48d_cmd =====
-- 48d: /bluetti авто вимк | /bluetti авто увімк — вимикач автовмикання бойлерів з чату
create or replace function public.bluetti_cmd(p_arg text) returns text
language plpgsql security definer set search_path = public as $fn$
declare a text := lower(btrim(coalesce(p_arg, '')));
begin
  if a ~ '^(авто|auto)\s+(вимк|off|ні|стоп)' then
    perform public.outage_st_set('boil_auto', 'off');
    perform public.outage_st_set('boil_cd', '');
    return '⏹ Автовмикання бойлерів вимкнено. Лишається кнопка «🔌 Увімкнути бойлери» і /boilers. Увімкнути знову: /bluetti авто увімк';
  elsif a ~ '^(авто|auto)\s+(увімк|on|так|старт)' then
    perform public.outage_st_set('boil_auto', 'on');
    return '▶️ Автовмикання бойлерів увімкнено: після повернення живлення з мережі ввімкну їх через 5 хв (з кнопкою «Скасувати»).';
  end if;
  return public.bluetti_text() || E'\n\nКерування: /bluetti авто вимк · /bluetti авто увімк';
end $fn$;
revoke all on function public.bluetti_cmd(text) from public, anon, authenticated;

do $do$
declare d text; f text;
begin
  d := pg_get_functiondef('public.tg_command(text, text)'::regprocedure);
  if position('bluetti_cmd' in d) = 0 then
    f := $q$'text', public.bluetti_text());$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'bluetti branch count'; end if;
    d := replace(d, f, $q$'text', public.bluetti_cmd(arg));$q$);
    execute d;
  end if;
end $do$;

-- ===== outage_power_monitor_50 =====
do $do$
declare d text; f text;
begin
  -- mon_pulse: сторож для нових розкладів
  d := pg_get_functiondef((select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'mon_pulse' limit 1));
  if position('outage-power' in d) = 0 then
    f := $q$('mon-cleanup', interval '30 hours', false)$q$;
    if position(f in d) = 0 then raise exception 'mon_pulse fragment not found'; end if;
    d := replace(d, f, $q$('mon-cleanup', interval '30 hours', false),
        ('outage-power', interval '15 minutes', true),
        ('bluetti-poll', interval '30 minutes', true)$q$);
    execute d;
  end if;

  -- outage_pwr_tick: зберігання bluetti_log 14 днів, чистка службових ключів, сторож токена Bluetti
  d := pg_get_functiondef('public.outage_pwr_tick(timestamptz, boolean)'::regprocedure);
  if position('btok:' in d) = 0 then
    f := $q$delete from public.bluetti_log where at < p_now - interval '30 days';$q$;
    if position(f in d) = 0 then raise exception 'cleanup fragment not found'; end if;
    d := replace(d, f, $q$delete from public.bluetti_log where at < p_now - interval '14 days';
      delete from public.outage_events where at < p_now - interval '30 days' and key ~ '^(bon|b15|b30|brem|bhalf|bnochg|bfull|bstale|bhold|btok):';$q$);
    f := $q$  -- надсилання$q$;
    if position(f in d) = 0 then raise exception 'send fragment not found'; end if;
    d := replace(d, f, $q$  -- 10. сторож токена Bluetti (раз на добу, лише Антону)
  if exists (select 1 from public.bluetti_auth where access_token is not null and expires_at is not null and expires_at < p_now + interval '3 days')
     and public.outage_ev_new('btok:' || (p_now at time zone tz)::date, p_dry) then
    out := out || jsonb_build_object('c', admin, 'q', quiet, 't', '⚠️ Токен Bluetti спливає '
      || to_char((select a.expires_at from public.bluetti_auth a where a.id = 1) at time zone tz, 'DD.MM HH24:MI')
      || ' і сам не оновився. Треба перепідключити Bluetti (інструкція: tech-overview-bluetti у базі знань).');
  end if;

  -- надсилання$q$);
    execute d;
  end if;
end $do$;

-- ===== outage_faster_51 =====
do $do$
declare d text; f text;
begin
  -- 1. tg_svitlo_tick: одразу переносити нові пости СвітлоБота в журнал сторінки
  d := pg_get_functiondef('public.tg_svitlo_tick()'::regprocedure);
  if position('outage_log_sync' in d) = 0 then
    f := $q$if maxid > lastid then perform public.tg_state_set('svitlo_last', maxid::text); end if;$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'svitlo fragment count'; end if;
    d := replace(d, f, f || $q$
          if maxid > lastid then
            begin perform public.outage_log_sync(); exception when others then null; end;
          end if;$q$);
    execute d;
  end if;

  -- 2. журнал розеток Tuya: з outage_extra_tick (5 хв) переносимо в outage_pwr_tick (щохвилини), запит не частіше ніж раз на ~2 хв
  d := pg_get_functiondef('public.outage_extra_tick(timestamptz)'::regprocedure);
  f := $q$begin lg := lg || public.outage_tuya_tick(p_now); exception when others then lg := lg || 'Tuya: ' || sqlerrm || '; '; end;$q$;
  if position(f in d) > 0 then
    d := replace(d, f, $q$-- журнал розеток Tuya читає outage_pwr_tick (SQL 51)$q$);
    execute d;
  end if;

  d := pg_get_functiondef('public.outage_tuya_tick(timestamptz)'::regprocedure);
  f := $q$fired < p_now - interval '4 minutes'$q$;
  if position(f in d) > 0 then
    d := replace(d, f, $q$fired < p_now - interval '110 seconds'$q$);
    execute d;
  end if;

  d := pg_get_functiondef('public.outage_pwr_tick(timestamptz, boolean)'::regprocedure);
  if position('outage_tuya_tick' in d) = 0 then
    f := $q$  quiet := m < 420;$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'pwr fragment count'; end if;
    d := replace(d, f, $q$  if not p_dry then
    begin perform public.outage_tuya_tick(p_now); exception when others then null; end;
  end if;
$q$ || f);
    execute d;
  end if;
end $do$;

-- 3. канал СвітлоБота читаємо раз на 2 хв
select cron.schedule('svitlo-tick', '*/2 * * * *', $$select public.tg_svitlo_tick()$$);

-- ===== outage_power_fix_52 =====
do $do$
declare d text; f text;
begin
  -- 1. останній відомий заряд беремо лише з онлайн-даних (вимкнений Bluetti віддає 0%)
  d := pg_get_functiondef('public.bluetti_now(timestamptz)'::regprocedure);
  f := $q$select at, soc into k from public.bluetti_log where soc is not null order by at desc limit 1;$q$;
  if position(f in d) > 0 then
    d := replace(d, f, $q$select at, soc into k from public.bluetti_log where soc is not null and online order by at desc limit 1;$q$);
    execute d;
  end if;
  d := pg_get_functiondef('public.bluetti_text()'::regprocedure);
  f := $q$select at, raw into r from public.bluetti_log where soc is not null order by at desc limit 1;$q$;
  if position(f in d) > 0 then
    d := replace(d, f, $q$select at, raw into r from public.bluetti_log where soc is not null and online order by at desc limit 1;$q$);
    execute d;
  end if;

  -- 2. outage_pwr_tick: час переходу на Bluetti (bl_since), повідомлення «на Bluetti» через 5 хв за медіаною навантаження,
  --    нагадування «світло вже N хв» лише якщо СвітлоБот сказав «є» ПІСЛЯ переходу на Bluetti
  d := pg_get_functiondef('public.outage_pwr_tick(timestamptz, boolean)'::regprocedure);
  if position('bl_since' in d) = 0 then
    f := $q$  res jsonb; fn text;$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'declare fragment'; end if;
    d := replace(d, f, $q$  blsince timestamptz := nullif(public.outage_st_get('bl_since'), '')::timestamptz; ldm numeric;
  res jsonb; fn text;$q$);

    f := $q$  if src = 'bluetti' and prev <> 'bluetti' and offat is not null and public.outage_ev_new('bon:' || cyc, p_dry) then
    out := out || jsonb_build_object('c', chats, 'q', quiet,
      't', '🔋 Квартира на Bluetti: ' || coalesce(soc::int::text, '?') || '% · ' || ld::int || ' Вт' || public.bluetti_eta(soc, ld, p_now));
  end if;$q$;
    if position(f in d) = 0 then raise exception 'bon fragment'; end if;
    d := replace(d, f, $q$  if src = 'bluetti' and blsince is not null and p_now >= blsince + interval '5 minutes' and offat is not null
     and public.outage_ev_new('bon:' || cyc, p_dry) then
    select percentile_cont(0.5) within group (order by coalesce(ac_w, 0)) into ldm
      from public.bluetti_log where sn is not null and online and at >= blsince;
    ldm := coalesce(ldm, ld);
    out := out || jsonb_build_object('c', chats, 'q', quiet,
      't', '🔋 Квартира на Bluetti: ' || coalesce(soc::int::text, '?') || '% · зазвичай ~' || ldm::int || ' Вт' || public.bluetti_eta(soc, ldm, p_now));
  end if;$q$);

    f := $q$if src = 'bluetti' and sv.kind = 'on' and sv.at > coalesce(offat, '-infinity'::timestamptz)$q$;
    if position(f in d) = 0 then raise exception 'brem fragment'; end if;
    d := replace(d, f, $q$if src = 'bluetti' and sv.kind = 'on' and blsince is not null and sv.at >= blsince$q$);

    f := $q$    perform public.outage_st_set('pwr_last', src);$q$;
    if position(f in d) = 0 then raise exception 'pwr_last fragment'; end if;
    d := replace(d, f, $q$    if src = 'bluetti' and blsince is null then perform public.outage_st_set('bl_since', p_now::text);
    elsif src in ('city', 'dark') and blsince is not null then perform public.outage_st_set('bl_since', ''); end if;
$q$ || f);
    execute d;
  end if;
end $do$;

-- ===== outage_yasno_4min_53 =====
do $do$
declare d text; f text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'outage_tick' limit 1;
  f := $q$gap := case when waiting and nowt >= time '17:00' then interval '4 minutes' else interval '14 minutes' end;$q$;
  if position(f in d) > 0 then
    d := replace(d, f, $q$gap := interval '230 seconds';  -- SQL 53: YASNO раз на ~4 хв цілодобово (було 14 хв / 4 хв увечері)$q$);
    execute d;
  elsif position('230 seconds' in d) = 0 then
    raise exception 'gap fragment not found';
  end if;
end $do$;
select cron.schedule('outage-tick', '*/2 * * * *', $$select public.outage_tick()$$);

-- ===== outage_extras_54 =====
-- 54: колонка ac у bluetti_log (щоб зберігати історію без raw), хвилини до наступного відключення, Bluetti в ранку і звіті
alter table public.bluetti_log add column if not exists ac boolean;
update public.bluetti_log set ac = coalesce(raw -> 'product' -> 'stateList' @> '[{"fnCode":"SetCtrlAc","fnValue":"1"}]'::jsonb, false) where ac is null;
create or replace function public.bluetti_log_ac() returns trigger
language plpgsql set search_path = public as $fn$
begin
  if new.ac is null then
    new.ac := coalesce(new.raw -> 'product' -> 'stateList' @> '[{"fnCode":"SetCtrlAc","fnValue":"1"}]'::jsonb, false);
  end if;
  return new;
end $fn$;
drop trigger if exists bluetti_log_ac on public.bluetti_log;
create trigger bluetti_log_ac before insert on public.bluetti_log for each row execute function public.bluetti_log_ac();

-- хвилин до початку наступного відключення дому за графіком (null, якщо зараз відключення або даних немає)
create or replace function public.outage_home_next(p_now timestamptz default now()) returns int
language plpgsql stable security definer set search_path = public as $fn$
declare g text; sn public.outage_snap%rowtype; tm public.outage_snap%rowtype; r jsonb; d date; m int; best int;
begin
  select grp into g from public.outage_subs where key = 'home';
  d := (p_now at time zone public.tg_tzn())::date;
  m := extract(hour from (p_now at time zone public.tg_tzn()))::int * 60 + extract(minute from (p_now at time zone public.tg_tzn()))::int;
  select * into sn from public.outage_snap where grp = g and day = d;
  if sn.grp is null or sn.status <> 'ScheduleApplies' then return null; end if;
  for r in select x from jsonb_array_elements(sn.rng) x loop
    if (r ->> 0)::int <= m and (r ->> 1)::int > m then return null; end if;
    if (r ->> 0)::int > m and (best is null or (r ->> 0)::int - m < best) then best := (r ->> 0)::int - m; end if;
  end loop;
  if best is null then
    select * into tm from public.outage_snap where grp = g and day = d + 1;
    if tm.grp is not null and tm.status = 'ScheduleApplies' and jsonb_array_length(tm.rng) > 0 then
      best := 1440 - m + (tm.rng -> 0 ->> 0)::int;
    end if;
  end if;
  return best;
end $fn$;

-- рядок Bluetti для ранкового графіка
create or replace function public.bluetti_morning(p_day date) returns text
language plpgsql stable security definer set search_path = public as $fn$
declare b jsonb := public.bluetti_now(); s numeric; typ numeric; wh numeric := coalesce(nullif(public.outage_st_get('bluetti_wh'), '')::numeric, 2304);
  mins int; g text; sn public.outage_snap%rowtype; r jsonb; mx int := 0; ma int; mb int;
begin
  if not coalesce((b ->> 'has')::boolean, false) or (b ->> 'last_soc') is null then return ''; end if;
  s := (b ->> 'last_soc')::numeric;
  select percentile_cont(0.5) within group (order by ac_w) into typ
    from public.bluetti_log where sn is not null and online and ac and ac_w > 0 and at > now() - interval '14 days';
  typ := greatest(coalesce(typ, 200), 30);
  mins := floor(s / 100.0 * wh * 0.9 / typ * 60);
  select grp into g from public.outage_subs where key = 'home';
  select * into sn from public.outage_snap where grp = g and day = p_day;
  if sn.grp is not null and sn.status = 'ScheduleApplies' then
    for r in select x from jsonb_array_elements(sn.rng) x loop
      if (r ->> 1)::int - (r ->> 0)::int > mx then mx := (r ->> 1)::int - (r ->> 0)::int; ma := (r ->> 0)::int; mb := (r ->> 1)::int; end if;
    end loop;
  end if;
  return E'\n\n🔋 Bluetti: ' || case when (b ->> 'online')::boolean and (b ->> 'fresh')::boolean then 'заряд ' else 'останній заряд ' end || s::int || '%'
    || ' · при звичному навантаженні ~' || typ::int || ' Вт вистачить ≈ ' || public.outage_dur(mins)
    || case when mx > 0 then E'\nНайдовше відключення ' || public.outage_hm(ma) || '–' || public.outage_hm(mb % 1440) || ' (' || public.outage_dur(mx) || '): '
         || case when mins >= mx then 'має вистачити' else '⚠️ може не вистачити' end
       else '' end;
end $fn$;

-- блок Bluetti для звіту за місяць
create or replace function public.bluetti_month(p_month date default null) returns text
language plpgsql stable security definer set search_path = public as $fn$
declare d0 timestamptz; d1 timestamptz; secs numeric; kwh numeric; n int;
begin
  d0 := (date_trunc('month', coalesce(p_month, (now() at time zone public.tg_tzn())::date))::date)::timestamp at time zone public.tg_tzn();
  d1 := ((date_trunc('month', coalesce(p_month, (now() at time zone public.tg_tzn())::date)) + interval '1 month')::date)::timestamp at time zone public.tg_tzn();
  with r as (
    select at, ac, coalesce(ac_w, 0) w, lead(at) over (order by at) nat
      from public.bluetti_log where sn is not null and online and at >= d0 and at < d1)
  select sum(least(extract(epoch from (nat - at)), 300)) filter (where ac),
         sum(w * least(extract(epoch from (nat - at)), 300)) filter (where ac) / 3600000.0
    into secs, kwh from r where nat is not null;
  select count(*) into n from public.outage_events where key like 'bauto:%' and at >= d0 and at < d1;
  if coalesce(secs, 0) < 60 and n = 0 then return ''; end if;
  return E'\n\n🔋 Bluetti: квартира на Bluetti ≈ ' || public.outage_dur(coalesce(secs, 0)::int / 60)
    || ', віддано ≈ ' || round(coalesce(kwh, 0), 1) || ' кВт·год'
    || E'\n🔌 Бойлери ввімкнено автоматично: ' || n || ' раз(и)';
end $fn$;

revoke all on function public.outage_home_next(timestamptz) from public, anon, authenticated;
revoke all on function public.bluetti_morning(date) from public, anon, authenticated;
revoke all on function public.bluetti_month(date) from public, anon, authenticated;
revoke all on function public.bluetti_log_ac() from public, anon, authenticated;

do $do$
declare d text; f text;
begin
  -- outage_pwr_tick: нагадування зарядити Bluetti, облік автовмикань, нова чистка (40 днів, raw лише 2 дні)
  d := pg_get_functiondef('public.outage_pwr_tick(timestamptz, boolean)'::regprocedure);
  if position('bchg:' in d) = 0 then
    f := $q$ldm numeric;$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'decl'; end if;
    d := replace(d, f, $q$ldm numeric; nx int;$q$);
    f := $q$            select fn_url, secret into fn, sec from public.tg_settings where id = 1;$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'fire'; end if;
    d := replace(d, f, $q$            perform public.outage_ev_new('bauto:' || p_now::text);
$q$ || f);
    f := $q$  -- 10. сторож токена Bluetti$q$;
    if position(f in d) = 0 then raise exception 'b10'; end if;
    d := replace(d, f, $q$  -- 11. за ~1 год до відключення Bluetti заряджений менше 90 % і не на зарядці
  nx := public.outage_home_next(p_now);
  if src = 'city' and nx between 45 and 75 and (b ->> 'last_soc') is not null and (b ->> 'last_soc')::numeric < 90
     and not (online and grid > 5)
     and public.outage_ev_new('bchg:' || to_char((p_now + make_interval(mins => nx)) at time zone tz, 'YYYY-MM-DD HH24:MI'), p_dry) then
    out := out || jsonb_build_object('c', chats, 'q', quiet,
      't', '🔌 Через ' || public.outage_dur(nx) || ' відключення за графіком, а Bluetti заряджений на ' || (b ->> 'last_soc')::numeric::int
        || E'%.\nПоставте його на зарядку, поки є світло.');
  end if;

$q$ || f);
    f := $q$delete from public.bluetti_log where at < p_now - interval '14 days';$q$;
    if position(f in d) = 0 then raise exception 'cleanup'; end if;
    d := replace(d, f, $q$delete from public.bluetti_log where at < p_now - interval '40 days';
      update public.bluetti_log set raw = null where at < p_now - interval '2 days' and raw is not null;$q$);
    d := replace(d, $q$bnochg|bfull|bstale|bhold|btok):$q$, $q$bnochg|bfull|bstale|bhold|btok|bchg):$q$);
    execute d;
  end if;

  -- outage_pwr_src: стан AC з колонки ac (raw чиститься через 2 дні)
  d := pg_get_functiondef('public.outage_pwr_src(timestamptz)'::regprocedure);
  f := $q$where online and raw -> 'product' -> 'stateList' @> '[{"fnCode":"SetCtrlAc","fnValue":"1"}]'::jsonb;$q$;
  if position(f in d) > 0 then d := replace(d, f, $q$where online and ac;$q$); execute d; end if;

  -- ранковий графік 07:30: рядок Bluetti
  d := pg_get_functiondef('public.outage_extra_tick(timestamptz)'::regprocedure);
  if position('bluetti_morning' in d) = 0 then
    f := $q$'☀️ Світло сьогодні, ' || public.outage_day_label(today) || E'\n\n' || body);$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'morning'; end if;
    d := replace(d, f, $q$'☀️ Світло сьогодні, ' || public.outage_day_label(today) || E'\n\n' || body || public.bluetti_morning(today));$q$);
    f := $q$c := public.outage_month_text(pm);$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'month'; end if;
    d := replace(d, f, $q$c := public.outage_month_text(pm) || public.bluetti_month(pm);$q$);
    execute d;
  end if;

  -- /світло звіт: блок Bluetti
  d := pg_get_functiondef('public.tg_command(text, text)'::regprocedure);
  if position('bluetti_month' in d) = 0 then
    f := $q$public.outage_month_text(null))$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'cmd month'; end if;
    d := replace(d, f, $q$public.outage_month_text(null) || public.bluetti_month(null))$q$);
    execute d;
  end if;

  -- СвітлоБот: час останнього успішного читання каналу
  d := pg_get_functiondef('public.tg_svitlo_tick()'::regprocedure);
  if position('svitlo_ok' in d) = 0 then
    f := $q$if resp.status_code = 200 and resp.content is not null then$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'svitlo'; end if;
    d := replace(d, f, f || $q$
        perform public.tg_state_set('svitlo_ok', now()::text);$q$);
    execute d;
  end if;

  -- сторінка (будинкова версія): остання подія СвітлоБота й час останнього читання
  d := pg_get_functiondef((select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'outage_house_core' limit 1));
  if position('sb_last' in d) = 0 then
    f := $q$'week_max', 1, 'subs', subs);$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'house core'; end if;
    d := replace(d, f, $q$'week_max', 1, 'subs', subs,
                            'sb_last', (select jsonb_build_object('kind', l.kind, 'at', (extract(epoch from l.at) * 1000)::bigint) from public.outage_log l order by l.at desc limit 1),
                            'sb_ok', (select (extract(epoch from nullif(t.val, '')::timestamptz) * 1000)::bigint from public.tg_state t where t.key = 'svitlo_ok'));$q$);
    execute d;
  end if;
end $do$;

-- ===== outage_extras_54b_fix =====
do $do$
declare d text;
begin
  d := pg_get_functiondef('public.bluetti_morning(date)'::regprocedure);
  d := replace(d, 'sn public.outage_snap%rowtype', 'snp public.outage_snap%rowtype');
  d := replace(d, 'select * into sn from', 'select * into snp from');
  d := replace(d, 'if sn.grp is not null and sn.status', 'if snp.grp is not null and snp.status');
  d := replace(d, 'jsonb_array_elements(sn.rng)', 'jsonb_array_elements(snp.rng)');
  execute d;
end $do$;
