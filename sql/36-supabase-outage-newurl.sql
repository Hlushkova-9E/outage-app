-- Бот відключень: нова адреса сторінки Mini App після переїзду репозиторію в Hlushkova-9E/outage-app.
-- Supabase -> SQL Editor -> New query -> вставити весь файл -> Run. Можна запускати повторно. Виконувати після 35.
-- Таблиць не створює й не змінює. Перед запуском задеплоїти Edge outage-app v4 (дозволяє обидві адреси).
--  * app_url (кнопка «📅 Графік» у FamilyBot): https://hlushkova-9e.github.io/outage-app/ — лише якщо кнопка вже увімкнена
--    (порожнє значення означає «вимкнено», його не чіпаємо).
--  * outage_house_post(): кнопка «🌐 У браузері» веде на https://hlushkova-9e.github.io/outage-app/?house=1.
-- Вручну в BotFather (не SQL): у будинкового бота змінити адресу Mini App (Direct Link /graph) на https://hlushkova-9e.github.io/outage-app/

do $do$
declare d text; d2 text;
begin
  if coalesce(public.outage_st_get('app_url'), '') <> '' then
    perform public.outage_st_set('app_url', 'https://hlushkova-9e.github.io/outage-app/');
  end if;

  d := pg_get_functiondef('public.outage_house_post(text)'::regprocedure);
  if position('https://hlushkova-9e.github.io/outage-app/' in d) = 0 then
    d2 := replace(d, 'https://abohdanovskyi.github.io/outage-app/', 'https://hlushkova-9e.github.io/outage-app/');
    if d2 = d then raise exception 'outage_house_post: не знайдено стару адресу'; end if;
    execute d2;
  end if;
end $do$;

-- перевірка: обидва рядки мають містити hlushkova-9e
select public.outage_st_get('app_url') as app_url,
       position('hlushkova-9e' in pg_get_functiondef('public.outage_house_post(text)'::regprocedure)) > 0 as house_button_ok;
