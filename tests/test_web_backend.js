#!/usr/bin/env node
// Tests cho selector backend (opencode ↔ claude direct) trong composer — pure helper.
// Spec: docs/superpowers/specs/2026-07-04-backend-switch-design.md
const assert = require('assert');
const { backendSelectorHtml } = require('../kit/web/app.js');

let pass = 0;
const t = (name, fn) => { fn(); pass++; console.log('  ok - ' + name); };

t('opencode selected → hiện combo select + nút add/del, default 9router/FREE', () => {
  const html = backendSelectorHtml({ provider: 'opencode' });
  assert.ok(/value="opencode"[^>]*selected/.test(html), 'opencode selected');
  const wrap = html.match(/<span[^>]*backend-opencode-wrap[^>]*>/)?.[0] || '';
  assert.ok(/backend-opencode-wrap/.test(html) && !/hidden/.test(wrap), 'wrap opencode hiện');
  assert.ok(/backend-opencode-add/.test(html) && /backend-opencode-del/.test(html), 'có nút add/del');
  assert.ok(/value="9router\/FREE"[^>]*selected/.test(html), 'default 9router/FREE selected');
  const cm = html.match(/<select[^>]*backend-claude-model[^>]*>/)?.[0] || '';
  assert.ok(/hidden/.test(cm), 'claude model select ẩn khi opencode');
});

t('opencode: list truyền vào render đúng + chèn combo custom đang chọn', () => {
  const html = backendSelectorHtml(
    { provider: 'opencode', opencode_model: '9router/Custom' },
    ['9router/FREE', '9router/Claude']);
  assert.ok(/value="9router\/Custom"[^>]*selected/.test(html), 'custom được chèn & selected');
  assert.ok(/value="9router\/Claude"/.test(html), 'list item render');
});

t('escape combo opencode_model lạ (XSS)', () => {
  const html = backendSelectorHtml({ provider: 'opencode', opencode_model: '"><img>' });
  assert.ok(!/"><img>/.test(html), 'phải escape');
});

t('claude selected → hiện model select với claude_model hiện tại', () => {
  const html = backendSelectorHtml({ provider: 'claude', claude_model: 'opus' });
  assert.ok(/value="claude"[^>]*selected/.test(html), 'claude selected');
  assert.ok(/backend-claude-model/.test(html) && !/backend-claude-model[^>]*hidden/.test(html.match(/<select[^>]*backend-claude-model[^>]*>/)?.[0] || 'hidden'),
    'model select hiện khi claude');
  assert.ok(/value="opus"[^>]*selected|selected[^>]*value="opus"/.test(html), 'opus selected');
  const ocWrap = html.match(/<span[^>]*backend-opencode-wrap[^>]*>/)?.[0] || '';
  assert.ok(/hidden/.test(ocWrap), 'wrap opencode ẩn khi claude');
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
