#!/usr/bin/env node
// Tests cho phân trang client-side History trong kit/web/app.js.
// Vanilla node assert — không dependency. app.js được require ở node (wiring DOM đã guard).
const assert = require('assert');
const { paginate, PAGE_SIZE } = require('../kit/web/app.js');

const mk = (n) => Array.from({ length: n }, (_, i) => ({ id: 'id' + i }));
let pass = 0;
const t = (name, fn) => { fn(); pass++; console.log('  ok - ' + name); };

// ── pageCount ──
t('pageCount: rỗng → 1 trang', () => {
  assert.strictEqual(paginate([], 1, PAGE_SIZE).pageCount, 1);
});
t('pageCount: đúng PAGE_SIZE → 1 trang', () => {
  assert.strictEqual(paginate(mk(PAGE_SIZE), 1, PAGE_SIZE).pageCount, 1);
});
t('pageCount: PAGE_SIZE+1 → 2 trang', () => {
  assert.strictEqual(paginate(mk(PAGE_SIZE + 1), 1, PAGE_SIZE).pageCount, 2);
});

// ── slice rows theo trang ──
t('rows: trang 1 lấy PAGE_SIZE đầu', () => {
  const r = paginate(mk(PAGE_SIZE + 5), 1, PAGE_SIZE);
  assert.strictEqual(r.rows.length, PAGE_SIZE);
  assert.strictEqual(r.rows[0].id, 'id0');
  assert.strictEqual(r.rows[PAGE_SIZE - 1].id, 'id' + (PAGE_SIZE - 1));
});
t('rows: trang cuối lấy phần dư', () => {
  const r = paginate(mk(PAGE_SIZE + 5), 2, PAGE_SIZE);
  assert.strictEqual(r.rows.length, 5);
  assert.strictEqual(r.rows[0].id, 'id' + PAGE_SIZE);
});

// ── clamp: trang vượt số trang → reset về 1 ──
t('page: vượt pageCount → về trang 1', () => {
  const r = paginate(mk(PAGE_SIZE + 1), 5, PAGE_SIZE);  // chỉ có 2 trang
  assert.strictEqual(r.page, 1);
  assert.strictEqual(r.rows[0].id, 'id0');
});
t('page: hợp lệ → giữ nguyên', () => {
  assert.strictEqual(paginate(mk(PAGE_SIZE + 1), 2, PAGE_SIZE).page, 2);
});

// ── hiển thị thanh phân trang ──
t('showPager: <= PAGE_SIZE → ẩn', () => {
  assert.strictEqual(paginate(mk(PAGE_SIZE), 1, PAGE_SIZE).showPager, false);
  assert.strictEqual(paginate([], 1, PAGE_SIZE).showPager, false);
});
t('showPager: > PAGE_SIZE → hiện', () => {
  assert.strictEqual(paginate(mk(PAGE_SIZE + 1), 1, PAGE_SIZE).showPager, true);
});

// ── prev/next ──
t('hasPrev: trang đầu tắt, trang sau bật', () => {
  const tasks = mk(PAGE_SIZE * 3);
  assert.strictEqual(paginate(tasks, 1, PAGE_SIZE).hasPrev, false);
  assert.strictEqual(paginate(tasks, 2, PAGE_SIZE).hasPrev, true);
});
t('hasNext: trang cuối tắt, trước đó bật', () => {
  const tasks = mk(PAGE_SIZE * 3);
  assert.strictEqual(paginate(tasks, 3, PAGE_SIZE).hasNext, false);
  assert.strictEqual(paginate(tasks, 2, PAGE_SIZE).hasNext, true);
});

console.log(`\n${pass} passed`);
