const $ = (sel) => document.querySelector(sel);
const el = (tag, cls, text) => {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined) node.textContent = text;
  return node;
};

async function getJson(url, timeoutMs = 5000) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(url, { signal: ctrl.signal });
    return { ok: res.ok, status: res.status, data: await res.json() };
  } catch (err) {
    return { ok: false, status: 0, data: null, error: err.name === 'AbortError' ? 'timeout' : err.message };
  } finally {
    clearTimeout(timer);
  }
}

async function postJson(url, body) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 8000);
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal: ctrl.signal,
    });
    return { ok: res.ok, status: res.status, data: await res.json() };
  } catch (err) {
    return { ok: false, status: 0, data: null, error: err.message };
  } finally {
    clearTimeout(timer);
  }
}

const fmtDate = (value) => (value ? new Date(value).toLocaleString() : '');
const show = (node, message, isError) => {
  node.textContent = message;
  node.className = 'result' + (isError ? ' error' : ' ok');
};

/* ---------------- health ---------------- */

async function renderHealth() {
  const grid = $('#healthGrid');
  grid.replaceChildren();

  for (const svc of Object.values(SERVICES)) {
    const card = el('div', 'card health-card');
    const { ok, status, data, error } = await getJson(`${svc.baseUrl}/health`, 3000);

    const dot = el('span', 'dot ' + (ok ? 'up' : 'down'));
    card.append(dot, el('strong', null, svc.label));

    if (ok && data) {
      card.append(el('div', 'meta', `status: ${data.status} · db: ${data.database}`));
    } else {
      card.append(el('div', 'meta', error ? `unreachable (${error})` : `HTTP ${status}`));
    }
    grid.append(card);
  }
}

/* ---------------- tables ---------------- */

function table(rows, columns) {
  const t = el('table');
  const thead = el('thead');
  const htr = el('tr');
  columns.forEach((c) => htr.append(el('th', null, c.title)));
  thead.append(htr);

  const tbody = el('tbody');
  rows.forEach((row) => {
    const tr = el('tr');
    columns.forEach((c) => tr.append(el('td', null, c.render ? c.render(row) : row[c.key] ?? '')));
    tbody.append(tr);
  });

  t.append(thead, tbody);
  return t;
}

async function loadUsers() {
  const host = $('#usersList');
  const { ok, data } = await getJson(`${SERVICES.a.baseUrl}/users`);
  if (!ok) { host.replaceChildren(el('p', 'error', 'service-a unavailable')); return; }
  host.replaceChildren(
    table(data, [
      { title: 'ID', key: 'id' },
      { title: 'Name', key: 'name' },
      { title: 'Email', key: 'email' },
      { title: 'Created', render: (r) => fmtDate(r.created_at) },
    ])
  );
}

async function loadOrders() {
  const host = $('#ordersList');
  const { ok, data } = await getJson(`${SERVICES.b.baseUrl}/orders`);
  if (!ok) { host.replaceChildren(el('p', 'error', 'service-b unavailable')); return; }
  host.replaceChildren(
    table(data, [
      { title: 'ID', key: 'id' },
      { title: 'User', key: 'user_id' },
      { title: 'Item', key: 'item' },
      { title: 'Qty', key: 'quantity' },
      { title: 'Status', key: 'status' },
      { title: 'Created', render: (r) => fmtDate(r.created_at) },
    ])
  );
}

async function loadNotifications() {
  const host = $('#notificationsList');
  const { ok, data } = await getJson(`${SERVICES.c.baseUrl}/notifications`);
  if (!ok) { host.replaceChildren(el('p', 'error', 'service-c unavailable')); return; }
  if (!data.length) { host.replaceChildren(el('p', 'meta', 'No notifications yet.')); return; }
  host.replaceChildren(
    table(data, [
      { title: 'ID', key: 'id' },
      { title: 'Order', key: 'order_id' },
      { title: 'User', key: 'user_id' },
      { title: 'Message', key: 'message' },
      { title: 'Status', key: 'status' },
      { title: 'Created', render: (r) => fmtDate(r.created_at) },
    ])
  );
}

/* ---------------- logs ---------------- */

const LEVEL_CLASS = { INFO: 'l-info', WARNING: 'l-warn', ERROR: 'l-error', DEBUG: 'l-debug', RAW: 'l-raw' };

function buildLogPanels() {
  const grid = $('#logGrid');
  grid.replaceChildren();
  Object.values(SERVICES).forEach((svc) => {
    const card = el('div', 'card log-card');
    card.append(el('h3', null, svc.label));
    const pre = el('pre', 'log');
    pre.id = 'log-' + svc.name;
    card.append(pre);
    grid.append(card);
  });
}

async function loadLogs() {
  const lines = $('#lines').value || 50;
  for (const svc of Object.values(SERVICES)) {
    const pre = document.getElementById('log-' + svc.name);
    if (!pre) continue;
    const { ok, data } = await getJson(`${svc.baseUrl}/logs?lines=${lines}`, 5000);
    if (!ok || !data) { pre.textContent = `${svc.name}: logs unavailable`; continue; }
    pre.replaceChildren(
      ...data.entries.map((entry) => {
        const line = el('div', 'log-line ' + (LEVEL_CLASS[entry.level] || 'l-raw'));
        const extra = entry.extra_fields ? ' ' + JSON.stringify(entry.extra_fields) : '';
        line.textContent =
          `${entry.timestamp} [${entry.level}] [${entry.event_type}] ${entry.message}${extra}`;
        return line;
      })
    );
    pre.scrollTop = pre.scrollHeight;
  }
}

/* ---------------- forms ---------------- */

$('#userForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const form = new FormData(e.target);
  const res = await postJson(`${SERVICES.a.baseUrl}/users`, {
    name: form.get('name'),
    email: form.get('email'),
  });
  show($('#userResult'), res.ok ? `Created user ${res.data.id}` : `Error ${res.status}: ${res.data?.error || res.error}`, !res.ok);
  if (res.ok) e.target.reset();
  loadUsers();
});

$('#orderForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const form = new FormData(e.target);
  const res = await postJson(`${SERVICES.b.baseUrl}/orders`, {
    user_id: Number(form.get('user_id')),
    item: form.get('item'),
    quantity: Number(form.get('quantity')),
  });
  show($('#orderResult'), res.ok ? `Created order ${res.data.id}` : `Error ${res.status}: ${res.data?.error || res.error}`, !res.ok);
  if (res.ok) e.target.reset();
  loadOrders();
});

/* ---------------- refresh loop ---------------- */

let timer = null;

async function refreshAll() {
  await renderHealth();
  await Promise.all([loadUsers(), loadOrders(), loadNotifications()]);
  await loadLogs();
}

function restartTimer() {
  if (timer) clearInterval(timer);
  if (!$('#autorefresh').checked) return;
  const ms = Math.max(1000, Number($('#interval').value) || 5000);
  timer = setInterval(refreshAll, ms);
}

$('#refreshNow').addEventListener('click', refreshAll);
$('#autorefresh').addEventListener('change', restartTimer);
$('#interval').addEventListener('change', restartTimer);
$('#lines').addEventListener('change', loadLogs);

buildLogPanels();
refreshAll();
restartTimer();
