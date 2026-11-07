-- SQL 40–43 бота відключень (копія міграцій Supabase, вивантажено 07.11.2026).
-- Виконано міграціями outage_plan_all_40, outage_visits_41, monitor_actions_usd_42, outage_diff_43. Опис: claude/family-budget/sql-core.md.
-- Повторний запуск безпечний (create or replace / if not exists); блоки з replace(pg_get_functiondef) не повторюють зміну, якщо її вже внесено.

-- ===== outage_plan_all_40 =====
create table if not exists public.outage_plan_all (
  day date not null, grp text not null, minutes int not null, rng jsonb not null,
  primary key (day, grp));
alter table public.outage_plan_all enable row level security;
revoke all on public.outage_plan_all from anon, authenticated;

create or replace view public.outage_plan_v as
  select day, grp, minutes, rng from public.outage_plan
  union all
  select a.day, a.grp, a.minutes, a.rng from public.outage_plan_all a
   where not exists (select 1 from public.outage_plan p where p.day = a.day and p.grp = a.grp);
revoke all on public.outage_plan_v from anon, authenticated;

create or replace function public.outage_log_sync() returns integer language plpgsql security definer set search_path to 'public' as $f$
declare c text; n int := 0; h public.outage_subs%rowtype;
begin
  select content into c from net._http_response where status_code = 200 and content like '%data-post=%' order by id desc limit 1;
  if c is not null then
    insert into public.outage_log (id, kind, at)
      select p.id, p.kind, p.at from public.tg_svitlo_parse(c) p where p.at is not null
      on conflict (id) do nothing;
    get diagnostics n = row_count;
  end if;
  select * into h from public.outage_subs where active and svitlo order by key limit 1;
  if found then
    insert into public.outage_plan (day, grp, minutes, rng)
      select s.day, s.grp, public.outage_total(s.rng), s.rng from public.outage_snap s
       where s.grp = h.grp and s.status = 'ScheduleApplies'
      on conflict (day) do update set grp = excluded.grp, minutes = excluded.minutes, rng = excluded.rng;
  end if;
  insert into public.outage_plan_all (day, grp, minutes, rng)
    select s.day, s.grp, public.outage_total(s.rng), s.rng from public.outage_snap s
     where s.status = 'ScheduleApplies' and s.grp in (select grp from public.outage_subs where active)
    on conflict (day, grp) do update set minutes = excluded.minutes, rng = excluded.rng;
  return n;
end $f$;

do $$ declare f text; nm text;
begin
  foreach nm in array array['outage_app_data','outage_house_core'] loop
    select pg_get_functiondef(p.oid) into f from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = nm;
    f := replace(f, 'public.outage_plan where grp = s.grp and day = d', 'public.outage_plan_v where grp = s.grp and day = d');
    execute f;
  end loop;
end $$;

-- ===== outage_visits_41 =====
create table if not exists public.outage_visits (
  day date not null, kind text not null, h text not null, n int not null default 1,
  primary key (day, kind, h));
alter table public.outage_visits enable row level security;
revoke all on public.outage_visits from anon, authenticated;

create or replace function public.outage_visit(p_kind text, p_h text) returns void
language sql security definer set search_path to 'public' as $$
  insert into public.outage_visits (day, kind, h)
  values ((now() at time zone public.tg_tzn())::date, left(p_kind, 8), left(p_h, 64))
  on conflict (day, kind, h) do update set n = outage_visits.n + 1;
$$;
revoke all on function public.outage_visit(text, text) from public, anon, authenticated;
grant execute on function public.outage_visit(text, text) to service_role;

create or replace function public.outage_visits_stats(p_days int default 7)
returns table(day date, tg_users bigint, web_devices bigint, requests bigint)
language sql security definer set search_path to 'public' as $$
  select v.day,
         count(*) filter (where v.kind = 'tg'), count(*) filter (where v.kind = 'web'), sum(v.n)::bigint
    from public.outage_visits v
   where v.day > (now() at time zone public.tg_tzn())::date - greatest(1, p_days)
   group by v.day order by v.day desc;
$$;
revoke all on function public.outage_visits_stats(int) from public, anon, authenticated;
grant execute on function public.outage_visits_stats(int) to service_role;

-- ===== monitor_actions_usd_42 =====
do $m$
declare d text;
begin
  d := pg_get_functiondef('public.mon_extra_text()'::regprocedure);
  d := replace(d, ' хв (станом на', ' $ (станом на');
  d := replace(d, 'GitHub Actions: ', 'GitHub Actions (акаунт Антона): ');
  execute d;
end $m$;
update public.mon_settings set actions_used = 0.22, actions_limit = 12, actions_at = (now() at time zone 'Europe/Kyiv')::date where id = 1;

-- ===== outage_diff_43 =====
create or replace function public.outage_diff(p_old jsonb, p_new jsonb) returns text
language plpgsql stable set search_path to 'public', 'extensions' as $f$
declare add_t text; rem_t text; res text := '';
begin
  with f as (
    select g as mn,
      exists(select 1 from jsonb_array_elements(coalesce(p_old, '[]'::jsonb)) x where g >= (x->>0)::int and g < (x->>1)::int) as o,
      exists(select 1 from jsonb_array_elements(coalesce(p_new, '[]'::jsonb)) x where g >= (x->>0)::int and g < (x->>1)::int) as n
    from generate_series(0, 1439) g),
  a as (select mn, mn - row_number() over (order by mn) as grp from f where n and not o),
  r as (select mn, mn - row_number() over (order by mn) as grp from f where o and not n)
  select (select string_agg(s, ', ' order by st) from (select min(mn) st, public.outage_hm(min(mn)) || '–' || public.outage_hm(max(mn) + 1) s from a group by grp) q),
         (select string_agg(s, ', ' order by st) from (select min(mn) st, public.outage_hm(min(mn)) || '–' || public.outage_hm(max(mn) + 1) s from r group by grp) q)
    into add_t, rem_t;
  if add_t is not null then res := '➕ Додано: ' || add_t; end if;
  if rem_t is not null then res := res || case when res <> '' then E'\n' else '' end || '➖ Скасовано: ' || rem_t; end if;
  return res;
end $f$;
revoke all on function public.outage_diff(jsonb, jsonb) from public, anon, authenticated;

do $m$
declare d text;
begin
  d := pg_get_functiondef('public.outage_msg2(text,text,text,boolean,date,date,text,jsonb,jsonb,jsonb,text)'::regprocedure);
  d := replace(d, 'body := body || E''\nБуло: '' || public.outage_compact(old_rng);',
    'body := body || coalesce(E''\n'' || nullif(public.outage_diff(old_rng, rng), ''''), '''') || E''\nБуло: '' || public.outage_compact(old_rng);');
  execute d;
end $m$;
