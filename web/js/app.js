/* 游戏方舟面板前端 —— 原生 JS，无任何外部依赖 */

/* ---------------- 基础工具 ---------------- */

const $ = (sel, el = document) => el.querySelector(sel);
const $$ = (sel, el = document) => Array.from(el.querySelectorAll(sel));

let TOKEN = localStorage.getItem('gp_token') || '';

/* 导航审计：记录每一次页面切换/登录跳转，便于定位"无缘无故退出" */
const navLog = [];
function logNav(reason) {
  const entry = { t: new Date().toLocaleTimeString(), view: currentView, reason };
  navLog.push(entry);
  if (navLog.length > 30) navLog.shift();
  localStorage.setItem('gp_navlog', JSON.stringify(navLog.slice(-20)));
  console.log('[nav]', entry);
}

let loginPending = 0;
function api(path, opts = {}) {
  const cfg = {
    method: opts.method || 'GET',
    headers: { 'Authorization': 'Bearer ' + TOKEN },
  };
  if (opts.body !== undefined) {
    cfg.headers['Content-Type'] = 'application/json';
    cfg.body = JSON.stringify(opts.body);
  }
  if (opts.raw !== undefined) { cfg.body = opts.raw; }
  const doFetch = () => fetch('/api/v1' + path, cfg).then(async r => {
    if (opts.binary) return r;
    const data = await r.json().catch(() => ({ code: -1, msg: '响应解析失败' }));
    if (data.code === 401) {
      // 会话失效：给出原因并缓冲 2 秒跳登录（期间成功请求会取消跳转）
      if (!loginPending) {
        loginPending = Date.now();
        logNav('401 会话失效 -> 登录页');
        toast('登录已失效，即将回到登录页', 'err');
        setTimeout(() => { if (Date.now() - loginPending >= 1900) showLogin(); }, 2000);
      }
      throw new Error('登录已过期');
    }
    loginPending = 0;
    return data;
  });
  // 网络容错：面板重启/瞬断时重试一次，失败返回 -1（绝不触发跳转）
  return doFetch().catch(err => {
    if (String(err.message).includes('登录')) throw err;
    return new Promise(res => setTimeout(() => doFetch().then(res).catch(() => res({ code: -1, msg: '连接面板失败' })), 800));
  });
}

/* ---------------- 主题 ---------------- */

const THEMES = [
  { key: 'auto', icon: '🌓', label: '跟随系统' },
  { key: 'light', icon: '☀️', label: '浅色' },
  { key: 'dark', icon: '🌙', label: '暗色' }
];
let themeIdx = THEMES.findIndex(t => t.key === (localStorage.getItem('gp_theme') || 'auto'));
if (themeIdx < 0) themeIdx = 0;

function applyTheme() {
  const t = THEMES[themeIdx];
  const dark = t.key === 'dark' || (t.key === 'auto' && matchMedia('(prefers-color-scheme: dark)').matches);
  if (dark) document.documentElement.setAttribute('data-theme', 'dark');
  else document.documentElement.removeAttribute('data-theme');
  localStorage.setItem('gp_theme', t.key);
  const btn = $('#theme-btn');
  if (btn) { btn.textContent = t.icon; btn.title = '主题：' + t.label + '（点击切换）'; }
}

function cycleTheme() {
  themeIdx = (themeIdx + 1) % THEMES.length;
  applyTheme();
  toast('主题：' + THEMES[themeIdx].label, '');
}

/* 系统主题变化时，auto 模式实时跟随 */
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
  if (THEMES[themeIdx].key === 'auto') applyTheme();
});

/* ---------------- 骨架屏 / 空状态 ---------------- */

function skeletonRows(n = 4) {
  let out = '';
  for (let i = 0; i < n; i++) {
    out += `<div class="skeleton-row">
      <div class="skeleton skel-avatar"></div>
      <div style="flex:1"><div class="skeleton skel-title"></div><div class="skeleton skel-line"></div></div>
      <div class="skeleton" style="width:70px;height:22px"></div>
    </div>`;
  }
  return `<div class="card"><div class="skeleton skel-title" style="width:130px;height:18px;margin-bottom:6px"></div>${out}</div>`;
}

function skeletonCards(n = 4) {
  let out = '';
  for (let i = 0; i < n; i++) out += '<div class="skeleton skel-card"></div>';
  return `<div class="grid cards">${out}</div>`;
}

function emptyState(icon, title, desc, actionHtml = '') {
  return `<div class="empty-state">
    <div class="es-icon">${icon}</div>
    <div class="es-title">${esc(title)}</div>
    ${desc ? `<div class="es-desc">${esc(desc)}</div>` : ''}
    ${actionHtml ? `<div class="es-action">${actionHtml}</div>` : ''}
  </div>`;
}

/* ---------------- toast ---------------- */

function toast(msg, type = '') {
  const ico = type === 'ok' ? '✓' : type === 'err' ? '✕' : 'ℹ';
  const el = document.createElement('div');
  el.className = 'toast ' + type;
  el.innerHTML = `<span class="t-ico">${ico}</span><span></span>`;
  el.lastElementChild.textContent = msg;
  $('#toast-root').appendChild(el);
  const life = type === 'err' ? 4200 : 2600;
  setTimeout(() => { el.classList.add('out'); setTimeout(() => el.remove(), 260); }, life);
}

function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function fmtSize(n) {
  if (n == null) return '-';
  if (n < 1024) return n + ' B';
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
  if (n < 1024 * 1024 * 1024) return (n / 1024 / 1024).toFixed(1) + ' MB';
  return (n / 1024 / 1024 / 1024).toFixed(2) + ' GB';
}

/* ---------------- 登录 ---------------- */

function showLogin() {
  logNav('showLogin');
  $('#app').classList.add('hidden');
  $('#login-page').classList.remove('hidden');
}

function showApp() {
  $('#login-page').classList.add('hidden');
  $('#app').classList.remove('hidden');
  startNotifyPolling();
}

let ME = { username: '', role: '' };

async function doLogin() {
  const user = $('#login-user') ? $('#login-user').value.trim() : '';
  const pass = $('#login-pass').value;
  const r = await fetch('/api/v1/auth/login', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: user, password: pass })
  }).then(r => r.json());
  if (r.code === 0) {
    TOKEN = r.data.token;
    ME = { username: r.data.username, role: r.data.role };
    localStorage.setItem('gp_token', TOKEN);
    localStorage.setItem('gp_me', JSON.stringify(ME));
    showApp();
    refreshTop();
    switchView('overview');
  } else {
    $('#login-err').textContent = r.msg || '登录失败';
  }
}

async function logout() {
  try { await api('/auth/logout', { method: 'POST' }); } catch (e) {}
  TOKEN = '';
  localStorage.removeItem('gp_token');
  showLogin();
}

/* ---------------- 全局快捷键与帮助 ---------------- */

const SHORTCUTS = [
  ['1 – 6', '切换导航页（总览/实例/任务/组网/用户/诊断）'],
  ['/', '聚焦实例搜索框'],
  ['n', '新建实例（打开创建向导）'],
  ['?', '显示本帮助'],
  ['Esc', '关闭弹窗 / 通知面板'],
  ['↑ ↓', '控制台内切换命令历史']
];

function showHelp() {
  modal('⌨️ 键盘快捷键', `
    <table class="tbl">
      ${SHORTCUTS.map(([k, d]) => `<tr><td class="mono" style="white-space:nowrap"><b>${esc(k)}</b></td><td class="muted">${esc(d)}</td></tr>`).join('')}
    </table>
    <div class="kv-note" style="margin-top:14px">输入框获得焦点时快捷键自动失效（不打字干扰）。</div>
    <div class="modal-actions"><button class="btn" onclick="closeModal()">知道了</button></div>`);
}

/* 全局键盘路由：输入态不打扰 */
document.addEventListener('keydown', e => {
  const tag = (document.activeElement?.tagName || '').toLowerCase();
  const typing = tag === 'input' || tag === 'textarea' || tag === 'select';
  if (e.key === 'Escape') {
    if ($('#modal-root').innerHTML.trim()) { closeModal(); return; }
    const np = $('#notify-panel');
    if (np) np.remove();
    return;
  }
  if (typing || e.ctrlKey || e.metaKey || e.altKey) return;
  if (e.key === '?') { showHelp(); return; }
  if (e.key === '/') {
    const search = $('input[placeholder^="🔍 搜索实例"]');
    if (search) { e.preventDefault(); search.focus(); }
    return;
  }
  if (e.key === 'n') { showCreateDialog(); return; }
  const navKeys = { '1': 'overview', '2': 'instances', '3': 'tasks', '4': 'mesh', '5': 'users', '6': 'diag' };
  const v = navKeys[e.key];
  if (v) {
    if ((v === 'users' || v === 'diag') && ME.role !== 'admin') { toast('该页面仅管理员可见', ''); return; }
    switchView(v);
  }
});

/* ---------------- 通知中心 ---------------- */

let notifyTimer = null;
const KIND_META = {
  instance: ['⚠️', 'var(--red)'],
  task: ['⏰', 'var(--amber)'],
  mesh: ['🌐', 'var(--violet)']
};

function startNotifyPolling() {
  if (notifyTimer) clearInterval(notifyTimer);
  refreshBell();
  notifyTimer = setInterval(refreshBell, 30000);
}

async function refreshBell() {
  const r = await api('/notifications').catch(() => null);
  if (!r || r.code !== 0) return;
  const dot = $('#bell-dot');
  if (!dot) return;
  dot.classList.toggle('hidden', !(r.data.unread > 0));
  dot.textContent = r.data.unread > 99 ? '99+' : r.data.unread;
}

function toggleNotifyPanel() {
  const existing = $('#notify-panel');
  if (existing) { existing.remove(); return; }
  const panel = document.createElement('div');
  panel.id = 'notify-panel';
  panel.className = 'notify-panel';
  panel.innerHTML = '<div class="empty-tip" style="padding:20px">加载中…</div>';
  document.body.appendChild(panel);
  loadNotifyPanel();
}

async function loadNotifyPanel() {
  const panel = $('#notify-panel');
  if (!panel) return;
  const r = await api('/notifications');
  if (r.code !== 0) { panel.innerHTML = `<div class="empty-tip">${esc(r.msg)}</div>`; return; }
  const items = r.data.items || [];
  const [markReadBtn, clearBtn] = [items.some(i => !i.read), items.length > 0];
  panel.innerHTML = `
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:10px">
      <b>🔔 通知${r.data.unread ? `（${r.data.unread} 未读）` : ''}</b>
      <span style="display:flex;gap:6px">
        ${markReadBtn ? '<button class="btn small" onclick="notifyReadAll()">全部已读</button>' : ''}
        ${clearBtn ? '<button class="btn small danger" onclick="notifyClear()">清空</button>' : ''}
        <button class="btn small ghost" onclick="toggleNotifyPanel()">✕</button>
      </span>
    </div>
    <div style="max-height:380px;overflow-y:auto">
      ${items.length ? items.map(n => {
        const [ico, color] = KIND_META[n.kind] || ['📌', 'var(--muted)'];
        return `
        <div class="notify-item ${n.read ? '' : 'unread'}">
          <span style="font-size:17px;flex-shrink:0">${ico}</span>
          <div style="flex:1;min-width:0">
            <div style="display:flex;justify-content:space-between;gap:8px">
              <b style="font-size:13px;color:${color}">${esc(n.title)}</b>
              <span class="muted" style="font-size:11px;white-space:nowrap">${esc(n.time)}</span>
            </div>
            <div class="muted" style="font-size:12px;margin-top:2px">${esc(n.body)}</div>
          </div>
        </div>`;
      }).join('') : '<div class="empty-tip" style="padding:26px">🎉 没有通知</div>'}
    </div>`;
}

async function notifyReadAll() {
  await api('/notifications/read-all', { method: 'POST' });
  loadNotifyPanel();
  refreshBell();
}

async function notifyClear() {
  await api('/notifications/clear', { method: 'POST' });
  loadNotifyPanel();
  refreshBell();
}

/* ---------------- 修改密码 ---------------- */

function showChangePass() {
  if (!ME.username) { toast('请先登录', 'err'); return; }
  modal('修改密码（' + esc(ME.username) + '）', `
    <div class="form-row"><label>旧密码</label><input class="inp" id="cp-old" type="password" autocomplete="current-password"></div>
    <div class="form-row"><label>新密码（至少 8 位）</label><input class="inp" id="cp-new" type="password" autocomplete="new-password"></div>
    <div class="form-row"><label>确认新密码</label><input class="inp" id="cp-new2" type="password" autocomplete="new-password"></div>
    <div class="kv-note" style="margin-top:0">改密不影响当前会话；其他已登录设备仍可用旧会话直到过期（管理员可在用户页踢出）。</div>
    <div class="modal-actions">
      <button class="btn" onclick="closeModal()">取消</button>
      <button class="btn primary" onclick="doChangePass()">确认修改</button>
    </div>`);
  $('#cp-old').focus();
}

async function doChangePass() {
  const old = $('#cp-old').value, np = $('#cp-new').value, np2 = $('#cp-new2').value;
  if (!old || !np) { toast('请填写完整', 'err'); return; }
  if (np !== np2) { toast('两次输入的新密码不一致', 'err'); return; }
  if (np.length < 8) { toast('新密码至少 8 位', 'err'); return; }
  const r = await api('/auth/change-password', { method: 'POST', body: { oldPassword: old, newPassword: np } });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  if (r.code === 0) closeModal();
}

/* ---------------- 顶部统计 ---------------- */

async function refreshTop() {
  const r = await api('/overview');
  if (r.code !== 0) return;
  const d = r.data;
  $('#top-stats').textContent = `实例 ${d.instanceCount} · 运行中 ${d.runningCount} · 数据 ${fmtSize(d.dataUsedMB * 1024 * 1024)} · 磁盘可用 ${d.diskAvailGB.toFixed(1)} GB`;
  const chip = $('#user-chip');
  if (chip) {
    const roleLabel = { admin: '管理员', operator: '运维', viewer: '访客' }[ME.role] || ME.role;
    chip.innerHTML = `<span>${esc(ME.username || '?')}</span><span class="badge badge-info" style="font-size:11px;padding:1px 8px">${esc(roleLabel)}</span>`;
    chip.title = '点击修改密码';
    chip.style.cursor = 'pointer';
    chip.onclick = showChangePass;
    chip.classList.remove('hidden');
  }
  const badge = $('#docker-badge');
  badge.textContent = d.dockerOk ? 'Docker 正常' : 'Docker 不可用';
  badge.className = 'badge' + (d.dockerOk ? '' : ' bad');
}

/* ---------------- 视图切换 ---------------- */

let currentView = 'overview';
let opTimer = null;
let consoleTimer = null;

function switchView(view) {
  logNav('switchView -> ' + view);
  currentView = view;
  if (consoleTimer) { clearInterval(consoleTimer); consoleTimer = null; }
  $$('.nav-item').forEach(a => a.classList.toggle('active', a.dataset.view === view));
  $('#main').innerHTML = skeletonRows(5);
  if (view === 'overview') renderOverview();
  if (view === 'instances') renderInstances();
  if (view === 'tasks') renderTasks();
  if (view === 'about') renderAbout();
  if (view === 'users') renderUsers();
  if (view === 'diag') renderDiag();
  if (view === 'mesh') renderMesh();
}

/* ---------------- 总览 ---------------- */

let overviewTimer = null;
let instFilter = '';

async function renderOverview() {
  if (overviewTimer) { clearTimeout(overviewTimer); }
  const [r, ov] = await Promise.all([api('/instances'), api('/overview').catch(() => ({ code: -1 }))]);
  if (r.code !== 0) return;
  const list = r.data;
  const running = list.filter(i => i.status === 'running').length;
  // 磁盘与数据目录可视化（overview 聚合）
  let diskCard = '';
  if (ov.code === 0) {
    const d = ov.data;
    const total = d.diskTotalGB || 0;
    const avail = d.diskAvailGB || 0;
    const usedPct = total > 0 ? Math.min(100, (total - avail) / total * 100) : 0;
    diskCard = `
      <div class="card lift">
        <div class="stat-num" style="font-size:20px">${avail.toFixed(1)} <span style="font-size:13px;color:var(--muted)">/ ${total.toFixed(0)} GB 可用</span></div>
        <div class="stat-label" style="margin-bottom:8px">💾 磁盘（已用 ${usedPct.toFixed(0)}%）</div>
        <div class="progress"><div style="width:${usedPct}%;background:${usedPct > 85 ? 'var(--red)' : usedPct > 70 ? 'var(--amber)' : 'var(--primary)'}"></div></div>
        <div class="stat-label" style="margin-top:6px">数据目录 ${fmtSize((d.dataUsedMB || 0) * 1024 * 1024)}</div>
      </div>`;
  }
  $('#main').innerHTML = `
    <div class="grid cols-4 mb">
      ${statCard('🎮', list.length, '实例总数')}
      ${statCard('✅', running, '运行中')}
      ${statCard('⏹', list.length - running, '已停止')}
      ${diskCard}
    </div>
    <div class="card">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
        <h3 style="margin:0">实例（10 秒自动刷新）</h3>
        <input class="inp" style="max-width:220px" placeholder="🔍 搜索实例…" value="${esc(instFilter)}" oninput="filterInst(this.value)">
      </div>
      <div class="grid cards" id="ov-cards"></div></div>`;
  drawInstCards(list);
  refreshTop();
  overviewTimer = setTimeout(() => { if (currentView === 'overview') renderOverview(); }, 10000);
}

