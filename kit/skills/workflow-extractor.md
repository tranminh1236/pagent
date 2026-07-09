---
name: workflow-extractor
description: Chưng cất lịch sử task + bugfix + prompt tích luỹ của project thành 1 spec điều phối AI agent (framework-agnostic) tái sử dụng, refresh vào agent-workflow.md
allowed_tools: Read,Write,Edit,Grep,Glob
---

# Skill: Agent Orchestration Workflow Extractor

Bạn được gọi SAU khi feature đã pass review + test. Nhiệm vụ của bạn KHÔNG phải
sinh runbook smoke-test nghiệp vụ. Bạn chưng cất toàn bộ lịch sử phát triển của
project thành MỘT spec điều phối AI agent — pseudo-spec **framework-agnostic**,
lấy triết lý chung từ Temporal / LangGraph / CrewAI / Google ADK / Microsoft
AutoGen / OpenAI Swarm nhưng KHÔNG bám cú pháp riêng của framework nào.

## Input bạn nhận
Các section (đặt tên khớp tuyệt đối với khối gọi trong `pagent`):
- `## FEATURE_TITLE` — title feature vừa hoàn thành
- `## TASK` — task gốc của lần chạy hiện tại
- `## CODER_CHANGES` — CHANGES từ coder (file + mô tả)
- `## TESTS_ADDED` — TESTS_ADDED từ tester
- `## REPORT_HISTORY` — nội dung quét từ `features/*.md` + `bugs/*.md` (lịch sử
  task đã làm và bug đã fix); có thể dài, dùng để rút ra pattern lặp lại
- `## PROJECT_PROMPT` — prompt/context tích luỹ của project (nếu có nguồn)
- `## EXISTING_WORKFLOW_PATH` — đường dẫn file đích `agent-workflow.md`. Nếu file
  đã tồn tại → ĐỌC nó, refresh/merge, tránh trùng lặp (đây là tài liệu SỐNG,
  không append vô hạn từng feature).

## Mục tiêu
Chưng cất lịch sử (task + bugfix + prompt) thành **1 spec điều phối agent duy
nhất, framework-agnostic**, mô tả cách một hệ multi-agent nên phối hợp để xử lý
loại công việc mà project này lặp đi lặp lại. Đây KHÔNG phải runbook smoke-test.
Mỗi lần chạy: đọc spec cũ (nếu có) + input mới → sinh lại/hoàn thiện spec, hợp
nhất pattern mới, loại bỏ trùng lặp. Giữ spec gọn, mạch lạc, sống được.

## Format (pseudo-spec — KHÔNG bám cú pháp 1 framework)
Ghi vào `agent-workflow.md` với các khối theo đúng thứ tự sau:

```markdown
# Agent Orchestration Workflow — <project>

_Chưng cất từ lịch sử task/bugfix. Refresh: YYYY-MM-DD._

## Overview
<1–3 câu: hệ agent này điều phối loại công việc gì, mục tiêu chung>

## Agents / Roles
- **<role>** — trách nhiệm: <...>; tools/quyền: <...>
- ...

## State / Context
- **<field>** — <shared state truyền giữa các bước, ai đọc/ghi>
- ...

## Nodes / Steps
- **<node id>** — <đơn vị công việc, agent đảm nhận, input/output>
- ...

## Edges / Handoffs
- **<from> → <to>** — điều kiện kích hoạt: <...>; dữ liệu chuyển giao: <...>
- ...

## Decision branches
- **<điểm rẽ>** — nếu <điều kiện> → <nhánh A>; ngược lại → <nhánh B>
- ...

## Triggers
- <điều kiện/sự kiện khởi động workflow>
- ...

## Termination / Retry
- **Termination:** <điều kiện dừng thành công / thất bại>
- **Retry / Compensation:** <chính sách retry, backoff, bù trừ kiểu Temporal
  (compensating action khi 1 bước fail)>

## Graph
​```
<sơ đồ ASCII graph tổng thể: node + edge + nhánh>
​```
```

Quy tắc:
- Framework-agnostic: mô tả bằng khái niệm chung (role, state, node, edge,
  handoff, trigger, retry/compensation), KHÔNG viết code hay cú pháp của
  Temporal/LangGraph/CrewAI/ADK/AutoGen/Swarm cụ thể.
- Spec là tài liệu SỐNG: refresh & merge, không nối thêm 1 section/feature.
- Rút pattern từ `REPORT_HISTORY` (task lặp, loại bug hay gặp) để định hình
  role/node/branch, không chỉ dựa lần chạy hiện tại.

## Ghi kết quả
Dùng Write/Edit ghi thẳng vào đường dẫn ở `## EXISTING_WORKFLOW_PATH`
(`agent-workflow.md`). KHÔNG động vào `workflow.md`. KHÔNG in spec ra response —
chỉ in 1 dòng confirm: `Updated agent-workflow.md`.
