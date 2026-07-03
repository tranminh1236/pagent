# Resume agent khi chạm max_turns (dừng-chờ tại chỗ)

**Ngày:** 2026-07-03 · **Trạng thái:** đã duyệt (user chọn "Run dừng CHỜ tại chỗ")

## Vấn đề

Agent chạm `max_turns` → `call_agent` return 1 → pipeline chết. Nút retry hiện tại
("Tăng lượt & chạy tiếp") spawn lại **toàn bộ pipeline** từ đầu: orchestrator khám phá
lại codebase, đốt token, mất context agent đang dở.

## Giải pháp

Khi agent (provider=claude) exit với `subtype == "error_max_turns"`, pipeline **không
chết** mà dừng chờ tại chỗ. User cấp thêm lượt qua button trên Live view (web) hoặc
prompt tty (CLI) → agent tiếp tục **đúng session cũ** (`claude -p --resume <session_id>
--max-turns <N>`) → pipeline chạy tiếp liền mạch các bước sau. Không ai duyệt trong
timeout → fail như hành vi cũ (nút retry cũ vẫn là fallback).

Mirror pattern confirm-plan gate sẵn có (`plan.pending.json` / `decision.json`).

## Thành phần

### 1. `kit/lib/resume.sh` (mới — sourceable, unit-testable)

- `resume_gate <agent> <session_id> <used_turns> <default_turns>` — dispatch:
  - tty (`/dev/tty` mở được): hỏi trực tiếp, Enter = default_turns, số = custom, n = bỏ.
  - non-tty + `PAGENT_RESUME` truthy (web spawn): file handshake.
  - còn lại: return 1 (fail-fast như cũ — backward compat automation/tests).
  - stdout = số lượt mới đã clamp `[1, PAGENT_MAX_TURNS_CEILING:-60]`; return 1 = không resume.
- File handshake (namespace theo agent — audits song song không giẫm nhau):
  - Ghi atomic `runs/<tid>/resume.pending.<agent>.json`
    `{agent, session_id, used_turns, default_turns, ts}`.
  - Poll `runs/<tid>/resume.decision.<agent>.json` mỗi 2s, timeout
    `PAGENT_RESUME_TIMEOUT` (mặc định 900s). Decision `{action: "resume", extra_turns: N}`
    → stdout N; `{action: "stop"}` / timeout → return 1. Cleanup cả 2 file mọi nhánh.

### 2. `pagent` — `call_agent`

- Tách invocation claude thành `_run_claude_once` (pre-hook, spawn, spinner, wait,
  post-hook — MỘT đường code cho lần đầu + các vòng resume; giữ token event pairing).
- Args build thành `args_base` (không có `--max-turns`); lần đầu = base + max_turns
  gốc; resume = base + `--max-turns <extra>` + `--resume <sid>`.
- Sau invocation, loop: `.result` thiếu + `subtype == error_max_turns` + có
  `session_id` + `resume_round < PAGENT_MAX_RESUME` (mặc định 3) → `resume_gate` →
  re-invoke với prompt ngắn: "Bạn bị dừng vì hết lượt. Tiếp tục từ chỗ đang dở,
  hoàn thành đúng yêu cầu và format output ban đầu." Session id đọc lại từ JSON
  mới nhất mỗi vòng (resume fork session mới).
- Chỉ provider=claude (openrouter không có session resume).

### 3. `kit/web/server.py`

- `GET /api/projects/<proj>/resume/<tid>` → `{pending: [{agent, session_id,
  used_turns, default_turns}...]}` (scan `resume.pending.*.json`, bỏ file hỏng).
- `POST .../resume/<tid>` body `{agent, extra_turns}` → validate: agent khớp regex
  an toàn + có pending file; extra_turns int clamp `[1, PAGENT_MAX_TURNS_CEILING:-60]`
  (mặc định = default_turns của pending khi client bỏ trống); ghi atomic
  `resume.decision.<agent>.json`. Không tin field nào khác từ client.
- `_spawn_pagent`: `env.setdefault("PAGENT_RESUME", "1")` — web spawn luôn bật gate.

### 4. `kit/web/app.js` — Live view

- Poll resume-pending cùng nhịp poll plan-pending hiện có.
- Live-item có pending → `⏸ Agent '<agent>' cạn lượt` + input số lượt (prefill
  default_turns) + button `▶ Resume làm tiếp`. Bấm → POST → hiện "đang chạy tiếp".
- Helpers pure (exported cho node test): `resumeControlHtml(pendingList)`.

## Trade-offs chấp nhận

- Run giữ `.run.lock` khi chờ (đúng ngữ nghĩa "đang chạy"); timeout giới hạn 900s.
- Cost mỗi vòng resume log thành event start/end riêng cùng agent trong tokens
  timeline (aggregation đếm thêm run — chấp nhận, phản ánh đúng chi phí).
- Resume sau khi pagent chết KHÔNG hỗ trợ (cần pipeline re-entrant — ngoài scope).

## Test

- `tests/test_resume_gate.sh`: unit lib (handshake, timeout, stop, clamp, cleanup,
  atomic) + grep-assert tích hợp call_agent + **e2e fake claude bin**: lần 1 trả
  `error_max_turns`, lần 2 (có `--resume`) trả success — pipeline hoàn thành.
- `tests/test_server_resume.py`: endpoints (validate, clamp, traversal, atomic,
  PAGENT_RESUME setdefault).
- `tests/test_web_resume.js`: pure helpers UI.

## Env vars mới

| Var | Default | Ý nghĩa |
|-----|---------|---------|
| `PAGENT_RESUME` | unset (web spawn = 1) | bật file-handshake gate khi non-tty |
| `PAGENT_RESUME_TIMEOUT` | 900 | giây chờ decision trước khi fail |
| `PAGENT_MAX_RESUME` | 3 | số vòng resume tối đa mỗi agent mỗi run |