function filterInst(v) { instFilter = v; }
function drawInstCards(list) {
  const f = instFilter.trim().toLowerCase();
  const shown = f ? list.filter(i => (i.name + i.gameTitle + i.id).toLowerCase().includes(f)) : list;
  renderInstCards(shown, $('#ov-cards'));
}

function statCard(icon, num, label) {
  return `<div class="card"><div class="stat-num">${icon} ${num}</div><div class="stat-label">${label}</div></div>`;
}

const STATUS_TEXT = { running: '运行中', exited: '已停止', missing: '未创建', paused: '已暂停', created: '已创建', pulling: '拉取镜像中…' };
const OP_TEXT = { stopping: '停止中…', restarting: '重启中…', 'backing-up': '备份中…', snapshotting: '快照中…', restoring: '恢复中…' };

function renderInstCards(list, box) {
  if (list.length === 0) {
    box.innerHTML = emptyState('🎮', '还没有实例', '选择一款游戏，几分钟即可开服', '<button class="btn primary" onclick="showCreateDialog()">＋ 创建第一个实例</button>');
    return;
  }
  box.innerHTML = list.map(i => {
    const op = i.operation || '';
    const busy = !!op;
    const statusHtml = busy
      ? `<span class="dot other"></span><b>${OP_TEXT[op] || op}</b>`
      : `<span class="dot ${i.status}"></span>${STATUS_TEXT[i.status] || i.status}`;
    return `
    <div class="card inst-card">
      <div class="inst-head">
        <div class="inst-icon">${i.icon}</div>
        <div>
          <div class="inst-name">${esc(i.name)}</div>
          <div class="inst-game">${esc(i.gameTitle)} · ${esc(i.version)}</div>
        </div>
      </div>
      <div class="inst-meta">
        <span>${statusHtml}</span>
        <span>端口 ${esc(i.ports.map(p => p.split(':')[0]).join('/'))}${i.useMesh ? '（虚拟网直连，详见联机组网页）' : ''}</span>
        <span>${fmtSize(i.memoryMB * 1024 * 1024)} 内存</span>
        ${i.node && i.node !== 'local' ? `<span class="badge">🖥 ${esc(i.node)}</span>` : ''}
        ${i.useMesh ? `<span class="badge" style="background:var(--violet-soft);color:var(--violet)">🌐 组网</span>` : ''}
      </div>
      <div>
        <div class="muted" style="font-size:12px">CPU ${esc(i.cpuPercent) || '-'} · 内存 ${esc(i.memUsage) || '-'}</div>
        <div class="usage-bar mt" style="margin-top:6px"><div class="usage-fill" style="width:${cpuPct(i.cpuPercent)}%"></div></div>
      </div>
      <div class="inst-actions">
        ${i.status === 'running'
          ? `<button class="btn small" ${busy ? 'disabled' : ''} onclick="instAction('${i.id}','stop', this)">停止</button>`
          : `<button class="btn small primary" ${busy ? 'disabled' : ''} onclick="instAction('${i.id}','start', this)">启动</button>`}
        <button class="btn small" ${busy ? 'disabled' : ''} onclick="instAction('${i.id}','restart', this)">重启</button>
        <button class="btn small" onclick="openInstance('${i.id}')">详情</button>
        ${ME.role === 'admin' ? `<button class="btn small danger" ${busy ? 'disabled' : ''} onclick="delInstance('${i.id}','${esc(i.name)}')">删除</button>` : ''}
      </div>
    </div>`;
  }).join('');
  // 有进行中的操作时，3 秒后自动刷新（操作完成状态自动翻转）
  if (opTimer) { clearTimeout(opTimer); opTimer = null; }
  if (list.some(i => i.operation)) {
    opTimer = setTimeout(() => {
      if (currentView === 'overview') renderOverview();
      else if (currentView === 'instances') renderInstances();
    }, 3000);
  }
}

function cpuPct(s) {
  const m = parseFloat(s);
  return isNaN(m) ? 0 : Math.min(100, m);
}

/* ---------------- 实例列表 ---------------- */

async function renderInstances() {
  const r = await api('/instances');
  if (r.code !== 0) return;
  $('#main').innerHTML = `<div class="card">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
        <h3 style="margin:0">全部实例</h3>
        <button class="btn" onclick="showImportDialog()">📥 导入已有容器</button>
      </div>
      <div class="grid cards" id="inst-box"></div></div>`;
  renderInstCards(r.data, $('#inst-box'));
  refreshTop();
}

async function instAction(id, action, el) {
  // 立即反馈：按钮置忙 + 提示下发；请求后台发出（停止等操作由后端异步执行，状态轮询接管）
  const btn = el || (typeof event !== 'undefined' ? event.target : null);
  if (btn && btn.disabled) return;
  if (btn) { btn.disabled = true; }
  toast('指令已下发', '');
  api(`/instances/${id}/${action}`, { method: 'POST' }).then(r => {
    if (r.code !== 0) toast(r.msg || '操作失败', 'err');
  }).catch(() => {});
  setTimeout(() => { if (currentView === 'overview') renderOverview(); if (currentView === 'instances') renderInstances(); if (currentView === 'detail') refreshCurView(); }, 300);
}

function delInstance(id, name) {
  // 高危操作：输入实例名确认（防手滑）
  modal(`删除实例「${esc(name)}」`, `
    <p>将删除容器、<b>全部数据文件与备份快照</b>，不可恢复。</p>
    <p class="muted">请输入实例名 <b class="mono">${esc(name)}</b> 以确认：</p>
    <input class="inp mono" id="del-confirm-name" placeholder="输入实例名">
    <div class="modal-actions">
      <button class="btn" onclick="closeModal()">取消</button>
      <button class="btn danger" id="del-confirm-btn" disabled onclick="doDelInstance('${id}', '${name.replace(/'/g, "\\'")}')">确认删除</button>
    </div>`);
  const input = $('#del-confirm-name');
  input.oninput = () => { $('#del-confirm-btn').disabled = input.value.trim() !== name; };
  input.focus();
}

async function doDelInstance(id, name) {
  const r = await api(`/instances/${id}/delete`, { method: 'POST' });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  closeModal();
  setTimeout(() => switchView(fromView), 500);
}

/* ---------------- 实例详情 ---------------- */

let CUR = null;   // 当前实例对象
let CUR_TAB = 'console';
let CUR_PATH = '';
let FM_BREADCRUMB = [];

let fromView = 'overview';   // 详情页的返回目标

async function openInstance(id) {
  const r = await api('/instances/' + id);
  if (r.code !== 0) { toast(r.msg, 'err'); return; }
  // 详情页是独立视图：阻止总览/列表的自动刷新定时器覆盖本页
  if (currentView !== 'detail') fromView = currentView;
  currentView = 'detail';
  closeWsConsole();
  if (consoleTimer) { clearInterval(consoleTimer); consoleTimer = null; }
  if (metricsTimer) { clearInterval(metricsTimer); metricsTimer = null; }
  CUR = r.data;
  CUR_TAB = 'console';
  CUR_PATH = '';
  renderDetail();
  loadConsole(true);
}

function backToList() {
  switchView(fromView);
}

async function refreshCur() {
  const r = await api('/instances/' + CUR.id);
  if (r.code === 0) CUR = r.data;
}

function renderDetail() {
  const i = CUR;
  const tabs = [
    ['console', '控制台'], ['files', '文件'], ['backup', '备份'],
    ['snapshot', '快照'], ['mods', 'Mod 管理'], ['metrics', '监控'], ['settings', '设置']
  ];
  if (i.game === 'minecraft') tabs.splice(1, 0, ['players', '玩家']);
  $('#main').innerHTML = `
    <div class="card">
      <div class="inst-head">
        <button class="btn ghost small" style="margin-right:6px" onclick="backToList()">← 返回</button>
        <div class="inst-icon" style="font-size:32px">${i.icon}</div>
        <div style="flex:1">
          <div class="inst-name" style="font-size:17px">${esc(i.name)}</div>
          <div class="inst-game">${esc(i.gameTitle)} · ${esc(i.version)} · ${i.operation ? `<b>${OP_TEXT[i.operation] || i.operation}</b>` : `<span class="dot ${i.status}"></span>${STATUS_TEXT[i.status] || i.status}`}</div>
        </div>
        <div class="inst-actions">
          ${i.status === 'running'
            ? `<button class="btn" onclick="instAction('${i.id}','stop').then(refreshCurView)">停止</button>`
            : `<button class="btn primary" onclick="instAction('${i.id}','start').then(refreshCurView)">启动</button>`}
          <button class="btn" onclick="instAction('${i.id}','restart').then(refreshCurView)">重启</button>
        </div>
      </div>
    </div>
    <div class="tabs">${tabs.map(([k, t]) => `<div class="tab ${CUR_TAB === k ? 'active' : ''}" onclick="switchTab('${k}', this)">${t}</div>`).join('')}</div>
    <div id="tab-body"></div>`;
  renderTabBody();
  scheduleDetailRefresh();
}

function refreshCurView() { refreshCur().then(renderDetail); }

/* 详情页：有进行中的操作时 3 秒轮询；仅在操作状态发生变化时重渲染，
   避免把用户正在编辑的表单（如游戏配置）重置掉 */
let lastDetailOp = '';
function scheduleDetailRefresh() {
  if (CUR && CUR.operation) {
    lastDetailOp = CUR.operation;
    setTimeout(async () => {
      if (currentView !== 'detail') return;
      await refreshCur();
      const changed = CUR.operation !== lastDetailOp;
      if (changed) {
        renderDetail();
        scheduleDetailRefresh();
      } else {
        // 操作未结束：只更新头部状态行，不动 tab 内容
        scheduleDetailRefresh();
      }
    }, 3000);
  }
}

function switchTab(tab, el) {
  CUR_TAB = tab;
  if (consoleTimer && tab !== 'console') { clearInterval(consoleTimer); consoleTimer = null; }
  if (tab !== 'console') closeWsConsole();
  if (metricsTimer && tab !== 'metrics') { clearInterval(metricsTimer); metricsTimer = null; }
  $$('.tab').forEach(t => t.classList.remove('active'));
  const tabEl = el || (typeof event !== 'undefined' && event.target && event.target.closest ? event.target.closest('.tab') : null);
  if (tabEl) tabEl.classList.add('active');
  renderTabBody();
}

