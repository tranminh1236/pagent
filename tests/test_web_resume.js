#!/usr/bin/env node
// Tests cho khối Resume (max_turns → cấp thêm lượt, tiếp tục ĐÚNG session) trên Live card.
// Spec: docs/superpowers/specs/2026-07-03-resume-max-turns-design.md
// Pure helpers (không đụng DOM): resumeControlHtml + liveSignature (phải gồm resume_pending
// để button xuất hiện/biến mất trigger re-render đúng).
const assert = require('assert');
const { resumeControlHtml, liveSignature } = require('../kit/web/app.js');

let pass = 0;
const t = (name, fn) => { fn(); pass++; console.log('  ok - ' + name); };

// ── resumeControlHtml ──
t('không có pending → chuỗi rỗng', () => {
  assert.strictEqual(resumeControlHtml({ task_id: 'T1' }), '');
  assert.strictEqual(resumeControlHtml({ task_id: 'T1', resume_pending: [] }), '');
  assert.strictEqual(resumeControlHtml(null), '');
});

t('1 agent pending → có label agent, input prefill default_turns, nút resume + bỏ', () => {
  const html = resumeControlHtml({
    task_id: 'T2',
    resume_pending: [{ agent: 'coder', session_id: 's1', used_turns: 30, default_turns: 30 }],
  });
  assert.ok(html.includes('coder'), 'label agent');
  assert.ok(html.includes('value="30"'), 'input prefill default_turns');
  assert.ok(html.includes('live-resume-btn'), 'nút resume');
  assert.ok(html.includes('live-resume-stop'), 'nút bỏ');
  assert.ok(html.includes('data-task-id="T2"'), 'data-task-id để delegation');
  assert.ok(html.includes('data-agent="coder"'), 'data-agent để POST đúng agent');
  assert.ok(html.includes('30'), 'hiện số lượt đã dùng');
});

t('2 agent pending song song → 2 khối, đúng agent từng khối', () => {
  const html = resumeControlHtml({
    task_id: 'T3',
    resume_pending: [
      { agent: 'security', used_turns: 12, default_turns: 15 },
      { agent: 'performance', used_turns: 9, default_turns: 15 },
    ],
  });
  assert.ok(html.includes('data-agent="security"'));
  assert.ok(html.includes('data-agent="performance"'));
  assert.strictEqual((html.match(/live-resume-btn/g) || []).length, 2);
});

t('escape HTML trong agent/task_id (an toàn XSS)', () => {
  const html = resumeControlHtml({
    task_id: 'T4"><img>',
    resume_pending: [{ agent: 'x<script>', used_turns: 1, default_turns: 5 }],
  });
  assert.ok(!html.includes('<script>'), 'agent phải được escape');
  assert.ok(!html.includes('"><img>'), 'task_id phải được escape');
});

t('default_turns thiếu/rác → prefill fallback 20', () => {
  const html = resumeControlHtml({
    task_id: 'T5',
    resume_pending: [{ agent: 'coder', used_turns: 3 }],
  });
  assert.ok(html.includes('value="20"'), 'fallback 20');
});

// ── liveSignature phải đổi khi resume_pending xuất hiện/biến mất ──
t('signature đổi khi có resume_pending (trigger re-render hiện button)', () => {
  const base = { task_id: 'T6', mode: 'feature', timeline: [{ agent: 'coder', running: 1 }] };
  const withPending = { ...base, resume_pending: [{ agent: 'coder', default_turns: 20 }] };
  assert.notStrictEqual(liveSignature([base]), liveSignature([withPending]));
});

t('signature ổn định khi resume_pending không đổi (không re-render thừa)', () => {
  const a = { task_id: 'T7', mode: 'find', timeline: [], resume_pending: [{ agent: 'coder' }] };
  const b = { task_id: 'T7', mode: 'find', timeline: [], resume_pending: [{ agent: 'coder' }] };
  assert.strictEqual(liveSignature([a]), liveSignature([b]));
});

console.log(`\n${pass} tests passed`);
