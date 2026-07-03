#!/usr/bin/env node
// Tests cho selector backend (opencode ↔ claude direct) trong composer — pure helper.
// Spec: docs/superpowers/specs/2026-07-04-backend-switch-design.md
const assert = require('assert');
const { backendSelectorHtml } = require('../kit/web/app.js');

let pass = 0;
const t = (name, fn) => { fn(); pass++; console.log('  ok - ' + name); };

t('opencode selected mặc định, không hiện model select', () => {
  const html = backendSelectorHtml({ provider: 'opencode', claude_model: 'sonnet' });
  assert.ok(/value="opencode"[^>]*selected/.test(html), 'opencode selected');
  assert.ok(!/backend-claude-model/.test(html) || /hidden/.test(html),
    'model select ẩn khi opencode');
});

t('claude selected → hiện model select với claude_model hiện tại', () => {
  const html = backendSelectorHtml({ provider: 'claude', claude_model: 'opus' });
  assert.ok(/value="claude"[^>]*selected/.test(html), 'claude selected');
  assert.ok(/backend-claude-model/.test(html) && !/backend-claude-model[^>]*hidden/.test(html.match(/<select[^>]*backend-claude-model[^>]*>/)?.[0] || 'hidden'),
    'model select hiện khi claude');
  assert.ok(/value="opus"[^>]*selected|selected[^>]*value="opus"/.test(html), 'opus selected');
});

t('nhãn nêu rõ mục đích: opencode việc nhỏ, claude việc lớn', () => {
  const html = backendSelectorHtml({ provider: 'opencode' });
  assert.ok(/9router/.test(html), 'nhắc 9router');
  assert.ok(/subscription/.test(html), 'nhắc subscription');
});

t('settings null/undefined → không throw, mặc định opencode', () => {
  const html = backendSelectorHtml(null);
  assert.ok(/value="opencode"[^>]*selected/.test(html));
});

t('escape giá trị claude_model lạ (an toàn XSS)', () => {
  const html = backendSelectorHtml({ provider: 'claude', claude_model: '"><img>' });
  assert.ok(!/"><img>/.test(html), 'phải escape');
});

console.log(`\n${pass} tests passed`);
