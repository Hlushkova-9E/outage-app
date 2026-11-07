import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

const SSO = 'https://sso.bluettipower.com';
const GW = 'https://gw.bluettipower.com';
const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const H = (tok: string) => ({ Authorization: tok, 'x-os': 'open', 'x-app-key': Deno.env.get('BLUETTI_APP_KEY') || '', 'x-app-ver': '1.0.0' });

async function refresh(rt: string) {
  const r = await fetch(SSO + '/oauth2/token', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: rt, client_id: 'HomeAssistant', client_secret: Deno.env.get('BLUETTI_CLIENT_SECRET') || '' }) });
  const t = await r.json().catch(() => ({}));
  const at = t.access_token ?? t.data?.access_token;
  if (!r.ok || !at) return null;
  const ei = Number(t.expires_in ?? t.data?.expires_in ?? 0);
  const upd = { access_token: at, refresh_token: t.refresh_token ?? t.data?.refresh_token ?? rt, expires_at: ei ? new Date(Date.now() + ei * 1000).toISOString() : null, updated: new Date().toISOString() };
  await sb.from('bluetti_auth').update(upd).eq('id', 1);
  return at as string;
}

const get = (tok: string, path: string) => fetch(GW + path, { headers: H(tok) }).then(async (r) => ({ s: r.status, j: await r.json().catch(() => ({})) }));
const expired = (x: { s: number; j: any }) => x.s === 401 || x.s === 403 || x.j?.msgCode === 805;
const num = (l: any[], code: string) => { const v = l.find((x) => x.fnCode === code)?.fnValue; const n = Number(v); return v === undefined || v === null || v === '' || Number.isNaN(n) ? null : n; };

Deno.serve(async (req) => {
  try {
    const qs = new URL(req.url).searchParams;
    const bind = qs.get('bind') === '1';
    const force = qs.get('force') === '1';
    const { data: a } = await sb.from('bluetti_auth').select('*').eq('id', 1).maybeSingle();
    if (!a?.access_token) return new Response('not linked', { status: 200 });
    let tok = a.access_token as string;
    if (a.refresh_token && a.expires_at && new Date(a.expires_at).getTime() - Date.now() < 7 * 86400000) tok = (await refresh(a.refresh_token)) || tok;
    if (!bind && !force) {
      const { data: last } = await sb.from('bluetti_log').select('at').order('at', { ascending: false }).limit(1).maybeSingle();
      if (last && Date.now() - new Date(last.at).getTime() < 90000) return new Response('too soon');
    }
    let dev = await get(tok, '/api/bluiotdata/ha/v1/devices');
    if (expired(dev) && a.refresh_token) { const n = await refresh(a.refresh_token); if (n) { tok = n; dev = await get(tok, '/api/bluiotdata/ha/v1/devices'); } }
    const list: any[] = dev.j?.data ?? [];
    if (!list.length) { await sb.from('bluetti_log').insert({ online: null, raw: { devices: dev.j, status: dev.s } }); return new Response('no devices'); }
    let bres = '';
    if (bind) {
      const r = await fetch(GW + '/api/bluiotdata/ha/v1/bindDevices', { method: 'POST', headers: { ...H(tok), 'content-type': 'application/json' }, body: JSON.stringify({ bindSnList: list.map((d) => d.sn) }) });
      bres = 'bind http ' + r.status + ' ' + (await r.text()).slice(0, 200) + '; ';
    }
    for (const d of list) {
      const sn = d.sn;
      const st = await get(tok, '/api/bluiotdata/ha/v1/deviceStates?sns=' + encodeURIComponent(sn));
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
