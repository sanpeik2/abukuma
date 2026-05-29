/* =====================================================================
 * 阿武隈 O&M / 朝会コックピット 共通Supabaseクライアント
 * ---------------------------------------------------------------------
 * 使い方（各HTMLで）:
 *   <script src="./lib/supabase.js"></script>
 *   <script>
 *     sb.requireLogin();                       // ログインオーバーレイを自動表示
 *     const rows = await sb.get('v_xxx?select=*');   // SELECT(ビュー/テーブル)
 *     const one  = await sb.rpc('get_morning_context', {}); // RPC呼び出し
 *   </script>
 *
 * ★セキュリティ: ここに入れてよいのは anon(publishable)キーのみ。
 *   service_role キーは絶対に置かない（全権限が漏れる）。守りはRLSが担当。
 * ===================================================================== */
(function (global) {
  'use strict';

  const SUPA_URL = 'https://kwhashtnuzrlzrpikhne.supabase.co';
  // anon(publishable)キー。公開前提で安全。RLSで権限制御される。
  const ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt3aGFzaHRudXpybHpycGlraG5lIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk2NjExNTIsImV4cCI6MjA5NTIzNzE1Mn0.rYfWQL6zDkl0WKkguHx_mtHg9g3MGij_Z8Ge35QYl_k';

  const TOKEN_KEY   = 'sb_access_token';
  const REFRESH_KEY = 'sb_refresh_token';

  const getToken = () => sessionStorage.getItem(TOKEN_KEY) || ANON_KEY;

  function headers(extra) {
    return Object.assign({
      'apikey': ANON_KEY,
      'Authorization': 'Bearer ' + getToken(),
      'Content-Type': 'application/json'
    }, extra || {});
  }

  /* ---- REST: SELECT ---- */
  // path 例: 'v_report_candidates?select=*&order=detected_at.desc'
  async function get(path) {
    const res = await fetch(`${SUPA_URL}/rest/v1/${path}`, { headers: headers() });
    if (!res.ok) throw new Error('HTTP ' + res.status + ' ' + (await res.text()).slice(0, 200));
    return res.json();
  }

  /* ---- REST: INSERT/UPDATE/DELETE（必要なら） ---- */
  async function write(method, path, body) {
    const res = await fetch(`${SUPA_URL}/rest/v1/${path}`, {
      method,
      headers: headers({ 'Prefer': 'return=representation' }),
      body: body != null ? JSON.stringify(body) : undefined
    });
    if (!res.ok) throw new Error('HTTP ' + res.status + ' ' + (await res.text()).slice(0, 200));
    return res.json();
  }

  /* ---- RPC ---- */
  async function rpc(fn, args) {
    const res = await fetch(`${SUPA_URL}/rest/v1/rpc/${fn}`, {
      method: 'POST', headers: headers(), body: JSON.stringify(args || {})
    });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    return res.json();
  }

  /* ---- Auth ---- */
  async function login(email, password) {
    const res = await fetch(`${SUPA_URL}/auth/v1/token?grant_type=password`, {
      method: 'POST',
      headers: { 'apikey': ANON_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password })
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error_description || 'ログイン失敗');
    sessionStorage.setItem(TOKEN_KEY, data.access_token);
    sessionStorage.setItem(REFRESH_KEY, data.refresh_token);
    return data;
  }

  function logout() {
    sessionStorage.removeItem(TOKEN_KEY);
    sessionStorage.removeItem(REFRESH_KEY);
  }

  async function isLoggedIn() {
    const t = sessionStorage.getItem(TOKEN_KEY);
    if (!t) return false;
    try {
      const r = await fetch(`${SUPA_URL}/auth/v1/user`, { headers: headers() });
      return r.ok;
    } catch { return false; }
  }

  /* ---- ログインオーバーレイ（共通UI）----
   * 既存セッションがあれば自動で閉じ onReady を実行。
   * options.onReady : ログイン確定後に呼ばれるコールバック（データ取得など）
   */
  function requireLogin(options) {
    options = options || {};
    const onReady = options.onReady || function () {};

    if (!document.getElementById('sbLoginOverlay')) injectOverlay();

    const ov  = document.getElementById('sbLoginOverlay');
    const btn = document.getElementById('sbLoginBtn');
    const err = document.getElementById('sbLoginErr');

    async function submit() {
      const email = document.getElementById('sbLoginEmail').value.trim();
      const pass  = document.getElementById('sbLoginPass').value;
      btn.textContent = 'ログイン中...'; btn.disabled = true; err.style.display = 'none';
      try {
        await login(email, pass);
        ov.style.display = 'none';
        onReady();
      } catch (e) {
        err.textContent = e.message; err.style.display = 'block';
        btn.textContent = 'ログイン'; btn.disabled = false;
      }
    }
    btn.onclick = submit;
    document.addEventListener('keydown', e => {
      if (e.key === 'Enter' && ov.style.display !== 'none') submit();
    });

    // セッション復元
    isLoggedIn().then(ok => {
      if (ok) { ov.style.display = 'none'; onReady(); }
    });
  }

  function injectOverlay() {
    const css = `
      #sbLoginOverlay{position:fixed;inset:0;background:rgba(13,17,23,.96);display:flex;align-items:center;justify-content:center;z-index:9999;font-family:"Segoe UI","Meiryo",sans-serif}
      #sbLoginOverlay .b{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:28px 30px;width:340px}
      #sbLoginOverlay h2{font-size:17px;color:#fff;margin:0 0 14px}
      #sbLoginOverlay input{width:100%;background:#0d1117;border:1px solid #30363d;color:#c9d1d9;padding:9px 12px;border-radius:8px;margin-bottom:10px;font-size:13px;box-sizing:border-box}
      #sbLoginOverlay button{width:100%;background:#58a6ff;border:none;color:#04101f;font-weight:700;padding:10px;border-radius:8px;cursor:pointer;font-size:13.5px}
      #sbLoginErr{color:#f85149;font-size:12px;margin-top:8px;display:none}`;
    const style = document.createElement('style'); style.textContent = css; document.head.appendChild(style);
    const div = document.createElement('div');
    div.id = 'sbLoginOverlay';
    div.innerHTML = `<div class="b">
        <h2>ログイン（O&M OS）</h2>
        <input id="sbLoginEmail" type="email" placeholder="メールアドレス" autocomplete="username">
        <input id="sbLoginPass" type="password" placeholder="パスワード" autocomplete="current-password">
        <button id="sbLoginBtn">ログイン</button>
        <div id="sbLoginErr"></div>
      </div>`;
    document.body.appendChild(div);
  }

  /* ---- 便利ヘルパ ---- */
  const fmtDateTime = s => s ? new Date(s).toLocaleString('ja-JP', { timeZone: 'Asia/Tokyo', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }) : '–';
  const esc = s => (s == null ? '' : String(s)).replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));

  global.sb = {
    URL: SUPA_URL,
    get, write, rpc,
    login, logout, isLoggedIn, requireLogin,
    headers, fmtDateTime, esc
  };
})(window);
