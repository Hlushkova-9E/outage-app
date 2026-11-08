-- 69: «🔌 Bluetti не заряджається» лише коли СвітлоБот показує «світло є» (09.11.2026).
-- Привід: 09.11 о 01:02 повідомлення прийшло без світла в будинку (перемкнулись на місто, журнал розеток запізнився).
do $do$
declare d text; a text := 'if src = ''city'' and online and not acon and soc is not null and soc < 100 and onat is not null and onat <= p_now - interval ''15 minutes''';
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'outage_pwr_tick';
  if position(a in d) = 0 then raise exception 'outage_pwr_tick: фрагмент не знайдено'; end if;
  execute replace(d, a, 'if src = ''city'' and sv.kind = ''on'' and online and not acon and soc is not null and soc < 100 and onat is not null and onat <= p_now - interval ''15 minutes''');
end $do$;
