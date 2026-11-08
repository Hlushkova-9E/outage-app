-- 68: бойлери після спрацювання захисту розетки від перенапруги (09.11.2026)
-- Розетки Tuya самі вимикають реле приблизно від 250 В (fault > 0), лишаючись онлайн, тож журнал «зникло/з'явилось» цього не бачить.
-- Блок 16 outage_pwr_tick: був fault за останні 6 год, минуло ≥5 хв, за останні 5 хв напруга нижче 245 В, квартира на місті,
-- автовмикання й сезон бойлерів увімкнені, відліку немає -> раз на подію (bfault:<час>) виклик Edge outage-boilers з note
-- «захист розетки, 251,8 В»; повідомлення лише якщо щось реально ввімкнено. Текст «⚠️ Висока напруга» уточнено (250 В розетки, 255 В ЗУБР).
do $do$
declare d text; anchor text := '  -- 10. сторож токена Bluetti (раз на добу, лише Антону)';
  t1 text := 'Реле ЗУБР вимикає квартиру приблизно від 250 В, тож можливі короткі відключення. Чутливу техніку краще вимкнути.';
begin
  select pg_get_functiondef(oid) into d from pg_proc where pronamespace = 'public'::regnamespace and proname = 'outage_pwr_tick';
  if position(anchor in d) = 0 or position(t1 in d) = 0 then raise exception 'outage_pwr_tick: фрагмент не знайдено'; end if;
  d := replace(d, t1, 'Розетки бойлерів вимикаються самі приблизно від 250 В (їхній захист), ЗУБР вимикає квартиру від 255 В. Чутливу техніку краще вимкнути.');
  d := replace(d, anchor, $b$  -- 16. захист розетки від перенапруги вимкнув бойлер (SQL 68)
  declare v_fa timestamptz; v_pk numeric; v_fn text; v_sc text; v_r jsonb;
  begin
    select max(v.at) into v_fa from public.outage_tuya_volt v where v.code = 'fault' and v.val > 0 and v.at > p_now - interval '6 hours';
    if v_fa is not null and src = 'city' and autoon and cd is null and p_now >= v_fa + interval '5 minutes'
       and not exists (select 1 from public.outage_tuya_volt v where v.code = 'cur_voltage' and v.val >= 2450 and v.at > greatest(v_fa, p_now - interval '5 minutes'))
       and public.outage_ev_new('bfault:' || v_fa::text, p_dry) then
      select max(v.val) into v_pk from public.outage_tuya_volt v where v.code = 'cur_voltage' and v.at between v_fa - interval '3 minutes' and v_fa + interval '1 minute';
      if not p_dry then
        v_r := public.tg_boilers_start();
        if coalesce((v_r ->> 'ok')::boolean, false) then
          perform public.outage_ev_new('bauto:' || p_now::text);
          select fn_url, secret into v_fn, v_sc from public.tg_settings where id = 1;
          perform net.http_post(url := replace(v_fn, '/telegram-bot', '/outage-boilers'),
            body := jsonb_build_object('silent', quiet, 'note', 'захист розетки' || coalesce(', ' || replace(round(v_pk / 10, 1)::text, '.', ',') || ' В', '')),
            headers := jsonb_build_object('Content-Type', 'application/json', 'X-Telegram-Bot-Api-Secret-Token', v_sc),
            timeout_milliseconds := 5000);
        end if;
      end if;
      lg := lg || 'захист розетки: перевіряю бойлери; ';
    end if;
  end;

$b$ || anchor);
  execute d;
end $do$;
