import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

const SSO = 'https://sso.bluettipower.com';
const REDIRECT = 'http://localhost:8123/cb';
const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const out = (m: string) => new Response(m, { headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store', 'referrer-policy': 'no-referrer' } });

Deno.serve(async (req) => {
  try {
    const q = new URL(req.url).searchParams;
    let code = q.get('code') || '';
    let state = q.get('state') || '';
    const u = q.get('u') || '';
    if (u) {
      try { const x = new URL(u); code = code || x.searchParams.get('code') || ''; state = state || x.searchParams.get('state') || ''; } catch (_) { /* ignore */ }
    }
    if (!code || !state) return out('Paste the whole localhost:8123/cb?... address right after ?u= in this link. No code or state found.');
    const { data: a } = await sb.from('bluetti_auth').select('state,state_exp').eq('id', 1).maybeSingle();
    if (!a || !a.state || a.state !== state || new Date(a.state_exp).getTime() < Date.now()) return out('State does not match or has expired. Start again.');
    const body = new URLSearchParams({
      grant_type: 'authorization_code', code,
      client_id: 'HomeAssistant', client_secret: Deno.env.get('BLUETTI_CLIENT_SECRET') || '',
      redirect_uri: REDIRECT });
    const r = await fetch(SSO + '/oauth2/token', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body });
    const t = await r.json().catch(() => ({}));
    const at = t.access_token ?? t.data?.access_token;
    if (!r.ok || !at) return out('Bluetti rejected the code: HTTP ' + r.status + ', error=' + String(t.error || t.msg || t.message || '?').slice(0, 80));
    const rt = t.refresh_token ?? t.data?.refresh_token ?? null;
    const ei = Number(t.expires_in ?? t.data?.expires_in ?? 0);
    const exp = ei ? new Date(Date.now() + ei * 1000).toISOString() : null;
    await sb.from('bluetti_auth').update({ access_token: at, refresh_token: rt, expires_at: exp, state: null, state_exp: null, updated: new Date().toISOString() }).eq('id', 1);
    return out('OK: linked. refresh=' + (rt ? 'yes' : 'no') + ', expires=' + (exp || 'unknown'));
  } catch (e) {
    return out('Error: ' + String(e).slice(0, 100));
  }
});