function renderTabBody() {
  const box = $('#tab-body');
  if (!CUR) {   // 详情未成功加载（如实例已被删除）：给出提示而不是静默崩溃
    if (box) box.innerHTML = '<div class="card"><div class="empty-tip">实例不存在或已被删除，请返回列表刷新</div></div>';
    return;
  }
  if (CUR_TAB === 'console') {
    consoleFilter = '';
    consoleAutoScroll = true;
    consoleNewCount = 0;
    consoleBuf = [];
    box.innerHTML = `
      <div class="card">
        <div class="console-toolbar">
          <input class="inp" id="console-filter" placeholder="🔍 过滤日志（关键字高亮）…" oninput="consoleFilterInput(this.value)" style="flex:1">
          <span class="muted mono" id="console-count" style="font-size:12px;white-space:nowrap">0 行</span>
          <button class="btn small" onclick="consoleExport()" title="导出当前日志（含过滤）">⬇ 导出</button>
          <button class="btn small ghost" onclick="editQuickCmds()" title="自定义快捷命令">⚙ 快捷命令</button>
        </div>
        <div style="position:relative">
          <div class="console-box" id="console-out" onscroll="consoleScrolled(this)">正在建立实时连接…</div>
          <button class="btn small console-float hidden" id="console-float" onclick="consoleGoBottom()">↓ 回到底部</button>
        </div>
        <div class="console-input">
          <input class="inp" id="cmd-input" placeholder="命令（↑↓ 切换历史，回车发送）" onkeydown="if(event.key==='Enter')sendCmd();cmdHistKey(event)">
          <button class="btn primary" onclick="sendCmd()">发送</button>
        </div>
        <div class="mt" id="quickcmd-box">
          ${quickCmds().map(c => `<button class="btn small ghost" style="margin:0 6px 6px 0" onclick="quickCmd('${c.cmd.replace(/'/g, "\\'")}')">${esc(c.label)}</button>`).join('')}
        </div>
      </div>`;
    connectWsConsole();
  }
  if (CUR_TAB === 'files') renderFiles();
  if (CUR_TAB === 'backup') renderRecords('backup');
  if (CUR_TAB === 'snapshot') renderRecords('snapshot');
  if (CUR_TAB === 'mods') renderMods();
  if (CUR_TAB === 'players') renderPlayers();
  if (CUR_TAB === 'metrics') renderMetrics();
  if (CUR_TAB === 'settings') renderSettings();
}

/* ----- 控制台（优先 WebSocket 实时流，断线自动回退轮询） ----- */

let wsConsole = null;

function closeWsConsole() {
  if (wsConsole) { try { wsConsole.close(); } catch (e) {} wsConsole = null; }
}

/* ----- 控制台缓冲模型：行数组 + 上限裁剪 + 过滤高亮 + 智能滚动 ----- */

const CONSOLE_MAX_LINES = 2000;
let consoleBuf = [];
let consoleFilter = '';
let consoleAutoScroll = true;     // 用户上滚即暂停，滚回底部自动恢复
let consoleNewCount = 0;          // 暂停期间积累的新行数

function appendConsole(text) {
  const lines = String(text).split('\n');
  for (const l of lines) consoleBuf.push(l);
  if (consoleBuf.length > CONSOLE_MAX_LINES) consoleBuf = consoleBuf.slice(-CONSOLE_MAX_LINES);
  if (!consoleAutoScroll) consoleNewCount += lines.length;
  renderConsole(false);
}

/* 单行转义 + 关键字高亮（先定位后转义，避免过滤器含特殊字符失配） */
function hlLine(line, q) {
  if (!q) return esc(line);
  let out = '';
  let i = 0;
  const low = line.toLowerCase();
  const ql = q.toLowerCase();
  while (i <= line.length) {
    const idx = low.indexOf(ql, i);
    if (idx < 0) { out += esc(line.slice(i)); break; }
    out += esc(line.slice(i, idx)) + '<mark>' + esc(line.slice(idx, idx + q.length)) + '</mark>';
    i = idx + q.length;
  }
  return out;
}

/* ANSI 颜色转义序列剥离（终端日志常见，留着会显示成乱码字面量） */
function stripAnsi(l) { return l.replace(/\x1b\[[0-9;]*m/g, ''); }

function renderConsole(scrollBottom) {
  const box = $('#console-out');
  if (!box) return;
  const q = consoleFilter.trim();
  const cleaned = consoleBuf.map(stripAnsi);
  const lines = q ? cleaned.filter(l => l.toLowerCase().includes(q.toLowerCase())) : cleaned;
  // 保留滚动位置：过滤/新行到达时若非自动滚动模式不跳动
  const keepTop = box.scrollTop;
  box.innerHTML = lines.map(l => '<span class="c-line">' + (l ? hlLine(l, q) : '&nbsp;') + '</span>').join('\n');
  if (scrollBottom || consoleAutoScroll) {
    box.scrollTop = box.scrollHeight;
  } else {
    box.scrollTop = keepTop;
  }
  const fb = $('#console-float');
  if (fb) {
    fb.classList.toggle('hidden', consoleAutoScroll);
    fb.textContent = consoleNewCount > 0 ? `↓ ${consoleNewCount} 行新日志` : '↓ 回到底部';
  }
  const cnt = $('#console-count');
  if (cnt) cnt.textContent = q ? `${lines.length}/${consoleBuf.length} 行` : `${consoleBuf.length} 行`;
}

/* 用户滚动：距底 40px 内恢复自动滚动，之上暂停 */
function consoleScrolled(el) {
  const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
  if (atBottom && !consoleAutoScroll) {
    consoleAutoScroll = true;
    consoleNewCount = 0;
    renderConsole(true);
  } else if (!atBottom && consoleAutoScroll) {
    consoleAutoScroll = false;
    // 暂停自动滚动时立即刷新浮标显示（renderConsole 保持滚动位置不跳动）
    renderConsole(false);
  }
}

function consoleGoBottom() {
  consoleAutoScroll = true;
  consoleNewCount = 0;
  renderConsole(true);
}

function consoleFilterInput(v) {
  consoleFilter = v;
  renderConsole(false);
}

/* 导出当前缓冲（应用过滤）为文本文件 */
function consoleExport() {
  const q = consoleFilter.trim();
  const lines = q ? consoleBuf.filter(l => l.toLowerCase().includes(q.toLowerCase())) : consoleBuf;
  const blob = new Blob([lines.join('\n')], { type: 'text/plain;charset=utf-8' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `console-${(CUR ? CUR.name : 'log').replace(/[^\w\u4e00-\u9fa5-]+/g, '_')}-${new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-')}.log`;
  a.click();
  URL.revokeObjectURL(a.href);
  toast(`已导出 ${lines.length} 行日志`, 'ok');
}

function connectWsConsole() {
  closeWsConsole();
  try {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    wsConsole = new WebSocket(`${proto}//${location.host}/api/v1/instances/${CUR.id}/ws-console?token=${TOKEN}`);
    wsConsole.onopen = () => {
      consoleBuf = [];
      renderConsole(true);
    };
    wsConsole.onmessage = e => {
      appendConsole(e.data);
    };
    wsConsole.onclose = () => {
      wsConsole = null;
      // 断线回退轮询（仍在控制台页时）
      if (CUR_TAB === 'console' && currentView === 'detail' && !consoleTimer) {
        consoleTimer = setInterval(() => loadConsole(false), 2500);
      }
    };
    wsConsole.onerror = () => { if (wsConsole) wsConsole.close(); };
  } catch (e) {
    wsConsole = null;
  }
  // 兜底：3 秒还没收到任何消息则启动轮询
  setTimeout(() => {
    if (CUR_TAB === 'console' && !wsConsole && !consoleTimer) {
      consoleTimer = setInterval(() => loadConsole(false), 2500);
    }
  }, 3000);
}

async function loadConsole(first) {
  if (CUR_TAB !== 'console') return;
  if (wsConsole && wsConsole.readyState === 1) return;   // 实时流在线，无需轮询
  const r = await api(`/instances/${CUR.id}/logs?tail=300`);
  if (r.code === 0) {
    consoleBuf = String(r.data.logs || '（暂无日志）').split('\n');
    if (consoleBuf.length > CONSOLE_MAX_LINES) consoleBuf = consoleBuf.slice(-CONSOLE_MAX_LINES);
    renderConsole(first);
  }
  if (!consoleTimer) consoleTimer = setInterval(() => loadConsole(false), 2500);
}

let CUR_RECS = [];
let cmdHistory = [];
let cmdHistIdx = -1;

async function sendCmd() {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  const input = $('#cmd-input');
  const cmd = input.value.trim();
  if (!cmd) return;
  if (wsConsole && wsConsole.readyState === 1) {
    wsConsole.send(cmd);
    cmdHistory.push(cmd); if (cmdHistory.length > 50) cmdHistory.shift();
    cmdHistIdx = cmdHistory.length;
    input.value = '';
    return;
  }
  const r = await api(`/instances/${CUR.id}/command`, { method: 'POST', body: { cmd } });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  if (r.code === 0) {
    cmdHistory.push(cmd);
    if (cmdHistory.length > 50) cmdHistory.shift();
    cmdHistIdx = cmdHistory.length;
    input.value = '';
    setTimeout(() => loadConsole(false), 800);
  }
}

function cmdHistKey(e) {
  if (e.key === 'ArrowUp') {
    if (cmdHistIdx > 0) { cmdHistIdx--; $('#cmd-input').value = cmdHistory[cmdHistIdx] || ''; }
    e.preventDefault();
  } else if (e.key === 'ArrowDown') {
    if (cmdHistIdx < cmdHistory.length) { cmdHistIdx++; $('#cmd-input').value = cmdHistory[cmdHistIdx] || ''; }
    e.preventDefault();
  }
}

/* ----- 文件管理 ----- */

let FILES_SORT = { key: 'name', dir: 1 };   // name | size，dir 1=升 -1=降
let FILES_SEL = new Set();                   // 多选的相对路径

function filesSortKey() {
  const label = { name: '名称', size: '大小' }[FILES_SORT.key];
  return `按${label}${FILES_SORT.dir > 0 ? '↑' : '↓'}`;
}

function filesToggleSort() {
  if (FILES_SORT.key === 'name') {
    FILES_SORT = FILES_SORT.dir > 0 ? { key: 'name', dir: -1 } : { key: 'size', dir: 1 };
  } else {
    FILES_SORT = FILES_SORT.dir > 0 ? { key: 'size', dir: -1 } : { key: 'name', dir: 1 };
  }
  renderFiles();
}

function filesSorted(d) {
  const arr = [...d.dirs.map(x => ({ ...x, isDir: true })), ...d.files.map(x => ({ ...x, isDir: false }))];
  arr.sort((a, b) => {
    if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;   // 目录永远在前
    let c = 0;
    if (FILES_SORT.key === 'size') c = (a.size || 0) - (b.size || 0);
    else c = a.name.localeCompare(b.name, 'zh-CN', { numeric: true });
    return c * FILES_SORT.dir;
  });
  return arr;
}

function fileSelToggle(path, checked) {
  if (checked) FILES_SEL.add(path); else FILES_SEL.delete(path);
  const n = FILES_SEL.size;
  const bar = $('#files-selbar');
  if (bar) bar.innerHTML = n
    ? `<span class="muted">已选 <b>${n}</b> 项</span> <button class="btn small danger" onclick="filesBatchDelete()">批量删除</button> <button class="btn small" onclick="filesSelClear()">取消选择</button>`
    : '';
}

function filesSelAll(cb) {
  FILES_SEL.clear();
  if (cb.checked) $$('.file-check').forEach(c => { c.checked = true; FILES_SEL.add(c.dataset.path); });
  fileSelToggle('', false);
}

function filesSelClear() { FILES_SEL.clear(); renderFiles(); }

async function filesBatchDelete() {
  const n = FILES_SEL.size;
  if (!n) return;
  confirmModal('批量删除', `确定删除选中的 <b>${n}</b> 项？此操作不可恢复。`, async () => {
    let ok = 0, fail = 0;
    for (const p of FILES_SEL) {
      const r = await api(`/instances/${CUR.id}/file-action`, { method: 'POST', body: { action: 'delete', path: p } });
      r.code === 0 ? ok++ : fail++;
    }
    toast(`批量删除完成：成功 ${ok}${fail ? '，失败 ' + fail : ''}`, fail ? 'err' : 'ok');
    FILES_SEL.clear();
    closeModal();
    renderFiles();
  });
}

async function renderFiles() {
  const r = await api(`/instances/${CUR.id}/files?path=${encodeURIComponent(CUR_PATH)}`);
  const box = $('#tab-body');
  if (r.code !== 0) { box.innerHTML = '<div class="card">加载失败</div>'; return; }
  const d = r.data;
  if (d.error) { box.innerHTML = `<div class="card">${esc(d.error)}</div>`; return; }
  FILES_SEL.clear();
  const items = filesSorted(d);
  const crumbs = ['<a onclick="gotoPath(\'\')">根目录</a>'];
  let acc = '';
  CUR_PATH.split('/').filter(Boolean).forEach(seg => {
    acc += (acc ? '/' : '') + seg;
    const p = acc.replace(/'/g, "\\'");
    crumbs.push(`/ <a onclick="gotoPath('${p}')">${esc(seg)}</a>`);
  });
  const rows = items.map(f => {
    const p = joinPath(f.name);
    const pe = p.replace(/'/g, "\\'");
    return `
    <div class="file-row">
      <input type="checkbox" class="file-check" data-path="${esc(p)}" ${FILES_SEL.has(p) ? 'checked' : ''} onchange="fileSelToggle('${pe}', this.checked)" style="margin-right:8px">
      <span class="fname" onclick="${f.isDir ? `gotoPath('${pe}')` : `openFile('${pe}', ${f.size})`}">
        <span class="file-icon">${f.isDir ? '📁' : fileIcon(f.name)}</span>${esc(f.name)}
      </span>
      <span class="fsize">${f.isDir ? '-' : fmtSize(f.size)}</span>
      <span class="file-ops">
        ${/\.(zip|tar\.gz|tgz|tar)$/i.test(f.name) ? `<button class="btn small" onclick="extractFile('${pe}')">解压</button>` : ''}
        <button class="btn small" onclick="downloadFile('${pe}')">下载</button>
        ${!f.isDir ? `<button class="btn small" onclick="renameFile('${pe}','${esc(f.name)}')">重命名</button>` : ''}
        <button class="btn small danger" onclick="deleteFile('${pe}')">删除</button>
      </span>
    </div>`;
  }).join('');
  const total = items.length;
  box.innerHTML = `
    <div class="card">
      <div class="crumbs">${crumbs.join(' ')}</div>
      <div class="mb" style="display:flex;gap:8px;align-items:center;flex-wrap:wrap">
        <button class="btn small" onclick="mkdirDialog()">新建文件夹</button>
        <label class="btn small">上传文件<input type="file" style="display:none" multiple onchange="uploadFile(this)"></label>
        <button class="btn small" onclick="filesToggleSort()" title="切换排序">↕ ${filesSortKey()}</button>
        ${CUR_PATH ? '<button class="btn small" onclick="gotoPath(parentPath())">⬆ 上级</button>' : ''}
        <span id="files-selbar" style="display:flex;gap:8px;align-items:center;margin-left:auto"></span>
      </div>
      ${total ? `<div style="display:flex;gap:8px;align-items:center;padding:4px 8px;color:var(--muted);font-size:12px">
        <input type="checkbox" onchange="filesSelAll(this)" title="全选">
        <span>${total} 项（目录 ${d.dirs.length} · 文件 ${d.files.length}）</span>
      </div>` : ''}
      <div id="files-dropzone" style="position:relative" ondragover="filesDrag(event, true)" ondragleave="filesDrag(event, false)" ondrop="filesDrop(event)">
        <div id="files-drophint" class="hidden" style="position:absolute;inset:0;z-index:5;display:flex;align-items:center;justify-content:center;border:2px dashed var(--primary);border-radius:8px;background:var(--primary-soft);font-weight:600;pointer-events:none">📥 松开以上传到当前目录</div>
        ${rows || emptyState('📂', '空目录', '拖拽文件到此区域即可上传')}
      </div>
    </div>`;
}

function filesDrag(e, over) {
  e.preventDefault();
  const hint = $('#files-drophint');
  if (hint) hint.classList.toggle('hidden', !over);
}

async function filesDrop(e) {
  e.preventDefault();
  filesDrag(e, false);
  const files = e.dataTransfer?.files;
  if (!files || !files.length) return;
  let ok = 0, fail = 0;
  for (const f of files) {
    const path = (CUR_PATH ? CUR_PATH + '/' : '') + f.name;
    const r = await fetch(`/api/v1/instances/${CUR.id}/file?path=${encodeURIComponent(path)}`, {
      method: 'PUT', headers: { 'Authorization': 'Bearer ' + TOKEN }, body: f
    }).then(r => r.json()).catch(() => ({ code: -1 }));
    r.code === 0 ? ok++ : fail++;
  }
  toast(`拖拽上传完成：成功 ${ok}${fail ? '，失败 ' + fail : ''}`, fail ? 'err' : 'ok');
  renderFiles();
}

function fileIcon(name) {
  if (/\.(jar|zip|gz|tar)$/i.test(name)) return '📦';
  if (/\.(properties|yml|yaml|json|txt|cfg|conf|ini|lua|cs)$/i.test(name)) return '📄';
  return '📄';
}

function joinPath(name) {
  const p = (CUR_PATH ? CUR_PATH + '/' : '') + name;
  return p.replace(/'/g, "\\'");
}
function parentPath() {
  const parts = CUR_PATH.split('/').filter(Boolean);
  parts.pop();
  return parts.join('/');
}
function gotoPath(p) { CUR_PATH = p; renderFiles(); }

async function downloadFile(path) {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  const r = await fetch(`/api/v1/instances/${CUR.id}/download?path=${encodeURIComponent(path)}`, {
    headers: { 'Authorization': 'Bearer ' + TOKEN }
  });
  const blob = await r.blob();
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = path.split('/').pop();
  a.click();
  URL.revokeObjectURL(a.href);
}

function openFile(path, size) {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  if (size > 2 * 1024 * 1024) { toast('文件超过 2MB，请下载后编辑', 'err'); return; }
  fetch(`/api/v1/instances/${CUR.id}/file?path=${encodeURIComponent(path)}`, {
    headers: { 'Authorization': 'Bearer ' + TOKEN }
  }).then(r => r.text()).then(text => {
    modal(`编辑 ${esc(path.split('/').pop())}`, `
      <textarea class="inp mono" id="edit-area" style="height:420px;white-space:pre">${esc(text)}</textarea>
      <div class="modal-actions">
        <button class="btn" onclick="closeModal()">取消</button>
        <button class="btn primary" onclick="saveFile('${path}')">保存</button>
      </div>`);
  });
}

async function saveFile(path) {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  const content = $('#edit-area').value;
  const r = await fetch(`/api/v1/instances/${CUR.id}/file?path=${encodeURIComponent(path)}`, {
    method: 'PUT', headers: { 'Authorization': 'Bearer ' + TOKEN }, body: content
  }).then(r => r.json());
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  if (r.code === 0) closeModal();
}

async function uploadFile(input) {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }
  const files = [...(input.files || [])];
  if (!files.length) return;
  let ok = 0, fail = 0;
  for (const file of files) {
    const path = (CUR_PATH ? CUR_PATH + '/' : '') + file.name;
    const r = await fetch(`/api/v1/instances/${CUR.id}/file?path=${encodeURIComponent(path)}`, {
      method: 'PUT', headers: { 'Authorization': 'Bearer ' + TOKEN }, body: file
    }).then(r => r.json()).catch(() => ({ code: -1 }));
    r.code === 0 ? ok++ : fail++;
  }
  toast(`上传完成：成功 ${ok}${fail ? '，失败 ' + fail : ''}`, fail ? 'err' : 'ok');
  input.value = '';
  renderFiles();
}

function mkdirDialog() {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  modal('新建文件夹', `
    <input class="inp" id="mk-name" placeholder="文件夹名称">
    <div class="modal-actions">
      <button class="btn" onclick="closeModal()">取消</button>
      <button class="btn primary" onclick="doMkdir()">创建</button>
    </div>`);
}

async function doMkdir() {
  const name = $('#mk-name').value.trim();
  if (!name) return;
  await fileAction('mkdir', (CUR_PATH ? CUR_PATH + '/' : '') + name);
  closeModal(); renderFiles();
}

function renameFile(path, oldName) {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  modal('重命名 ' + esc(oldName), `
    <input class="inp" id="rn-name" value="${esc(oldName)}">
    <div class="modal-actions">
      <button class="btn" onclick="closeModal()">取消</button>
      <button class="btn primary" onclick="doRename('${path}')">确定</button>
    </div>`);
}

async function doRename(path) {
  const newName = $('#rn-name').value.trim();
  if (!newName) return;
  await fileAction('rename', path, newName);
  closeModal(); renderFiles();
}

async function deleteFile(path) {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  confirmModal('删除文件', `确定删除「${path}」？`, async () => {
    await fileAction('delete', path);
    closeModal(); renderFiles();
  });
}

async function extractFile(path) {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  toast('解压中…', '');
  const r = await api(`/instances/${CUR.id}/file-action`, { method: 'POST', body: { action: 'extract', path } });
  toast(r.msg || '解压完成', r.code === 0 ? 'ok' : 'err');
  renderFiles();
}

async function fileAction(action, path, newName) {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  const body = { action, path };
  if (newName) body.newName = newName;
  const r = await api(`/instances/${CUR.id}/file-action`, { method: 'POST', body });
  toast(r.msg || '完成', r.code === 0 ? 'ok' : 'err');
}

/* ----- 备份 / 快照 ----- */

async function renderRecords(kind) {
  const [recR, taskR] = await Promise.all([
    api(`/instances/${CUR.id}/records?kind=${kind}`),
    api('/tasks').catch(() => ({ code: -1, data: [] }))
  ]);
  if (recR.code !== 0) return;
  const recs = recR.data || [];
  CUR_RECS = recs;
  const title = kind === 'backup' ? '备份（全量目录）' : '快照（仅存档，秒级回档）';
  // 统计概览
  const totalBytes = recs.reduce((a, r) => a + (r.sizeBytes || 0), 0);
  const latest = recs[0];
  const hasAuto = (taskR.data || []).some(t => t.instanceId === CUR.id && (t.action === 'backup' || t.action === 'snapshot') && t.enabled);
  const rows = recs.map(rec => `
    <tr>
      <td>${esc(rec.name)}</td>
      <td>${fmtSize(rec.sizeBytes)}</td>
      <td class="muted">${esc(rec.createdAt)}</td>
      <td>${rec.auto ? '<span class="badge badge-info">计划任务</span>' : '<span class="badge badge-off">手动</span>'}</td>
      <td>
        <button class="btn small" onclick="previewRec('${rec.id}')">👁 预览</button>
        <button class="btn small" onclick="restoreRec('${rec.id}')">恢复</button>
        <button class="btn small" onclick="downloadRec('${rec.id}')">下载</button>
        <button class="btn small danger" onclick="delRec('${rec.id}')">删除</button>
      </td>
    </tr>`).join('');
  $('#tab-body').innerHTML = `
    <div class="grid cols-4 mb">
      <div class="card lift"><div class="stat-num">${recs.length}</div><div class="stat-label">${kind === 'backup' ? '备份' : '快照'}总数</div></div>
      <div class="card lift"><div class="stat-num">${fmtSize(totalBytes)}</div><div class="stat-label">归档总大小</div></div>
      <div class="card lift"><div class="stat-num" style="font-size:17px;line-height:39px">${latest ? esc(latest.createdAt) : '—'}</div><div class="stat-label">最近一次</div></div>
      <div class="card lift"><div class="stat-num" style="font-size:15px;line-height:39px">${hasAuto ? '✅ 已配置' : '⚠️ 未配置'}</div><div class="stat-label">自动${kind === 'backup' ? '备份' : '快照'}</div></div>
    </div>
    ${!hasAuto && recs.length ? `<div class="kv-note">💡 还没有自动${kind === 'backup' ? '备份' : '快照'}计划 —— 到「计划任务」页添加 <b>0 4 * * *</b>（每日凌晨 4 点）可高枕无忧。</div>` : ''}
    <div class="card">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
        <h3 style="margin:0">${title}</h3>
        <button class="btn primary" onclick="createRec('${kind}')">＋ 立即${kind === 'backup' ? '备份' : '快照'}</button>
      </div>
      ${recs.length ? `<table class="tbl"><tr><th>名称</th><th>大小</th><th>创建时间</th><th>来源</th><th>操作</th></tr>${rows}</table>` : emptyState('🗄', '暂无' + (kind === 'backup' ? '备份' : '快照'), '创建第一个归档，世界就有后悔药了', `<button class="btn primary" onclick="createRec('${kind}')">＋ 立即${kind === 'backup' ? '备份' : '快照'}</button>`)}
    </div>`;
}

/* 归档内容预览（tar 文件清单） */
async function previewRec(rid) {
  modal('👁 归档预览', '<div class="empty-tip">读取归档清单中…</div>');
  const r = await api(`/records/${rid}/preview`);
  if (r.code !== 0) { modal('👁 归档预览', `<div class="kv-note">${esc(r.msg)}</div>`); return; }
  const d = r.data;
  modal(`👁 ${esc(d.name)}（${fmtSize(d.sizeBytes)} · ${esc(d.createdAt)}）`, `
    <div class="kv-note">共 <b>${d.total}</b> 个条目${d.truncated ? `（仅显示前 ${d.entries.length} 个）` : ''}；${d.kind === 'snapshot' ? '快照仅含存档目录，恢复只覆盖存档' : '全量备份包含整个数据目录，恢复即整体回滚'}</div>
    <div class="console-box" style="height:320px">${d.entries.map(e => esc(e)).join('\n')}</div>
    <div class="modal-actions">
      <button class="btn" onclick="closeModal()">关闭</button>
      <button class="btn danger" onclick="closeModal();restoreRec('${rid}')">从此归档恢复…</button>
    </div>`);
}

async function createRec(kind) {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  modal(kind === 'backup' ? '创建备份' : '创建快照', `
    <input class="inp" id="rec-name" placeholder="名称（可选，默认 manual）">
    <div class="modal-actions">
      <button class="btn" onclick="closeModal()">取消</button>
      <button class="btn primary" id="rec-go">开始${kind === 'backup' ? '备份' : '快照'}</button>
    </div>`);
  $('#rec-go').onclick = async () => {
    $('#rec-go').disabled = true;
    $('#rec-go').textContent = '打包中…';
    const r = await api(`/instances/${CUR.id}/${kind}`, { method: 'POST', body: { name: $('#rec-name').value.trim() || 'manual' } });
    toast(r.msg, r.code === 0 ? 'ok' : 'err');
    closeModal();
    renderRecords(kind);
  };
}

async function restoreRec(rid) {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }
  const rec = (CUR_RECS || []).find(r => r.id === rid);
  const info = rec ? `${esc(rec.name)}（${fmtSize(rec.sizeBytes)} · ${esc(rec.createdAt)}）` : rid;
  confirmModal('恢复确认', `
    <p>即将从以下归档恢复：</p>
    <p><b>${info}</b></p>
    <p class="muted">恢复前会自动创建保护快照（恢复错了还能再回）。要求实例处于停止状态，进行中会短暂锁定操作。</p>
    <p style="color:var(--red)">⚠️ 当前数据将被归档内容覆盖，确定继续？</p>`, async () => {
    const r = await api(`/records/${rid}/restore`, { method: 'POST' });
    toast(r.msg, r.code === 0 ? 'ok' : 'err');
    closeModal();
  });
}

async function delRec(rid) {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  const r = await api(`/records/${rid}`, { method: 'DELETE' });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  renderRecords(CUR_TAB);
}

/* ----- Mod 管理 ----- */

let MR_RESULTS = [];

let MOD_SOURCE = 'modrinth';
let MOD_SEARCH_URL = '';

async function renderMods() {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  // 按游戏生态加载对应面板（MC=Modrinth 市场 / 饥荒&PZ=Steam工坊 / 泰拉瑞亚=直链下载）
  const tr = await api('/templates');
  if (tr.code === 0) {
    const tpl = (tr.data || []).find(x => x.key === CUR.game);
    if (tpl) { MOD_SOURCE = tpl.modSource; MOD_SEARCH_URL = tpl.modSearchUrl; }
    else { MOD_SOURCE = 'url'; MOD_SEARCH_URL = ''; }
  }
  const r = await api(`/instances/${CUR.id}/mods`);
  if (r.code !== 0) { $('#tab-body').innerHTML = '<div class="card">加载失败</div>'; return; }
  const d = r.data;
  const rows = [...(d.files || [])].map(f => {
    const off = f.name.endsWith('.disabled');
    return `
    <div class="file-row">
      <span class="fname"><span class="file-icon">${off ? '⚪' : '🧩'}</span>${esc(f.name)} ${off ? '<span class="muted">（已禁用）</span>' : ''}</span>
      <span class="fsize">${fmtSize(f.size)}</span>
      <span class="file-ops">
        <button class="btn small" onclick="toggleMod('${esc(f.name)}')">${off ? '启用' : '禁用'}</button>
        <button class="btn small danger" onclick="delMod('${esc(f.name)}')">删除</button>
      </span>
    </div>`;
  }).join('');
  const marketCard = MOD_SOURCE === 'modrinth'
    ? `<div class="card">
        <h3>Modrinth 市场（按本服版本过滤，一键安装）</h3>
        <div class="form-inline mb">
          <input class="inp" id="mr-q" placeholder="搜索 Mod/插件，如 lithium / essentials" onkeydown="if(event.key==='Enter')mrSearch()">
          <button class="btn primary" onclick="mrSearch()">搜索</button>
        </div>
        <div id="mr-results"></div>
      </div>`
    : '';
  $('#tab-body').innerHTML = `
    <div class="card">
      <h3>已安装</h3>
      ${rows || '<div class="empty-tip">暂无 Mod，可从下方安装或用「文件」页上传</div>'}
    </div>
    ${marketCard}
    <div id="mod-extra"></div>`;
  if (MOD_SOURCE === 'steam') renderWorkshopPanel();
  if (MOD_SOURCE === 'url') renderUrlPanel();
}

/* ----- Steam 创意工坊面板（饥荒 / 僵尸毁灭工程）----- */

async function renderWorkshopPanel() {
  const box = $('#mod-extra');
  if (!box) return;
  const r = await api(`/instances/${CUR.id}/workshop`);
  if (r.code !== 0) { box.innerHTML = `<div class="card">${esc(r.msg)}</div>`; return; }
  const d = r.data;
  const isPZ = CUR.game === 'zomboid';
  const search = (d.searchUrl || '').replace('{q}', encodeURIComponent($('#ws-q') ? $('#ws-q').value.trim() : ''));
  box.innerHTML = `
    <div class="card">
      <h3>🛠 Steam 创意工坊（${isPZ ? '僵尸毁灭工程 appid 108600' : '饥荒联机版 appid 322330'}）</h3>
      <div class="kv-note">在创意工坊页面找到 Mod，复制网址里的数字 ID（如 <span class="mono">.../?id=<b>3795506590</b></span>）填到下面；服务器重启时会自动从 Steam 下载。</div>
      <div class="form-inline mb">
        <input class="inp" id="ws-q" placeholder="关键词（打开 Steam 创意工坊搜索）">
        <button class="btn" onclick="wsSearch()">🔍 工坊搜索</button>
      </div>
      <div class="form-inline mb">
        <input class="inp mono" id="ws-id" placeholder="Workshop ID（数字）">
        ${isPZ ? '<input class="inp mono" id="ws-modid" placeholder="Mod ID（工坊页面的 Mod ID，PZ 需要）">' : ''}
        <input class="inp" id="ws-name" placeholder="名称备注（可选）">
        <button class="btn primary" onclick="wsAdd()">添加</button>
      </div>
      <div id="ws-list">
        ${d.entries.map(e => `
          <div class="file-row">
            <span class="fname">🛠 <b class="mono">${esc(e.id)}</b> ${esc(e.name || '')}</span>
            <span class="file-ops">
              <a class="btn small" target="_blank" href="https://steamcommunity.com/sharedfiles/filedetails/?id=${esc(e.id)}">工坊页</a>
              <button class="btn small danger" onclick="wsRemove('${esc(e.id)}')">移除</button>
            </span>
          </div>`).join('') || '<div class="empty-tip">尚未添加工坊 Mod</div>'}
      </div>
    </div>`;
}

function wsSearch() {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  const q = $('#ws-q').value.trim();
  const url = (MOD_SEARCH_URL || '').replace('{q}', encodeURIComponent(q));
  if (url) window.open(url, '_blank');
}

async function wsAdd() {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  const body = { modId: $('#ws-id').value.trim(), name: $('#ws-name').value.trim() };
  if (!body.modId) { toast('请填写 Workshop ID', 'err'); return; }
  const mid = $('#ws-modid');
  if (mid) body.pzModId = mid.value.trim();
  const r = await api(`/instances/${CUR.id}/workshop`, { method: 'POST', body });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  if (r.code === 0) renderWorkshopPanel();
}

async function wsRemove(id) {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  const r = await api(`/instances/${CUR.id}/workshop/${id}`, { method: 'DELETE' });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  renderWorkshopPanel();
}

/* ----- 直链下载面板（泰拉瑞亚 TShock 插件等）----- */

function renderUrlPanel() {
  const box = $('#mod-extra');
  if (!box) return;
  box.innerHTML = `
    <div class="card">
      <h3>🔗 直链安装（TShock 插件 / 任意文件）</h3>
      <div class="kv-note">从 <a href="${MOD_SEARCH_URL || 'https://tshock.co/'}" target="_blank">TShock 插件仓库</a> 找到插件的 .dll 或 .zip 下载直链，粘贴到下面；zip 会自动解压到 ServerPlugins/。</div>
      <div class="form-inline mb">
        <input class="inp mono" id="url-dl" placeholder="https://github.com/xxx/releases/download/v1/Plugin.dll">
        <button class="btn primary" onclick="urlInstall()">下载安装</button>
      </div>
      <button class="btn" onclick="window.open('${MOD_SEARCH_URL || 'https://tshock.co/'}', '_blank')">🔍 浏览插件仓库（新窗口）</button>
    </div>`;
}

async function urlInstall() {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  const url = $('#url-dl').value.trim();
  if (!url) { toast('请填写下载直链', 'err'); return; }
  toast('下载中…', '');
  const r = await api(`/instances/${CUR.id}/mods/url-install`, { method: 'POST', body: { url } });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  if (r.code === 0) renderMods();
}

async function toggleMod(name) {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  const r = await api(`/instances/${CUR.id}/mods/toggle`, { method: 'POST', body: { name } });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  renderMods();
}

async function delMod(name) {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  const r = await api(`/instances/${CUR.id}/mods/${encodeURIComponent(name)}`, { method: 'DELETE' });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  renderMods();
}

async function mrSearch() {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  const q = $('#mr-q').value.trim();
  const box = $('#mr-results');
  box.innerHTML = '<div class="empty-tip">搜索中…</div>';
  const r = await api(`/modrinth/search?q=${encodeURIComponent(q)}&instance=${CUR.id}`);
  if (r.code !== 0) { box.innerHTML = '<div class="empty-tip">搜索失败（检查网络）</div>'; return; }
  MR_RESULTS = r.data.hits || [];
  box.innerHTML = MR_RESULTS.map((h, i) => `
    <div class="file-row">
      <img src="${esc(h.icon_url)}" style="width:28px;height:28px;border-radius:6px;margin-right:10px" onerror="this.style.visibility='hidden'">
      <span class="fname"><b>${esc(h.title)}</b> <span class="muted">${esc(h.author)}</span><br><span class="muted" style="font-size:12px">${esc(h.description || '').slice(0, 80)}</span></span>
      <span class="fsize">${(h.downloads || 0).toLocaleString()} 次下载</span>
      <span class="file-ops"><button class="btn small primary" onclick="mrPick(${i})">安装</button></span>
    </div>`).join('') || '<div class="empty-tip">无结果</div>';
}

function mrPick(i) {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  const h = MR_RESULTS[i];
  modal(`安装 ${esc(h.title)}`, `<div id="mr-vers" class="empty-tip">加载版本…</div>`);
  api(`/modrinth/versions?project=${h.project_id}`).then(r => {
    if (r.code !== 0) { $('#mr-vers').innerHTML = '获取版本失败'; return; }
    const vers = (r.data || []).slice(0, 20).map((v, j) => `
      <div class="file-row">
        <span class="fname"><b>${esc(v.name)}</b><br><span class="muted" style="font-size:12px">${(v.game_versions || []).join(', ')} · ${esc(v.version_type)}</span></span>
        <span class="file-ops"><button class="btn small primary" onclick="mrInstall('${h.project_id}','${v.id}',this)">安装</button></span>
      </div>`).join('');
    $('#mr-vers').innerHTML = vers || '无可用版本';
  });
}

async function mrInstall(pid, vid, btn) {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  btn.disabled = true; btn.textContent = '下载中…';
  const r = await api(`/instances/${CUR.id}/mods/install`, { method: 'POST', body: { projectId: pid, versionId: vid } });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  if (r.code === 0) closeModal();
}

/* ----- 设置 ----- */

let TPL_CACHE = null;

async function renderSettings() {
  if (!TPL_CACHE) {
    const r = await api('/templates');
    if (r.code === 0) TPL_CACHE = r.data;
  }
  const i = CUR;
  const tpl = (TPL_CACHE || []).find(t => t.key === i.game);
  const envText = Object.entries(i.extraEnv || {}).map(([k, v]) => k + '=' + v).join('\n');
  $('#tab-body').innerHTML = `
    <div class="card" id="gamecfg-card">
      <h3>🎮 游戏专属配置</h3>
      <div id="gamecfg-body" class="empty-tip">加载中…</div>
    </div>
    <div class="card">
      <h3>基本设置（保存后自动重建容器，数据不受影响）</h3>
      <div class="form-row"><label>实例名称</label><input class="inp" id="set-name" value="${esc(i.name)}"></div>
      <div class="form-inline">
        <div class="form-row"><label>内存上限 (MB)</label><input class="inp" id="set-mem" type="number" value="${i.memoryMB}"></div>
        <div class="form-row"><label>CPU 核数（0 = 不限制）</label><input class="inp" id="set-cpu" type="number" step="0.5" value="${i.cpus}"></div>
        <div class="form-row"><label>随面板自启</label>
          <select class="inp" id="set-auto"><option value="true" ${i.autoStart ? 'selected' : ''}>开启</option><option value="false" ${!i.autoStart ? 'selected' : ''}>关闭</option></select>
        </div>
      </div>
      <div class="form-row"><label>自定义环境变量（每行 KEY=VALUE）</label>
        <textarea class="inp mono" id="set-env" rows="4">${esc(envText)}</textarea></div>
      <button class="btn primary" onclick="saveSettings()">保存设置</button>
    </div>
    <div class="card">
      <h3>版本切换</h3>
      <div class="form-row"><label>服务端版本</label>
        <select class="inp" id="set-version">
          ${(tpl ? tpl.versions : []).map(v => `<option value="${v.key}" ${v.key === i.version ? 'selected' : ''}>${esc(v.label)}</option>`).join('')}
        </select></div>
      <button class="btn primary" onclick="changeVersion()">切换版本</button>
      <div class="muted mt">切换会拉取新镜像并重建容器，数据目录保留。</div>
    </div>
    <div class="card">
      <h3>连接信息</h3>
      <div class="mono">镜像：${esc(i.image)}<br>数据目录：${esc(i.dataDir)}<br>端口：${esc(i.ports.join(', '))}</div>
    </div>`;
  loadGameCfg();
}

/* ----- 游戏专属配置 ----- */

async function loadGameCfg() {
  if (!CUR) return;
  const r = await api(`/instances/${CUR.id}/game-config`);
  // await 期间详情页可能被整体重渲染（操作状态自动刷新），旧节点引用会失效：
  // 必须重新获取当前挂在 DOM 上的容器再写入
  const box = $('#gamecfg-body');
  if (!box) return;
  if (r.code !== 0) { box.textContent = r.msg || '该游戏暂无专属配置'; return; }
  const d = r.data;
  if (!d.fields || d.fields.length === 0) { box.textContent = '该游戏暂无专属配置'; return; }
  const warn = d.fileMissing
    ? `<div class="kv-note">配置文件尚未生成（首次启动实例后创建），当前显示默认值，保存后将在下次启动时生效。</div>` : '';
  // 按分组聚合渲染（同组字段一个分区；无 group 字段时归入"通用"）
  const groups = [];
  const groupIdx = {};
  d.fields.forEach(f => {
    const g = f.group || '通用';
    if (!(g in groupIdx)) { groupIdx[g] = groups.length; groups.push({ name: g, fields: [] }); }
    groups[groupIdx[g]].fields.push(f);
  });
  box.innerHTML = `${warn}
    ${groups.map(g => `
      <h3 style="font-size:13px;color:var(--muted);margin:16px 0 10px">${esc(g.name)}（${g.fields.length}）</h3>
      <div class="grid cols-2" style="gap:12px">
        ${g.fields.map(f => {
          const i = d.fields.indexOf(f);
          return `
        <div class="form-row" style="margin:0">
          <label>${esc(f.label)} <span class="muted mono" style="font-weight:400">(${esc(f.path)})</span></label>
          ${f.kind === 'toggle'
            ? `<select class="inp" data-gc="${i}"><option value="true" ${f.value === 'true' ? 'selected' : ''}>开启</option><option value="false" ${f.value !== 'true' ? 'selected' : ''}>关闭</option></select>`
            : f.kind === 'select'
              ? `<select class="inp" data-gc="${i}">${f.options.map(o => `<option value="${esc(o.value)}" ${o.value === f.value ? 'selected' : ''}>${esc(o.label)}</option>`).join('')}</select>`
              : `<input class="inp" data-gc="${i}" type="${f.kind === 'number' ? 'number' : 'text'}" value="${esc(f.value)}">`}
          ${f.help ? `<div class="muted" style="font-size:12px;margin-top:4px">${esc(f.help)}</div>` : ''}
        </div>`;
        }).join('')}
      </div>`).join('')}
    <div class="mt" style="display:flex;gap:10px;align-items:center">
      <button class="btn primary" id="gamecfg-save">保存配置</button>
      <span class="muted" style="font-size:12px">保存后需重启实例生效</span>
    </div>`;
  $('#gamecfg-save').onclick = async () => {
    const values = {};
    $$('#gamecfg-body [data-gc]').forEach(el => {
      const f = d.fields[parseInt(el.dataset.gc)];
      values[f.path] = el.value;
    });
    $('#gamecfg-save').disabled = true;
    const rr = await api(`/instances/${CUR.id}/game-config`, { method: 'PUT', body: { values } });
    $('#gamecfg-save').disabled = false;
    toast(rr.msg, rr.code === 0 ? 'ok' : 'err');
  };
}

async function saveSettings() {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  const env = {};
  $('#set-env').value.split('\n').forEach(line => {
    const idx = line.indexOf('=');
    if (idx > 0) env[line.slice(0, idx).trim()] = line.slice(idx + 1).trim();
  });
  const body = {
    name: $('#set-name').value.trim(),
    memoryMB: parseInt($('#set-mem').value) || 1024,
    cpus: parseFloat($('#set-cpu').value) || 0,
    autoStart: $('#set-auto').value === 'true',
    extraEnv: env
  };
  const r = await api(`/instances/${CUR.id}`, { method: 'PUT', body });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  if (r.code === 0) { await refreshCur(); renderDetail(); }
}

async function changeVersion() {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  const version = $('#set-version').value;
  confirmModal('切换版本', '将停止当前容器并按新版本重建（数据保留）。继续？', async () => {
    const r = await api(`/instances/${CUR.id}/change-version`, { method: 'POST', body: { version } });
    toast(r.msg, r.code === 0 ? 'ok' : 'err');
    closeModal();
    await refreshCur(); renderDetail();
  });
}

/* ---------------- 创建实例向导 ---------------- */

/* ---------------- 创建实例向导（三步式） ---------------- */

let WZ_STEP = 0;
const MEM_PRESETS = {
  minecraft: [1024, 2048, 4096, 8192],
  dst: [4096, 6144, 8192],
  terraria: [1024, 2048, 4096],
  zomboid: [4096, 8192, 12288],
  custom: [1024, 2048, 4096]
};
const MEM_HINTS = {
  minecraft: '原版/轻量 Mod 2G 起步；整合包或 10+ 人建议 4G+',
  dst: '含洞穴（双进程）建议 4G 起步',
  terraria: '2G 足够大多数规模',
  zomboid: '地图大/Mod 多建议 8G+',
  custom: '按服务端文档评估'
};
let portCheckTimer = null;
let portCheckState = { ok: null, msg: '' };

function wizardGo(n) {
  WZ_STEP = Math.max(0, Math.min(2, n));
  $$('.wz-step-page').forEach((el, i) => el.classList.toggle('hidden', i !== WZ_STEP));
  $$('.steps .step').forEach((el, i) => {
    el.classList.toggle('cur', i === WZ_STEP);
    el.classList.toggle('done', i < WZ_STEP);
  });
  $('#wz-back').classList.toggle('hidden', WZ_STEP === 0);
  $('#wz-next').textContent = WZ_STEP === 2 ? '🚀 创建并启动' : '下一步';
  $('#wz-note').classList.toggle('hidden', WZ_STEP === 0);
  if (WZ_STEP === 2) buildWzSummary();
}

function wzNext() {
  if (WZ_STEP < 2) { wizardGo(WZ_STEP + 1); return; }
  if (portCheckState.ok === false) {
    toast('端口不可用：' + portCheckState.msg, 'err');
    $('#wz-port').focus();
    return;
  }
  createInstance();
}

/* 第 3 步的确认摘要（选了什么一目了然） */
function buildWzSummary() {
  const g = (TPL_CACHE || []).find(x => x.key === (($$('.game-opt.sel')[0] || {}).dataset || {}).g) || {};
  const loader = ($('#wz-loader') || {}).value || '';
  const ver = ($('#wz-version') || {}).value || '';
  const mem = ($('#wz-mem') || {}).value || '';
  const box = $('#wz-summary');
  if (!box) return;
  box.innerHTML = `
    <table class="tbl">
      <tr><td style="width:110px;color:var(--muted)">游戏</td><td>${g.icon || ''} ${esc(g.title || '')}</td></tr>
      <tr><td style="color:var(--muted)">版本</td><td class="mono">${esc(g.key === 'minecraft' ? loader + ' ' + ver : ver)}</td></tr>
      <tr><td style="color:var(--muted)">资源</td><td>${esc(mem)} MB 内存${Number(($('#wz-cpu') || {}).value) > 0 ? ' · ' + $('#wz-cpu').value + ' 核' : ' · CPU 不限'}</td></tr>
      <tr><td style="color:var(--muted)">端口</td><td class="mono">${esc(($('#wz-port') || {}).value || (g.ports && g.ports[0] ? g.ports[0].split(':')[0] : '自动'))} <span id="wz-port-badge"></span></td></tr>
      <tr><td style="color:var(--muted)">节点</td><td>${esc(($('#wz-node') || {}).value || 'local')}</td></tr>
    </table>`;
  renderPortBadge();
}

/* 端口预检：防抖 400ms */
function wzPortInput(v) {
  if (portCheckTimer) clearTimeout(portCheckTimer);
  portCheckState = { ok: null, msg: '' };
  renderPortBadge();
  const port = parseInt(v, 10);
  if (!v || !port) { renderPortBadge(); return; }
  portCheckTimer = setTimeout(async () => {
    const r = await api('/port-check?port=' + port).catch(() => null);
    if (!r || r.code !== 0) return;
    const d = r.data;
    if (d.available) portCheckState = { ok: true, msg: '可用' };
    else if (d.byInstance) portCheckState = { ok: false, msg: '已被实例「' + d.byInstance + '」占用' };
    else if (d.systemInUse) portCheckState = { ok: false, msg: '被本机其他程序占用' };
    renderPortBadge();
  }, 400);
}

function renderPortBadge() {
  const b = $('#wz-port-badge');
  if (!b) return;
  if (portCheckState.ok === true) b.innerHTML = '<span class="badge badge-ok">✓ 可用</span>';
  else if (portCheckState.ok === false) b.innerHTML = '<span class="badge bad">✕ ' + esc(portCheckState.msg) + '</span>';
  else b.innerHTML = '<span class="muted" style="font-size:12px">输入后自动检测</span>';
}

function memPreset(v, el) {
  $('#wz-mem').value = v;
  $$('.mem-chip').forEach(c => c.classList.toggle('primary', c === el));
}

async function showCreateDialog() {
  if (!TPL_CACHE) {
    const r = await api('/templates');
    if (r.code !== 0) { toast(r.msg, 'err'); return; }
    TPL_CACHE = r.data;
  }
  const games = TPL_CACHE;
  if (!games || games.length === 0) {
    toast('游戏模板加载失败，请刷新页面重试', 'err');
    return;
  }
  portCheckState = { ok: null, msg: '' };
  modal('创建实例', `
    <div class="steps">
      <div class="step cur">① 选择游戏</div>
      <div class="step">② 版本与资源</div>
      <div class="step">③ 命名与端口</div>
    </div>
    <div id="wizard">
      <div class="wz-step-page">
        <div class="game-pick" id="pick-games">
          ${games.map((g, i) => `
            <div class="game-opt ${i === 0 ? 'sel' : ''}" data-g="${g.key}" onclick="pickGame('${g.key}')">
              <div class="g-icon">${g.icon}</div>
              <div class="g-title">${esc(g.title)}</div>
              <div class="g-desc">${esc(g.desc)}</div>
            </div>`).join('')}
        </div>
        <div class="mt" style="text-align:center">
          <span class="muted">想直接玩整合包？</span>
          <button class="btn small" onclick="showModpackDialog()">📦 从 Modrinth 整合包一键开服</button>
        </div>
      </div>
      <div class="wz-step-page hidden">
        <div class="form-inline">
          <div class="form-row" style="flex:0 0 130px"><label>服务端类型</label>
            <select class="inp" id="wz-loader" onchange="fillMcVersions()">
              <option value="paper">Paper</option>
              <option value="fabric">Fabric</option>
              <option value="vanilla">原版</option>
              <option value="forge">Forge</option>
            </select></div>
          <div class="form-row"><label>版本</label><select class="inp" id="wz-version"></select></div>
          <div class="form-row" style="flex:0 0 150px"><label>节点</label><select class="inp" id="wz-node"></select></div>
        </div>
        <div class="form-row"><label>内存配额（MB）<span class="muted" id="wz-mem-hint" style="margin-left:8px"></span></label>
          <div style="display:flex;gap:6px;flex-wrap:wrap" id="wz-mem-chips"></div>
          <input class="inp mt" id="wz-mem" type="number" value="2048" min="256" step="256" style="width:160px">
        </div>
        <div class="form-row" style="width:200px"><label>CPU 核数（0 不限）</label>
          <input class="inp" id="wz-cpu" type="number" step="0.5" value="0" min="0"></div>
      </div>
      <div class="wz-step-page hidden">
        <div class="form-inline">
          <div class="form-row"><label>实例名称</label><input class="inp" id="wz-name" placeholder="如：周末生存服"></div>
          <div class="form-row" style="flex:0 0 150px"><label>宿主端口</label>
            <input class="inp" id="wz-port" placeholder="留空用默认" oninput="wzPortInput(this.value)"></div>
        </div>
        <div class="form-inline">
          <div class="form-row" style="flex:0 0 170px"><label>接入联机组网</label>
            <select class="inp" id="wz-mesh">
              <option value="false">不接入</option>
              <option value="true">🌐 EasyTier（玩家用虚拟IP连接）</option>
            </select></div>
        </div>
        <div class="form-row"><label>自定义环境变量（每行 KEY=VALUE，可空）</label>
          <textarea class="inp mono" id="wz-env" rows="2" placeholder="如 DST_CLUSTER_TOKEN=xxx"></textarea></div>
        <h3 class="mt" style="font-size:13px;color:var(--muted)">确认信息</h3>
        <div id="wz-summary"></div>
      </div>
      <div id="wz-note" class="kv-note hidden"></div>
      <div class="modal-actions">
        <button class="btn" onclick="closeModal()">取消</button>
        <button class="btn hidden" id="wz-back" onclick="wizardGo(WZ_STEP - 1)">上一步</button>
        <button class="btn primary" id="wz-next" onclick="wzNext()">下一步</button>
      </div>
    </div>`);
  api('/nodes').then(nr => {
    if (nr.code === 0) {
      $('#wz-node').innerHTML = nr.data.map(n => `<option value="${esc(n.name)}">${esc(n.name)}${n.name === 'local' ? '（本机）' : ''}</option>`).join('');
    }
  });
  pickGame(games[0].key);
}

function pickGame(key) {
  $$('.game-opt').forEach(el => el.classList.toggle('sel', el.dataset.g === key));
  const g = TPL_CACHE.find(t => t.key === key);
  $('#wz-version').innerHTML = g.versions.map(v => `<option value="${v.key}">${esc(v.label)}</option>`).join('');
  $('#wz-port').placeholder = '默认 ' + g.ports[0].split(':')[0];
  $('#wz-note').textContent = g.note ? '📌 ' + g.note : '';
  // 资源建议：预设档位 chips + 经验提示（游戏选完即更新）
  const presets = MEM_PRESETS[g.key] || MEM_PRESETS.custom;
  const chipsBox = $('#wz-mem-chips');
  if (chipsBox) {
    chipsBox.innerHTML = presets.map(v =>
      `<button class="btn small mem-chip${v === 2048 ? ' primary' : ''}" onclick="memPreset(${v}, this)">${v >= 1024 ? (v / 1024) + ' GB' : v + ' MB'}</button>`).join('');
    const def = presets.includes(2048) ? 2048 : presets[Math.floor(presets.length / 2)];
    $('#wz-mem').value = def;
    $$('.mem-chip').forEach(c => c.classList.toggle('primary', c.textContent.includes(def >= 1024 ? (def / 1024) + ' GB' : def + ' MB')));
  }
  const hint = $('#wz-mem-hint');
  if (hint) hint.textContent = MEM_HINTS[g.key] || MEM_HINTS.custom;
  // Minecraft：动态拉取官方最新版本列表（失败保留静态表兜底）
  if (key === 'minecraft') fillMcVersions();
}

async function fillMcVersions() {
  const sel = $('#wz-version');
  if (!sel) return;
  // 记录静态兜底
  const fallback = sel.innerHTML;
  // loader 来自显式下拉（静态 key 场景回退推断）
  let loader = ($('#wz-loader') && $('#wz-loader').value) || (sel.value || 'paper-').split('-')[0];
  if (!['paper', 'fabric', 'vanilla', 'forge'].includes(loader)) loader = 'paper';
  if (loader === 'forge') return;   // forge 无轻量公开 API，保留静态
  sel.innerHTML = '<option>获取官方最新版本…</option>';
  const r = await api(`/mc-versions?loader=${loader}`).catch(() => null);
  if (!r || r.code !== 0 || !r.data || r.data.length === 0) {
    sel.innerHTML = fallback;   // 回退静态表
    toast('在线版本获取失败，使用内置版本列表', '');
    return;
  }
  const latest = r.data[0];
  sel.innerHTML =
    `<option value="${loader}-${latest}">⚡ 最新正式版 ${latest}（自动）</option>` +
    r.data.map(v => `<option value="${loader}-${v}">${loader === 'vanilla' ? '原版' : loader[0].toUpperCase() + loader.slice(1)} ${v}</option>`).join('');
}

async function createInstance() {
  const env = {};
  $('#wz-env').value.split('\n').forEach(line => {
    const idx = line.indexOf('=');
    if (idx > 0) env[line.slice(0, idx).trim()] = line.slice(idx + 1).trim();
  });
  const body = {
    game: $('.game-opt.sel').dataset.g,
    version: $('#wz-version').value,
    name: $('#wz-name').value.trim(),
    port: $('#wz-port').value.trim(),
    memoryMB: parseInt($('#wz-mem').value) || 2048,
    cpus: parseFloat($('#wz-cpu').value) || 0,
    extraEnv: env,
    node: ($('#wz-node') ? $('#wz-node').value : 'local'),
    useMesh: ($('#wz-mesh') ? $('#wz-mesh').value === 'true' : false)
  };
  if (!body.name) { toast('请填写实例名称', 'err'); return; }
  const r = await api('/instances', { method: 'POST', body });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  if (r.code === 0) {
    closeModal();
    switchView('instances');
  }
}

/* ---------------- 计划任务 ---------------- */

const ACTIONS = [
  ['backup', '创建备份'], ['snapshot', '创建快照'],
  ['restart', '重启实例'], ['start', '启动实例'], ['stop', '停止实例'],
  ['command', '发送控制台命令']
];

async function renderTasks() {
  const [tr, ir] = await Promise.all([api('/tasks'), api('/instances')]);
  if (tr.code !== 0 || ir.code !== 0) return;
  const tasks = tr.data;
  TASK_CACHE = tasks;
  const insts = ir.data;
  const nameOf = id => { const i = insts.find(x => x.id === id); return i ? `${i.icon} ${i.name}` : '(实例已删除)'; };
  const actionText = a => (ACTIONS.find(x => x[0] === a) || ['', a])[1];
  const lastRunHtml = t => {
    const h = (t.history || []);
    if (!h.length) return '<span class="muted">未执行</span>';
    const last = h[h.length - 1];
    return last.ok
      ? `<span class="badge badge-ok">成功</span> <span class="muted" style="font-size:12px">${esc(last.time)}</span>`
      : `<span class="badge bad">失败</span> <span class="muted" style="font-size:12px" title="${esc(last.msg)}">${esc(last.time)}</span>`;
  };
  const rows = tasks.map(t => `
    <tr>
      <td>${esc(t.name)}</td>
      <td>${esc(nameOf(t.instanceId))}</td>
      <td class="mono">${esc(t.cron)}</td>
      <td>${actionText(t.action)}${t.action === 'command' ? `：${esc(t.command)}` : ''}</td>
      <td>${t.action === 'backup' || t.action === 'snapshot' ? `保留 ${t.keepCount} 份` : '-'}</td>
      <td>${t.enabled ? `<span class="dot running"></span>启用` : '<span class="dot exited"></span>停用'}</td>
      <td>${lastRunHtml(t)}</td>
      <td class="muted">${esc(t.nextRun || '-')}</td>
      <td>
        <button class="btn small" onclick="runTaskNow('${t.id}')">执行</button>
        <button class="btn small" onclick="showTaskDialog('${t.id}')">编辑</button>
        ${(t.history || []).length ? `<button class="btn small" onclick="taskHistory('${t.id}')">历史</button>` : ''}
        <button class="btn small" onclick="toggleTask('${t.id}', ${!t.enabled})">${t.enabled ? '停用' : '启用'}</button>
        <button class="btn small danger" onclick="delTask('${t.id}')">删除</button>
      </td>
    </tr>`).join('');
  $('#main').innerHTML = `
    <div class="card">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
        <h3 style="margin:0">计划任务</h3>
        <button class="btn primary" onclick="showTaskDialog()">＋ 新建任务</button>
      </div>
      ${tasks.length ? `<table class="tbl">
        <tr><th>名称</th><th>实例</th><th>cron</th><th>动作</th><th>保留</th><th>状态</th><th>最近执行</th><th>下次运行</th><th>操作</th></tr>${rows}</table>`
      : emptyState('⏰', '暂无计划任务', '让备份与重启自动发生', '<button class="btn primary" onclick="showTaskDialog()">＋ 新建任务</button>')}
    </div>
    <div class="card muted" style="font-size:13px">
      cron 为五段表达式「分 时 日 月 周」，例如：<span class="mono">0 4 * * *</span> 每天 4 点；<span class="mono">*/30 * * * *</span> 每 30 分钟；<span class="mono">0 */6 * * *</span> 每 6 小时。
    </div>`;
}

/* 任务执行历史弹窗 */
function taskHistory(tid) {
  const t = TASK_CACHE.find(x => x.id === tid);
  if (!t) return;
  const h = (t.history || []).slice().reverse();
  modal(`📜 ${esc(t.name)} · 执行历史（最近 ${h.length} 次）`, `
    ${h.length ? `<table class="tbl"><tr><th>时间</th><th>结果</th><th>说明</th></tr>${h.map(e => `
      <tr>
        <td class="mono" style="white-space:nowrap">${esc(e.time)}</td>
        <td>${e.ok ? '<span class="badge badge-ok">成功</span>' : '<span class="badge bad">失败</span>'}</td>
        <td class="muted" style="font-size:12px">${esc(e.msg)}</td>
      </tr>`).join('')}</table>` : '<div class="empty-tip">暂无记录</div>'}
    <div class="modal-actions"><button class="btn" onclick="closeModal()">关闭</button></div>`);
}

let TASK_CACHE = [];
const TASK_TEMPLATES = [
  { label: '🌙 每日 4 点备份', cron: '0 4 * * *', action: 'backup' },
  { label: '⚡ 每小时快照', cron: '0 * * * *', action: 'snapshot' },
  { label: '🔄 每周一 5 点重启', cron: '0 5 * * 1', action: 'restart' },
  { label: '🛡 每 6 小时存档', cron: '0 */6 * * *', action: 'command' }
];
let cronPreviewTimer = null;

function showTaskDialog(editId) {
  api('/instances').then(r => {
    if (r.code !== 0) return;
    const insts = r.data;
    if (insts.length === 0) { toast('请先创建实例', 'err'); return; }
    const t = editId ? TASK_CACHE.find(x => x.id === editId) : null;
    window.__taskEditId = editId || null;
    modal(t ? '编辑计划任务' : '新建计划任务', `
      <div class="form-row"><label>常用模板</label>
        <div style="display:flex;gap:6px;flex-wrap:wrap">
          ${TASK_TEMPLATES.map(tp => `<button class="btn small" onclick="applyTaskTemplate('${tp.cron}','${tp.action}')">${tp.label}</button>`).join('')}
        </div>
      </div>
      <div class="form-row"><label>任务名称</label><input class="inp" id="tk-name" value="${t ? esc(t.name) : ''}" placeholder="如：每日自动备份"></div>
      <div class="form-inline">
        <div class="form-row"><label>目标实例</label>
          <select class="inp" id="tk-inst">${insts.map(i => `<option value="${i.id}" ${t && t.instanceId === i.id ? 'selected' : ''}>${esc(i.name)}</option>`).join('')}</select></div>
        <div class="form-row"><label>动作</label>
          <select class="inp" id="tk-action" onchange="taskActionChange()">${ACTIONS.map(([k, txt]) => `<option value="${k}" ${t && t.action === k ? 'selected' : ''}>${txt}</option>`).join('')}</select></div>
      </div>
      <div class="form-row"><label>cron 表达式（分 时 日 月 周）</label>
        <input class="inp mono" id="tk-cron" value="${t ? esc(t.cron) : '0 4 * * *'}" oninput="cronPreviewInput(this.value)"></div>
      <div class="form-row"><label>未来执行预览</label>
        <div id="tk-preview" class="muted mono" style="font-size:12px;min-height:18px">输入 cron 后自动校验并预览</div></div>
      <div class="form-row" id="tk-cmd-row" style="display:none"><label>命令内容</label><input class="inp mono" id="tk-cmd" value="${t ? esc(t.command) : ''}" placeholder="如 say 服务器即将重启"></div>
      <div class="form-row" id="tk-keep-row"><label>备份/快照保留份数</label><input class="inp" id="tk-keep" type="number" value="${t ? t.keepCount : 7}"></div>
      <div class="modal-actions">
        <button class="btn" onclick="closeModal()">取消</button>
        <button class="btn primary" onclick="createTask()">${t ? '保存' : '创建'}</button>
      </div>`);
    taskActionChange();
    if (t) cronPreviewInput(t.cron);
  });
}

function applyTaskTemplate(cron, action) {
  $('#tk-cron').value = cron;
  $('#tk-action').value = action;
  taskActionChange();
  cronPreviewInput(cron);
}

/* cron 实时校验 + 未来 5 次执行预览（防抖 400ms） */
function cronPreviewInput(v) {
  if (cronPreviewTimer) clearTimeout(cronPreviewTimer);
  const box = $('#tk-preview');
  if (!box) return;
  const expr = v.trim();
  if (!expr) { box.textContent = '输入 cron 后自动校验并预览'; return; }
  cronPreviewTimer = setTimeout(async () => {
    const r = await api('/cron-preview?expr=' + encodeURIComponent(expr)).catch(() => null);
    if (!r || r.code !== 0 || !$('#tk-preview')) {
      if ($('#tk-preview')) $('#tk-preview').innerHTML = '<span style="color:var(--red)">✕ 表达式不合法（五段：分 时 日 月 周）</span>';
      return;
    }
    $('#tk-preview').innerHTML = '<span style="color:var(--green)">✓</span> ' + r.data.runs.map(x => esc(x.replace(/\d{4}-/, ''))).join(' → ');
  }, 400);
}

function taskActionChange() {
  const a = $('#tk-action').value;
  $('#tk-cmd-row').style.display = a === 'command' ? '' : 'none';
  $('#tk-keep-row').style.display = (a === 'backup' || a === 'snapshot') ? '' : 'none';
}

async function createTask() {
  const body = {
    name: $('#tk-name').value.trim() || '计划任务',
    instanceId: $('#tk-inst').value,
    action: $('#tk-action').value,
    cron: $('#tk-cron').value.trim(),
    command: $('#tk-cmd').value,
    keepCount: parseInt($('#tk-keep').value) || 7
  };
  const editId = window.__taskEditId;
  const r = editId
    ? await api(`/tasks/${editId}`, { method: 'PUT', body })
    : await api('/tasks', { method: 'POST', body });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  if (r.code === 0) { closeModal(); window.__taskEditId = null; renderTasks(); }
}

async function runTaskNow(id) {
  const r = await api(`/tasks/${id}/run`, { method: 'POST' });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  setTimeout(renderTasks, 2500);
}

async function toggleTask(id, enabled) {
  const r = await api(`/tasks/${id}`, { method: 'PUT', body: { enabled } });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  renderTasks();
}

async function delTask(id) {
  const r = await api(`/tasks/${id}`, { method: 'DELETE' });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  renderTasks();
}

/* ---------------- 说明页 ---------------- */

function renderAbout() {
  $('#main').innerHTML = `
    <div class="card">
      <h3>关于面板</h3>
      <p>游戏方舟是使用 <b>仓颉（Cangjie）</b> 语言从零实现的容器化游戏服务器面板，单二进制部署，无数据库依赖。</p>
      <div class="mt">
        <b>核心理念</b>
        <ul style="margin:8px 0 0 20px;line-height:1.9">
          <li>容器化隔离：每个实例一个 Docker 容器，资源配额（内存/CPU）硬限制</li>
          <li>备份与快照分离：备份 = 全量目录归档（迁移/兜底）；快照 = 仅存档目录（世界级秒回档）</li>
          <li>版本管理：模板内置各游戏常用服务端版本，一键切换且数据保留</li>
          <li>Mod 一键装：集成 Modrinth 开源市场，搜索-选版本-安装三步完成</li>
          <li>计划任务：cron 定时备份/快照/重启/发命令，自带保留策略</li>
        </ul>
      </div>
    </div>
    <div class="card">
      <h3>快捷键与提示</h3>
      <ul style="margin-left:20px;line-height:1.9">
        <li>控制台日志每 2.5 秒自动刷新，发送命令对 Minecraft 走 RCON，其余游戏走 stdin 控制台</li>
        <li>文件管理器支持在线编辑 ≤2MB 文本、上传任意文件、打包下载</li>
        <li>恢复备份/快照前需先停止实例</li>
        <li>API 完全开放（Bearer Token 鉴权），可脚本化运维</li>
      </ul>
    </div>
    <div class="card">
      <h3>🔍 导航诊断日志（最近 20 次页面切换/跳转）</h3>
      <div class="mono" style="font-size:12px;line-height:1.8" id="navlog-box"></div>
    </div>`;
  const saved = JSON.parse(localStorage.getItem('gp_navlog') || '[]');
  const box = $('#navlog-box');
  if (box) box.textContent = saved.length ? saved.map(e => `${e.t}  ${e.reason}  (当时视图: ${e.view})`).join('\n') : '（暂无记录——若再次出现自动退出，回到本页查看是哪次跳转）';
}

/* ----- 监控曲线 ----- */

let metricsTimer = null;

let METRICS_RANGE = 120;   // 显示点数：30=15分 60=30分 120=1小时

async function renderMetrics() {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  if (metricsTimer) { clearInterval(metricsTimer); metricsTimer = null; }
  $('#tab-body').innerHTML = `
    <div class="card">
      <h3 style="display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px">
        <span>资源监控（每 30 秒采样）</span>
        <span style="display:flex;gap:4px">
          ${[['15 分钟', 30], ['30 分钟', 60], ['1 小时', 120]].map(([label, n]) =>
            `<button class="btn small${METRICS_RANGE === n ? ' primary' : ''}" onclick="setMetricsRange(${n})">${label}</button>`).join('')}
        </span>
      </h3>
      <div id="metrics-box" class="empty-tip">加载中…</div>
    </div>`;
  await drawMetrics();
  metricsTimer = setInterval(drawMetrics, 30000);
}

function setMetricsRange(n) {
  METRICS_RANGE = n;
  if (metricsTimer) { clearInterval(metricsTimer); metricsTimer = null; }
  renderMetrics();
}

async function drawMetrics() {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  const r = await api(`/instances/${CUR.id}/metrics`);
  const box = $('#metrics-box');
  if (!box) return;
  if (r.code !== 0) { box.textContent = '加载失败'; return; }
  const all = r.data || [];
  const pts = all.slice(-METRICS_RANGE);
  if (pts.length < 2) { box.textContent = '采样中，请稍候（实例运行时每 30 秒记录一次）'; return; }
  const W = 860, H = 260, PAD = 46;
  const maxCpu = Math.max(10, ...pts.map(p => p.cpu)) * 1.15;
  const maxMem = Math.max(128, ...pts.map(p => p.memMB)) * 1.15;
  const X = i => PAD + i * (W - PAD * 2) / (pts.length - 1);
  const Y = (v, max) => H - PAD - v / max * (H - PAD * 2);
  const line = (key, max) => pts.map((p, i) => `${i ? 'L' : 'M'}${X(i).toFixed(1)},${Y(p[key], max).toFixed(1)}`).join(' ');
  const area = (key, max) => `${line(key, max)} L${X(pts.length - 1).toFixed(1)},${H - PAD} L${PAD},${H - PAD} Z`;
  const labels = pts.filter((_, i) => i % Math.ceil(pts.length / 8) === 0);
  const last = pts[pts.length - 1];
  const yTicks = (max, unit) => [1, .5, 0].map(f =>
    `<text x="${PAD - 6}" y="${Y(f * max, max) + 3}" font-size="10" fill="var(--muted)" text-anchor="end">${(max * f).toFixed(0)}${unit}</text>`).join('');
  box.innerHTML = `
    <svg viewBox="0 0 ${W} ${H}" style="width:100%;background:var(--card);border:1px solid var(--line);border-radius:8px">
      <defs>
        <linearGradient id="gCpu" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color="var(--primary)" stop-opacity=".25"/>
          <stop offset="100%" stop-color="var(--primary)" stop-opacity="0"/>
        </linearGradient>
        <linearGradient id="gMem" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color="var(--green)" stop-opacity=".2"/>
          <stop offset="100%" stop-color="var(--green)" stop-opacity="0"/>
        </linearGradient>
      </defs>
      ${[0, .25, .5, .75, 1].map(f => `<line x1="${PAD}" x2="${W - PAD}" y1="${Y(f * maxCpu, maxCpu)}" y2="${Y(f * maxCpu, maxCpu)}" stroke="var(--line)" stroke-width="1"/>`).join('')}
      ${yTicks(maxCpu, '%')}
      ${yTicks(maxMem / 1024 > 1 ? maxMem / 1024 : maxMem, maxMem / 1024 > 1 ? 'G' : 'M')}
      <path d="${area('cpu', maxCpu)}" fill="url(#gCpu)"/>
      <path d="${area('memMB', maxMem)}" fill="url(#gMem)"/>
      <path d="${line('cpu', maxCpu)}" fill="none" stroke="var(--primary)" stroke-width="2"/>
      <path d="${line('memMB', maxMem)}" fill="none" stroke="var(--green)" stroke-width="2"/>
      <circle cx="${X(pts.length - 1)}" cy="${Y(last.cpu, maxCpu)}" r="3.5" fill="var(--primary)"/>
      <circle cx="${X(pts.length - 1)}" cy="${Y(last.memMB, maxMem)}" r="3.5" fill="var(--green)"/>
      ${labels.map((p, li) => {
        const i = li * Math.ceil(pts.length / 8);
        return `<text x="${X(i)}" y="${H - 12}" font-size="10" fill="var(--muted)" text-anchor="middle">${p.t}</text>`;
      }).join('')}
    </svg>
    <div style="margin-top:10px;font-size:13px;display:flex;gap:18px;flex-wrap:wrap">
      <span style="color:var(--primary)">━ CPU（峰值 ${(Math.max(...pts.map(p => p.cpu))).toFixed(1)}%，当前 ${last.cpu.toFixed(1)}%）</span>
      <span style="color:var(--green)">━ 内存（峰值 ${fmtSize(Math.max(...pts.map(p => p.memMB)) * 1024 * 1024)}，当前 ${fmtSize(last.memMB * 1024 * 1024)}）</span>
    </div>`;
}

/* ----- 快捷命令 ----- */

function quickCmds() {
  if (!CUR) return [];
  let list = [];
  if (CUR.game === 'minecraft') {
    list = [
      { label: '在线列表', cmd: 'list' },
      { label: '存档', cmd: 'save-all' },
      { label: '白名单', cmd: 'whitelist list' },
      { label: '难度', cmd: 'difficulty' }
    ];
  } else {
    list = [{ label: '帮助', cmd: 'help' }];
  }
  // 用户自定义（追加在内置之后，按游戏持久化）
  try {
    const custom = JSON.parse(localStorage.getItem('gp_quick_' + CUR.game) || '[]');
    list = list.concat(custom.filter(c => c && c.label && c.cmd));
  } catch (e) {}
  return list;
}

/* 只重绘快捷命令按钮区，不打断控制台连接 */
function drawQuickCmds() {
  const box = $('#quickcmd-box');
  if (!box || !CUR) return;
  box.innerHTML = quickCmds().map(c =>
    `<button class="btn small ghost" style="margin:0 6px 6px 0" onclick="quickCmd('${c.cmd.replace(/'/g, "\\'")}')">${esc(c.label)}</button>`).join('');
}

/* 自定义快捷命令编辑器 */
function editQuickCmds() {
  if (!CUR) return;
  let custom = [];
  try { custom = JSON.parse(localStorage.getItem('gp_quick_' + CUR.game) || '[]'); } catch (e) {}
  const draw = (items) => modal('自定义快捷命令（' + (CUR.game) + '）', `
    <div class="form-inline" style="align-items:flex-end">
      <div class="form-row" style="flex:0 0 40%"><label>按钮文字</label><input class="inp" id="qc-label" placeholder="如：晴天"></div>
      <div class="form-row"><label>命令</label><input class="inp mono" id="qc-cmd" placeholder="如 weather clear"></div>
      <button class="btn primary" style="flex:0 0 auto;margin-bottom:14px" onclick="qcAdd()">添加</button>
    </div>
    ${items.length ? `<table class="tbl"><tr><th>文字</th><th>命令</th><th></th></tr>${items.map((c, i) => `
      <tr><td>${esc(c.label)}</td><td class="mono">${esc(c.cmd)}</td>
      <td><button class="btn small danger" onclick="qcDel(${i})">删除</button></td></tr>`).join('')}</table>`
      : '<div class="empty-tip">还没有自定义命令，把常用命令做成一键按钮</div>'}
    <div class="kv-note" style="margin-top:14px">保存在浏览器本地（localStorage），只影响当前浏览器的「${esc(CUR.game)}」控制台。</div>
    <div class="modal-actions">
      <button class="btn" onclick="closeModal()">关闭</button>
    </div>`);
  window.__qcDraw = draw;
  draw(custom);
}

function qcAdd() {
  const label = ($('#qc-label') || {}).value || '';
  const cmd = ($('#qc-cmd') || {}).value || '';
  if (!label.trim() || !cmd.trim()) { toast('文字和命令都要填', 'err'); return; }
  let custom = [];
  try { custom = JSON.parse(localStorage.getItem('gp_quick_' + CUR.game) || '[]'); } catch (e) {}
  custom.push({ label: label.trim(), cmd: cmd.trim() });
  localStorage.setItem('gp_quick_' + CUR.game, JSON.stringify(custom));
  window.__qcDraw(custom);
  drawQuickCmds();
}

function qcDel(i) {
  let custom = [];
  try { custom = JSON.parse(localStorage.getItem('gp_quick_' + CUR.game) || '[]'); } catch (e) {}
  custom.splice(i, 1);
  localStorage.setItem('gp_quick_' + CUR.game, JSON.stringify(custom));
  window.__qcDraw(custom);
  drawQuickCmds();
}

function quickCmd(cmd) {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }
 $('#cmd-input').value = cmd; sendCmd(); }

async function downloadRec(rid) {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  const r = await fetch(`/api/v1/records/${rid}/download`, { headers: { 'Authorization': 'Bearer ' + TOKEN } });
  if (!r.ok) { toast('下载失败', 'err'); return; }
  const blob = await r.blob();
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  const cd = r.headers.get('content-disposition') || '';
  a.download = cd.match(/filename="?([^";]+)"?/)?.[1] || 'archive.tar.gz';
  a.click();
  URL.revokeObjectURL(a.href);
}

