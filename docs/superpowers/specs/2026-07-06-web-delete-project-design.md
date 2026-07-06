# Web dashboard — xóa (soft-delete) project

**Ngày:** 2026-07-06
**Trạng thái:** approved

## Mục tiêu

Cho phép xóa một project khỏi pagent web dashboard để dọn các project làm tạm, sau này
không còn dùng nữa. Chỉ đụng thư mục reports `~/.pagent-reports/<project>/` — **KHÔNG bao
giờ** đụng source code thật của project.

## Quyết định thiết kế (đã chốt)

- **Soft-delete**, không xóa vật lý: `mv` project vào `~/.pagent-reports/.trash/<project>-<UTC-ts>/`.
  Dashboard tự ẩn vì `list_projects()` bỏ mọi dir bắt đầu bằng `.` (giống `.opencode` đã có).
  Muốn sạch đĩa hẳn → user xóa `.trash/` bằng tay. Đổi được ý / khôi phục lỡ tay.
- **Type-to-confirm**: modal bắt gõ lại chính xác tên project mới cho xóa (thao tác irreversible
  ở góc nhìn UI).
- **Chặn khi đang chạy**: project có run live (`live_tasks(proj)` không rỗng) → từ chối (HTTP 409).

## Backend — `kit/web/server.py`

Route mới, theo đúng pattern mutation sẵn có (cancel/retry/resume/settings):

```
POST /api/projects/<proj>/delete
```

Trong `do_POST`, sau khi `_valid_proj(proj)`:
- `if live_tasks(proj):` → `_j({"error": "project đang có run chạy — dừng trước khi xoá"}, 409)`.
- `_delete_project(proj)`:
  1. `src = _safe_join(REPORTS, proj)` — None → 400.
  2. `dest = _safe_join(REPORTS, ".trash", f"{proj}-{UTC-ts}")` — None → 400. Tạo `.trash/` nếu thiếu.
  3. `shutil.move(src, dest)`.
  4. Trả `{"ok": True, "trashed_to": dest}`.

Path-safety: `proj` đã qua `_valid_proj` (regex `[A-Za-z0-9_.-]+` + phải nằm trong `list_projects()`),
cả `src` lẫn `dest` verify `_within_reports`. Không thể traversal ra ngoài REPORTS.

## Frontend — `kit/web/index.html` + `kit/web/app.js`

- Nút 🗑 cạnh `<select id="project">`.
- Modal riêng `#delete-modal`: hiện tên project + ô input + nút "Xoá vĩnh viễn" **disabled** đến
  khi input trùng chính xác tên project hiện tại. Esc / click nền / nút Huỷ → đóng.
- Xác nhận → `fetch(POST /api/projects/<proj>/delete)`:
  - OK → đóng modal, `loadProjects()`, switch sang project còn lại đầu tiên (hoặc empty state).
  - 409 → hiện lỗi trong modal ("project đang chạy, không xoá được"), không đóng.

## Test — `tests/`

Test Python cho `_delete_project` + guard (chạy server.py như module):
1. Move đúng vào `.trash/`, project biến khỏi `list_projects()`, `.trash` không lọt vào list.
2. Guard: có live task → 409, thư mục project vẫn nguyên.
3. Path-safety: tên project bẩn (`../`, không nằm trong list) → từ chối, không move gì.

## Ngoài phạm vi

Source code thật của project; các mode/pipeline của pagent; khôi phục từ `.trash` qua UI
(làm tay). Không thêm cron dọn `.trash` tự động (YAGNI).
