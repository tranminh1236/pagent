# Source Summary

**Project type:** bash-cli
**Language(s):** Bash (core), Python 3 (web dashboard), Markdown (agent/skill prompts)
**Entry point:** `pagent` (Bash script ~730 dòng)
**Test framework:** N/A (không có test framework — script CLI)
**Test command:** N/A
**Build command:** N/A (không cần build)
**Run command:** `pagent <subcommand>` — sau khi cài qua `install.sh`

## Cấu trúc thư mục
```
pipelineAgent/
├── pagent                  # CLI entry point chính — Bash orchestrator
├── install.sh              # Cài symlink vào ~/.local/bin + thêm PATH vào .zshrc
├── .env.pagent.example     # Template config per-project
└── kit/                    # Global kit — không sửa per-project
    ├── agents/             # Agent prompts (YAML frontmatter + Markdown body)
    │   ├── orchestrator.md # Lead agent kiêm Project Owner: phân tích task → JSON plan; điều phối QUA Leader Code
    │   ├── coder.md        # Sửa code thật trong $PAGENT_SOURCE; tuân CODE_RULES do Leader Code chưng
    │   ├── reviewer.md     # Leader Code — 2 pha: PHA 0 chưng CODE_RULES, PHA 1 cân đối verdict (read-only)
    │   ├── architecture.md # Auditor kiến trúc (layer/schema/redis key) — read-only, 2 pha, chạy SONG SONG
    │   ├── performance.md  # Auditor hiệu năng (hot path/tài nguyên/scale) — read-only, 2 pha, SONG SONG
    │   ├── security.md     # Auditor bảo mật (injection/authz/secret/PII) — read-only, 2 pha, SONG SONG
    │   ├── devops.md       # DevOps — sinh Dockerfile/compose (dev+deploy)/.gitlab-ci + chốt env .env.pagent; chạy SỚM (init/thiếu file hạ tầng)
    │   ├── docs.md         # Docs — cập nhật swagger/OpenAPI + admin config khi task thêm/sửa API; scope hẹp, chạy CUỐI (sau code merged)
    │   └── tester.md       # Sinh + chạy tests
    ├── skills/             # Skill prompts (dùng như agent, khác ở vai trò)
    │   ├── source-summary.md     # Sinh .pagent/source-summary.md
    │   ├── feature.md            # Flow chi tiết cho feature
    │   ├── hotfix.md             # Flow chi tiết cho hotfix
    │   └── workflow-extractor.md # Append vào workflow.md sau feature
    ├── hooks/
    │   ├── pre.sh          # Pre-prompt hook (chuẩn bị env)
    │   └── post.sh         # Post-prompt hook → ghi token/cost vào tokens/<date>.jsonl
    ├── web/
    │   ├── server.py       # Python stdlib HTTP server — web dashboard
    │   ├── index.html      # Dashboard UI
    │   ├── style.css
    │   └── app.js
    └── completions/
        └── _pagent         # Zsh completion script
```

## Convention
- **Naming:** hàm Bash dùng `snake_case` (`cmd_init`, `call_agent`); file agent/skill dùng `kebab-case` (`workflow-extractor.md`); biến môi trường `PAGENT_*` ALL_CAPS
- **Module boundary:** mỗi agent/skill là file Markdown độc lập — YAML frontmatter khai báo `allowed_tools`, `disallowed_tools`, `model`, `max_turns`; body là system prompt được inject qua `--append-system-prompt` / `--system-prompt` của `claude` CLI; project-local `.pagent/agents/` hoặc `.pagent/skills/` override global `kit/`

## Domain
`pagent` là CLI orchestrator dùng `claude` CLI (Anthropic) làm backend để tự động hoá vòng lặp phát triển phần mềm: nhận task text (`feature` / `fix`), chạy pipeline **orchestrator → (devops: init/thiếu file hạ tầng) → [PHA 0: architecture‖performance‖security audit baseline SONG SONG → Leader Code chưng CODE_RULES] → coder → [PHA 1: 3 auditor review diff SONG SONG → Leader Code cân đối verdict] (loop) → tester → (docs: task thêm/sửa API) → workflow-extractor**, lưu report Markdown và log token/cost theo ngày. `devops` chạy SỚM (sinh Dockerfile/compose dev+deploy, `.gitlab-ci.yml`, chốt env `.env.pagent`/`.env.pagent.example`); `docs` scope hẹp chạy CUỐI (cập nhật swagger/OpenAPI + admin config, KHÔNG sửa code sản phẩm). Tầng review gồm 3 auditor read-only chạy song song (mỗi cái 2 pha) do **Leader Code** (agent `reviewer`) tổng hợp; orchestrator điều phối QUA Leader Code, không gọi trực tiếp coder/auditor. Mục tiêu: giảm thao tác thủ công khi làm việc với Claude trên các codebase thực.

## Files quan trọng
- `pagent` — CLI chính: dispatch subcommand, `call_agent()` spawn claude CLI, PHA 0 baseline audit SONG SONG → CODE_RULES, vòng lặp coder↔(PHA 1 audit SONG SONG → Leader Code verdict), `write_report()`, token tracking. `ENABLED_AUDITORS` = auditor enabled theo `required_agents`; `eff_max_round` = ngân sách vòng review (override qua `reviewer.md` frontmatter `max_review_round`)
- `kit/agents/orchestrator.md` — agent đầu pipeline kiêm Project Owner: đọc `source-summary.md`, xuất JSON plan (`title`, `coder_task`, `reviewer_focus`, `audit_focus`, `business_context`, `required_agents` gồm `architecture`/`performance`/`security`/`reviewer`, `tester_task`, `risk`, `affected_paths`)
- `kit/hooks/post.sh` — ghi JSONL token+cost sau mỗi lần gọi agent (dùng cho `pagent report` và `pagent gain`)
- `kit/skills/source-summary.md` — skill được gọi bởi `pagent init` để sinh `.pagent/source-summary.md` cho project target
- `kit/web/server.py` — web dashboard đọc `~/.pagent-reports` phục vụ HTTP, viết bằng Python stdlib (không dependency)
- `.env.pagent.example` — template cấu hình per-project: model, report dir, max review round
