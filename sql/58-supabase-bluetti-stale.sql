-- 58: сповіщення Антону, якщо хмара Bluetti не віддає дані понад 3 год (і коли відновиться). Нічого існуючого не змінює.
-- Застосовано 07.11.2026 (міграція outage_bstale_58). cron: bluetti-stale кожні 10 хв. Нічна тиша 22:00–08:00 (Київ).
-- «Свіжі дані» = останній рядок bluetti_log із soc (і з REST, і з резервного push-каналу bluetti-poll v7).
-- Події в outage_events: bstale:<час останніх даних> і bstaleok:<той самий ключ> — по одному повідомленню на епізод.
create or replace function public.bluetti_stale_tick() returns text
language plpgsql security definer set search_path = public as $fn$
declare
  ch text; lok timestamptz; k text; hr int := extract(hour from (now() at time zone public.tg_tzn()));
begin
  select chat_id into ch from public.tg_people where name = 'Антон';
  select max(at) into lok from public.bluetti_log where soc is not null;
  if ch is null or lok is null then return 'skip'; end if;
  k := to_char(lok, 'YYYYMMDDHH24MISS');
  if hr < 8 or hr >= 22 then return 'quiet'; end if;
  if now() - lok > interval '3 hours' then
    if not exists (select 1 from public.outage_events where key = 'bstale:' || k) then
      insert into public.outage_events(key, at) values ('bstale:' || k, now());
      perform public.outage_tg(array[ch],
        '🔋 Bluetti: хмара не віддає дані вже понад 3 год (останні дані ' || to_char(lok at time zone public.tg_tzn(), 'HH24:MI DD.MM') || '). Станція, ймовірно, працює, збій на боці Bluetti. Коли зв''язок повернеться, напишу.', null, false);
    end if;
    return 'stale';
  elsif exists (select 1 from public.outage_events where key like 'bstale:%' and at > now() - interval '2 days')
    and not exists (select 1 from public.outage_events where key = 'bstaleok:' || (select max(substr(key, 8)) from public.outage_events where key like 'bstale:%')) then
    insert into public.outage_events(key, at) values ('bstaleok:' || (select max(substr(key, 8)) from public.outage_events where key like 'bstale:%'), now());
    perform public.outage_tg(array[ch], '✅ Bluetti: зв''язок із хмарою відновився, дані знову надходять.', null, false);
    return 'recovered';
  end if;
  return 'ok';
end $fn$;
revoke all on function public.bluetti_stale_tick() from public, anon, authenticated;
select cron.schedule('bluetti-stale', '*/10 * * * *', 'select public.bluetti_stale_tick()');

-- Перевірка: select public.bluetti_stale_tick();  → ok / stale / recovered / quiet
-- Вимкнути: select cron.unschedule('bluetti-stale');

-- Ручне заповнення діри в історії (07.11.2026, збій REST 17:04–19:42): рядки 504 у bluetti_log переписано
-- як «станція живила квартиру», заряд лінійно за скриншотами/пробами, raw.manual = пояснення. Шаблон:
-- update public.bluetti_log l set sn = '<SN>', online = true, ac = true, ac_w = <Вт>,
--   soc = round(<soc0> - (<soc0> - <soc1>) * extract(epoch from (l.at - '<t0>')) / extract(epoch from ('<t1>'::timestamptz - '<t0>'))),
--   raw = l.raw || '{"manual":"..."}'
-- where l.at > '<t0>' and l.at < '<t1>' and l.soc is null and l.raw->>'status' = '504';
