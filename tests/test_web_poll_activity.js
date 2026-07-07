#!/usr/bin/env node
// Tests cho pollTickHasActivity trong kit/web/app.js — quyết định 1 nhịp poll có "tiến
// triển" không, để reset đồng hồ idle safety-stop. Mục tiêu: safety-stop CHỈ dừng khi poll
// thực sự im lặng ~25' (task chết / mồ côi), KHÔNG giết run khoẻ hay lúc đang chờ confirm.
const assert = require('assert');
const { pollTickHasActivity } = require('../kit/web/app.js');

let pass = 0;
const t = (name, fn) => { fn(); pass++; console.log('  ok - ' + name); };

// signature: pollTickHasActivity(plan, isLive, newLog, isDone)

t('đã xong → activity (khỏi timeout đè lên "hoàn thành")', () => {
  assert.strictEqual(pollTickHasActivity(null, false, false, true), true);
});
t('agent đang chạy (live) → activity', () => {
  assert.strictEqual(pollTickHasActivity(null, true, false, false), true);
});
t('có log mới → activity', () => {
  assert.strictEqual(pollTickHasActivity(null, false, true, false), true);
});
t('plan đang chờ confirm → activity (KHÔNG đếm vào idle timeout)', () => {
  assert.strictEqual(pollTickHasActivity({ pending: true }, false, false, false), true);
});
t('plan có nhưng không pending + im lặng → KHÔNG activity', () => {
  assert.strictEqual(pollTickHasActivity({ pending: false }, false, false, false), false);
});
t('không gì cả (poll mồ côi / task chết) → KHÔNG activity → đếm về timeout', () => {
  assert.strictEqual(pollTickHasActivity(null, false, false, false), false);
});
t('plan null an toàn (không ném lỗi)', () => {
  assert.strictEqual(pollTickHasActivity(undefined, false, false, false), false);
});

console.log(`\n${pass} passed`);
