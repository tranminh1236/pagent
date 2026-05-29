// pagent dashboard frontend
const $ = (s) => document.querySelector(s);
const j = async (u) => (await fetch(u)).json();
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

async function loadProjects() {
  const projs = await j('/api/projects');
  const sel = $('#project');
  sel.innerHTML = projs.length
    ? projs.map(p => `<option value="${esc(p)}">${esc(p)}</option>`).join('')
    : '<option value="">(no projects)</option>';
  project = projs[0] || null;
  if (project) refresh();
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

$('#project').addEventListener('change', (e) => { project = e.target.value; refresh(); });
$('#refresh-btn').addEventListener('click', refresh);
$('#modal-close').addEventListener('click', () => $('#modal').classList.add('hidden'));
$('#modal').addEventListener('click', (e) => { if (e.target.id === 'modal') $('#modal').classList.add('hidden'); });
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') $('#modal').classList.add('hidden'); });

loadProjects();
setInterval(refresh, 3000);
