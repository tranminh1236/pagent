---
name: feature
description: Build feature mới — orchestrator → coder → reviewer → tester → workflow update
flow: [orchestrator, coder, reviewer, tester, workflow]
report_dir: features
---

# Skill: Feature

Workflow đầy đủ cho feature mới:

1. **orchestrator** — lập plan JSON.
2. **coder** — implement, output CHANGES block.
3. **reviewer** — đọc diff, output VERDICT. Nếu CHANGES_REQUESTED → loop lại coder (tối đa 2 lần).
4. **tester** — viết test + run.
5. **workflow** — extractor đọc test mới, cập nhật `workflow.md`.

Report ghi vào `reports/<project>/features/<date>-<promptid>.md`.