/* ----- 玩家管理（Minecraft） ----- */

let PLAYERS_DATA = null;
let playerFilter = '';

async function renderPlayers() {
  const box = $('#tab-body');
  box.innerHTML = skeletonRows(3);
  const r = await api(`/instances/${CUR.id}/players`);
  if (r.code !== 0) {
    box.innerHTML = `<div class="card"><div class="empty-tip">${esc(r.msg || '暂不支持')}</div></div>`;
    return;
  }
  PLAYERS_DATA = r.data;
  drawPlayers();
}

function drawPlayers() {
  const d = PLAYERS_DATA;
  if (!d) return;
  const q = playerFilter.trim().toLowerCase();
  const match = n => !q || n.toLowerCase().includes(q);
  const row = (p, extra) => `
    <div class="file-row">
      <span class="fname">👤 <b>${esc(p.name)}</b> <span class="muted mono" style="font-size:11px">${esc(p.uuid || '').slice(0, 18)}${p.uuid ? '…' : ''}</span></span>
      <span class="file-ops">${extra}</span>
    </div>`;
  const listCard = (title, list, actions) => {
    const shown = list.filter(p => match(p.name));
    return `
    <div class="card">
      <h3>${title}（${shown.length}${q && shown.length !== list.length ? '/' + list.length : ''}）</h3>
      ${shown.map(p => row(p, actions(p.name))).join('') || `<div class="empty-tip">${q ? '无匹配' : '空'}</div>`}
    </div>`;
  };
  $('#tab-body').innerHTML = `
    <div class="grid cols-4 mb">
      <div class="card lift"><div class="stat-num">${d.online.length}</div><div class="stat-label">🟢 在线</div></div>
      <div class="card lift"><div class="stat-num">${d.whitelist.length}</div><div class="stat-label">📋 白名单</div></div>
      <div class="card lift"><div class="stat-num">${d.ops.length}</div><div class="stat-label">⭐ OP</div></div>
      <div class="card lift"><div class="stat-num">${d.banned.length}</div><div class="stat-label">🚫 封禁</div></div>
    </div>
    <div class="card">
      <h3>🟢 在线玩家</h3>
      ${d.online.filter(match).map(n => row({ name: n, uuid: '' }, `<button class="btn small" onclick="playerAction('kick','${esc(n)}')">踢出</button>`)).join('') || `<div class="empty-tip">${q ? '无匹配' : '无人在线'}</div>`}
      <div class="form-inline mt">
        <input class="inp" id="pl-name" placeholder="玩家名（添加白名单/OP/封禁）">
        <button class="btn" onclick="playerAction('whitelist-add')">加白名单</button>
        <button class="btn" onclick="playerAction('op')">设 OP</button>
        <button class="btn danger" onclick="playerAction('ban')">封禁</button>
      </div>
      <div class="form-inline mt">
        <input class="inp" id="pl-broadcast" placeholder="📢 广播消息（发送给全服玩家）" onkeydown="if(event.key==='Enter')broadcastMsg()">
        <button class="btn primary" style="flex:0 0 auto" onclick="broadcastMsg()">广播</button>
      </div>
      <div class="form-inline mt">
        <textarea class="inp mono" id="pl-batch" rows="2" placeholder="👥 批量加白（每行一个玩家名，或逗号分隔）"></textarea>
        <button class="btn" style="flex:0 0 auto" onclick="batchWhitelist()">批量加白</button>
      </div>
    </div>
    <div class="mb" style="display:flex;gap:8px;align-items:center">
      <input class="inp" placeholder="🔍 搜索玩家（过滤下方所有列表）…" value="${esc(playerFilter)}" oninput="playerFilter=this.value;drawPlayers()" style="max-width:320px">
    </div>
    <div class="grid cols-2">
      ${listCard('📋 白名单', d.whitelist, n => `<button class="btn small danger" onclick="playerAction('whitelist-remove','${esc(n)}')">移除</button>`)}
      ${listCard('⭐ 管理员 OP', d.ops, n => `<button class="btn small" onclick="playerAction('deop','${esc(n)}')">撤销</button>`)}
    </div>
    ${listCard('🚫 封禁列表', d.banned, n => `<button class="btn small" onclick="playerAction('pardon','${esc(n)}')">解封</button>`)}`;
}

