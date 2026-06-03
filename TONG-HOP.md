# Tổng hợp pipelineAgent — Tính năng & Lịch sử fix

> File tổng hợp tự sinh: liệt kê tính năng theo task + các bug đã fix trong quá khứ.
> Cập nhật: 2026-06-02. Nguồn: `pagent` (933 dòng), `kit/`, `tests/`, git history.

`pagent` là CLI bashscript điều phối nhiều subagent qua `claude` CLI để chạy
pipeline dev tự động (feature/hotfix). Không scaffold file tĩnh — nó edit code
thật trong `$PAGENT_SOURCE` và track token/cost theo project → date → task_id.

---

## Phần 1 — Tính năng theo task

### 1. CLI & dispatch
- Sub-command: `init`, `feature`/`feat`, `fix`/`bug`/`hotfix`, `report`, `workflow`, `skills`, `skill new`, `agent new`, `env`, `gain`, `web`, `help`. — [pagent:885-933](pagent#L885)
- Fallback dispatch theo `$PAGENT_MODE` khi gõ lệnh không khớp. — [pagent:926-931](pagent#L926)
- Zsh autocomplete. — [kit/completions/_pagent](kit/completions/_pagent)

### 2. Auto-detect project & env
- `PAGENT_SOURCE` = git toplevel của cwd, fallback `$PWD`. `PAGENT_PROJECT` = basename. — [pagent:34-44](pagent#L34)
- Auto-source `.env.pagent` tìm ngược lên parents từ cwd. — [pagent:22-32](pagent#L22)

### 3. Pipeline feature (`pagent feature "..."`) — [pagent:434-631](pagent#L434)
1. **orchestrator** → JSON plan `{title, coder_task, reviewer_focus, tester_task, risk, affected_paths}`.
2. **designer** (chỉ khi task động đến UI — gate bằng regex) → design-spec JSON. — [pagent:492-515](pagent#L492)
3. **coder ↔ reviewer loop** → tối đa `PAGENT_MAX_REVIEW_ROUND` vòng, verdict `APPROVED`/`CHANGES_REQUESTED`. — [pagent:517-551](pagent#L517)
4. **tester** → viết + chạy test.
5. **workflow-extractor** → append section vào `workflow.md`.
6. Report + auto-compact run dir → `bundle.tar.gz`.

### 4. Pipeline hotfix (`pagent fix "..."`)
- Như feature nhưng bỏ workflow-extractor.
- **Root-cause synthesis**: sau review+test, orchestrator hợp nhất root cause → field `root_cause_summary`, ghi `root_cause.txt` + section riêng trong report. — [pagent:566-589](pagent#L566)

### 5. call_agent — engine gọi 1 agent — [pagent:194-303](pagent#L194)
- Resolve agent md: project-local (`.pagent/`) thắng global (`kit/`). — [pagent:200-207](pagent#L200)
- Đọc frontmatter: `allowed_tools`, `disallowed_tools`, `system_prompt_mode`, `max_turns`, `caveman`, `mcp_servers`, `provider`, `model`.
- Prompt đẩy qua stdin (tránh xung đột `--allowed-tools` variadic). — [pagent:284-286](pagent#L284)
- Spinner khi đợi, pre/post hook bao quanh mọi call.

### 6. Multi-provider — Claude CLI + OpenRouter fallback
- Mặc định Claude CLI local; bật OpenRouter qua frontmatter `provider:` hoặc `PAGENT_PROVIDER`. — [pagent:216-217](pagent#L216)
- `call_openrouter` transform chat-completion → shape giống claude JSON cho post-hook. — [pagent:84-127](pagent#L84)
- Lưu ý: OpenRouter không support tools → chỉ hợp orchestrator/reviewer/workflow-extractor.

### 7. Token & cost tracking
- pre/post hook ghi event `start`/`end` vào `tokens/<date>.jsonl` (input/output/cache tokens, cost_usd, duration, provider, model). — [kit/hooks/pre.sh](kit/hooks/pre.sh), [kit/hooks/post.sh](kit/hooks/post.sh)
- `pagent report` tổng hợp theo ngày + theo task_id. — [pagent:633-671](pagent#L633)

### 8. Token optimization
- **RTK** — compress output bash commands (`pagent gain`). — [pagent:901-910](pagent#L901)
- **Caveman** — compress agent response (off/lite/full/ultra) qua frontmatter hoặc `PAGENT_CAVEMAN`. — [pagent:242-252](pagent#L242)

### 9. MCP integration
- **context7** (docs) — gate `PAGENT_CONTEXT7`. **figma/canvas** (design) — gate `PAGENT_DESIGN`. — [pagent:219-236](pagent#L219)
- Mỗi server nạp `--mcp-config` riêng, có điều kiện theo `mcp_servers`/`allowed_tools` của agent.

### 10. Workflow management
- `pagent workflow show|list|run|new|file` — parse section `## <title>` trong `workflow.md`, chạy "Smoke test command". — [pagent:744-809](pagent#L744)

### 11. Web dashboard
- `pagent web [port] [host]` — 4 panel (Live, Agents, History, Modal task DAG), stdlib Python, auto-refresh 3s. — [kit/web/server.py](kit/web/server.py)

### 12. Skills/agents có thể override per-project
- `pagent skill new` / `agent new` scaffold vào `.pagent/`. `pagent skills` đánh dấu `(overridden)`. — [pagent:673-720](pagent#L673)

---

## Phần 2 — Lịch sử fix bug (từ rationale trong code + test regression)

Các fix dưới đây đều có comment giải thích trong code và/hoặc test bảo vệ chống tái phát.

| # | Bug đã xử lý | Cách fix | Vị trí | Test bảo vệ |
|---|---|---|---|---|
| 1 | **Task ID trùng** khi 2 process khởi tạo trong cùng 1 giây | `date -u` + PID `$$` + random → tách biệt tuyệt đối | [pagent:78-80](pagent#L78) | test_parallel_isolation |
| 2 | **Spinner xoá trắng EXIT trap** (mất `release_run_lock`) | Lưu trap EXIT cũ, khôi phục sau spinner thay vì `trap - EXIT` | [pagent:172-184](pagent#L172) | test_parallel_isolation |
| 3 | **JSONL interleave** khi 2 agent append song song | Portable file lock (flock Linux / mkdir spin-lock macOS), fd 9 scope trong subshell tránh leak | [kit/lib/lock.sh](kit/lib/lock.sh) | test_parallel_isolation |
| 4 | **2 run song song lẫn git diff** của nhau | `acquire_run_lock` warn-only khi phát hiện run khác active trên cùng project | [pagent:320-341](pagent#L320) | test_parallel_isolation |
| 5 | **release_run_lock xoá nhầm lock** của run giành sau | Chỉ `rm` nếu lock vẫn của `$$` mình | [pagent:335-341](pagent#L335) | test_parallel_isolation |
| 6 | **Orphan `start` event** khi agent fail (không có `end`) | Post-hook LUÔN chạy kể cả khi agent fail | [pagent:292-293](pagent#L292) | — |
| 7 | **Cost của task này lẫn task khác** trong report | `_sum_tokens` filter theo `task_id==$tid && event=="end"` | [pagent:354-365](pagent#L354) | test_parallel_isolation (#7) |
| 8 | **orchestrator JSON không parse** (fence/preamble/postamble) | `extract_json` 3 tầng: raw → strip fence → brace-matching; có fallback plan tối thiểu | [pagent:131-163](pagent#L131), [pagent:467-480](pagent#L467) | test_root_cause_flow |
| 9 | **Agent bọc code-fence quanh output** (init source-summary) | `sed` strip fence dòng đầu/cuối | [pagent:424](pagent#L424) | — |
| 10 | **post-hook crash khi response không parse** | jq fallback `0/parse_fail` thay vì lỗi | [kit/hooks/post.sh:24-40](kit/hooks/post.sh#L24) | — |
| 11 | **Root-cause synthesis ghi đè plan gốc** của orchestrator | Backup `orchestrator.plan.txt`, khôi phục sau synthesis | [pagent:569-580](pagent#L569) | test_root_cause_flow |
| 12 | **Synthesis chạy nhầm khi reviewer rỗng** | Gate `mode==hotfix && -s reviewer.txt` | [pagent:567](pagent#L567) | test_root_cause_flow (#15) |
| 13 | **Tester chạy headless** (không thấy browser thật) | Agent cấm headless, ép `PLAYWRIGHT_HEADLESS=false` | [kit/agents/tester.md](kit/agents/tester.md) | test_tester_agent |
| 14 | **figma/canvas hardcode secret** | Dùng env placeholder `${FIGMA_API_KEY}`/`${CANVAS_API_TOKEN}` | [kit/mcp/](kit/mcp/) | test_designer_integration |

**Trạng thái test hiện tại:** 7 suite, **189 assertions pass / 0 fail** (chạy 2026-06-02).

---

## Phần 3 — Điểm còn tồn (chưa fix, đề xuất)

1. **`python3` là hard-dependency nhưng không `need`** — `extract_json` + `call_openrouter` cần python3; pipeline core luôn gọi `extract_json` nhưng [pagent:63-65](pagent#L63) chỉ check `jq`/`claude`. → thêm `need python3`.
2. **Verdict parse mong manh** — [pagent:543](pagent#L543) lấy match `APPROVED|CHANGES_REQUESTED` đầu tiên; reviewer nhắc lại từ này trong giải thích sẽ gây sai. → neo theo dòng verdict.
3. **`cmd_report` cost null** — [pagent:653](pagent#L653) `add // 0` trả null nếu có entry `cost_usd: null` → `printf '%.4f'` lỗi. → `map(.cost_usd // 0)`.
