---
name: decision-log
description: Chưng cất 1 quyết định thiết kế của lần chạy hiện tại thành MỘT mục ADR ngắn (ngày, context, quyết định, hệ quả, ref bug/PR) rồi APPEND vào cuối .pagent/knowledge/decisions.md. Append-only — chỉ thêm mục mới, KHÔNG sửa/xoá mục cũ.
allowed_tools: Read,Write
---

# Skill: Decision Log (ADR) Writer

Bạn ghi lại **một quyết định thiết kế** vừa được đưa ra trong lần chạy hiện tại
thành một mục **ADR ngắn** (Architecture Decision Record) và **APPEND** vào cuối
`.pagent/knowledge/decisions.md`. Đây là **nhật ký bất biến (immutable log)**: mỗi
lần chạy chỉ **thêm đúng MỘT mục mới ở cuối file**, TUYỆT ĐỐI KHÔNG sửa, gộp,
sắp xếp lại hay xoá bất kỳ mục cũ nào. Đây KHÔNG phải tài liệu sống merge-idempotent
như `domain.md` / `workflow.md` — đối lập hẳn: chỉ nối thêm, giữ nguyên lịch sử.

## Input bạn nhận
Các section `## <TITLE>` đọc từ stdin (đặt tên khớp tuyệt đối với khối gọi trong
`pagent`). Section chứa **đường dẫn** → dùng `Read` để nạp nội dung; section chứa
**nội dung inline** → dùng trực tiếp:
- `## DECISION_DATE` — ngày quyết định dạng `YYYY-MM-DD` (do `pagent` truyền vào).
  Nếu thiếu/rỗng → ghi `unknown` ở trường ngày, KHÔNG bịa ngày.
- `## DECISION_TITLE` — tiêu đề ngắn của quyết định (hoặc feature/hotfix title).
- `## TASK` — task gốc của lần chạy hiện tại (nguồn để rút *context*).
- `## RATIONALE` — lý do/thiết kế (thường từ CHANGES/RATIONALE của coder) → nguồn
  cho *quyết định* và *hệ quả*.
- `## REF` — tham chiếu bug/PR/report/commit (vd `bugs/2026-07-02-xxx.md`, `#123`).
  Nếu thiếu → ghi `—`.
- `## EXISTING_DECISIONS_PATH` — đường dẫn file đích `.pagent/knowledge/decisions.md`.
  Nếu file đã tồn tại → ĐỌC toàn bộ để **giữ nguyên văn** rồi nối mục mới vào cuối.
  Nếu chưa tồn tại → tạo mới kèm heading tiêu đề file.

## Mục tiêu
Từ input trên, chưng cất thành **MỘT** mục ADR ngắn gọn (không lan man) gồm đủ:
ngày, context (vì sao cần quyết định), quyết định (chọn gì), hệ quả (đánh đổi /
ảnh hưởng về sau), và ref. Rồi **append** vào cuối `decisions.md`, sau tất cả mục
đã có, không đụng phần cũ.

## Format đích (`.pagent/knowledge/decisions.md`)
Khi file CHƯA tồn tại, tạo với heading tiêu đề rồi mục đầu tiên. Khi ĐÃ tồn tại,
giữ nguyên toàn bộ nội dung cũ và chỉ nối thêm đúng khối `## ADR ...` mới ở cuối.

Heading tiêu đề file (chỉ ghi 1 lần khi tạo mới):

```markdown
# Decision Log — <project>

_Nhật ký quyết định thiết kế (ADR). Append-only: mục mới nối ở cuối, mục cũ bất biến._
```

Mỗi mục ADR (khối được append):

```markdown

## ADR <YYYY-MM-DD> — <tiêu đề quyết định>

- **Context:** <bối cảnh/vấn đề khiến phải ra quyết định, 1–3 câu>
- **Decision:** <quyết định đã chọn + phương án bị loại nếu có, 1–3 câu>
- **Consequences:** <hệ quả/đánh đổi/ảnh hưởng về sau, 1–2 câu>
- **Ref:** <bug/PR/report/commit liên quan, hoặc —>
```

## Quy tắc
- **Append-only, bất biến:** chỉ thêm đúng MỘT mục ở cuối file mỗi lần chạy. KHÔNG
  sửa nội dung mục cũ, KHÔNG sắp xếp lại, KHÔNG xoá, KHÔNG gộp/dedupe. Cho phép
  trùng chủ đề với mục cũ — lịch sử phản ánh diễn tiến, không cô đọng.
- **Giữ nguyên văn phần cũ:** nếu file đã tồn tại, nội dung cũ phải xuất hiện lại
  y hệt (byte-for-byte) trong lần ghi; chỉ khác ở khối mới nối thêm cuối file.
- Mỗi mục **ngắn gọn**: rút gọn từ input, không copy nguyên văn TASK/RATIONALE dài;
  không thêm heading cấp cao khác ngoài `## ADR ...`.
- **Thiếu input vẫn ghi mục:** thiếu ngày → `unknown`; thiếu ref → `—`; thiếu
  context/hệ quả → ghi `_(chưa rõ)_`. KHÔNG bỏ trống toàn mục, KHÔNG báo lỗi rồi dừng.
- `<project>` suy từ nội dung/đường dẫn nếu có; không suy được để `project`.

## Ghi kết quả
Dùng `Read` nạp nội dung cũ (nếu file tồn tại) rồi dùng `Write` ghi lại **toàn bộ
nội dung cũ (nguyên văn) + khối ADR mới ở cuối** vào đúng đường dẫn ở
`## EXISTING_DECISIONS_PATH` (`.pagent/knowledge/decisions.md`). Nếu file chưa tồn
tại, `Write` heading tiêu đề + mục ADR đầu tiên. **KHÔNG đụng bất kỳ file nào khác**
(TASK, RATIONALE, report, các knowledge khác đều read-only). KHÔNG in nội dung ra
response — chỉ in 1 dòng confirm: `Appended ADR to .pagent/knowledge/decisions.md`.
