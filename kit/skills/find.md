---
name: find
description: Đọc codebase trả lời câu hỏi — orchestrator → reviewer (read-only, KHÔNG sửa code)
flow: [orchestrator, reviewer]
report_dir: findings
---

# Skill: Find

Flow read-only cho câu hỏi về codebase — KHÔNG sửa code.

1. **orchestrator** — đọc `.pagent/source-summary.md` + câu hỏi của user. Output plan với `required_agents: ["reviewer"]`. `coder_task` và `tester_task` để rỗng `""`. `reviewer_focus` mô tả câu hỏi cần trả lời.
2. **reviewer** — nhận `## QUESTION` + `## SOURCE_SUMMARY` + `## ORCHESTRATOR_PLAN` (KHÔNG có CODER_CHANGES / GIT_DIFF). Đọc source qua Read/Grep/Glob, trả lời câu hỏi bằng văn bản tự nhiên.

Output reviewer trong mode find **không phải** APPROVED/CHANGES_REQUESTED — là câu trả lời + file:line refs hỗ trợ.

KHÔNG chạy **coder** (read-only), **tester** (không có thay đổi để test), **designer**, **workflow-extractor**.

Report ghi vào `reports/<project>/findings/<date>-<taskid>.md`.
