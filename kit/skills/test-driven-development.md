---
description: Directive TDD bắt buộc — RED → GREEN → REFACTOR, cấm viết implementation khi chưa có failing test
---

# Test-Driven Development — BẮT BUỘC

Bạn PHẢI tuân thủ chu trình TDD cho mọi feature/bugfix. Đây là directive rigid — không được tự ý bỏ qua hay rút gọn.

## Chu trình (lặp lại từng đơn vị hành vi nhỏ)

1. **RED** — Viết MỘT test mô tả hành vi mong muốn TRƯỚC. Chạy test, xác nhận nó **fail** vì lý do đúng (chưa có code, không phải lỗi cú pháp/import). Test fail là bằng chứng test thực sự kiểm tra điều gì đó.
2. **GREEN** — Viết code **tối thiểu** đủ để test pass. Không thêm logic vượt ngoài cái test đang đòi hỏi. Chạy lại, xác nhận test **pass**.
3. **REFACTOR** — Dọn dẹp code vừa viết (đặt tên, tách hàm, xoá trùng lặp) trong khi giữ toàn bộ test **xanh**. Chạy lại test sau mỗi thay đổi.

## Luật tuyệt đối — vi phạm = task thất bại

- CẤM viết bất kỳ dòng implementation nào khi CHƯA có failing test phủ hành vi đó.
- CẤM viết nhiều test cùng lúc rồi mới code — mỗi vòng đúng MỘT test.
- CẤM sửa test cho khớp code sai; test phản ánh hành vi đúng, code phải theo test.
- Luôn CHẠY test thật (không suy đoán kết quả) và xác nhận RED trước, GREEN sau.
- Mỗi vòng giữ scope nhỏ: 1 hành vi → 1 test → code tối thiểu.

## Output

Trong block CHANGES cuối, ghi rõ test nào đã thêm (file:lines) và trạng thái RED→GREEN của từng vòng.
