#!/usr/bin/env node
// Tests cho aiWorkflowModel trong kit/web/app.js: chuẩn hoá payload /agent-workflow
// thành render-model (empty | blocks | raw | empty2). Pure fn, không đụng DOM.
const assert = require('assert');
const { aiWorkflowModel, renderAgentWorkflow } = require('../kit/web/app.js');

let pass = 0;
const t = (name, fn) => { fn(); pass++; console.log('  ok - ' + name); };

t('exists=false → empty state', () => {
  const m = aiWorkflowModel({ exists: false, path: '', content: '', blocks: [] });
  assert.strictEqual(m.state, 'empty');
});
t('null/undefined data → empty (không vỡ)', () => {
  assert.strictEqual(aiWorkflowModel(null).state, 'empty');
  assert.strictEqual(aiWorkflowModel(undefined).state, 'empty');
});
t('có blocks → state blocks + giữ path', () => {
  const m = aiWorkflowModel({ exists: true, path: '/r/demo/agent-workflow.md',
    content: '# x', blocks: [{ heading: 'Overview', body: 'abc' }] });
  assert.strictEqual(m.state, 'blocks');
  assert.strictEqual(m.blocks.length, 1);
  assert.strictEqual(m.path, '/r/demo/agent-workflow.md');
});
t('lọc block rỗng (không heading, body trắng)', () => {
  const m = aiWorkflowModel({ exists: true, blocks: [
    { heading: 'Overview', body: 'abc' },
    { heading: '', body: '   ' },
  ], content: '## Overview\nabc' });
  assert.strictEqual(m.blocks.length, 1);
});
t('exists nhưng blocks rỗng + content có chữ → raw fallback', () => {
  const m = aiWorkflowModel({ exists: true, blocks: [], content: 'text lệch format' });
  assert.strictEqual(m.state, 'raw');
  assert.strictEqual(m.content, 'text lệch format');
});
t('exists + file rỗng (content trắng) → empty2', () => {
  const m = aiWorkflowModel({ exists: true, blocks: [], content: '   \n' });
  assert.strictEqual(m.state, 'empty2');
});
t('blocks thiếu field body → không throw', () => {
  const m = aiWorkflowModel({ exists: true, blocks: [{ heading: 'Graph' }], content: '## Graph' });
  assert.strictEqual(m.state, 'blocks');
  assert.strictEqual(m.blocks[0].heading, 'Graph');
});

// ───────── smoke render (DOM stub, không dependency) ─────────
// Xác nhận renderAgentWorkflow: (a) blocks → cards vào #ai-workflow-body,
// (b) empty-state → idle-msg, (c) CHỈ đụng #ai-workflow-*, KHÔNG chạm section
// Workflow log cũ (#workflow-*). Stub DOM tối giản đúng ethos zero-dep của project.
function makeEl() {
  const el = {
    tagName: '', className: '', _tc: '', _html: '', children: [],
    appendChild(c) { this.children.push(c); this._html = ''; return c; },
  };
  Object.defineProperty(el, 'textContent', {
    get() { return this._tc; },
    set(v) { this._tc = v; },
  });
  Object.defineProperty(el, 'innerHTML', {
    get() { return this._html; },
    set(v) { this._html = v; if (v === '') this.children = []; },
  });
  return el;
}
function installDom() {
  const els = { '#ai-workflow-body': makeEl(), '#ai-workflow-path': makeEl() };
  const queried = [];
  global.document = {
    querySelector(sel) { queried.push(sel); return els[sel] || null; },
    createElement(tag) { const e = makeEl(); e.tagName = tag; return e; },
  };
  return { els, queried };
}
function uninstallDom() { delete global.document; }

t('render blocks → cards vào #ai-workflow-body, path set', () => {
  const { els } = installDom();
  try {
    renderAgentWorkflow({ exists: true, path: '/r/demo/agent-workflow.md',
      content: '', blocks: [{ heading: 'Overview', body: 'abc' },
                            { heading: 'Graph', body: '```\nplan --> review\n```' }] });
    const body = els['#ai-workflow-body'];
    assert.strictEqual(body.children.length, 2);
    assert.strictEqual(body.children[0].className, 'ai-wf-block');
    // heading card có <h3.ai-wf-heading> + <pre.ai-wf-body>
    const h = body.children[0].children[0];
    assert.strictEqual(h.className, 'ai-wf-heading');
    assert.strictEqual(h.textContent, 'Overview');
    const pre = body.children[0].children[1];
    assert.strictEqual(pre.className, 'ai-wf-body');
    assert.strictEqual(pre.textContent, 'abc');
    assert.strictEqual(els['#ai-workflow-path'].textContent, '/r/demo/agent-workflow.md');
  } finally { uninstallDom(); }
});
t('render empty-state (exists=false) → idle-msg, không tạo card', () => {
  const { els } = installDom();
  try {
    renderAgentWorkflow({ exists: false, path: '', content: '', blocks: [] });
    const body = els['#ai-workflow-body'];
    assert.match(body.innerHTML, /Chưa có AI workflow/);
    assert.strictEqual(body.children.length, 0);
  } finally { uninstallDom(); }
});
t('render empty2 (file rỗng) → "AI workflow rỗng"', () => {
  const { els } = installDom();
  try {
    renderAgentWorkflow({ exists: true, path: '/r/d/agent-workflow.md', content: '  \n', blocks: [] });
    assert.match(els['#ai-workflow-body'].innerHTML, /AI workflow rỗng/);
  } finally { uninstallDom(); }
});
t('KHÔNG đụng section Workflow log cũ (#workflow-*)', () => {
  const { queried } = installDom();
  try {
    renderAgentWorkflow({ exists: true, content: '', blocks: [{ heading: 'Overview', body: 'x' }] });
    // chỉ query selector ai-workflow; không có selector nào của log cũ
    assert.ok(queried.every(s => s.startsWith('#ai-workflow')), 'queried non-ai selector: ' + queried);
    assert.ok(!queried.some(s => /#workflow-|#stat-workflows/.test(s)));
  } finally { uninstallDom(); }
});

console.log(`\n${pass} passed`);
