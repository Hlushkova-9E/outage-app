-- 59: менше шуму в повідомленнях про повернення світла й вмикання бойлерів (07.11.2026)
-- 1) «Світло з'явилося» без порад і без кнопки, якщо квартира вже на мережі (і автовмикання увімкнене);
-- 2) до «Світло з'явилося» додається рядок «🎉 Раніше за графік…», а окреме «ДАЛИ РАНІШЕ ЗА ГРАФІК» більше не йде Антону й Ксенії;
-- 3) прибрано окреме «🤖 Автоматично. 🔌 Вмикаю…» (підсумок надсилає Edge outage-boilers v3).
-- Таблиць не чіпає, змінює лише функції tg_svitlo_msg, tg_svitlo_kb, tg_svitlo_tick, outage_fact, outage_pwr_tick.

-- Рядок «раніше за графік» для моменту p_at (порожній, якщо це не так)
create or replace function public.outage_early_line(p_at timestamptz) returns text
language plpgsql stable security definer set search_path to 'public' as $f$
declare h public.outage_subs%rowtype; sn public.outage_snap%rowtype; loc timestamp; m int; a int; b int;
begin
  if p_at is null then return ''; end if;
  select * into h from public.outage_subs where active and svitlo order by key limit 1;
  if not found then return ''; end if;
  loc := p_at at time zone public.tg_tzn();
  m := extract(hour from loc)::int * 60 + extract(minute from loc)::int;
  select * into sn from public.outage_snap where grp = h.grp and day = loc::date;
  if not found or sn.status <> 'ScheduleApplies' then return ''; end if;
  select (x->>0)::int, (x->>1)::int into a, b from jsonb_array_elements(sn.rng) x where m >= (x->>0)::int and m < (x->>1)::int limit 1;
  if a is not null and b - m >= 15 then
    return '🎉 Раніше за графік: за графіком до ' || public.outage_hm(b) || ' (на ' || public.outage_dur(b - m) || ' раніше)';
  end if;
  return '';
end $f$;

-- Текст «Світло з'явилося / зникло»; третій параметр — час події СвітлоБота
drop function if exists public.tg_svitlo_msg(text, text);
create or replace function public.tg_svitlo_msg(kind text, txt text, p_at timestamptz default null) returns text
language sql stable set search_path to 'public', 'extensions' as $f$
  select case when kind = 'on'
    then E'✅ Світло в будинку з\'явилося.\n' || public.tg_svitlo_rest(txt)
      || case when public.outage_early_line(p_at) <> '' then public.outage_early_line(p_at) || E'\n' else '' end
      || case
           when coalesce(public.outage_st_get('boil_auto'), 'on') <> 'off'
                and coalesce(public.outage_pwr_src() ->> 'src', '') = 'city' then ''
           else E'⚠️ Якщо ви на Bluetti: вимкніть AC, перемкніть щиток на мережу й поставте Bluetti заряджатись.'
                || case when coalesce(public.outage_st_get('boil_auto'), 'on') <> 'off'
                        then E'\n🔌 Бойлери ввімкну сам, щойно побачу, що квартира на мережі.'
                        else E'\n🔌 Кнопку «Увімкнути бойлери» натискайте ТІЛЬКИ ПІСЛЯ цього! ❗️' end
         end
    else E'❌ Світло в будинку зникло.\n' || public.tg_svitlo_rest(txt)
      || E'\n🔋 Якщо треба світло: вийміть вилку зарядки Bluetti, перемкніть щиток на Bluetti, увімкніть AC.' end
$f$;

-- Кнопка «Увімкнути бойлери» не потрібна, якщо квартира вже на мережі й автовмикання працює
create or replace function public.tg_svitlo_kb(kind text) returns jsonb
language sql stable security definer set search_path to 'public' as $f$
  select case when kind = 'on' and public.tg_boilers_ready()
              and not (coalesce(public.outage_st_get('boil_auto'), 'on') <> 'off' and coalesce(public.outage_pwr_src() ->> 'src', '') = 'city')
    then jsonb_build_array(jsonb_build_array(jsonb_build_object('text', '🔌 Увімкнути бойлери', 'callback_data', 'b:on')))
    else null end
$f$;

-- tg_svitlo_tick: передаємо час події у tg_svitlo_msg
do $do$
declare d text;
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'tg_svitlo_tick';
  if position('public.tg_svitlo_msg(m.kind, m.txt)' in d) = 0 then raise exception 'tg_svitlo_tick: фрагмент не знайдено'; end if;
  execute replace(d, 'public.tg_svitlo_msg(m.kind, m.txt)', 'public.tg_svitlo_msg(m.kind, m.txt, m.at)');
end $do$;

-- outage_fact: «ДАЛИ РАНІШЕ ЗА ГРАФІК» не надсилаємо Антону й Ксенії (вони бачать цей рядок у «Світло з'явилося»), крім випадку «лінія без напруги»
do $do$
declare d text;
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'outage_fact';
  if position('txt text; ok boolean; offm int;' in d) = 0
     or position('txt := null;' in d) = 0
     or position('txt := ''🎉 СВІТЛО ДАЛИ' in d) = 0
     or position('if txt is not null then msgs := public.outage_add(msgs, chats, txt); end if;' in d) = 0 then
    raise exception 'outage_fact: фрагмент не знайдено';
  end if;
  d := replace(d, 'txt text; ok boolean; offm int;', 'txt text; ok boolean; offm int; early boolean := false;');
  d := replace(d, 'txt := null;', 'txt := null; early := false;');
  d := replace(d, 'txt := ''🎉 СВІТЛО ДАЛИ', 'early := true; txt := ''🎉 СВІТЛО ДАЛИ');
  d := replace(d, 'if txt is not null then msgs := public.outage_add(msgs, chats, txt); end if;',
    'if txt is not null then msgs := public.outage_add(msgs, case when early and not coalesce(public.outage_line_dead(), false) then array(select c from unnest(chats) c where c not in (select t.chat_id from public.tg_targets() t where public.tg_pref(t.prefs, ''svitlo'', true))) else chats end, txt); end if;');
  execute d;
end $do$;

-- outage_pwr_tick: прибираємо «🤖 Автоматично. 🔌 Вмикаю…» (підсумок надсилає Edge)
do $do$
declare d text;
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'outage_pwr_tick';
  if position('out := out || jsonb_build_object(''c'', chats, ''t'', ''🤖 Автоматично. '' || (res ->> ''text''), ''q'', quiet);' in d) = 0 then
    raise exception 'outage_pwr_tick: фрагмент не знайдено';
  end if;
  execute replace(d, 'out := out || jsonb_build_object(''c'', chats, ''t'', ''🤖 Автоматично. '' || (res ->> ''text''), ''q'', quiet);', 'null;');
end $do$;
