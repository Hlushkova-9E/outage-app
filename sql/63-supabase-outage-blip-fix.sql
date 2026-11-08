-- 63: виправлення outage_blip (08.11.2026): якщо СвітлоБот у момент вимкнення розеток уже показував «світла немає»
-- (квартира була на Bluetti, розетки живила станція), це справжнє відключення, а не збій лінії.
create or replace function public.outage_blip(p_off timestamptz, p_on timestamptz, p_now timestamptz default now()) returns text
language plpgsql stable security definer set search_path to 'public' as $f$
declare mx numeric; fl numeric; sbk text;
begin
  if p_off is null then return null; end if;
  select kind into sbk from public.outage_log where at <= p_off + interval '10 minutes' order by at desc limit 1;
  if sbk = 'off' then return null; end if;
  select max(val) filter (where code = 'cur_voltage'), max(val) filter (where code = 'fault')
    into mx, fl from public.outage_tuya_volt
   where at between p_off - interval '15 minutes' and coalesce(p_on, p_now) + interval '2 minutes';
  if mx >= 2500 then return 'перенапруга ' || replace(round(mx / 10, 1)::text, '.', ',') || ' В'; end if;
  if coalesce(fl, 0) > 0 then return 'збій напруги'; end if;
  if not exists (select 1 from public.outage_log where kind = 'off' and at >= p_off - interval '10 minutes' and at <= p_now) then
    return 'Світлобот не бачив відключення';
  end if;
  return null;
end $f$;
