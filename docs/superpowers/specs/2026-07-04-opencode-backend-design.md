# Backend opencode CLI — mặc định; claude CLI thành provider ẩn

**Ngày:** 2026-07-04 · **Trạng thái:** đã duyệt (user chốt: model dạng `9router/Claude`,
resume/retry giữ dormant, claude giữ làm provider ẩn sau `PAGENT_PROVIDER=claude`)

## Bối cảnh & quyết định

pagent hiện gọi LLM qua claude CLI (`claude -p`) route 9router bằng `ANTHROPIC_BASE_URL`.
User yêu cầu thay bằng **opencode CLI** (đã cấu hình sẵn provider 9router trong
`~/.config/opencode/opencode.json`, default model `9router/Claude`). claude giữ lại làm
provider ẨN — quay lại bằng 1 biến env, không cần revert code.

**Đã xác minh thực nghiệm (opencode 1.17.13):**
- `opencode run --dir <src> -m provider/model --agent <name> --format json --auto "<prompt>"`
  → NDJSON events: `step_start` / `text` (part.text) / `step_finish` (part.tokens
  {input,output,reasoning,cache{read,write}}, part.cost, reason) / `error`
  (error.name, error.data.message); mọi event có `sessionID`. rc=0 thành công, rc≠0 lỗi.
- **BẮT BUỘC redirect XDG**: `~/.local/share|state/opencode`, `~/.cache/opencode` đang
  thuộc root (di sản chạy sudo) → user thường chạy là EACCES/treo lock heartbeat.
  pagent trỏ `XDG_DATA_HOME/STATE_HOME/CACHE_HOME` → `$PAGENT_OC_HOME/{data,state,cache}`
  (mặc định `$PAGENT_REPORT_DIR/.opencode`) — né root-owned + cô lập session pagent.
- Agent md opencode: `.opencode/agents/<name>.md`, frontmatter
  {description, mode, model, temperature, permission{edit,bash,webfetch}}, body = system prompt.
- Gateway 9router lành mạnh (FREE combo trả lời 7s qua curl) — điểm treo trước đó là XDG.

## Thành phần

### 1. `pagent` — `call_agent` nhánh opencode (MẶC ĐỊNH)

- `provider="${provider:-${PAGENT_PROVIDER:-opencode}}"` (đổi default claude → opencode).
  Frontmatter `provider:` per-agent vẫn override. Nhánh claude/openrouter giữ nguyên code.
- `need` claude bỏ khỏi top-level; check binary lazy theo provider trong call_agent.
- **Sinh agent file** mỗi lần gọi: `$PAGENT_SOURCE/.opencode/agents/pagent-<agent>.md`
  - body = system_prompt SAU các injection (caveman, TDD, runtime block)
  - frontmatter: `description`, `mode: primary`, `permission:`
    map từ allowed_tools: có Write/Edit → `edit: allow`; có Bash → `bash: allow`;
    có WebFetch → `webfetch: allow`; còn lại deny. (Không map được pattern
    `Bash(cat *)` chi tiết — chấp nhận thô allow/deny.)
  - User nên gitignore `.opencode/agents/pagent-*.md` (docs, không tự sửa .gitignore).
- **Invoke**: env XDG_* redirect + `perl alarm ${PAGENT_AGENT_TIMEOUT:-3600}` (opencode
  không có max_turns → guard treo) →
  `opencode run --dir $PAGENT_SOURCE --format json --title pagent-<tid>-<agent> --auto
   --agent pagent-<agent> [-m $model] "<prompt>"`.
  `-m` chỉ truyền khi model non-empty (unset → opencode dùng default config 9router/Claude).
  Prompt qua argv (chấp nhận trần ARG_MAX ~256KB; ghi chú trong help).
  Events → `$PAGENT_RUN_DIR/<agent>.oc.jsonl` (giữ để debug), stderr → `<agent>.err`.
- **Transform** events → JSON claude-shape ghi `<agent>.json` (mirror call_openrouter):
  `.result` = text event cuối (khi error → error message để warn hiện đúng reason),
  `.usage.{input_tokens,output_tokens,cache_read_input_tokens,cache_creation_input_tokens}`
  = tổng các step_finish, `.total_cost_usd` = tổng cost, `.session_id`, `.num_turns` =
  số step_finish, `.duration_ms` đo wall-time, `.modelUsage.{<model>}` 1 entry (web pill),
  `.is_error` = (có event error || rc≠0), `.subtype` success|error, `.provider` "opencode",
  `.terminal_reason` "completed"|message lỗi.
  → post.sh / tokens log / web UI / `_resp_ok` KHÔNG đổi.
