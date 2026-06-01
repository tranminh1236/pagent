---
name: hotfix
description: Fix bug nhanh — orchestrator → coder → reviewer → tester regression
flow: [orchestrator, coder, reviewer, tester]
report_dir: bugs
---

# Skill: Hotfix

Bug fix flow:

1. **orchestrator** — analyze bug, hypothesis root cause → plan JSON.
2. **coder** — fix tối thiểu.
3. **reviewer** — verify fix không vỡ flow khác; ngoài verdict, xuất khối
   `ROOT_CAUSE_ANALYSIS` (cause + suspect `file:line` + confidence).
4. **tester** — viết 1 test regression repro bug trước fix → pass sau fix.
5. **orchestrator (tổng hợp)** — chạy lại với `REVIEWER_OUTPUT` + `TESTER_OUTPUT`,
   hợp nhất root cause của reviewer với kết quả test thành 1 field
   `root_cause_summary` trong JSON output (nguyên nhân cuối đã xác nhận qua review+test).

Thứ tự xác nhận root cause: **reviewer phân tích → tester verify → orchestrator tổng hợp**.

Skip workflow extraction (hotfix không thay đổi workflow nghiệp vụ).

Report ghi vào `reports/<project>/bugs/<date>-<promptid>.md`.