/* 广播：say 命令 UI 化（MC 全服消息） */
async function broadcastMsg() {
  const input = $('#pl-broadcast');
  const msg = input.value.trim();
  if (!msg) { toast('请输入广播内容', 'err'); return; }
  // 走 RCON 命令通道：say = MC 全服广播
  const c = await api(`/instances/${CUR.id}/command`, { method: 'POST', body: { cmd: `say ${msg}` } });
  if (c.code === 0) { toast('📢 已广播', 'ok'); input.value = ''; }
  else { toast(c.msg, 'err'); }
}

/* 批量加白：逗号/换行分隔逐个执行 */
async function batchWhitelist() {
  const input = $('#pl-batch');
  const names = input.value.split(/[,,\n]/).map(x => x.trim()).filter(Boolean);
  if (!names.length) { toast('请输入玩家名（逗号或换行分隔）', 'err'); return; }
  let ok = 0, fail = 0;
  for (const n of names) {
    const r = await api(`/instances/${CUR.id}/players/whitelist-add`, { method: 'POST', body: { player: n } });
    r.code === 0 ? ok++ : fail++;
  }
  toast(`批量加白完成：成功 ${ok}${fail ? '，失败 ' + fail : ''}`, fail ? 'err' : 'ok');
  input.value = '';
  setTimeout(renderPlayers, 600);
}

