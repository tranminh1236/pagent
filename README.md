# pipelineAgent — claude-cli orchestrator

Bashscript dispatch nhiều subagent (coder/reviewer/tester/orchestrator) qua **`claude` CLI**.
Mỗi project tự config qua `.env.pagent`. Report + token cost được track theo project → date → task_id.

## Cấu trúc

```text
pipelineAgent/
├── pagent                  ← bashscript (add vào PATH)
├── install.sh
├── .env.pagent.example     ← template env vars
└── kit/                    ← md templates dùng chung mọi project
    ├── agents/             # orchestrator | coder | reviewer | tester
    ├── skills/             # feature | hotfix | source-summary | workflow-extractor
    ├── hooks/              # pre.sh (start log) | post.sh (cost+token JSONL)
    ├── completions/        # _pagent — zsh autocomplete
    └── web/                # server.py + index.html + app.js + style.css (dashboard)
```

## Cài

```bash
./install.sh
# pagent giờ ở ~/.local/bin/pagent
```

## Auto-detect project / source

Bạn KHÔNG cần set `PAGENT_PROJECT` hay `PAGENT_SOURCE`. `pagent` tự nhận diện
khi bạn `cd` vào bất kỳ thư mục con của project:

- `PAGENT_SOURCE` = git toplevel của cwd (`git rev-parse --show-toplevel`),
  fallback `$PWD` nếu không phải git repo.
- `PAGENT_PROJECT` = basename của `PAGENT_SOURCE`.

Chỉ tạo `.env.pagent` ở root project khi cần override các tùy chọn khác:

```bash
PAGENT_REPORT_DIR="$HOME/.pagent-reports"
PAGENT_MODEL="claude-sonnet-4-6"
PAGENT_MAX_REVIEW_ROUND=2
# PAGENT_PROJECT="my-app"   # chỉ set nếu muốn khác tên folder
```

`pagent` auto-source file này (tìm ngược lên parents từ cwd).

## Dùng

```bash
cd ~/your-project

pagent init                                  # quét source → .pagent/source-summary.md
pagent feature "Thêm endpoint POST /users"   # full pipeline
pagent fix "Bug 500 khi login email hoa"     # hotfix pipeline
pagent report                                # tổng kết + cost
pagent workflow                              # in workflow.md
pagent env                                   # check biến môi trường
```

## Pipeline khi gõ `pagent feature "..."`

1. **orchestrator** — đọc task + `.pagent/source-summary.md` → JSON plan `{title, coder_task, reviewer_focus, tester_task, risk, affected_paths}`.
2. **coder** — edit code thật bằng `claude -p` với `--allowed-tools Read,Write,Edit,Bash,Grep,Glob`. Xuất block `CHANGES` + `RATIONALE`.
3. **reviewer** — read-only (`Read,Grep,Glob,Bash`), đọc `git diff` + CHANGES. Verdict `APPROVED` hoặc `CHANGES_REQUESTED` → loop coder lại tối đa `PAGENT_MAX_REVIEW_ROUND` vòng.
4. **tester** — viết test + chạy, output `TESTS_ADDED` + kết quả run.
5. **workflow-extractor** (chỉ feature) — append section vào `reports/<project>/workflow.md`.

Hotfix bỏ bước 5.

## Token & cost tracking

Pre/post hook tự ghi mỗi lần call agent:

```jsonl
{"ts":"...","event":"end","project":"my-app","mode":"feature","task_id":"...",
 "agent":"coder","model":"claude-sonnet-4-6[1m]",
 "input_tokens":42,"output_tokens":380,"cache_read":12000,"cache_creation":3500,
 "cost_usd":0.0234,"duration_ms":8123}
```

Lưu tại `$PAGENT_REPORT_DIR/<project>/tokens/<YYYY-MM-DD>.jsonl`.

`pagent report` tổng hợp theo ngày + theo task_id.

## Auto compact

Sau mỗi pipeline xong, `runs/<taskid>/*.json|*.err` được nén thành `bundle.tar.gz`.
Report final + workflow giữ nguyên ở `features/`, `bugs/`, `workflow.md`.

## Cấu trúc output cuối

```text
$PAGENT_REPORT_DIR/<project>/
├── features/<YYYY-MM-DD>-<taskid>.md
├── bugs/<YYYY-MM-DD>-<taskid>.md
├── workflow.md                              ← test scenarios tích lũy
├── tokens/<YYYY-MM-DD>.jsonl                ← raw event log
└── runs/<taskid>/
    ├── task.txt
    ├── orchestrator.txt
    ├── coder.txt
    ├── reviewer.txt
    ├── tester.txt
    └── bundle.tar.gz                        ← raw JSON gộp
```

## Skills & agents — global vs project-local

Resolution order khi `pagent` cần load 1 agent/skill (project-local thắng):

