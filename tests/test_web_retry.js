#!/usr/bin/env node
// Tests cho nút retry ('Tăng lượt & chạy tiếp') trên Live card trong kit/web/app.js.
// Pure helpers (không đụng DOM): liveMaxTurnsHit (điều kiện hiện nút) + retryControlHtml (markup).
// Vanilla node assert — không dependency, đồng nhất test_web_stats.js.
const assert = require('assert');
const { liveMaxTurnsHit, retryControlHtml } = require('../kit/web/app.js');

let pass = 0;
const t = (name, fn) => { fn(); pass++; console.log('  ok - ' + name); };

// ── liveMaxTurnsHit: chỉ true khi có step terminal_reason chứa 'max_turns' ──
t('hit khi 1 step terminal_reason === max_turns', () => {
  const task = { task_id: 'T1', timeline: [
    { agent: 'coder', terminal_reason: 'completed' },
    { agent: 'reviewer', terminal_reason: 'max_turns' },
  ] };
  assert.strictEqual(liveMaxTurnsHit(task), true);
});
t('hit khi terminal_reason chứa max_turns dạng chuỗi dài', () => {
  const task = { task_id: 'T2', timeline: [{ agent: 'coder', terminal_reason: 'max_turns (24)' }] };
  assert.strictEqual(liveMaxTurnsHit(task), true);
});
t('không hit khi mọi step completed', () => {
  const task = { task_id: 'T3', timeline: [
    { agent: 'coder', terminal_reason: 'completed' },
    { agent: 'tester', terminal_reason: 'completed' },
  ] };
  assert.strictEqual(liveMaxTurnsHit(task), false);
});
t('không hit khi thiếu terminal_reason', () => {
  const task = { task_id: 'T4', timeline: [{ agent: 'coder' }] };
  assert.strictEqual(liveMaxTurnsHit(task), false);
});
t('timeline rỗng / thiếu → false, không throw', () => {
  assert.strictEqual(liveMaxTurnsHit({ task_id: 'T5', timeline: [] }), false);
  assert.strictEqual(liveMaxTurnsHit({ task_id: 'T6' }), false);
});
t('task null/undefined → false, không throw', () => {
  assert.strictEqual(liveMaxTurnsHit(null), false);
  assert.strictEqual(liveMaxTurnsHit(undefined), false);
});

// ── retryControlHtml: markup rỗng khi không hit, có nút + data-task-id khi hit ──
t('không hit → chuỗi rỗng (không render nút)', () => {
  const task = { task_id: 'T7', timeline: [{ agent: 'coder', terminal_reason: 'completed' }] };
  assert.strictEqual(retryControlHtml(task), '');
});
t('hit → có nút .live-retry-btn mang data-task-id đã esc', () => {
  const task = { task_id: 'T<8>', timeline: [{ agent: 'coder', terminal_reason: 'max_turns' }] };
  const html = retryControlHtml(task);
  assert.ok(/class="live-retry-btn"/.test(html), 'thiếu nút retry');
  assert.ok(/data-task-id="T&lt;8&gt;"/.test(html), 'task_id chưa escape / thiếu data-task-id');
  assert.ok(/live-retry-turns/.test(html), 'thiếu ô nhập max_turns');
  assert.ok(!/T<8>/.test(html), 'task_id chưa escape (XSS)');
});

console.log(`\n${pass} passed`);
