---
name: chore
description: Chore — refactor / bổ sung logic nhỏ: orchestrator → coder → reviewer
flow: [orchestrator, coder, reviewer]
report_dir: chores
---

# Skill: Chore

Flow gọn cho task chore — refactor, dọn dẹp, bổ sung logic nhỏ không cần workflow nghiệp vụ mới:

1. **orchestrator** — đọc `.pagent/source-summary.md`, ra plan ngắn 2–4 bước. `required_agents` mặc định `["coder","reviewer"]`; thêm `tester` nếu plan yêu cầu test mới.
2. **coder** — thực hiện thay đổi tối thiểu trong `$PAGENT_SOURCE`, xuất CHANGES block.
3. **reviewer** — verify thay đổi không vỡ flow khác (read-only, APPROVED / CHANGES_REQUESTED, loop tối đa N vòng).
4. **tester** — chỉ chạy khi orchestrator đưa `tester` vào `required_agents`.

KHÔNG chạy **designer** (không phải UI feature) và KHÔNG chạy **workflow-extractor** (chore không thêm workflow nghiệp vụ).

Report ghi vào `reports/<project>/chores/<date>-<taskid>.md`.
