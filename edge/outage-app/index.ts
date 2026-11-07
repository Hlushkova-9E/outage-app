// Supabase Edge Function «outage-app» (v8): віддає сторінці Mini App «📅 Графік» дані з бази.
// Перевірка підпису Telegram (initData) робиться в SQL-функціях outage_app_data (бот FamilyBot) і outage_house_data (будинковий бот), тут лише передача запиту.
// v6: для будинкової версії додає блок збору (налаштування fundraise), якщо він увімкнений.
// v7: анонімна статистика візитів (SQL 41): хеш (HMAC) Telegram user.id або IP+браузера, без імен; запис не ламає відповідь.
// v8: особисті посилання без Telegram (SQL 56): POST {key, week} → outage_key_data; лише перегляд; невірний ключ → 401 із затримкою.
// Verify JWT: вимкнено (сторінка публічна, доступ дає підпис Telegram або особистий ключ). Секрети не потрібні (ключ service_role Supabase підставляє сам).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// дозволені адреси сторінки: нова (hlushkova-9e) і стара (abohdanovskyi), поки старі посилання ще живі
const ORIGINS = ["https://hlushkova-9e.github.io", "https://abohdanovskyi.github.io"];

// блок збору для будинкової версії: JSON у налаштуванні fundraise, лише якщо on=true
async function withFund(data: any) {
  try {
    if (!data?.ok) return data;
    const r = await sb.rpc("outage_st_get", { k: "fundraise" });
    if (r.error || !r.data) return data;
    const f = JSON.parse(r.data);
    if (f && f.on === true) data.fundraise = f;
  } catch (e) { console.error("fundraise", e); }
  return data;
}

// анонімний лічильник візитів: HMAC-SHA256 від значення з ключем service_role (ключ не виходить із функції)
const enc = new TextEncoder();
let hmacKey: CryptoKey | null = null;
async function hashId(v: string) {
  hmacKey ??= await crypto.subtle.importKey("raw", enc.encode(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const s = await crypto.subtle.sign("HMAC", hmacKey, enc.encode(v));
  return [...new Uint8Array(s)].slice(0, 16).map((b) => b.toString(16).padStart(2, "0")).join("");
}
async function visit(kind: string, v: string) {
  try {
    const r = await sb.rpc("outage_visit", { p_kind: kind, p_h: await hashId(v) });
    if (r.error) console.error("visit", r.error);
  } catch (e) { console.error("visit", e); }
}

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
      if (pr.data?.ok) {
        const ip = req.headers.get("cf-connecting-ip") ?? (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim();
        await visit("web", ip + "|" + (req.headers.get("user-agent") ?? ""));
      }
      return json(await withFund(pr.data) ?? { ok: false }, pr.data?.ok ? 200 : 500);
    }
    if (typeof body?.key === "string") {
      // особисте посилання (SQL 56): у базі лише відбиток ключа; лише перегляд
      const key = body.key.trim();
      if (key.length < 20 || key.length > 100) return json({ ok: false }, 401);
      const kr = await sb.rpc("outage_key_data", { p_key: key, p_week: week });
      if (kr.error) { console.error("outage_key_data", kr.error); return json({ ok: false }, 500); }
      if (!kr.data?.ok) { await new Promise((r) => setTimeout(r, 700)); return json({ ok: false }, 401); }
      await visit("key", String(kr.data.who ?? ""));
      return json(kr.data);
    }
    const { init_data } = body;
    if (typeof init_data !== "string" || !init_data || init_data.length > 4000) return json({ ok: false }, 400);
    let { data, error } = await sb.rpc("outage_app_data", { p_init: init_data, p_week: week });
    if (error) { console.error("outage_app_data", error); return json({ ok: false }, 500); }
    if (!data?.ok) {
      // запуск із будинкового бота (підпис іншого токена): лише підписка дому, без розеток
      const h = await sb.rpc("outage_house_data", { p_init: init_data, p_week: week });
      if (h.error) { console.error("outage_house_data", h.error); return json({ ok: false }, 500); }
      data = await withFund(h.data);
    }
    if (data?.ok) {
      try {
        const uid = JSON.parse(new URLSearchParams(init_data).get("user") ?? "{}")?.id;
        if (uid) await visit("tg", String(uid));
      } catch (e) { console.error("visit-uid", e); }
    }
    return json(data ?? { ok: false }, data?.ok ? 200 : 401);
  } catch (e) {
    console.error(e);
    return json({ ok: false }, 400);
  }
});
