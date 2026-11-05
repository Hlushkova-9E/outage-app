// Supabase Edge Function «outage-app»: віддає сторінці Mini App «📅 Графік» дані з бази.
// Перевірка підпису Telegram (initData) робиться в SQL-функціях outage_app_data (бот FamilyBot) і outage_house_data (будинковий бот), тут лише передача запиту.
// Verify JWT: вимкнено (сторінка публічна, доступ дає підпис Telegram). Секрети не потрібні (ключ service_role Supabase підставляє сам).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const ORIGIN = "https://abohdanovskyi.github.io";
const cors = {
  "Access-Control-Allow-Origin": ORIGIN,
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "content-type",
  "Vary": "Origin",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return json({ ok: false }, 405);
  try {
    const { init_data } = await req.json();
    if (typeof init_data !== "string" || !init_data || init_data.length > 4000) return json({ ok: false }, 400);
    let { data, error } = await sb.rpc("outage_app_data", { p_init: init_data });
    if (error) { console.error("outage_app_data", error); return json({ ok: false }, 500); }
    if (!data?.ok) {
      // запуск із будинкового бота (підпис іншого токена): лише підписка дому, без розеток
      const h = await sb.rpc("outage_house_data", { p_init: init_data });
      if (h.error) { console.error("outage_house_data", h.error); return json({ ok: false }, 500); }
      data = h.data;
    }
    return json(data ?? { ok: false }, data?.ok ? 200 : 401);
  } catch (e) {
    console.error(e);
    return json({ ok: false }, 400);
  }
});
