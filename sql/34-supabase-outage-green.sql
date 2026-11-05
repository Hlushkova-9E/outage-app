-- Бот відключень: «зелені» години (коли світло є) у повідомленнях про графік, підпис «Підтверджено YASNO · оновлено ДД.ММ ГГ:ХХ».
-- Supabase -> SQL Editor -> New query -> вставити весь файл -> Run. Можна запускати повторно. Виконувати після 33.
-- Нова outage_msg2 (текст повідомлень «графік на завтра», «змінився», з часом оновлення YASNO); стара outage_msg лишається обгорткою без часу
-- (її викликають outage_tick і outage_test). outage_apply переходить на outage_msg2 (заміна тексту через pg_get_functiondef). Таблиці й розклад не чіпає.
-- Формат: червоні й зелені проміжки йдуть підряд за часом доби, далі «Без світла» і «Зі світлом»,
-- «Можливі» (жовті) окремим рядком, у «ЗМІНИВСЯ» ще «Було: …». Екстрені, «не підтверджено» й порожній графік без змін.

create or replace function public.outage_msg2(kind text, title text, grp text, show_grp boolean, d date, today date, st text, rng jsonb, pos jsonb, old_rng jsonb, p_upd text)
 returns text
 language plpgsql
 stable
 set search_path to 'public', 'extensions'
as $function$
declare
  dayw text := case when d = today + 1 then 'ЗАВТРА' when d = today then 'СЬОГОДНІ' else to_char(d, 'DD.MM') end;
  head text; body text := '';
  sub text := title || case when show_grp then ' · група ' || grp else '' end || ' · ' || public.outage_day_label(d);
begin
  head := case kind
    when 'new' then '🔔 ГРАФІК НА ' || dayw
    when 'chg' then '🔄 ГРАФІК ЗМІНИВСЯ · ' || dayw
    when 'emg' then '🚨 ЕКСТРЕНІ ВІДКЛЮЧЕННЯ · ' || dayw
    when 'back' then '✅ ЕКСТРЕНІ СКАСОВАНО · ' || dayw
    when 'pend' then '⏳ ГРАФІК НА ' || dayw || ' НЕ ПІДТВЕРДЖЕНО'
    else 'ℹ️ СТАТУС ГРАФІКА ЗМІНИВСЯ · ' || dayw end;

  if kind = 'pend' then
    body := 'Очікуємо оновлення YASNO. Напишу, щойно зʼявиться.';
    if jsonb_array_length(coalesce(rng, '[]'::jsonb)) > 0 then
      body := body || E'\n\nПопередньо (не підтверджено):\n' || public.outage_lines(rng, '⚪️');
    end if;
  elsif st like 'Emergency%' then
    body := 'Графік не діє, світло можуть вимикати будь-коли.';
  elsif st = 'WaitingForSchedule' then
    body := '⏳ Не підтверджено, очікуємо графік від YASNO.';
  elsif st = 'ScheduleApplies' then
    if jsonb_array_length(coalesce(rng, '[]'::jsonb)) = 0 and jsonb_array_length(coalesce(pos, '[]'::jsonb)) = 0 then
      body := '🟢 Відключень не заплановано';
    else
      if jsonb_array_length(rng) > 0 then
        body := (select string_agg(case z.t when 'r' then '🔴' else '🟢' end || ' ' || public.outage_hm(z.a) || '–' || public.outage_hm(z.b)
                                   || ' · ' || public.outage_dur(z.b - z.a), E'\n' order by z.a, z.b)
                   from (
                     select (x->>0)::int as a, (x->>1)::int as b, 'r' as t from jsonb_array_elements(rng) x
                     union all
                     select q.ga, q.gb, 'g'
                       from (select p.b as ga, lead(p.a) over (order by p.a, p.b) as gb
                               from (select 0 as a, 0 as b
                                     union all select (x->>0)::int, (x->>1)::int from jsonb_array_elements(rng) x
                                     union all select 1440, 1440) p) q
                      where q.gb > q.ga
                   ) z)
              || E'\n\n⏱ Без світла: ' || public.outage_dur(public.outage_total(rng))
              || case when 1440 - public.outage_total(rng) > 0 then E'\n💡 Зі світлом: ' || public.outage_dur(1440 - public.outage_total(rng)) else '' end;
      end if;
      if jsonb_array_length(coalesce(pos, '[]'::jsonb)) > 0 then
        body := body || case when body <> '' then E'\n' else '' end || '🟡 Можливі: ' || public.outage_compact(pos);
      end if;
    end if;
    if kind = 'chg' and old_rng is not null then body := body || E'\nБуло: ' || public.outage_compact(old_rng); end if;
    body := body || E'\n✅ Підтверджено YASNO' || case when coalesce(p_upd, '') <> '' then ' · оновлено ' || to_char(p_upd::timestamptz at time zone public.tg_tzn(), 'DD.MM HH24:MI') else '' end;
  else
    body := 'Статус: ' || coalesce(st, '?');
  end if;
  return head || E'\n' || sub || E'\n\n' || body;
end $function$;

create or replace function public.outage_msg(kind text, title text, grp text, show_grp boolean, d date, today date, st text, rng jsonb, pos jsonb, old_rng jsonb default null::jsonb)
 returns text
 language sql
 stable
 set search_path to 'public', 'extensions'
as $function$
  select public.outage_msg2(kind, title, grp, show_grp, d, today, st, rng, pos, old_rng, null)
$function$;

do $do$
declare d text; d2 text;
begin
  d := pg_get_functiondef('public.outage_apply(jsonb,boolean,timestamptz)'::regprocedure);
  if position('outage_msg2' in d) = 0 then
    d2 := replace(d, 'public.outage_msg(', 'public.outage_msg2(');
    d2 := replace(d2, 'case when had then old.rng else null end)', $q$case when had then old.rng else null end, j -> g.grp ->> 'updatedOn')$q$);
    if d2 = d then raise exception 'outage_apply: не знайдено виклик outage_msg'; end if;
    execute d2;
  end if;
end $do$;
