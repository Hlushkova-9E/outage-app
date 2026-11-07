// Автовмикання бойлерів (Tuya) за командою бази (outage_pwr_tick).
// Захист: заголовок X-Telegram-Bot-Api-Secret-Token має збігатися з tg_settings.secret.
// Логіка Tuya скопійована з telegram-bot (runBoilers), бюджетний бот не змінюється.
// Якщо жодна розетка не ввімкнулась через offline, цикл не вважається обробленим (boil_cycle = '', пауза 10 хв).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

type TuyaCfg = {
  endpoint: string; client_id: string; client_secret: string; uid: string;
  names: string[] | null; gap_seconds: number | null;
};
type TuyaDevice = { id: string; name: string; online?: boolean; status?: { code: string; value: unknown }[] };

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");

function bg(p: Promise<unknown>) {
  const task = p.catch((e) => console.error("background", e));
  const rt = (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime;
  if (rt?.waitUntil) rt.waitUntil(task);
}

async function tuyaCall(cfg: TuyaCfg, method: string, path: string, body?: unknown, token?: string) {
  const t = String(Date.now());
  const bodyStr = body === undefined ? "" : JSON.stringify(body);
  const contentHash = hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(bodyStr)));
  const stringToSign = [method, contentHash, "", path].join("\n");
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(cfg.client_secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sign = hex(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(cfg.client_id + (token ?? "") + t + stringToSign))).toUpperCase();
  const headers: Record<string, string> = { client_id: cfg.client_id, sign, t, sign_method: "HMAC-SHA256", "Content-Type": "application/json" };
  if (token) headers.access_token = token;
  const res = await fetch(cfg.endpoint.replace(/\/+$/, "") + path, { method, headers, body: bodyStr === "" ? undefined : bodyStr });
  const j = await res.json().catch(() => ({}));
  if (!j.success) throw new Error(`${j.msg ?? "помилка запиту"} (код ${String(j.code ?? res.status)})`);
  return j.result;
}

function switchCode(d: TuyaDevice): string {
  const codes = (d.status ?? []).map((x) => x.code);
  return codes.includes("switch_1") ? "switch_1" : codes.includes("switch") ? "switch" : (codes.find((c) => /^switch/.test(c)) ?? "switch_1");
}

async function tg(token: string, body: Record<string, unknown>) {
  const r = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  });
  if (!r.ok) console.error("tg", r.status, await r.text());
}

async function run(token: string, silent: boolean) {
  const { data: ppl } = await sb.from("tg_people").select("chat_id");
  const ids = (ppl ?? []).map((r: { chat_id: string }) => r.chat_id);
  const say = (text: string) => Promise.all(ids.map((c) => tg(token, { chat_id: c, text, disable_notification: silent })));
  let okCount = 0, offlineCount = 0;
  try {
    const { data: cfg } = await sb.from("tuya_settings").select("*").eq("id", 1).maybeSingle();
    const c = cfg as TuyaCfg | null;
    if (!c || !c.client_id || !c.client_secret || !c.uid || String(c.client_id).startsWith("ВАШ_")) {
      await say("⚠️ Автовмикання: Tuya ще не налаштовано (таблиця tuya_settings).");
      return;
    }
    const names = (c.names ?? []).filter((n) => n && n.trim());
    const gap = Math.max(0, Math.min(90, Number(c.gap_seconds ?? 60)));
    const tk = (await tuyaCall(c, "GET", "/v1.0/token?grant_type=1")).access_token as string;
    const devs = (await tuyaCall(c, "GET", `/v1.0/users/${encodeURIComponent(c.uid)}/devices`, undefined, tk)) as TuyaDevice[];
    const norm = (x: string) => x.trim().toLowerCase();
    let switched = false;
    for (const name of names) {
      const d = (devs ?? []).find((x) => norm(x.name ?? "") === norm(name));
      if (!d) { await say(`⚠️ Не знайдено розетку «${name}» у Smart Life.`); continue; }
      const code = switchCode(d);
      try {
        let already = false;
        try {
          const st0 = (await tuyaCall(c, "GET", `/v1.0/devices/${d.id}/status`, undefined, tk)) as { code: string; value: unknown }[];
          already = (st0 ?? []).find((x) => x.code === code)?.value === true;
        } catch (_) { already = false; }
        if (already) { okCount++; await say(`✅ «${name}» уже ввімкнено.`); continue; }
        if (switched && gap > 0) await sleep(gap * 1000);
        for (let k = 0; ; k++) {
          try {
            await tuyaCall(c, "POST", `/v1.0/devices/${d.id}/commands`, { commands: [{ code, value: true }] }, tk);
            break;
          } catch (e) {
            if (k >= 3 || !/offline|2008/i.test((e as Error).message)) throw e;
            await sleep(10000);
          }
        }
        switched = true;
        await sleep(3000);
        const st = (await tuyaCall(c, "GET", `/v1.0/devices/${d.id}/status`, undefined, tk)) as { code: string; value: unknown }[];
        const on = (st ?? []).find((x) => x.code === code)?.value === true;
        if (on) okCount++;
        await say(on ? `✅ «${name}» ввімкнено (автоматично).` : `⚠️ Команду для «${name}» надіслано, але ввімкнення не підтверджено. Перевірте в Smart Life.`);
      } catch (e) {
        if (/offline|2008/i.test((e as Error).message)) offlineCount++;
        await say(`⚠️ «${name}»: ${(e as Error).message}`);
      }
    }
    if (okCount === 0 && offlineCount > 0) {
      await sb.rpc("outage_st_set", { k: "boil_cycle", v: "" });
      await sb.rpc("outage_st_set", { k: "boil_hold", v: new Date(Date.now() + 10 * 60000).toISOString() });
      await say("ℹ️ Розетки без зв'язку. Спробую ввімкнути бойлери ще раз, коли живлення стабілізується.");
    }
  } catch (e) {
    await say(`⚠️ Tuya (автовмикання): ${(e as Error).message}`);
  } finally {
    await sb.rpc("tg_state_set", { k: "boilers_run", v: "" });
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok");
  const { data: s } = await sb.from("tg_settings").select("token,secret").eq("id", 1).single();
  if (!s?.token || !s?.secret) return new Response("not configured");
  if (req.headers.get("x-telegram-bot-api-secret-token") !== s.secret) return new Response("forbidden", { status: 403 });
  const body = await req.json().catch(() => ({}));
  bg(run(s.token, !!body.silent));
  return new Response("started");
});
