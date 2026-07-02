# Workflow Log — demo

## Thêm tính năng A

**Trigger:** Khi user làm X trong pipeline.
**Preconditions:** File `foo.md` tồn tại; gate bật.
**Flow:**
1. Bước một đọc input.
2. Bước hai xử lý.
3. Bước ba xuất kết quả.
**Expected outcome:** Kết quả đúng; 10/10 test pass.
**Smoke test command:** `bash tests/test_a.sh`
**Related files:** kit/foo.md, pagent, tests/test_a.sh
**Added:** 2026-06-01

## Sửa bug B

**Trigger:** Hotfix mode.
**Flow:**
1. Chỉ một bước.
**Expected outcome:** Bug hết.
**Smoke test command:** `echo ok`
**Related files:** bar.sh
**Added:** 2026-06-02
