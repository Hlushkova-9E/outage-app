// Supabase Edge Function «bluetti-poll» (v9): кожні 2 хв читає стан Bluetti AC200PL і пише рядок у bluetti_log.
// Основний канал: REST gw.bluettipower.com/api/bluiotdata/ha/v1 (devices + deviceStates), ліміт відповіді 15 с.
// v7 (07.11.2026): якщо REST мовчить/дає 5xx (відомі збої хмари Bluetti), резерв — push-канал (STOMP over WebSocket)
//   wss://gw.bluettipower.com/api/edgeiotgw/ws-coordination/websocket: чекаємо DEVICE_REALTIME_STATUS до 100 с (сервер шле ~раз на 70 с),
//   пишемо soc / ac_w / grid_w з raw.via = 'ws'. Працює у фоні (EdgeRuntime.waitUntil), щоб cron не чекав.
//   Сервер пускає лише з x-app-ver ≥ 2.0.0 (з 1.0.0 відповідає msgCode 600 «Upgrade required»).
// Секрети (лише назви): BLUETTI_CLIENT_SECRET, BLUETTI_APP_KEY — у Supabase → Edge Functions → Secrets. Токени — у таблиці bluetti_auth.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

const SSO = 'https://sso.bluettipower.com';
const GW = 'https://gw.bluettipower.com';
const WSS = 'wss://gw.bluettipower.com/api/edgeiotgw/ws-coordination/websocket';
const APP_VER = '2.0.0';
const REST_MS = 15000;
const WS_MS = 100000; // сервер шле повне повідомлення ~раз на 70 с, але буває й довше (07.11 19:48 за 80 с нічого)
const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
// REST лишається з x-app-ver 1.0.0, як працювало з першого дня; 2.0.0 потрібна лише push-каналу
const H = (tok: string) => ({ Authorization: tok, 'x-os': 'open', 'x-app-key': Deno.env.get('BLUETTI_APP_KEY') || '', 'x-app-ver': '1.0.0' });

async function refresh(rt: string) {
  const r = await fetch(SSO + '/oauth2/token', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: rt, client_id: 'HomeAssistant', client_secret: Deno.env.get('BLUETTI_CLIENT_SECRET') || '' }),
    signal: AbortSignal.timeout(REST_MS) });
  const t = await r.json().catch(() => ({}));
  const at = t.access_token ?? t.data?.access_token;
  if (!r.ok || !at) return null;
  const ei = Number(t.expires_in ?? t.data?.expires_in ?? 0);
  const upd = { access_token: at, refresh_token: t.refresh_token ?? t.data?.refresh_token ?? rt, expires_at: ei ? new Date(Date.now() + ei * 1000).toISOString() : null, updated: new Date().toISOString() };
  await sb.from('bluetti_auth').update(upd).eq('id', 1);
  return at as string;
}

// REST із лімітом: зависання → s = 0 (як «немає відповіді»)
const get = (tok: string, path: string) => fetch(GW + path, { headers: H(tok), signal: AbortSignal.timeout(REST_MS) })
  .then(async (r) => ({ s: r.status, j: await r.json().catch(() => ({})) }))
  .catch((e) => ({ s: 0, j: { error: String(e).slice(0, 100) } }));
const expired = (x: { s: number; j: any }) => x.s === 401 || x.s === 403 || x.j?.msgCode === 805;
const num = (l: any[], code: string) => { const v = l.find((x) => x.fnCode === code)?.fnValue; const n = Number(v); return v === undefined || v === null || v === '' || Number.isNaN(n) ? null : n; };
const n = (v: any) => { const x = Number(v); return v === undefined || v === null || v === '' || Number.isNaN(x) ? null : x; };

// STOMP-кадри: CMD\nheader:value...\n\nbody\0
function frames(raw: string) {
  const out: { cmd: string; h: Record<string, string>; body: string }[] = [];
  for (const part of raw.split('\x00')) {
    const s = part.replace(/^\n+/, '');
    if (!s) continue;
    const i = s.indexOf('\n\n');
    const head = i < 0 ? s : s.slice(0, i);
    const [cmd, ...hl] = head.split('\n');
    const h: Record<string, string> = {};
    for (const l of hl) { const k = l.indexOf(':'); if (k > 0) h[l.slice(0, k)] = l.slice(k + 1); }
    out.push({ cmd, h, body: i < 0 ? '' : s.slice(i + 2) });
  }
  return out;
}

