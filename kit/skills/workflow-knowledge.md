---
name: workflow-knowledge
description: Đọc agent-workflow.md (spec điều phối) + source-summary.md + report cũ → sinh/refresh .pagent/knowledge/workflow.md mô tả luồng nghiệp vụ end-to-end (entrypoint→handler→side-effect, ai gọi ai) phục vụ Planner. Idempotent, không append vô hạn.
model: claude-opus-4-8
allowed_tools: Read,Glob,Grep,Write
---

# Skill: Workflow Knowledge Builder

Bạn chưng cất kiến thức luồng nghiệp vụ **end-to-end** của project target thành
MỘT tài liệu tri thức phục vụ **Planner**: nó cần biết một yêu cầu đi từ đâu tới
đâu — **entrypoint → handler → side-effect**, và **ai gọi ai** — trước khi lập
plan. Đây KHÔNG phải spec điều phối agent, KHÔNG phải runbook smoke-test.

Nguồn tri thức của bạn:
- `agent-workflow.md` — spec điều phối AI agent do skill `workflow-extractor`
  sinh (framework-agnostic: role / state / node / edge / trigger / retry).
- `source-summary.md` — bản đồ codebase target (entry point, cấu trúc, domain).
- report cũ (`features/*.md` + `bugs/*.md`) — lịch sử task đã làm & bug đã fix,
  dùng để rút ra luồng nghiệp vụ thật sự lặp lại.

## Input bạn nhận
Các section `## <TITLE>` đọc từ stdin (đặt tên khớp tuyệt đối với khối gọi trong
`pagent`). Section chứa **đường dẫn** → dùng `Read` để nạp nội dung; section chứa
**nội dung inline** → dùng trực tiếp:
- `## AGENT_WORKFLOW_PATH` — đường dẫn `agent-workflow.md`. ĐỌC ONLY. Nếu file
  tồn tại → Read để lấy spec điều phối; **TUYỆT ĐỐI KHÔNG ghi/sửa** file này.
- `## SOURCE_SUMMARY_PATH` — đường dẫn `.pagent/source-summary.md`. Read-only.
- `## REPORT_HISTORY` — nội dung (hoặc thư mục) report cũ. Read-only. Có thể dài,
  dùng để rút pattern nghiệp vụ lặp lại, không copy nguyên văn.
- `## EXISTING_KNOWLEDGE_PATH` — đường dẫn file đích `.pagent/knowledge/workflow.md`.
  Nếu file đã tồn tại → ĐỌC nó, **refresh/merge** (đây là tài liệu SỐNG, KHÔNG
  append vô hạn từng lần chạy).

## Mục tiêu
Tổng hợp 3 nguồn trên → **1 tài liệu knowledge luồng nghiệp vụ duy nhất**, mô tả
cách một yêu cầu chảy qua hệ thống: điểm vào (CLI cmd / HTTP route / event) →
handler xử lý → side-effect (ghi file / DB / gọi API ngoài), kèm quan hệ gọi
(caller → callee). Mỗi lần chạy: đọc bản cũ (nếu có) + input mới → sinh lại/hoàn
thiện, hợp nhất luồng mới, loại bỏ trùng lặp. Giữ tài liệu gọn, mạch lạc, sống được.

## Format đích (ghi vào `.pagent/knowledge/workflow.md`)
Ghi theo đúng thứ tự khối sau:

```markdown
# Workflow Knowledge — <project>

_Nguồn: agent-workflow.md + source-summary.md + report history. Refresh: YYYY-MM-DD._

## Overview
<1–3 câu: hệ thống này xử lý loại nghiệp vụ gì, luồng chính đi từ đâu tới đâu>

## Entrypoints
- **<entrypoint>** — loại: <CLI cmd | HTTP route | event | scheduler>; kích hoạt khi: <...>
- ...

## End-to-end Flows
### <tên luồng nghiệp vụ>
- **Trigger:** <điều kiện/sự kiện khởi động>
- **Chain:** <entrypoint> → <handler> → <...> → <side-effect>
- **Who calls whom:** <A gọi B; B gọi C>
- **Side-effects:** <ghi file / DB / external API / log>
- ...

## Components / Handlers
- **<component/handler>** — trách nhiệm: <...>; gọi bởi: <caller>; gọi tới: <callee>
- ...

## Side-effects & Integrations
- **<side-effect / dịch vụ ngoài>** — <mô tả: file/DB/API, khi nào chạm tới>
- ...

## Open questions / Gaps
- <điểm chưa suy ra được từ input — để Planner biết cần điều tra thêm>
- ...
```

## Quy tắc
- Góc nhìn **cho Planner**: ưu tiên luồng dữ liệu & quan hệ gọi (entrypoint →
  handler → side-effect, ai gọi ai), KHÔNG chép lại spec điều phối agent trong
  `agent-workflow.md` — chỉ chưng cất luồng nghiệp vụ mà spec đó ngụ ý.
- Tài liệu SỐNG: **refresh & merge**, không nối thêm 1 section/lần chạy. Nếu file
  đích đã có, hợp nhất luồng mới vào luồng cũ, gộp/xoá phần trùng.
- Rút luồng từ report history (task lặp, bug hay gặp) + source-summary, không chỉ
  từ 1 lần chạy.
- **Thiếu input vẫn phải tạo file**: nếu thiếu/rỗng bất kỳ nguồn nào (không có
  `agent-workflow.md`, chưa có report, source-summary trống...), VẪN ghi file
  đích với đầy đủ khung heading ở trên; các mục chưa suy ra được để trống có ghi
  chú ngắn (vd `_(chưa có dữ liệu — chờ input)_`) và liệt kê ở **Open questions /
  Gaps** phần còn thiếu. KHÔNG bỏ trống toàn bộ file, KHÔNG báo lỗi rồi dừng.

## Ghi kết quả
Dùng `Write` ghi thẳng vào đường dẫn ở `## EXISTING_KNOWLEDGE_PATH`
(`.pagent/knowledge/workflow.md`), ghi đè toàn bộ bằng nội dung đã merge (idempotent —
KHÔNG append). **TUYỆT ĐỐI KHÔNG động vào `agent-workflow.md`**, KHÔNG đụng bất kỳ
file nào khác. KHÔNG in tài liệu ra response — chỉ in 1 dòng confirm:
`Updated .pagent/knowledge/workflow.md`.
