---
name: hotfix
description: Fix bug nhanh — orchestrator → coder → reviewer → tester regression
flow: [orchestrator, coder, reviewer, tester]
report_dir: bugs
---

# Skill: Hotfix

Bug fix flow:

1. **orchestrator** — analyze bug, hypothesis root cause.
2. **coder** — fix tối thiểu.
3. **reviewer** — verify fix không vỡ flow khác.
4. **tester** — viết 1 test regression repro bug trước fix → pass sau fix.

Skip workflow extraction (hotfix không thay đổi workflow nghiệp vụ).

Report ghi vào `reports/<project>/bugs/<date>-<promptid>.md`.