// Резерв: один повний DEVICE_REALTIME_STATUS із push-каналу (або хоча б заряд), не довше WS_MS
function wsRead(tok: string): Promise<{ sn: string | null; p: any; partial: boolean; err?: string }> {
  return new Promise((res) => {
    let sn: string | null = null; let last: any = null; let fin = false; let hb: number | undefined;
    const ws = new WebSocket(WSS);
    const finish = (r: { sn: string | null; p: any; partial: boolean; err?: string }) => {
      if (fin) return; fin = true; clearTimeout(t); if (hb) clearInterval(hb);
      try { ws.close(); } catch (_) { /* */ }
      res(r);
    };
    const t = setTimeout(() => finish(last ? { sn, p: last, partial: true } : { sn, p: null, partial: true, err: 'ws timeout' }), WS_MS);
    ws.onopen = () => {
      ws.send('CONNECT\naccept-version:1.0,1.1,2.0\nHost:gw.bluettipower.com\nAuthorization: ' + tok +
        '\nheart-beat:10000,10000\nx-os:open\nx-app-key:' + (Deno.env.get('BLUETTI_APP_KEY') || '') + '\nx-app-ver:' + APP_VER + '\n\n\x00\n');
      hb = setInterval(() => { try { ws.send('\n'); } catch (_) { /* */ } }, 10000);
    };
    ws.onmessage = (m) => {
      const raw = String(m.data);
      if (raw === '\n') return;
      for (const f of frames(raw)) {
        if (f.cmd === 'CONNECTED') {
          const u = f.h['user-name'];
          if (!u) return finish({ sn, p: null, partial: true, err: 'ws no user' });
          ws.send('SUBSCRIBE\nid:poll\ndestination:/ws-subscribe/user/' + u + '/notify\nack:auto\n\n\x00\n');
        } else if (f.cmd === 'ERROR') {
          return finish({ sn, p: last, partial: true, err: 'ws error ' + (f.h['message'] ?? '').replace(/\\c/g, ':').slice(0, 120) });
        } else if (f.cmd === 'MESSAGE') {
          let j: any = null; try { j = JSON.parse(f.body); } catch (_) { continue; }
          const d = j?.data; const msg = d?.message && typeof d.message === 'object' ? d.message : d;
          const p = msg?.payload;
          if (msg?.messageType !== 'DEVICE_REALTIME_STATUS' || !p || p.allFieldIsNull !== false) continue;
          sn = msg.deviceSn ?? sn;
          last = { ...(last ?? {}), ...Object.fromEntries(Object.entries(p).filter(([, v]) => v !== null)) };
          if (p.powerAcOut != null && p.batterySoc != null) return finish({ sn, p: last, partial: false });
        }
      }
    };
    ws.onerror = () => finish({ sn, p: last, partial: !!last, err: last ? undefined : 'ws socket error' });
    ws.onclose = () => finish({ sn, p: last, partial: !!last, err: last ? undefined : 'ws closed' });
  });
}

async function wsFallback(tok: string, why: any) {
  const r = await wsRead(tok);
  // час рядка = момент, коли отримано дані (а не початок прослуховування), щоб на сторінці «оновлено» було правдивим
  const at = new Date().toISOString();
  if (!r.p || n(r.p.batterySoc) === null) {
    await sb.from('bluetti_log').insert({ at, online: null, raw: { ...why, ws: r.err ?? 'no data' } });
    return;
  }
  // AC: перемикач, якщо прийшов; інакше — є навантаження AC; інакше — як було в останньому справжньому записі
  let ac: boolean | null = r.p.acSwitch != null ? String(r.p.acSwitch) === '1' : (n(r.p.powerAcOut) ?? 0) > 0 ? true : null;
  let sn = r.sn;
  if (ac === null || !sn) {
    const { data: lr } = await sb.from('bluetti_log').select('sn, ac').not('sn', 'is', null).order('at', { ascending: false }).limit(1).maybeSingle();
    if (ac === null) ac = lr?.ac ?? false;
    sn = sn ?? lr?.sn ?? null;
  }
  await sb.from('bluetti_log').insert({ at, sn, online: true, ac, soc: n(r.p.batterySoc), grid_w: n(r.p.powerGridIn), ac_w: n(r.p.powerAcOut),
    // product.stateList — у тому ж вигляді, що з REST, щоб bluetti_now / bluetti_text / тригер ac читали без змін
    raw: { via: 'ws', partial: r.partial, rest: why, payload: r.p, product: { online: 1, stateList: [
      { fnCode: 'SOC', fnValue: String(r.p.batterySoc) },
      { fnCode: 'ACLoadAllTotalPower', fnValue: r.p.powerAcOut ?? '' },
      { fnCode: 'GridAllTotalPower', fnValue: r.p.powerGridIn ?? '' },
      { fnCode: 'DCLoadAllTotalPower', fnValue: r.p.powerDcOut ?? '' },
      { fnCode: 'SetCtrlAc', fnValue: ac ? '1' : '0' },
    ] } } });
}

