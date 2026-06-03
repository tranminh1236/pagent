// pagent dashboard frontend
const $ = (s) => document.querySelector(s);
// Parse JSON an toàn: nếu server trả HTML / rỗng (vd unhandled exception → trang lỗi
// stdlib) thì throw lỗi có ý nghĩa thay vì "Unexpected token <".
async function parseJson(res) {
  const ct = res.headers.get('content-type') || '';
  if (ct.includes('application/json')) return res.json();
  const text = (await res.text().catch(() => '')).trim();
  throw new Error(`HTTP ${res.status}${text ? ' — ' + text.slice(0, 200) : ' (phản hồi rỗng)'}`);
}
const j = async (u) => parseJson(await fetch(u));
const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const fmtMs = (ms) => ms ? (ms < 1000 ? `${ms}ms` : `${(ms/1000).toFixed(1)}s`) : '—';
const fmtCost = (n) => '$' + (n || 0).toFixed(4);
const fmtNum = (n) => (n || 0).toLocaleString();
const fmtAgo = (ts) => {
  if (!ts) return '';
  const d = new Date(ts);
  const s = Math.floor((Date.now() - d.getTime()) / 1000);
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.floor(s/60)}m ago`;
  if (s < 86400) return `${Math.floor(s/3600)}h ago`;
  return d.toLocaleDateString() + ' ' + d.toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'});
};

let project = null;
// Chat tách theo project: mỗi project giữ riêng nội dung stream + task đang theo dõi + offset log.
// chatState[proj] = { streamHTML, activeTaskId, logOffset }
const chatState = {};
const CHAT_PLACEHOLDER =
  '<div class="idle-msg">Nhập task để khởi chạy pipeline. Đính kèm ảnh/figma → bật designer.</div>';

function getChatState(proj) {
  if (!chatState[proj]) chatState[proj] = { streamHTML: null, activeTaskId: null, logOffset: 0 };
  return chatState[proj];
}

async function loadProjects() {
  const projs = await j('/api/projects');
  const sel = $('#project');
  sel.innerHTML = projs.length
    ? projs.map(p => `<option value="${esc(p)}">${esc(p)}</option>`).join('')
    : '<option value="">(no projects)</option>';
  const first = projs[0] || null;
  if (first) switchProject(first);
}

// Đổi project: lưu state hiện tại, dừng poll cũ, nạp lại stream của project đích,
// rồi re-attach task đang chạy (nếu có) để biết 'đang chạy / hoàn thành'.
async function switchProject(newProj) {
  if (project) {
    const cur = getChatState(project);
    cur.streamHTML = $('#chat-stream').innerHTML;
    cur.activeTaskId = activeTaskId;
    cur.logOffset = logOffset;
  }
  stopChatPoll();
  project = newProj;
  const st = getChatState(newProj);
  $('#chat-stream').innerHTML = st.streamHTML != null ? st.streamHTML : CHAT_PLACEHOLDER;
  activeTaskId = st.activeTaskId;
  logOffset = st.logOffset || 0;
  updateSendState();
  refresh();
  await attachLive(newProj);                       // phát hiện task còn chạy → dựng bubble + poll
  // attachLive đã startChatPoll() nếu tìm thấy task running. Guard project===newProj phòng
  // re-entrant switch: user đổi project lần nữa trong lúc await → đừng arm poll cho project cũ.
  if (project === newProj && activeTaskId && !chatPoll) startChatPoll();  // khôi phục để bắt 'done' + tail log
}

// Re-attach: hỏi /live, nếu có task đang chạy thì dựng lại agent bubble + arm poll đúng project.
async function attachLive(proj) {
  try {
    const live = await j(`/api/projects/${encodeURIComponent(proj)}/live`);
    if (proj !== project || !live.length) return;
    const t = live[0];                             // live sort desc theo ts → task mới nhất
    if (activeTaskId !== t.task_id) { activeTaskId = t.task_id; logOffset = 0; }
    const bubble = ensureAgentBubble(activeTaskId);
    const running = (t.active || []).map(a => a.agent).join(', ');
    bubble.querySelector('.msg-meta').textContent = `${t.mode} · ${running || '…'} đang chạy`;
    bubble.querySelector('.msg-timeline').innerHTML = renderTimeline(t.timeline || []);
    startChatPoll();
  } catch (e) { /* transient; bỏ qua */ }
}

async function refresh() {
  if (!project) return;
  const [live, tasks, agents] = await Promise.all([
    j(`/api/projects/${encodeURIComponent(project)}/live`),
    j(`/api/projects/${encodeURIComponent(project)}/tasks`),
    j(`/api/projects/${encodeURIComponent(project)}/agents`),
  ]);
  renderLive(live);
  renderHistory(tasks);
  renderAgents(agents);
  $('#refresh-info').textContent = `↻ ${new Date().toLocaleTimeString()}`;
}

function shortModel(m) {
  if (!m) return '';
  // claude-sonnet-4-6[1m] → sonnet-4-6; openai/gpt-4o-mini → gpt-4o-mini
  return String(m).replace(/^claude-/, '').replace(/\[.*\]$/, '').replace(/^[^/]+\//, '');
}
function providerClass(p) { return 'prov-' + String(p || 'claude').toLowerCase().replace(/[^a-z]/g, ''); }

function renderProviderPill(provider, model) {
  if (!model && !provider) return '';
  return `<span class="model-pill ${providerClass(provider)}"
    title="${esc(provider || 'claude')} · ${esc(model || '')}">
    ${esc(provider || 'claude')}<span class="dim">·</span>${esc(shortModel(model))}
  </span>`;
}

function renderLive(live) {
  $('#live-dot').classList.toggle('active', live.length > 0);
  $('#live-count').textContent = live.length ? `${live.length} running` : 'idle';
  $('#live-list').innerHTML = live.length
    ? live.map(t => `
        <div class="live-item">
          <div class="live-head">
            <div class="live-task-id">${esc(t.task_id)} · ${esc(t.mode)} · ${esc(fmtAgo(t.last_ts))}</div>
            <div class="live-task-text">${esc(t.task || '(no task text)')}</div>
          </div>
          <div class="live-dag">${renderTimeline(t.timeline || [])}</div>
        </div>
      `).join('')
    : '<div class="idle-msg">No active tasks. Run <code>pagent feature "..."</code> trong terminal.</div>';
}

function renderAgents(agents) {
  $('#agent-grid').innerHTML = agents.length
    ? agents.map(a => {
        const models = (a.by_model || []).map(m => {
          const [prov, ...rest] = m.key.split('/');
          return `<div class="model-line">
            ${renderProviderPill(prov, rest.join('/'))}
            <span class="dim">${m.runs}× · ${fmtCost(m.cost_usd)}</span>
          </div>`;
        }).join('');
        return `
          <div class="agent-card">
            <div class="name">${esc(a.agent)}</div>
            <div class="stats">
              ${a.runs} runs · ${fmtCost(a.cost_usd)}<br>
              avg ${fmtMs(a.avg_duration_ms)} · ${fmtNum(a.total_tokens_out)} tok out
            </div>
            <div class="model-list">${models}</div>
          </div>
        `;
      }).join('')
    : '<div class="idle-msg">Chưa có hoạt động nào.</div>';
}

function renderHistory(tasks) {
  $('#history-count').textContent = tasks.length ? `(${tasks.length})` : '';
  $('#history-tbody').innerHTML = tasks.length
    ? tasks.map(t => `
        <tr class="row" data-id="${esc(t.id)}">
          <td><span title="${esc(new Date(t.mtime*1000).toLocaleString())}">${esc(fmtAgo(new Date(t.mtime*1000).toISOString()))}</span></td>
          <td><span class="kind-tag ${t.kind}">${esc(t.kind === 'features' ? 'feat' : 'bug')}</span></td>
          <td>${esc(t.title)}</td>
          <td><div class="agent-pills">${(t.agents || []).map(a => `<span class="agent-pill">${esc(a)}</span>`).join('')}</div></td>
          <td class="num">${fmtCost(t.cost_usd)}</td>
          <td class="num">${fmtMs(t.duration_ms)}</td>
          <td class="num">${fmtNum(t.output_tokens)}</td>
        </tr>
      `).join('')
    : '<tr><td colspan="7" class="idle-msg">Chưa có report nào.</td></tr>';
  $('#history-tbody').querySelectorAll('tr.row').forEach(tr =>
    tr.addEventListener('click', () => showDetail(tr.dataset.id)));
}

async function showDetail(id) {
  const r = await j(`/api/projects/${encodeURIComponent(project)}/tasks/${encodeURIComponent(id)}`);
  if (r.error) { alert(r.error); return; }
  $('#modal-meta').innerHTML = `
    <b>${esc(r.kind)}</b> · task_id=<b>${esc(r.task_id)}</b> · ${r.timeline.length} agent steps
  `;
  $('#modal-timeline').innerHTML = renderTimeline(r.timeline);
  $('#modal-report').textContent = r.content || '(empty)';
  $('#modal').classList.remove('hidden');
}

function renderTimeline(steps) {
  if (!steps.length) return '<div class="idle-msg">No timeline data.</div>';
  const parts = [];
  steps.forEach((s, i) => {
    if (i > 0) parts.push('<div class="timeline-arrow">→</div>');
    const running = s.running ? ' running' : '';
    const errored = s.is_error ? ' errored' : '';
    parts.push(`
      <div class="timeline-step${running}${errored}">
        <div class="step-agent">${esc(s.agent)}${s.running ? ' ⠿' : ''}</div>
        <div class="step-pill">${renderProviderPill(s.provider, s.model)}</div>
        <div class="step-meta">
          ${fmtMs(s.duration_ms)} · ${fmtCost(s.cost_usd)}<br>
          in ${fmtNum(s.input_tokens)} / out ${fmtNum(s.output_tokens)}
          ${s.terminal_reason && s.terminal_reason !== 'completed'
            ? `<br><span class="dim">${esc(s.terminal_reason)}</span>` : ''}
        </div>
      </div>
    `);
  });
  return `<div class="timeline">${parts.join('')}</div>`;
}

// ── chat composer ──
let chatMode = 'feature';
let draftId = null;
let attachments = [];      // {path, name, is_image, url}
let activeTaskId = null;
let chatPoll = null;
let pollTicks = 0;
let logOffset = 0;         // byte offset đã đọc của log task hiện tại (tail incremental)

function newDraftId() { draftId = 'draft-' + Date.now() + '-' + Math.floor(1000 + Math.random() * 9000); }
function scrollStream() { const s = $('#chat-stream'); s.scrollTop = s.scrollHeight; }
function clearStreamPlaceholder() { const ph = $('#chat-stream .idle-msg'); if (ph) ph.remove(); }

function updateSendState() {
  const btn = $('#send-btn');
  btn.disabled = !$('#task-input').value.trim() || !project || btn.classList.contains('loading');
}

function setMode(mode) {
  chatMode = mode;
  $('#mode-toggle').querySelectorAll('.mode-opt').forEach(b => {
    const on = b.dataset.mode === mode;
    b.classList.toggle('active', on);
    b.setAttribute('aria-checked', on ? 'true' : 'false');
  });
}

function renderPreviews() {
  $('#file-previews').innerHTML = attachments.map((a, i) =>
    a.is_image && a.url
      ? `<div class="thumb"><img src="${a.url}" alt="${esc(a.name)}">
           <button class="thumb-x" data-i="${i}" aria-label="Xoá ${esc(a.name)}">×</button></div>`
      : `<div class="file-chip"><span class="file-chip-name">${esc(a.name)}</span>
           <button class="thumb-x" data-i="${i}" aria-label="Xoá ${esc(a.name)}">×</button></div>`
  ).join('');
  $('#file-previews').querySelectorAll('.thumb-x').forEach(b =>
    b.addEventListener('click', () => { attachments.splice(+b.dataset.i, 1); renderPreviews(); }));
}

async function uploadFiles(files) {
  if (!project) return;
  for (const file of files) {
    const localUrl = file.type.startsWith('image/') ? URL.createObjectURL(file) : null;
    const fd = new FormData();
    fd.append('task', draftId);
    fd.append('file', file, file.name);
    try {
      const r = await parseJson(await fetch(`/api/projects/${encodeURIComponent(project)}/upload`, { method: 'POST', body: fd }));
      if (r.error) { showChatError(r.error); continue; }
      attachments.push({ path: r.path, name: r.name, is_image: r.is_image, url: localUrl });
      renderPreviews();
    } catch (e) { showChatError(String(e)); }
  }
}

function showChatError(msg) {
  clearStreamPlaceholder();
  $('#chat-stream').insertAdjacentHTML('beforeend', `<div class="msg msg-error">⚠ ${esc(msg)}</div>`);
  scrollStream();
}

function appendUserMessage(task, atts, figma) {
  clearStreamPlaceholder();
  const chips = atts.map(a => `<span class="msg-chip">${a.is_image ? '🖼' : '📄'} ${esc(a.name)}</span>`).join('');
  const fig = figma ? `<div class="msg-figma">figma: ${esc(figma)}</div>` : '';
  $('#chat-stream').insertAdjacentHTML('beforeend',
    `<div class="msg msg-user"><div class="msg-body">${esc(task)}</div>${chips ? `<div class="msg-chips">${chips}</div>` : ''}${fig}</div>`);
  scrollStream();
}

function ensureAgentBubble(id) {
  let el = document.getElementById('agent-msg-' + id);
  if (!el) {
    $('#chat-stream').insertAdjacentHTML('beforeend',
      `<div class="msg msg-agent" id="agent-msg-${esc(id)}"><div class="msg-meta dim">đang khởi chạy…</div><div class="msg-timeline"></div><pre class="msg-log" hidden></pre></div>`);
    el = document.getElementById('agent-msg-' + id);
  }
  return el;
}

function startChatPoll() { stopChatPoll(); pollTicks = 0; pollChat(); chatPoll = setInterval(pollChat, 2500); }
function stopChatPoll() { if (chatPoll) clearInterval(chatPoll); chatPoll = null; }

async function pollChat() {
  // Snapshot project/task ở đầu hàm: pollChat là async, đọc globals sau mỗi await.
  // stopChatPoll() chỉ huỷ interval — KHÔNG cancel promise đang in-flight. Nếu switchProject
  // chạy giữa chừng (ghi đè project/activeTaskId/logOffset), promise cũ resume với state của
  // project mới → rò log/timeline project này vào stream project khác. Bail khi stale.
  const proj = project, tid = activeTaskId;
  if (!tid || !proj) return stopChatPoll();
  const stale = () => proj !== project || tid !== activeTaskId;
  if (++pollTicks > 600) {   // ~25 min safety stop
    const meta = ensureAgentBubble(tid).querySelector('.msg-meta');
    if (meta) meta.textContent = 'timeout — reload để xem kết quả';
    return stopChatPoll();
  }
  const bubble = ensureAgentBubble(tid);
  try {
    const live = await j(`/api/projects/${encodeURIComponent(proj)}/live`);
    if (stale()) return;
    const hit = live.find(t => t.task_id === tid);
    await fetchChatLog(bubble, proj, tid);
    if (stale()) return;
    if (hit) {
      const running = (hit.active || []).map(a => a.agent).join(', ');
      bubble.querySelector('.msg-meta').textContent = `${hit.mode} · ${running || '…'} đang chạy`;
      bubble.querySelector('.msg-timeline').innerHTML = renderTimeline(hit.timeline || []);
    } else {
      const tasks = await j(`/api/projects/${encodeURIComponent(proj)}/tasks`);
      if (stale()) return;
      const done = tasks.find(t => t.task_id === tid);
      if (done) {
        const detail = await j(`/api/projects/${encodeURIComponent(proj)}/tasks/${encodeURIComponent(done.id)}`);
        if (stale()) return;
        bubble.querySelector('.msg-meta').innerHTML =
          `✓ hoàn thành · <a href="#" class="open-report" data-report-id="${esc(done.id)}">xem report</a>`;
        bubble.querySelector('.msg-timeline').innerHTML = renderTimeline(detail.timeline || []);
        await fetchChatLog(bubble, proj, tid);   // gom nốt phần log ghi ra ngay trước khi pagent thoát
        if (stale()) return;
        stopChatPoll();
        refresh();
      }
      // chưa có trong live và chưa done → pagent đang khởi chạy, tiếp tục poll
    }
  } catch (e) { /* transient; keep polling */ }
  if (!stale()) scrollStream();
}

// Tail log per-task: fetch từ logOffset, append text (esc tự nhiên qua text node) vào khối terminal.
// proj/tid được snapshot bởi caller; bail khi stale để không append/ghi offset nhầm project.
async function fetchChatLog(bubble, proj, tid) {
  if (!tid || !proj) return;
  const off = logOffset;
  try {
    const r = await j(`/api/projects/${encodeURIComponent(proj)}/chat-log/${encodeURIComponent(tid)}?offset=${off}`);
    if (proj !== project || tid !== activeTaskId) return;   // user đã đổi project/task khi đang fetch
    if (r.error) return;
    if (r.data) {
      const log = bubble.querySelector('.msg-log');
      if (log) { log.hidden = false; log.insertAdjacentText('beforeend', r.data); }
    }
    if (typeof r.offset === 'number') logOffset = r.offset;
  } catch (e) { /* transient; keep polling */ }
}

async function sendChat() {
  const task = $('#task-input').value.trim();
  if (!task || !project) return;
  const figma = $('#figma-url').value.trim();
  const btn = $('#send-btn');
  btn.classList.add('loading'); updateSendState();
  try {
    const r = await parseJson(await fetch(`/api/projects/${encodeURIComponent(project)}/chat`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ mode: chatMode, task, attachments: attachments.map(a => a.path), figma_url: figma }),
    }));
    if (r.error) { showChatError(r.error); return; }
    appendUserMessage(task, attachments, figma);
    activeTaskId = r.task_id;
    logOffset = 0;
    ensureAgentBubble(activeTaskId);
    $('#task-input').value = ''; $('#figma-url').value = '';
    attachments = []; renderPreviews(); newDraftId();
    autoGrow();
    startChatPoll();
  } catch (e) { showChatError(String(e)); }
  finally { btn.classList.remove('loading'); updateSendState(); }
}

function autoGrow() {
  const ta = $('#task-input');
  ta.style.height = 'auto';
  ta.style.height = Math.min(ta.scrollHeight, 200) + 'px';
}

// wiring
newDraftId();
$('#mode-toggle').querySelectorAll('.mode-opt').forEach(b => b.addEventListener('click', () => setMode(b.dataset.mode)));
$('#task-input').addEventListener('input', () => { autoGrow(); updateSendState(); });
$('#task-input').addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendChat(); }
});
$('#send-btn').addEventListener('click', sendChat);
$('#file-input').addEventListener('change', (e) => { uploadFiles([...e.target.files]); e.target.value = ''; });
const dz = $('#dropzone');
['dragenter', 'dragover'].forEach(ev => dz.addEventListener(ev, (e) => { e.preventDefault(); dz.classList.add('drag-over'); }));
['dragleave', 'drop'].forEach(ev => dz.addEventListener(ev, (e) => { e.preventDefault(); if (ev === 'dragleave' && dz.contains(e.relatedTarget)) return; dz.classList.remove('drag-over'); }));
dz.addEventListener('drop', (e) => { if (e.dataTransfer && e.dataTransfer.files.length) uploadFiles([...e.dataTransfer.files]); });

$('#project').addEventListener('change', (e) => { switchProject(e.target.value); });
// Delegation: link 'xem report' tồn tại qua các lần restore innerHTML khi đổi project.
$('#chat-stream').addEventListener('click', (e) => {
  const a = e.target.closest('.open-report');
  if (a) { e.preventDefault(); showDetail(a.dataset.reportId); }
});
$('#refresh-btn').addEventListener('click', refresh);
$('#modal-close').addEventListener('click', () => $('#modal').classList.add('hidden'));
$('#modal').addEventListener('click', (e) => { if (e.target.id === 'modal') $('#modal').classList.add('hidden'); });
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') $('#modal').classList.add('hidden'); });

loadProjects();
setInterval(refresh, 3000);
