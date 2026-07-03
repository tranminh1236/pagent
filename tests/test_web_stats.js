#!/usr/bin/env node
// Tests cho stat cards trong kit/web/app.js: fmtCompact (rút gọn số) + computeStats (gom số liệu).
// Vanilla node assert — không dependency. app.js require ở node (wiring DOM đã guard).
const assert = require('assert');
const { fmtCompact, fmtSpend, computeStats } = require('../kit/web/app.js');

let pass = 0;
const t = (name, fn) => { fn(); pass++; console.log('  ok - ' + name); };

// ── fmtCompact ──
t('fmtCompact: triệu → M 2 chữ số', () => {
  assert.strictEqual(fmtCompact(1090000), '1.09M');
});
t('fmtCompact: strip trailing zero', () => {
  assert.strictEqual(fmtCompact(2000000), '2M');
  assert.strictEqual(fmtCompact(1500000), '1.5M');
});
t('fmtCompact: nghìn → K', () => {
  assert.strictEqual(fmtCompact(1500), '1.5K');
});
t('fmtCompact: tỷ → B', () => {
  assert.strictEqual(fmtCompact(3200000000), '3.2B');
});
t('fmtCompact: số nhỏ dùng fmtNum (locale)', () => {
  assert.strictEqual(fmtCompact(999), (999).toLocaleString());
  assert.strictEqual(fmtCompact(0), (0).toLocaleString());
});
t('fmtCompact: null/undefined → 0', () => {
  assert.strictEqual(fmtCompact(null), (0).toLocaleString());
  assert.strictEqual(fmtCompact(undefined), (0).toLocaleString());
});
t('fmtCompact: boundary 1000 → 1K', () => {
  assert.strictEqual(fmtCompact(1000), '1K');
});
t('fmtCompact: non-numeric → 0, không NaN', () => {
  const r = fmtCompact('abc');
  assert.strictEqual(r, (0).toLocaleString());
  assert.ok(!/NaN/.test(r));
});

// ── fmtSpend (card Total Spend: 2 chữ số, khác fmtCost 4 số cho bảng) ──
t('fmtSpend: 2 chữ số', () => {
  assert.strictEqual(fmtSpend(84.88), '$84.88');
  assert.strictEqual(fmtSpend(1.5), '$1.50');
});
t('fmtSpend: null/undefined → $0.00', () => {
  assert.strictEqual(fmtSpend(null), '$0.00');
  assert.strictEqual(fmtSpend(undefined), '$0.00');
});

// ── computeStats ──
t('computeStats: gom sum agents + count', () => {
  const agents = [
    { cost_usd: 1.5, runs: 3, total_tokens_out: 1000000 },
    { cost_usd: 0.25, runs: 2, total_tokens_out: 90000 },
  ];
  const tasks = [{}, {}, {}];
  const r = computeStats(tasks, agents, 4);
  assert.strictEqual(r.spend, 1.75);
  assert.strictEqual(r.runs, 5);
  assert.strictEqual(r.tokensOut, 1090000);
  assert.strictEqual(r.agents, 2);
  assert.strictEqual(r.tasks, 3);
  assert.strictEqual(r.workflows, 4);
});
t('computeStats: field tokens_out fallback total_tokens_out', () => {
  const r = computeStats([], [{ tokens_out: 500 }], 0);
  assert.strictEqual(r.tokensOut, 500);
});
t('computeStats: mảng rỗng / thiếu field → 0', () => {
  const r = computeStats([], [], undefined);
  assert.strictEqual(r.spend, 0);
  assert.strictEqual(r.runs, 0);
  assert.strictEqual(r.tokensOut, 0);
  assert.strictEqual(r.agents, 0);
  assert.strictEqual(r.tasks, 0);
  assert.strictEqual(r.workflows, 0);
});

// ── computeStats với 3 auditor (architecture/performance/security) — stat dashboard ──
// Kịch bản pipeline thật: endpoint /agents phát 1 record/agent (server.py:529 → total_tokens_out).
// Dashboard phải gom đủ 3 auditor + coder/reviewer/tester vào Spend/Runs/Tokens/Agents.
t('computeStats: gom đủ 3 auditor vào aggregate dashboard', () => {
  const agents = [
    { agent: 'architecture', cost_usd: 0.40, runs: 2, total_tokens_out: 120000 },
    { agent: 'performance',  cost_usd: 0.35, runs: 2, total_tokens_out: 110000 },
    { agent: 'security',     cost_usd: 0.30, runs: 2, total_tokens_out: 100000 },
    { agent: 'coder',        cost_usd: 1.20, runs: 3, total_tokens_out: 500000 },
    { agent: 'reviewer',     cost_usd: 0.50, runs: 2, total_tokens_out: 150000 },
    { agent: 'tester',       cost_usd: 0.25, runs: 1, total_tokens_out: 80000 },
  ];
  const r = computeStats([{}, {}], agents, 1);
  assert.strictEqual(r.agents, 6);                       // đếm cả 3 auditor
  assert.strictEqual(r.runs, 12);                        // 2+2+2+3+2+1
  assert.strictEqual(r.spend, 3.0);                      // 0.40+0.35+0.30+1.20+0.50+0.25
  assert.strictEqual(r.tokensOut, 1060000);              // tổng token 6 agent
});
t('computeStats: chỉ 3 auditor read-only (không coder) vẫn gom đúng', () => {
  const auditors = [
    { agent: 'architecture', cost_usd: 0.1, runs: 1, total_tokens_out: 10000 },
    { agent: 'performance',  cost_usd: 0.1, runs: 1, total_tokens_out: 20000 },
    { agent: 'security',     cost_usd: 0.1, runs: 1, total_tokens_out: 30000 },
  ];
  const r = computeStats([], auditors, 0);
  assert.strictEqual(r.agents, 3);
  assert.strictEqual(r.tokensOut, 60000);
  assert.ok(Math.abs(r.spend - 0.3) < 1e-9);
});

console.log(`\n${pass} passed`);