async function playerAction(action, name) {
  if (!CUR) { toast('请先从列表打开实例详情', 'err'); return; }

  const player = name || ($('#pl-name') ? $('#pl-name').value.trim() : '');
  if (!player) { toast('请输入玩家名', 'err'); return; }
  const r = await api(`/instances/${CUR.id}/players/${action}`, { method: 'POST', body: { player } });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  if (r.code === 0) setTimeout(renderPlayers, 800);
}

/* ----- Modrinth 整合包一键开服 ----- */

let MP_RESULTS = [];

function showModpackDialog() {
  modal('📦 Modrinth 整合包一键开服', `
    <p class="muted" style="margin-bottom:12px">搜索整合包 → 选择版本 → 面板创建实例，服务端启动时自动下载装配全部 Mod 与配置（无需手动搬运文件）。</p>
    <div class="form-inline mb">
      <input class="inp" id="mp-q" placeholder="搜索整合包，如 RLCraft / Create" onkeydown="if(event.key==='Enter')mpSearch()">
      <button class="btn primary" onclick="mpSearch()">搜索</button>
    </div>
    <div id="mp-results"><div class="empty-tip">输入关键词开始搜索</div></div>`);
}

async function mpSearch() {
  const q = $('#mp-q').value.trim();
  const box = $('#mp-results');
  if (!box) return;
  box.innerHTML = '<div class="empty-tip">搜索中…</div>';
  const r = await api(`/modrinth/modpacks?q=${encodeURIComponent(q)}`);
  if (r.code !== 0) { box.innerHTML = `<div class="empty-tip">${esc(r.msg)}</div>`; return; }
  MP_RESULTS = r.data.hits || [];
  box.innerHTML = MP_RESULTS.map((h, i) => `
    <div class="file-row">
      <img src="${esc(h.icon_url)}" style="width:30px;height:30px;border-radius:6px;margin-right:10px" onerror="this.style.visibility='hidden'">
      <span class="fname"><b>${esc(h.title)}</b> <span class="muted">${esc(h.author)}</span><br>
        <span class="muted" style="font-size:12px">${esc(h.description || '').slice(0, 70)} · MC ${(h.versions || []).slice(-2).join(' / ')}</span></span>
      <span class="fsize">${(h.downloads || 0).toLocaleString()} 次</span>
      <span class="file-ops"><button class="btn small primary" onclick="mpPick(${i})">选此包</button></span>
    </div>`).join('') || '<div class="empty-tip">无结果</div>';
}