1. `$PAGENT_SOURCE/.pagent/skills/<name>.md`     ← project-local skill
2. `$PAGENT_SOURCE/.pagent/agents/<name>.md`     ← project-local agent
3. `$KIT_DIR/skills/<name>.md`                    ← global fallback
4. `$KIT_DIR/agents/<name>.md`

Mỗi project có thể override `coder.md` (vd: convention React Native) hoặc thêm
skill mới (`mobile-release.md`) chỉ áp dụng cho project đó. Travel chung với
git repo (commit thư mục `.pagent/` vào project).

```bash
cd ~/my-react-native-app
pagent agent new coder        # tạo .pagent/agents/coder.md, edit theo stack RN
pagent skill new mobile-feat  # tạo .pagent/skills/mobile-feat.md
pagent skills                 # liệt kê, đánh dấu (overridden)
```

## Backend providers — claude CLI và OpenRouter (fallback)

Mặc định mỗi agent gọi qua `claude` CLI local. Khi Claude bị rate-limit / down,
hoặc muốn so chi phí với model khác (GPT, Gemini, DeepSeek), bật **OpenRouter**
qua frontmatter hoặc env.

### Setup 1 lần

```bash
# Trong ~/.zshrc hoặc .env.pagent của project
export PAGENT_OPENROUTER_KEY="sk-or-v1-..."   # lấy ở openrouter.ai/keys
```

### Cách 1 — per-agent (recommended)

Mỗi agent md có thể tự chọn provider + model. Bỏ Claude cho 1 agent cụ thể:

```markdown
---
name: reviewer
provider: openrouter
model: openai/gpt-4o-mini
caveman: full
allowed_tools: Read,Grep,Glob,Bash
---
```

Models hay dùng (OpenRouter slug):

| Slug | Giá | Khi dùng |
|---|---|---|
| `openai/gpt-4o-mini` | $$ rẻ | reviewer free-text |
| `openai/gpt-4o` | $$$ | task khó |
| `google/gemini-2.0-flash-001` | $ siêu rẻ | source-summary, workflow-extractor |
| `deepseek/deepseek-chat` | $ rẻ | coder fallback (text-only) |
| `anthropic/claude-sonnet-4` | $$$$ | "Claude qua OpenRouter" khi CLI hỏng |

### Cách 2 — ép toàn pipeline

Khi local Claude CLI chết hoàn toàn:

```bash
PAGENT_PROVIDER=openrouter PAGENT_MODEL="anthropic/claude-sonnet-4" \
  pagent feature "..."
```

### Lưu ý quan trọng

OpenRouter dùng OpenAI chat format → **không support tools** kiểu claude
(Read/Write/Edit/Bash). Hệ quả:

- ✅ Phù hợp: `orchestrator` (JSON plan), `reviewer` (read-only, diff inject qua prompt), `workflow-extractor` (markdown gen).
- ❌ Không phù hợp: `coder` (cần Write/Edit), `tester` (cần Bash chạy test), `source-summary` (cần Read/Glob).

Đối với 2 agent này nếu Claude die mà vẫn muốn chạy: dùng `anthropic/claude-sonnet-4`
qua OpenRouter — model là Claude nhưng đường truyền khác, tránh được local CLI bug,
**nhưng vẫn không có tools** (chỉ text gen). Coi như fallback giảm nhẹ thôi.

### Cost tracking sau khi switch

Pre/post hook tự ghi `provider`, `model`, `cost_usd` (từ OpenRouter), `input_tokens`,
`output_tokens` vào `tokens/<date>.jsonl` cùng format như Claude. `pagent report`
và web dashboard hiển thị đúng.

## Custom global kit

Sửa md trong `kit/` để đổi behavior toàn cục — không cần rebuild:

- `kit/agents/coder.md` — convention chung cho mọi project
- `kit/agents/reviewer.md` — severity rubric
- `kit/skills/feature.md` — flow steps
- `kit/hooks/post.sh` — alert nếu cost vượt ngưỡng, ping Slack, v.v.

## Token optimization (RTK + Caveman)

Đã có 2 tầng compress:

1. **RTK** — compress output Bash commands (`ls`/`git`/`test`/...) trước khi vào
   context window. Cài qua claude code: `rtk init --global`. Verify bằng `rtk gain`.
2. **Caveman** — compress agent response: drop articles/filler/pleasantries.
   Set qua frontmatter `caveman: off|lite|full|ultra`. Reviewer dùng `full`,
   coder/tester dùng `lite`, orchestrator/source-summary `off` (cần format chuẩn).
   Override toàn pipeline qua `PAGENT_CAVEMAN=full`.

`pagent gain` để xem RTK savings, `pagent gain -w` live watch.

## Web dashboard

```bash
pagent web                          # http://127.0.0.1:8765
pagent web 8080 0.0.0.0             # bind ra LAN
```

4 panel: Live (đang chạy) · Agents (stats per agent) · History (features+bugs +
cost + duration) · Modal mỗi task (pipeline timeline DAG + report). Auto-refresh
3s, không dep ngoài stdlib Python.
