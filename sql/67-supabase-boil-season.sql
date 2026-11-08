-- 67: сезонний вимикач бойлерів (09.11.2026). Коли є гаряча вода з труби: /bluetti бойлери вимк; навесні: /bluetti бойлери увімк.
-- Ключ стану boil_season ('off' = бойлери на сезон вимкнено). Без нього все працює як раніше.
-- У вимкненому стані: немає автовмикання, відліку, «⏸ …», «⚠️ Висока напруга» лишається; у «Світло з'явилося» немає рядків
-- і кнопки про бойлери; рядки «🚿 Бойлери …» і «🔌 Бойлери вмикались…» зникають зі звітів. Кнопка /boilers працює вручну.

create or replace function public.outage_boil_on() returns boolean
language sql stable security definer set search_path to 'public' as $f$
  select coalesce(public.outage_st_get('boil_season'), 'on') <> 'off'
$f$;

-- Команда бота
do $do$
declare d text; a text := E'  return public.bluetti_text() || E''\\n\\nКерування: /bluetti авто вимк · /bluetti авто увімк'';';
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'bluetti_cmd';
  if position(a in d) = 0 then raise exception 'bluetti_cmd: фрагмент не знайдено'; end if;
  d := replace(d, a, E'  if a ~ ''^(бойлери|boilers|сезон)\\s+(вимк|off|ні|стоп)'' then\n'
    || E'    perform public.outage_st_set(''boil_season'', ''off'');\n    perform public.outage_st_set(''boil_cd'', '''');\n'
    || E'    return ''🚿 Бойлери на сезон вимкнено: не вмикаю їх після відключень, не нагадую й не рахую. Кнопка /boilers працює вручну. Повернути: /bluetti бойлери увімк'';\n'
    || E'  elsif a ~ ''^(бойлери|boilers|сезон)\\s+(увімк|on|так|старт)'' then\n'
    || E'    perform public.outage_st_set(''boil_season'', ''on'');\n'
    || E'    return ''🚿 Бойлери знову в роботі: автовмикання після відключень, підсумки й вартість у ранковому повідомленні.'';\n  end if;\n'
    || E'  return public.bluetti_text() || E''\\n\\nКерування: /bluetti авто вимк · /bluetti авто увімк · /bluetti бойлери вимк|увімк'';');
  execute d;
end $do$;

-- Картка /bluetti
do $do$
declare d text; a text := '''Автовмикання бойлерів: '' || case when coalesce(public.outage_st_get(''boil_auto''), ''on'') = ''off'' then ''вимкнено'' else ''увімкнено'' end';
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'bluetti_text';
  if position(a in d) = 0 then raise exception 'bluetti_text: фрагмент не знайдено'; end if;
  execute replace(d, a, '''Автовмикання бойлерів: '' || case when not public.outage_boil_on() then ''вимкнено на сезон'' when coalesce(public.outage_st_get(''boil_auto''), ''on'') = ''off'' then ''вимкнено'' else ''увімкнено'' end');
end $do$;

-- Автовмикання
do $do$
declare d text; a text := 'autoon := coalesce(public.outage_st_get(''boil_auto''), ''on'') <> ''off'';';
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'outage_pwr_tick';
  if position(a in d) = 0 then raise exception 'outage_pwr_tick: фрагмент не знайдено'; end if;
  execute replace(d, a, 'autoon := coalesce(public.outage_st_get(''boil_auto''), ''on'') <> ''off'' and public.outage_boil_on();');
end $do$;

-- «Світло з'явилося»: без порад і кнопки про бойлери в сезон
create or replace function public.tg_svitlo_msg(kind text, txt text, p_at timestamptz default null) returns text
language sql stable set search_path to 'public', 'extensions' as $f$
  select case when kind = 'on'
    then E'✅ Світло в будинку з\'явилося.\n' || public.tg_svitlo_rest(txt)
      || case when public.outage_early_line(p_at) <> '' then public.outage_early_line(p_at) || E'\n' else '' end
      || case
           when coalesce(public.outage_pwr_src() ->> 'src', '') = 'city'
                and (not public.outage_boil_on() or coalesce(public.outage_st_get('boil_auto'), 'on') <> 'off') then ''
           else E'⚠️ Якщо ви на Bluetti: вимкніть AC, перемкніть щиток на мережу й поставте Bluetti заряджатись.'
                || case when not public.outage_boil_on() then ''
                        when coalesce(public.outage_st_get('boil_auto'), 'on') <> 'off'
                        then E'\n🔌 Бойлери ввімкну сам, щойно побачу, що квартира на мережі.'
                        else E'\n🔌 Кнопку «Увімкнути бойлери» натискайте ТІЛЬКИ ПІСЛЯ цього! ❗️' end
         end
    else E'❌ Світло в будинку зникло.\n' || public.tg_svitlo_rest(txt)
      || E'\n🔋 Якщо треба світло: вийміть вилку зарядки Bluetti, перемкніть щиток на Bluetti, увімкніть AC.' end
$f$;

create or replace function public.tg_svitlo_kb(kind text) returns jsonb
language sql stable security definer set search_path to 'public' as $f$
  select case when kind = 'on' and public.tg_boilers_ready() and public.outage_boil_on()
              and not (coalesce(public.outage_st_get('boil_auto'), 'on') <> 'off' and coalesce(public.outage_pwr_src() ->> 'src', '') = 'city')
    then jsonb_build_array(jsonb_build_array(jsonb_build_object('text', '🔌 Увімкнути бойлери', 'callback_data', 'b:on')))
    else null end
$f$;

-- Звіти
do $do$
declare d text; a text := E'  if (e ->> ''kwh'')::numeric < 0.05 then return ''''; end if;';
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'outage_boil_line';
  if position(a in d) = 0 then raise exception 'outage_boil_line: фрагмент не знайдено'; end if;
  execute replace(d, a, E'  if not public.outage_boil_on() or (e ->> ''kwh'')::numeric < 0.05 then return ''''; end if;');
end $do$;

do $do$
declare d text; a text := '|| E''\n🔌 Бойлери ввімкнено автоматично: '' || n || '' раз(и)''';
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'bluetti_month';
  if position(a in d) = 0 then raise exception 'bluetti_month: фрагмент не знайдено'; end if;
  execute replace(d, a, '|| case when n > 0 then E''\n🔌 Бойлери ввімкнено автоматично: '' || n || '' раз(и)'' else '''' end');
end $do$;
