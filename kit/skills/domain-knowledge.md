---
name: domain-knowledge
description: Đọc source-summary.md + report cũ → sinh/refresh .pagent/knowledge/domain.md mô tả tri thức MIỀN (khái niệm, business rule, thuật ngữ, ràng buộc) phục vụ Planner. Merge idempotent, không nhân đôi mục, không append vô hạn.
allowed_tools: Read,Glob,Grep,Write
---

# Skill: Domain Knowledge Builder

Bạn chưng cất **tri thức miền (domain knowledge)** của project target thành MỘT
tài liệu phục vụ **Planner**: trước khi lập plan nó cần hiểu *ngôn ngữ nghiệp vụ*
— **khái niệm miền, business rule, thuật ngữ, ràng buộc** — chứ không chỉ luồng
gọi hàm. Đây KHÔNG phải bản đồ codebase (đó là `source-summary.md`), KHÔNG phải
luồng end-to-end (đó là `workflow.md`); bạn tập trung vào *ý nghĩa nghiệp vụ*.

Nguồn tri thức của bạn:
- `source-summary.md` — bản đồ codebase target (project type, cấu trúc, domain,
  file quan trọng). Rút khái niệm & thuật ngữ từ tên entity/module/bảng DB.
- report cũ (`features/*.md` + `bugs/*.md`) — lịch sử task & bug, nơi business
  rule và ràng buộc thật sự lộ ra (yêu cầu, edge case, invariant đã fix).

## Input bạn nhận
Các section `## <TITLE>` đọc từ stdin (đặt tên khớp tuyệt đối với khối gọi trong
`pagent`). Section chứa **đường dẫn** → dùng `Read` để nạp nội dung; section chứa
**nội dung inline** → dùng trực tiếp:
- `## SOURCE_SUMMARY_PATH` — đường dẫn `.pagent/source-summary.md`. Read-only.
- `## REPORT_HISTORY` — nội dung (hoặc thư mục) report cũ. Read-only. Có thể dài,
  dùng để rút business rule / ràng buộc lặp lại, KHÔNG copy nguyên văn.
- `## EXISTING_KNOWLEDGE_PATH` — đường dẫn file đích `.pagent/knowledge/domain.md`.
  Nếu file đã tồn tại → ĐỌC nó, **refresh/merge** (đây là tài liệu SỐNG, KHÔNG
  append vô hạn từng lần chạy).

## Mục tiêu
Tổng hợp các nguồn trên → **1 tài liệu domain knowledge duy nhất**: khái niệm
miền và quan hệ giữa chúng, business rule (điều gì được/không được phép), thuật
ngữ (từ điển nghiệp vụ), và ràng buộc/invariant. Mỗi lần chạy: đọc bản cũ (nếu
có) + input mới → sinh lại/hoàn thiện, hợp nhất mục mới, **loại bỏ trùng lặp**.
Giữ tài liệu gọn, mạch lạc, sống được.

## Format đích (ghi vào `.pagent/knowledge/domain.md`)
Ghi theo đúng thứ tự khối sau:

```markdown
# Domain Knowledge — <project>

_Nguồn: source-summary.md + report history. Refresh: YYYY-MM-DD._

## Overview
<1–3 câu: miền nghiệp vụ của hệ thống này là gì, phục vụ ai, giải quyết vấn đề gì>

## Concepts / Entities
- **<khái niệm/entity>** — <định nghĩa nghiệp vụ ngắn>; quan hệ: <với khái niệm khác>
- ...

## Business Rules
- **<mã/tên rule>** — <điều được phép / không được phép / phải xảy ra khi nào>
- ...

## Glossary
- **<thuật ngữ>** — <giải nghĩa 1 dòng, cách hệ thống hiểu từ này>
- ...

## Constraints / Invariants
- **<ràng buộc>** — <điều luôn phải đúng: unique, không âm, thứ tự trạng thái...>
- ...

## Open questions / Gaps
- <điểm chưa suy ra được từ input — để Planner biết cần điều tra thêm>
- ...
```

## Quy tắc
- Góc nhìn **cho Planner**: ưu tiên *ý nghĩa nghiệp vụ* (khái niệm, rule, thuật
  ngữ, ràng buộc), KHÔNG chép lại cấu trúc thư mục từ `source-summary.md` hay
  luồng gọi hàm — chỉ chưng cất tri thức miền mà chúng ngụ ý.
- Tài liệu SỐNG: **refresh & merge idempotent**, không nối thêm 1 section/lần
  chạy. Nếu file đích đã có, hợp nhất mục mới vào mục cũ theo tên/định danh; mục
  trùng thì gộp (giữ bản đầy đủ hơn), KHÔNG tạo mục thứ hai cùng khái niệm.
- Rút rule & ràng buộc từ report history (task lặp, bug hay gặp) + source-summary,
  không chỉ từ 1 lần chạy.
- **Thiếu input vẫn phải tạo file**: nếu thiếu/rỗng bất kỳ nguồn nào (chưa có
  report, source-summary trống...), VẪN ghi file đích với đầy đủ khung heading ở
  trên; các mục chưa suy ra được để trống có ghi chú ngắn (vd
  `_(chưa có dữ liệu — chờ input)_`) và liệt kê phần còn thiếu ở **Open questions
  / Gaps**. KHÔNG bỏ trống toàn bộ file, KHÔNG báo lỗi rồi dừng.

## Ghi kết quả
Dùng `Write` ghi thẳng vào đường dẫn ở `## EXISTING_KNOWLEDGE_PATH`
(`.pagent/knowledge/domain.md`), ghi đè toàn bộ bằng nội dung đã merge (idempotent —
KHÔNG append). **KHÔNG đụng bất kỳ file nào khác** (source-summary, report,
workflow.md đều read-only). KHÔNG in tài liệu ra response — chỉ in 1 dòng confirm:
`Updated .pagent/knowledge/domain.md`.