- **MCP**: gate `PAGENT_CONTEXT7`/`PAGENT_DESIGN` như cũ; khi bật, sinh
  `$PAGENT_SOURCE/.opencode/opencode.json` với key `mcp` (transform từ kit/mcp/*.json
  dạng claude `{mcpServers:{n:{command,args,env}}}` → opencode
  `{mcp:{n:{type:"local",command:[cmd,...args],environment:{}}}}`).
- `PAGENT_MODEL` default đổi `sonnet` → RỖNG (unset = dùng default opencode config);
  nhánh claude ẩn tự fallback `sonnet` nội bộ. `.env.pagent`: `PAGENT_MODEL="9router/Claude"`.

### 2. Gỡ sanitizer `9router/` (đảo fix 2026-07-03 — dạng provider/model giờ là ĐÚNG)

- pagent: xoá block strip prefix `9router/` sau load_env.
- server.py `_spawn_pagent`: xoá block trả 400 khi model prefix `9router/`.
- Tests flip: `test_env_provider.sh` (case cấm "/" → yêu cầu provider/model; case sanitize
  → xoá; case PAGENT_OPENCODE_BIN "biến chết" → đảo thành "pagent PHẢI tham chiếu"),
  `test_server_model_validation.py` → assert spawn CHẤP NHẬN model 9router/Claude.
- Memory/ghi chú cập nhật (dạng provider/model đúng cho backend opencode).

### 3. Không đổi / dormant

- openrouter branch, pre/post hook, web UI, server endpoints (trừ bỏ model block).
- Resume gate + retry max_turns: dormant (chỉ trigger trong nhánh claude ẩn).
- `PAGENT_RESUME` setdefault trong server giữ nguyên (vô hại).
- Tests fake-claude hiện có (test_resume_gate e2e, test_agent_error_detection) thêm
  `PAGENT_PROVIDER=claude` để tiếp tục test nhánh ẩn.

### 4. Env vars mới/đổi

| Var | Default | Ý nghĩa |
|-----|---------|---------|
| `PAGENT_PROVIDER` | `opencode` | opencode \| claude \| openrouter |
| `PAGENT_OPENCODE_BIN` | `opencode` | path opencode CLI |
| `PAGENT_OC_HOME` | `$PAGENT_REPORT_DIR/.opencode` | XDG data/state/cache riêng cho pagent |
| `PAGENT_AGENT_TIMEOUT` | `3600` | giây tối đa 1 lượt agent (guard treo, mọi provider opencode) |
| `PAGENT_MODEL` | (rỗng) | dạng `provider/model` (vd `9router/Claude`); rỗng → default opencode config |

## Test

- `tests/test_opencode_backend.sh`: fake opencode bin (in NDJSON events giả, dump argv/env
  ra marker) — (1) e2e `pagent find` rc=0; (2) `<agent>.json` đủ field claude-shape đúng
  giá trị; (3) agent file sinh đúng frontmatter permission theo allowed_tools; (4) XDG_*
  trỏ PAGENT_OC_HOME; (5) `-m`/`--agent`/`--dir`/`--auto` đúng; (6) event error → pipeline
  fail + reason trong log; (7) PAGENT_MODEL rỗng → không truyền `-m`.
- Flip/giữ như mục 2, 3. Full suite phải xanh (trừ 4 fail có sẵn của working tree).
- Smoke thật (thủ công, gateway sống): `pagent find` với `9router/FREE`.

## Rủi ro chấp nhận

- Prompt qua argv: trần ARG_MAX (~256KB) — context brief cực lớn có thể chạm; sẽ lộ rõ
  bằng lỗi spawn, không im lặng.
- opencode không có max_turns → chi phí 1 lượt agent không có trần lượt, chỉ có trần
  thời gian (`PAGENT_AGENT_TIMEOUT`).
- Permission map thô (allow/deny cả nhóm bash) — mất allow-list chi tiết `Bash(cat *)`.
- `.opencode/agents/pagent-*.md` là file sinh trong repo user (cần gitignore).