Deno.serve(async (req) => {
  try {
    const qs = new URL(req.url).searchParams;
    const bind = qs.get('bind') === '1';
    const force = qs.get('force') === '1';
    const { data: a } = await sb.from('bluetti_auth').select('*').eq('id', 1).maybeSingle();
    if (!a?.access_token) return new Response('not linked', { status: 200 });
    let tok = a.access_token as string;
    if (a.refresh_token && a.expires_at && new Date(a.expires_at).getTime() - Date.now() < 7 * 86400000) tok = (await refresh(a.refresh_token).catch(() => null)) || tok;
    if (!bind && !force) {
      const { data: last } = await sb.from('bluetti_log').select('at, via:raw->>via').order('at', { ascending: false }).limit(1).maybeSingle();
      // рядок з резервного каналу ставиться наприкінці прослуховування (до 100 с), тому для нього захист лише 10 с
      if (last && Date.now() - new Date(last.at).getTime() < (last.via === 'ws' ? 10000 : 90000)) return new Response('too soon');
    }
    let dev = await get(tok, '/api/bluiotdata/ha/v1/devices');
    if (expired(dev) && a.refresh_token) { const nt = await refresh(a.refresh_token).catch(() => null); if (nt) { tok = nt; dev = await get(tok, '/api/bluiotdata/ha/v1/devices'); } }
    const list: any[] = dev.j?.data ?? [];
    if (!list.length) {
      // REST не віддав пристрої: якщо це збій хмари (0 = зависання, 5xx), пробуємо push-канал у фоні
      if (!bind && (dev.s === 0 || dev.s >= 500)) {
        // @ts-ignore EdgeRuntime є в Supabase Edge
        EdgeRuntime.waitUntil(wsFallback(tok, { status: dev.s, devices: dev.j }).catch((e) => console.error('ws', e)));
        return new Response('rest ' + dev.s + ', ws fallback');
      }
      await sb.from('bluetti_log').insert({ online: null, raw: { devices: dev.j, status: dev.s } });
      return new Response('no devices');
    }
    let bres = '';
    if (bind) {
      const r = await fetch(GW + '/api/bluiotdata/ha/v1/bindDevices', { method: 'POST', headers: { ...H(tok), 'content-type': 'application/json' }, body: JSON.stringify({ bindSnList: list.map((d) => d.sn) }), signal: AbortSignal.timeout(REST_MS) });
      bres = 'bind http ' + r.status + ' ' + (await r.text()).slice(0, 200) + '; ';
    }
    for (const d of list) {
      const sn = d.sn;
      const st = await get(tok, '/api/bluiotdata/ha/v1/deviceStates?sns=' + encodeURIComponent(sn));
      if (st.s === 0 || st.s >= 500) {
        // @ts-ignore EdgeRuntime є в Supabase Edge
        EdgeRuntime.waitUntil(wsFallback(tok, { status: st.s, states: st.j }).catch((e) => console.error('ws', e)));
        return new Response(bres + 'states ' + st.s + ', ws fallback');
      }
      const p = (st.j?.data ?? [])[0] ?? {};
      const online = p.online === undefined ? null : (p.online === true || p.online === 1 || p.online === '1');
      const l: any[] = p.stateList ?? [];
      await sb.from('bluetti_log').insert({ sn, online, soc: num(l, 'SOC'), grid_w: num(l, 'GridAllTotalPower'), ac_w: num(l, 'ACLoadAllTotalPower'), raw: { status: st.s, product: p } });
    }
    return new Response(bres + 'ok ' + list.length);
  } catch (e) {
    return new Response('err ' + String(e).slice(0, 100), { status: 500 });
  }
});