function mpPick(i) {
  const h = MP_RESULTS[i];
  modal(`创建「${esc(h.title)}」`, `
    <div id="mp-vers" class="empty-tip">加载版本…</div>`);
  api(`/modrinth/versions?project=${h.project_id}`).then(r => {
    if (r.code !== 0 || !$('#mp-vers')) { if ($('#mp-vers')) $('#mp-vers').textContent = '获取版本失败'; return; }
    window.__MP_PROJECT = h.project_id;
    $('#mp-vers').innerHTML = `
      <div class="form-row"><label>整合包版本</label>
        <select class="inp" id="mp-version">
          ${(r.data || []).slice(0, 15).map(v => `<option value="${v.id}">${esc(v.name)}（${(v.game_versions || []).join(',')}）</option>`).join('')}
        </select></div>
      <div class="form-inline">
        <div class="form-row"><label>实例名称</label><input class="inp" id="mp-name" value="${esc(h.title)}"></div>
        <div class="form-row"><label>宿主端口</label><input class="inp" id="mp-port" placeholder="默认 25565"></div>
      </div>
      <div class="form-row"><label>内存 (MB)</label><input class="inp" id="mp-mem" type="number" value="4096"></div>
      <div class="kv-note">整合包首次启动需下载全部文件（视大小几分钟到十几分钟），日志出现 Done 即开服完成。</div>
      <div class="modal-actions">
        <button class="btn" onclick="closeModal()">取消</button>
        <button class="btn primary" onclick="mpCreate()">创建并启动</button>
      </div>`;
  });
}

async function mpCreate() {
  const body = {
    projectId: window.__MP_PROJECT,
    versionId: $('#mp-version').value,
    name: $('#mp-name').value.trim(),
    port: $('#mp-port').value.trim(),
    memoryMB: parseInt($('#mp-mem').value) || 4096
  };
  if (!body.name) { toast('请填写实例名称', 'err'); return; }
  const r = await api('/instances/from-modpack', { method: 'POST', body });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  if (r.code === 0) { closeModal(); switchView('instances'); }
}

/* ----- 导入已有容器 ----- */

function showImportDialog() {
  modal('导入已有容器', `
    <p class="muted" style="margin-bottom:14px">把手工 docker run 起来的游戏服纳管进面板：读取容器镜像/端口/挂载生成实例，<b>不会重启或重建容器</b>。</p>
    <div class="form-row"><label>容器名（docker ps 里的 NAMES）</label><input class="inp mono" id="imp-container" placeholder="如 minecraft"></div>
    <div class="form-row"><label>展示名称（可空）</label><input class="inp" id="imp-name" placeholder="如 我的老服"></div>
    <div class="modal-actions">
      <button class="btn" onclick="closeModal()">取消</button>
      <button class="btn primary" onclick="doImport()">导入</button>
    </div>`);
}

async function doImport() {
  const container = $('#imp-container').value.trim();
  if (!container) { toast('请填写容器名', 'err'); return; }
  const r = await api('/instances/import', { method: 'POST', body: { container, name: $('#imp-name').value.trim() } });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  if (r.code === 0) { closeModal(); renderInstances(); }
}

/* ---------------- 系统诊断（admin） ---------------- */

async function renderDiag() {
  $('#main').innerHTML = skeletonRows(4);
  const [hr, st] = await Promise.all([
    api('/health-report').catch(() => ({ code: -1 })),
    api('/storage').catch(() => ({ code: -1 }))
  ]);
  let healthCard = '<div class="card">健康自检不可用</div>';
  if (hr.code === 0) {
    const items = hr.data || [];
    const okCnt = items.filter(x => x.ok).length;
    healthCard = `
    <div class="card">
      <h3 style="display:flex;justify-content:space-between;align-items:center">
        <span>🩺 健康自检</span>
        <span class="badge ${okCnt === items.length ? 'badge-ok' : 'badge-warn'}">${okCnt}/${items.length} 通过</span>
      </h3>
      <table class="tbl">
        <tr><th style="width:44px"></th><th>检查项</th><th>详情</th></tr>
        ${items.map(x => `
        <tr>
          <td>${x.ok ? '<span style="color:var(--green);font-size:16px">✓</span>' : '<span style="color:var(--red);font-size:16px">✕</span>'}</td>
          <td><b>${esc(x.item)}</b></td>
          <td class="muted">${esc(x.detail)}</td>
        </tr>`).join('')}
      </table>
    </div>`;
  }
  let storageCard = '';
  if (st.code === 0) {
    const d = st.data;
    const insts = (d.instances || []).slice().sort((a, b) => b.sizeKB - a.sizeKB);
    const cat = [
      ['实例数据', d.instancesKB, 'var(--primary)'],
      ['备份归档', d.backupsKB, 'var(--violet)'],
      ['快照归档', d.snapshotsKB, 'var(--green)'],
      ['监控/其他', (d.metricsKB || 0) + (d.otherKB || 0), 'var(--muted)']
    ];
    const tot = Math.max(1, d.totalKB || 1);
    storageCard = `
    <div class="card">
      <h3>💾 数据目录明细（共 ${fmtSize(d.totalKB * 1024)}）</h3>
      <div class="progress" style="height:14px;display:flex;border-radius:7px;overflow:hidden;margin-bottom:14px">
        ${cat.filter(([_, kb]) => kb > 0).map(([n, kb, c]) => `<div title="${n} ${fmtSize(kb * 1024)}" style="width:${(kb / tot * 100).toFixed(1)}%;background:${c}"></div>`).join('')}
      </div>
      <div style="display:flex;gap:16px;flex-wrap:wrap;font-size:12px;margin-bottom:12px">
        ${cat.map(([n, kb, c]) => `<span><span style="display:inline-block;width:10px;height:10px;border-radius:3px;background:${c};margin-right:5px"></span>${n} ${fmtSize(kb * 1024)}</span>`).join('')}
      </div>
      ${insts.length ? `<table class="tbl"><tr><th>实例</th><th>占用</th><th style="width:40%"></th></tr>
        ${insts.map(i => `<tr>
          <td><b>${esc(i.name)}</b> <span class="muted">(${esc(i.game)})</span></td>
          <td class="mono">${fmtSize(i.sizeKB * 1024)}</td>
          <td><div class="progress"><div style="width:${(i.sizeKB / tot * 100).toFixed(1)}%"></div></div></td>
        </tr>`).join('')}</table>` : '<div class="empty-tip">暂无实例</div>'}
    </div>`;
  }
  $('#main').innerHTML = healthCard + storageCard;
}

/* ---------------- 用户管理（admin） ---------------- */

const ROLE_TEXT = { admin: '管理员', operator: '运维', viewer: '只读' };

async function renderUsers() {
  $('#main').innerHTML = skeletonRows(5);
  const r = await api('/users');
  if (r.code !== 0) { $('#main').innerHTML = `<div class="card">${esc(r.msg)}</div>`; return; }
  const d = r.data;
  const rows = d.users.map(u => `
    <tr>
      <td><b>${esc(u.username)}</b></td>
      <td>${ROLE_TEXT[u.role] || u.role}</td>
      <td class="muted">${esc(u.createdAt)}</td>
      <td>${u.username !== 'admin' ? `<button class="btn small danger" onclick="delUser('${esc(u.username)}')">删除</button>` : '<span class="muted">内置账户</span>'}</td>
    </tr>`).join('');
  $('#main').innerHTML = `
    <div class="card">
      <h3>用户（${d.users.length}）</h3>
      <div class="form-inline mb" style="align-items:flex-end">
        <div class="form-row" style="margin:0"><label>用户名</label><input class="inp" id="nu-name"></div>
        <div class="form-row" style="margin:0"><label>密码</label><input class="inp" id="nu-pass" type="password"></div>
        <div class="form-row" style="margin:0"><label>角色</label>
          <select class="inp" id="nu-role">
            <option value="viewer">viewer（只读）</option>
            <option value="operator">operator（运维）</option>
            <option value="admin">admin（管理员）</option>
          </select></div>
        <button class="btn primary" onclick="addUser()">添加/更新</button>
      </div>
      <table class="tbl"><tr><th>用户名</th><th>角色</th><th>创建时间</th><th>操作</th></tr>${rows}</table>
    </div>
    <div class="card">
      <h3>📝 审计日志（最近 ${d.audit.length} 条）</h3>
      <div class="mono" style="font-size:12px;line-height:1.9;max-height:300px;overflow-y:auto">
        ${d.audit.slice().reverse().map(a => `${esc(a.time)}&nbsp; <b>${esc(a.user)}</b> ${esc(a.action)}`).join('<br>') || '暂无'}
      </div>
    </div>
    <div class="card muted" style="font-size:13px">
      <b>角色说明</b>：viewer 可浏览全部页面但不能操作；operator 可启停实例/改配置/备份恢复/装 Mod/管理计划任务；admin 另有删除实例、导入容器、用户管理权限。
    </div>
    <div class="card" id="sessions-card"></div>
    <div class="card" id="nodes-card"></div>`;
  renderSessions();
  renderNodes();
}

