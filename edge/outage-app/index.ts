// Supabase Edge Function «outage-app» (v5): віддає сторінці Mini App «📅 Графік» дані з бази.
// Перевірка підпису Telegram (initData) робиться в SQL-функціях outage_app_data (бот FamilyBot) і outage_house_data (будинковий бот), тут лише передача запиту.
// Verify JWT: вимкнено (сторінка публічна, доступ дає підпис Telegram). Секрети не потрібні (ключ service_role Supabase підставляє сам).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// дозволені адреси сторінки: нова (hlushkova-9e) і стара (abohdanovskyi), поки старі посилання ще живі
const ORIGINS = ["https://hlushkova-9e.github.io", "https://abohdanovskyi.github.io"];

Deno.serve(async (req) => {
  const origin = req.headers.get("origin") ?? "";
  const cors = {
    "Access-Control-Allow-Origin": ORIGINS.includes(origin) ? origin : ORIGINS[0],
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "content-type",
    "Vary": "Origin",
  };
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" } });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return json({ ok: false }, 405);
  try {
    const body = await req.json();
    // зсув у тижнях від поточного (SQL 37 обрізає до −8…+1)
    const week = Number.isInteger(body?.week) && Math.abs(body.week) <= 52 ? body.week : 0;
    if (body?.public === "house") {
      // публічна версія для будинкового чату (без входу через Telegram): лише підписка дому, без розеток
      const pr = await sb.rpc("outage_house_core", { p_week: week });
      if (pr.error) { console.error("outage_house_core", pr.error); return json({ ok: false }, 500); }
      return json(pr.data ?? { ok: false }, pr.data?.ok ? 200 : 500);
    }
    const { init_data } = body;
    if (typeof init_data !== "string" || !init_data || init_data.length > 4000) return json({ ok: false }, 400);
    let { data, error } = await sb.rpc("outage_app_data", { p_init: init_data, p_week: week });
    if (error) { console.error("outage_app_data", error); return json({ ok: false }, 500); }
    if (!data?.ok) {
      // запуск із будинкового бота (підпис іншого токена): лише підписка дому, без розеток
      const h = await sb.rpc("outage_house_data", { p_init: init_data, p_week: week });
      if (h.error) { console.error("outage_house_data", h.error); return json({ ok: false }, 500); }
      data = h.data;
    }
    return json(data ?? { ok: false }, data?.ok ? 200 : 401);
  } catch (e) {
    console.error(e);
    return json({ ok: false }, 400);
  }
});
