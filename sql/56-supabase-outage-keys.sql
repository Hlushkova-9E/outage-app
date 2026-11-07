-- 56: особисті посилання на сторінку графіка без Telegram (для Антона й Ксенії; лише перегляд).
-- Ключ (32 символи, 192 біти) генерується в базі й надсилається людині в Telegram; у базі лише SHA-256 відбиток.
-- Нова таблиця outage_keys; outage_app_data стає обгорткою над outage_app_data_for(chat, week). Бюджетних таблиць не змінює.

create table if not exists public.outage_keys (
  id bigserial primary key,
  name text not null,
  chat_id text not null,
  hash text not null unique,
  created timestamptz not null default now(),
  revoked timestamptz,
  last_used timestamptz,
  uses int not null default 0
);
alter table public.outage_keys enable row level security;
revoke all on public.outage_keys from public, anon, authenticated;

-- 1. outage_app_data_for(chat, week): тіло колишньої outage_app_data, але з готовим chat_id
do $do$
declare d text; f text;
begin
  if to_regprocedure('public.outage_app_data_for(text, integer)') is null then
    d := pg_get_functiondef('public.outage_app_data(text, integer)'::regprocedure);
    f := $q$public.outage_app_data(p_init text, p_week integer DEFAULT 0)$q$;
    if position(f in d) = 0 then raise exception 'header'; end if;
    d := replace(d, f, $q$public.outage_app_data_for(p_chat text, p_week integer DEFAULT 0)$q$);
    f := $q$chat text := public.outage_app_user(p_init);$q$;
    if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'chat'; end if;
    d := replace(d, f, $q$chat text := p_chat;$q$);
    execute d;
  end if;
end $do$;
revoke all on function public.outage_app_data_for(text, integer) from public, anon, authenticated;

create or replace function public.outage_app_data(p_init text, p_week integer default 0) returns jsonb
language sql security definer set search_path = public as $$
  select public.outage_app_data_for(public.outage_app_user(p_init), p_week);
$$;
revoke all on function public.outage_app_data(text, integer) from public, anon, authenticated;
grant execute on function public.outage_app_data(text, integer) to service_role;

-- 2. новий ключ для людини з tg_people (старі ключі цієї людини вимикаються)
create or replace function public.outage_key_new(p_name text) returns text
language plpgsql security definer set search_path = public, extensions as $fn$
declare ch text; k text;
begin
  select chat_id into ch from public.tg_people where name = p_name;
  if ch is null then raise exception 'немає людини %', p_name; end if;
  update public.outage_keys set revoked = now() where name = p_name and revoked is null;
  k := translate(encode(gen_random_bytes(24), 'base64'), '+/', '-_');
  insert into public.outage_keys (name, chat_id, hash) values (p_name, ch, encode(digest(k, 'sha256'), 'hex'));
  return k;
end $fn$;
revoke all on function public.outage_key_new(text) from public, anon, authenticated;

-- 3. створити ключ і надіслати посилання людині в Telegram (ключ не повертається й ніде не друкується)
create or replace function public.outage_key_send(p_name text) returns text
language plpgsql security definer set search_path = public, extensions as $fn$
declare ch text; u text;
begin
  select chat_id into ch from public.tg_people where name = p_name;
  if ch is null then return 'немає людини ' || p_name; end if;
  u := coalesce(nullif(public.outage_st_get('app_url'), ''), 'https://hlushkova-9e.github.io/outage-app/');
  u := regexp_replace(u, '[?#].*$', '');
  if right(u, 1) <> '/' then u := u || '/'; end if;
  perform public.outage_tg(array[ch],
    E'🔑 Ваше особисте посилання на графік світла (з розетками й Bluetti), відкривається без Telegram:\n'
    || u || '?k=' || public.outage_key_new(p_name)
    || E'\n\n📲 Як додати на екран iPhone: відкрийте посилання в Safari → «Поділитися» → «На початковий екран».'
    || E'\n\n🔒 Нікому не пересилайте: з ним видно графік дому, адреси й стан Bluetti. Попереднє посилання (якщо було) більше не діє.',
    null, false);
  return 'надіслано: ' || p_name;
end $fn$;
revoke all on function public.outage_key_send(text) from public, anon, authenticated;

-- 4. дані сторінки за ключем (викликає Edge outage-app)
create or replace function public.outage_key_data(p_key text, p_week integer default 0) returns jsonb
language plpgsql security definer set search_path = public, extensions as $fn$
declare r public.outage_keys%rowtype;
begin
  if p_key is null or length(p_key) < 20 or length(p_key) > 100 then return jsonb_build_object('ok', false); end if;
  select * into r from public.outage_keys where hash = encode(digest(p_key, 'sha256'), 'hex') and revoked is null;
  if not found then return jsonb_build_object('ok', false); end if;
  update public.outage_keys set last_used = now(), uses = uses + 1 where id = r.id;
  return public.outage_app_data_for(r.chat_id, p_week) || jsonb_build_object('via', 'key', 'who', r.name);
end $fn$;
revoke all on function public.outage_key_data(text, integer) from public, anon, authenticated;
grant execute on function public.outage_key_data(text, integer) to service_role;

-- 5. стан ключів (без самих ключів)
create or replace function public.outage_keys_status() returns table(name text, created timestamptz, revoked timestamptz, last_used timestamptz, uses int)
language sql stable security definer set search_path = public as $$
  select k.name, k.created, k.revoked, k.last_used, k.uses from public.outage_keys k order by k.created desc;
$$;
revoke all on function public.outage_keys_status() from public, anon, authenticated;

-- Вимкнути всі посилання людини без нового: update public.outage_keys set revoked = now() where name = 'Антон' and revoked is null;
-- Нове посилання (старе перестає діяти): select public.outage_key_send('Антон');