async function renderSessions() {
  const box = $('#sessions-card');
  if (!box) return;
  const r = await api('/sessions').catch(() => null);
  if (!r || r.code !== 0) { box.remove(); return; }
  const list = r.data || [];
  const now = Math.floor(Date.now() / 1000);
  const rows = list.map(x => `
    <tr>
      <td class="mono">${esc(x.tokenPrefix)}…</td>
      <td><b>${esc(x.username)}</b>${x.current ? ' <span class="badge badge-info">当前</span>' : ''}</td>
      <td>${ROLE_TEXT[x.role] || x.role}</td>
      <td class="muted">${x.expire > now ? Math.floor((x.expire - now) / 3600) + ' 小时后过期' : '已过期'}</td>
      <td>${x.current ? '<span class="muted">—</span>' : `<button class="btn small danger" onclick="kickSession('${esc(x.tokenPrefix)}')">踢出</button>`}</td>
    </tr>`).join('');
  box.innerHTML = `
    <h3>🔑 在线会话（${list.length}）</h3>
    ${list.length ? `<table class="tbl"><tr><th>会话</th><th>用户</th><th>角色</th><th>有效期</th><th>操作</th></tr>${rows}</table>` : '<div class="empty-tip">无在线会话</div>'}`;
}

async function kickSession(prefix) {
  const r = await api(`/sessions/${prefix}`, { method: 'DELETE' });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  renderSessions();
}

async function renderNodes() {
  const box = $('#nodes-card');
  if (!box) return;
  const r = await api('/nodes');
  if (r.code !== 0) { box.innerHTML = '<h3>🖥 节点</h3>' + esc(r.msg); return; }
  box.innerHTML = `
    <h3>🖥 多节点（docker context）</h3>
    <div class="kv-note">在面板宿主机执行 <span class="mono">docker context create 节点名 --docker "host=ssh://user@远程机"</span> 配置好远程 Docker 后，在这里登记节点，即可把实例开到远程机器上（复用全部容器管理能力）。</div>
    <div class="form-inline mb" style="align-items:flex-end">
      <div class="form-row" style="margin:0"><label>context 名称</label><input class="inp mono" id="nd-name"></div>
      <div class="form-row" style="margin:0"><label>备注</label><input class="inp" id="nd-note" placeholder="如 机房A"></div>
      <button class="btn primary" onclick="addNode()">登记节点</button>
    </div>
    ${r.data.map(n => `
      <div class="file-row">
        <span class="fname">🖥 <b>${esc(n.name)}</b> <span class="muted">${esc(n.note)}</span></span>
        <span class="fsize">实例 ${n.instances} 个 · Docker ${n.dockerVersion ? n.dockerVersion : '不可达'}</span>
        <span class="file-ops">${n.name !== 'local' ? `<button class="btn small danger" onclick="delNode('${esc(n.name)}')">移除</button>` : ''}</span>
      </div>`).join('')}`;
}

async function addNode() {
  const body = { name: $('#nd-name').value.trim(), note: $('#nd-note').value.trim() };
  if (!body.name) { toast('请填写 context 名称', 'err'); return; }
  const r = await api('/nodes', { method: 'POST', body });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  if (r.code === 0) renderNodes();
}

async function delNode(name) {
  const r = await api(`/nodes/${encodeURIComponent(name)}`, { method: 'DELETE' });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  renderNodes();
}

async function addUser() {
  const body = { username: $('#nu-name').value.trim(), password: $('#nu-pass').value, role: $('#nu-role').value };
  if (!body.username || !body.password) { toast('用户名与密码必填', 'err'); return; }
  const r = await api('/users', { method: 'POST', body });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  if (r.code === 0) renderUsers();
}

async function delUser(name) {
  confirmModal(`删除用户 ${name}`, '确定删除该账户？', async () => {
    const r = await api(`/users/${encodeURIComponent(name)}`, { method: 'DELETE' });
    toast(r.msg, r.code === 0 ? 'ok' : 'err');
    closeModal();
    renderUsers();
  });
}

/* 角色控制：非 admin 隐藏管理入口 */
function applyRole() {
  $$('.gp-admin-only').forEach(el => el.style.display = (ME.role === 'admin') ? '' : 'none');
}

/* ---------------- EasyTier 联机组网 ---------------- */

let ET_TIMER = null;

async function renderMesh() {
  if (ET_TIMER) { clearInterval(ET_TIMER); ET_TIMER = null; }
  $('#main').innerHTML = skeletonRows(5);
  drawMesh(await api('/easytier/status'));
  ET_TIMER = setInterval(async () => {
    if (currentView !== 'mesh') { clearInterval(ET_TIMER); ET_TIMER = null; return; }
    drawMesh(await api('/easytier/status'), true);
  }, 5000);
}

/* KB 数 -> 人类可读（B/KB/MB/GB） */
function fmtKB(kb) {
  kb = Number(kb) || 0;
  if (kb === 0) return '0';
  if (kb < 1) return (kb * 1024).toFixed(0) + ' B';
  if (kb < 1024) return kb.toFixed(1) + ' KB';
  if (kb < 1024 * 1024) return (kb / 1024).toFixed(2) + ' MB';
  return (kb / 1024 / 1024).toFixed(2) + ' GB';
}

async function drawMesh(r, silent) {
  if (r.code !== 0) { $('#main').innerHTML = `<div class="card">${esc(r.msg)}</div>`; return; }
  const d = r.data;
  const cfg = d.config || {};
  const isAdmin = ME.role === 'admin';
  const traffic = d.traffic || {};
  const peerTraffic = p => traffic[(p.ipv4 || '').split('/')[0]] || {};
  const peerRows = (d.peers || []).map(p => {
    const t = peerTraffic(p);
    return `
    <tr>
      <td>${esc(p.hostname || p.node_id || '-')}</td>
      <td class="mono">${esc(p.ipv4 || '-')}</td>
      <td>${esc(p.latency_ms != null ? p.latency_ms + 'ms' : '-')}</td>
      <td>${esc(p.loss_rate != null ? (p.loss_rate * 100).toFixed(1) + '%' : '-')}</td>
      <td class="mono" title="面板口径累计（对端重连自动续算）">↓${fmtKB(t.rxKB)} ↑${fmtKB(t.txKB)}</td>
      <td>${esc(p.tunnel_proto || '-')}</td>
      <td>${esc(p.nat_type || '-')}</td>
    </tr>`;
  }).join('');
  const routeRows = (d.routes || []).map(rt => `
    <tr>
      <td class="mono">${esc(rt.ipv4 || '-')}</td>
      <td>${esc(rt.hostname || '-')}</td>
      <td>${esc(rt.next_hop_hostname || rt.next_hop_ipv4 || '-')}</td>
      <td>${esc(rt.path_latency != null ? rt.path_latency + 'ms' : '-')}</td>
    </tr>`).join('');
  $('#main').innerHTML = `
    <div class="card">
      <h3>🕸 联机组网（EasyTier）<span class="badge">${d.running && d.enabled ? '运行中' : '未启用'}</span></h3>
      <div class="kv-note">让无公网的服务器也能联机：玩家装 EasyTier 客户端（或 WireGuard）加入同一虚拟网后，直接用虚拟 IP 连接游戏服务器。家宽服务器配中继节点即可打洞直连。</div>
      ${d.error ? `<div class="kv-note">${esc(d.error)}</div>` : ''}
      ${isAdmin ? `
      <div class="form-inline mb" style="align-items:flex-end">
        <div class="form-row" style="margin:0;flex:0 0 110px"><label>模式</label>
          <select class="inp" id="et-mode">
            <option value="join" ${cfg.mode === 'join' ? 'selected' : ''}>挂接(默认)</option>
            <option value="host" ${cfg.mode === 'host' ? 'selected' : ''}>开放直连</option>
          </select></div>
        <div class="form-row" style="margin:0"><label>网络名</label><input class="inp" id="et-name" value="${esc(cfg.networkName || '')}" placeholder="如 my-game-lan"></div>
        <div class="form-row" style="margin:0"><label>密钥</label><input class="inp" id="et-secret" value="${esc(cfg.secret && !cfg.secret.includes('*') ? cfg.secret : '')}" placeholder="留空自动生成"></div>
        <div class="form-row" style="margin:0;flex:1"><label>中继/对端（逗号分隔，可空）</label><input class="inp mono" id="et-peers" value="${esc((cfg.peers || []).join(', '))}" placeholder="tcp://public.easytier.cn:11010（官方公共节点，自建中继填自己VPS）"></div>
        <div class="form-row" style="margin:0;flex:0 0 90px"><label>RPC端口</label><input class="inp" id="et-rpc" value="${esc(cfg.rpcPort || '15890')}"></div>
        <div class="form-row" style="margin:0;flex:0 0 170px"><label>WireGuard Portal</label>
          <select class="inp" id="et-wg">
            <option value="off" ${cfg.wgEnabled ? '' : 'selected'}>关闭</option>
            <option value="on" ${cfg.wgEnabled ? 'selected' : ''}>开启(玩家免装ET)</option>
          </select></div>
        <div class="form-row" style="margin:0;flex:0 0 auto"><label>玩家上下线通知</label>
          <label style="display:flex;align-items:center;gap:6px;font-weight:400;padding:8px 0">
            <input type="checkbox" id="et-notify" ${cfg.peerNotify ? 'checked' : ''} style="width:auto">
            <span class="muted">Webhook推送</span>
          </label></div>
        <button class="btn primary" onclick="etApply()">${d.enabled ? '保存并重启' : '启用组网'}</button>
        ${d.enabled ? '<button class="btn danger" onclick="etStop()">停止</button>' : ''}
      </div>` : '<div class="muted">仅管理员可配置</div>'}
    </div>
    ${d.enabled ? `
    <div class="card">
      <h3>📡 在线节点（${(d.peers || []).length}）</h3>
      ${(d.peers || []).length ? `<table class="tbl"><tr><th>主机名</th><th>虚拟IP</th><th>延迟</th><th>丢包</th><th>累计流量</th><th>隧道</th><th>NAT类型</th></tr>${peerRows}</table>` : '<div class="empty-tip">暂无其他节点（玩家加入后会出现在这里）</div>'}
      ${(d.routes || []).length ? `<h3 class="mt">路由表</h3><table class="tbl"><tr><th>虚拟IP</th><th>主机名</th><th>下一跳</th><th>路径延迟</th></tr>${routeRows}</table>` : ''}
      ${meshStatsHtml(d)}
    </div>` : ''}
    <div id="et-invite"></div>`;
  if (isAdmin && d.enabled && d.running) { loadInvite(); loadWgConfig(); }
}

async function loadInvite() {
  const r = await api('/easytier/invite');
  if (r.code !== 0 || !$('#et-invite')) return;
  const d = r.data;
  $('#et-invite').innerHTML = `
    <div class="card">
      <h3>💌 玩家邀请卡</h3>
      <div class="kv-note">发给玩家：安装 <a href="https://easytier.cn" target="_blank">EasyTier 客户端</a>（全平台图形版）→ 网络参数按下表填写 → 游戏内连接 <b>虚拟IP:游戏端口</b></div>
      <table class="tbl">
        <tr><th>网络名称</th><td class="mono">${esc(d.networkName)}</td></tr>
        <tr><th>网络密钥</th><td class="mono">${esc(d.secret)}</td></tr>
        <tr><th>对端地址</th><td class="mono">${(d.addrs || []).map(esc).join('<br>') || '（开放直连模式启动后自动生成）'}</td></tr>
      </table>
      <div class="mt">
        <b>一键命令（进阶玩家）</b>
        <div class="console-box" style="height:auto;min-height:40px">${esc(d.joinCommand)}</div>
        <button class="btn mt" onclick="navigator.clipboard.writeText(${JSON.stringify(d.joinCommand).replace(/"/g, '&quot;')}).then(()=>toast('已复制','ok'))">复制完整加入命令</button>
      </div>
    </div>`
  $('#et-invite').insertAdjacentHTML('afterend', `
    <div class="card" id="et-wg-box" style="display:none">
      <h3>🔐 WireGuard 接入（免装 EasyTier）</h3>
      <div class="kv-note">玩家用任意 WireGuard 客户端（手机/电脑系统级支持）新建隧道，粘贴下方配置即可入网。</div>
      <div class="console-box" id="et-wg-conf" style="height:auto;min-height:60px"></div>
      <button class="btn mt" onclick="navigator.clipboard.writeText(document.getElementById('et-wg-conf').textContent).then(()=>toast('已复制 WG 配置','ok'))">复制 WG 客户端配置</button>
    </div>`);
}

async function loadWgConfig() {
  const r = await api('/easytier/wg-config');
  const box = $('#et-wg-box');
  if (!box) return;
  if (r.code !== 0) { box.style.display = 'none'; return; }
  box.style.display = '';
  $('#et-wg-conf').textContent = r.data.config;
}

/* 连接动态时间线 + 节点流量统计（数据来自后端 30 秒采样） */
function meshStatsHtml(d) {
  const events = d.events || [];
  const traffic = d.traffic || {};
  const online = new Set((d.peers || []).map(p => (p.ipv4 || '').split('/')[0]));
  const statRows = Object.entries(traffic)
    .sort((a, b) => (Number(b[1].rxKB) || 0) + (Number(b[1].txKB) || 0) - (Number(a[1].rxKB) || 0) - (Number(a[1].txKB) || 0))
    .slice(0, 20)
    .map(([ip, t]) => `
      <tr>
        <td>${online.has(ip) ? '<span class="badge badge-ok">在线</span>' : '<span class="badge badge-off">离线</span>'}</td>
        <td>${esc(t.hostname || '-')}</td>
        <td class="mono">${esc(ip)}</td>
        <td class="mono">↓${fmtKB(t.rxKB)} ↑${fmtKB(t.txKB)}</td>
        <td>${t.joins != null ? t.joins : '-'}</td>
        <td class="mono">${esc(t.firstSeen || '-')}</td>
      </tr>`).join('');
  const evRows = events.slice(0, 15).map(e => `
    <div style="display:flex;gap:8px;align-items:baseline;padding:3px 0">
      <span class="mono muted" style="flex:0 0 110px;font-size:12px">${esc(e.time)}</span>
      <span class="badge" style="flex:0 0 auto;background:${e.event === 'join' ? 'var(--green-soft);color:var(--green)' : 'var(--gray-soft);color:var(--muted)'}">${e.event === 'join' ? '上线' : '离线'}</span>
      <span>${esc(e.hostname || '-')}</span>
      <span class="mono muted">${esc(e.ipv4)}</span>
    </div>`).join('');
  return `
    ${statRows ? `<h3 class="mt">📊 节点流量统计</h3>
    <table class="tbl"><tr><th>状态</th><th>主机名</th><th>虚拟IP</th><th>累计流量</th><th>接入次数</th><th>首次发现</th></tr>${statRows}</table>
    <div class="kv-note">每 30 秒采样对端累计计数器折算，对端重启/重连计数器回退时自动续算，面板重启不丢（et-stats.json）。</div>` : ''}
    ${evRows ? `<h3 class="mt">🛰 连接动态（玩家上下线）</h3>${evRows}` : ''}`;
}

async function etApply() {
  const peers = $('#et-peers').value.split(/[,，]/).map(s => s.trim()).filter(Boolean);
  let secret = $('#et-secret').value.trim();
  if (!secret) {
    secret = 'gp-' + Math.random().toString(36).slice(2, 12);
    toast('已自动生成密钥: ' + secret, '');
  }
  const body = {
    mode: $('#et-mode').value,
    networkName: $('#et-name').value.trim(),
    secret: secret,
    peers: peers,
    rpcPort: $('#et-rpc').value.trim() || '15890',
    wgEnabled: $('#et-wg').value === 'on',
    peerNotify: $('#et-notify').checked
  };
  if (!body.networkName) { toast('请填写网络名', 'err'); return; }
  const r = await api('/easytier/config', { method: 'PUT', body });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  if (r.code === 0) setTimeout(renderMesh, 2000);
}

async function etStop() {
  const r = await api('/easytier/stop', { method: 'POST' });
  toast(r.msg, r.code === 0 ? 'ok' : 'err');
  renderMesh();
}

function modal(title, bodyHtml) {
  $('#modal-root').innerHTML = `
    <div class="modal-mask" onclick="if(event.target===this)closeModal()">
      <div class="modal"><h3>${title}</h3>${bodyHtml}</div>
    </div>`;
}

function confirmModal(title, text, onOk) {
  modal(title, `
    <p>${text}</p>
    <div class="modal-actions">
      <button class="btn" onclick="closeModal()">取消</button>
      <button class="btn danger" id="confirm-ok">确定</button>
    </div>`);
  $('#confirm-ok').onclick = onOk;
}

function closeModal() { $('#modal-root').innerHTML = ''; }

$('#login-btn').onclick = doLogin;
$('#login-pass').addEventListener('keydown', e => { if (e.key === 'Enter') doLogin(); });

window.addEventListener('error', e => {
  console.error('[js-error]', e.message, e.filename, e.lineno);
  try { toast('脚本错误: ' + e.message + '（' + (e.lineno || '?') + ' 行）', 'err'); } catch (_) {}
});
window.addEventListener('unhandledrejection', e => {
  console.error('[unhandled]', e.reason);
  try { toast('请求异常: ' + (e.reason && e.reason.message || e.reason), 'err'); } catch (_) {}
});

(async function init() {
  try { ME = JSON.parse(localStorage.getItem('gp_me') || '{}') || {}; } catch (e) { ME = { username: '', role: '' }; }
  if (!TOKEN) { showLogin(); return; }
  const r = await api('/overview').catch(() => null);
  if (r === null || r.code === 401) { showLogin(); return; }
  showApp();
  refreshTop();
  switchView('overview');
})();
