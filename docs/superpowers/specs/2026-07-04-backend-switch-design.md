# Công tắc backend trên pagent web: opencode (việc nhỏ) ↔ claude direct (việc lớn)

**Ngày:** 2026-07-04 · **Trạng thái:** đã duyệt

## Mục tiêu (lời user)

- Việc nhỏ → opencode CLI + 9router. Việc lớn/phức tạp → claude CLI **direct
  Anthropic subscription**.
- Chọn TAY qua config trên pagent web (persist, không phải chọn lại mỗi message).
- pagent là lớp quản lý: system prompt / history / cost / MCP / custom agent dùng
  chung — đổi backend KHÔNG phải thiết kế lại prompt (đã đạt nhờ kit/agents md +
  transform chung; spec này chỉ thêm công tắc).

## Thành phần

### 1. server.py — settings per-project

- File: `REPORTS/<proj>/settings.json` — `{provider: "opencode"|"claude",
  claude_model: "<tên trần>"}`. Ghi atomic tmp+replace.
- `GET  /api/projects/<proj>/settings` → settings merge default
  (`{provider:"opencode", claude_model:"sonnet"}`).
- `POST /api/projects/<proj>/settings` body `{provider?, claude_model?}` —
  provider whitelist {opencode, claude}; claude_model regex `^[A-Za-z0-9.-]{1,64}$`
  (tên trần, KHÔNG provider/model); field lạ bị bỏ; merge với settings cũ.
- `_spawn_pagent`: đọc settings → set `PAGENT_PROVIDER` + `PAGENT_CLAUDE_MODEL`
  vào env spawn. Thứ tự ưu tiên: settings ĐÈ os.environ kế thừa (ý định user từ
  web thắng env rơi rớt của shell — bài học bug 9router/Claude), nhưng `env_extra`
  nội bộ (retry/resume) đè được settings.

### 2. pagent — claude direct mode

- Defaults mới: `PAGENT_CLAUDE_DIRECT=1` (theo lựa chọn user: claude = direct sub),
  `PAGENT_CLAUDE_MODEL=sonnet`.
- Nhánh claude trong call_agent:
  - model chứa "/" (provider/model — vô nghĩa với claude direct) → bỏ qua, fallback
    `PAGENT_CLAUDE_MODEL`.
  - `PAGENT_CLAUDE_DIRECT` truthy → invoke qua `env -u ANTHROPIC_BASE_URL
    -u ANTHROPIC_API_KEY` (cả lần đầu LẪN vòng resume) → claude CLI dùng thẳng
    subscription Anthropic. `=0` → giữ đường gateway cũ (ANTHROPIC_BASE_URL).
- Resume gate max_turns tự sống lại khi chạy claude (có sẵn, không đổi gì).

### 3. Web UI — selector trong composer

- Cạnh mode-toggle: select `⚡ opencode · 9router (việc nhỏ)` /
  `🧠 claude · subscription (việc lớn)`; chọn claude → hiện select model
  (sonnet/opus/tên tuỳ ý từ settings).
- Đổi → POST settings → toast xác nhận; hiệu lực mọi run kế của project.
- Helper pure exported cho node test: `backendSelectorHtml(settings)`.

## Test

- `tests/test_server_settings.py`: GET default; POST validate/persist/merge;
  field lạ bị bỏ; provider sai → 400; claude_model dạng provider/model → 400;
  spawn inject từ settings; settings đè os.environ; env_extra đè settings.
- `tests/test_backend_direct.sh`: fake claude dump env → PAGENT_PROVIDER=claude +
  ANTHROPIC_BASE_URL đang set → invoke thực tế KHÔNG còn ANTHROPIC_BASE_URL/KEY;
  model = PAGENT_CLAUDE_MODEL; PAGENT_CLAUDE_DIRECT=0 → giữ ANTHROPIC_BASE_URL;
  model frontmatter chứa "/" bị bỏ.
- `tests/test_web_backend.js`: backendSelectorHtml (selected đúng, claude hiện
  model select, escape).

## Ngoài scope

- Auto-route theo risk/plan (user chọn tay). Per-message override. CLI flag mới
  (`PAGENT_PROVIDER=claude pagent ...` đã đủ).
