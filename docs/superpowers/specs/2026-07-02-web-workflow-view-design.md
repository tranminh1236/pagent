# Thiết kế: Workflow view + reuse trong pagent web

**Ngày:** 2026-07-02
**Trạng thái:** Đã duyệt design — chờ viết plan
**Nhánh:** `web-workflow-view` (tách từ `main`, độc lập với migration opencode)
**Phạm vi:** `kit/web/server.py`, `kit/web/index.html`, `kit/web/app.js`, `kit/web/style.css`, test

---

## 1. Mục tiêu

Bổ sung vào web dashboard (`pagent web`) một khu vực **hiển thị workflow của project** (đọc từ
`$PAGENT_REPORT_DIR/<project>/workflow.md`) để **xem** và **dùng lại**. "Dùng lại" = bấm 1 workflow
→ prefill ô chat composer để chạy một task mới tương tự (user chỉnh rồi Send).

Giá trị: workflow.md là nhật ký các feature đã build (Trigger/Flow/Smoke test/Related files). Hiện chỉ
xem được qua CLI (`pagent workflow show/list`). Đưa lên web giúp duyệt nhanh và tái sử dụng làm bàn đạp
cho task mới, ngay cạnh composer.

## 2. Quyết định đã chốt

| # | Vấn đề | Quyết định |
|---|--------|-----------|
| 1 | "Dùng lại" | **Prefill composer**: set mode + đổ text vào `#task-input` + focus. Không tự submit. |
| 2 | Nội dung prefill | **Gọn**: `Làm tương tự "<title>". Cụ thể: ` (1 dòng, con trỏ ở cuối). |
| 3 | Nhánh | Nhánh mới `web-workflow-view` từ `main`. |
| 4 | Phạm vi (YAGNI) | Chỉ **xem + reuse-prefill**. KHÔNG edit/xoá/tạo-trên-web, KHÔNG chạy smoke test từ web. |
| 5 | Nạp dữ liệu | Khi đổi project + khi bấm ↻ refresh (workflow hiếm đổi → không poll mỗi tick). |

## 3. Kiến trúc

Bám đúng pattern web hiện có (SPA: `server.py` phục vụ JSON + static; `app.js` fetch qua `j(url)`,
render vào section; `switchProject → refresh`).

```
workflow.md (đĩa) ──read_workflow──▶ JSON sections ──GET /api/projects/<proj>/workflow──▶
  app.js renderWorkflows ──▶ cards ──"Dùng lại"──▶ prefill #task-input + set mode + focus
  ──▶ (flow chat POST sẵn có) ──▶ pipeline
```

### 3.1 Backend — `kit/web/server.py`

**`read_workflow(proj)`** (hàm mới, thuần, testable):
- Resolve `f = _safe_join(proj, "workflow.md")` (dùng guard sẵn có; chặn path traversal).
- Nếu không tồn tại → `{"exists": False, "path": <str>, "workflows": []}`.
- Parse markdown thành list section, mỗi section bắt đầu bằng `## <title>`. Với mỗi section trích:
  - `title` (chuỗi sau `## `)
  - `trigger` (`**Trigger:**` → phần còn lại dòng)
  - `preconditions` (`**Preconditions:**`)
  - `flow` (list — các dòng dưới `**Flow:**` bắt đầu bằng số `N.`, tới field `**` kế tiếp)
  - `expected` (`**Expected outcome:**`)
  - `smoke_cmd` (`**Smoke test command:**` → nội dung trong backtick `` `...` ``)
  - `related` (`**Related files:**` → tách theo dấu phẩy → list, strip)
  - `added` (`**Added:**`)
  - Field khuyết → `""`/`[]` (bỏ qua mềm, không lỗi).
- Trả `{"exists": True, "path": <str>, "workflows": [ {…}, … ]}`. Thứ tự giữ như trong file.

**Route** trong `do_GET` (thêm vào tuple `with_proj`):
```python
(r"/workflow", lambda p: self._j(read_workflow(p))),
```
(dùng lại `_valid_proj`, `_j`, `_safe_error`.)

### 3.2 Frontend

**`index.html`** — thêm 1 `<section id="workflow-section">` trong `<main>` (đặt sau `chat-section`,
trước `live-section` — gần composer để reuse tiện):
```html
<section id="workflow-section">
  <div class="section-head">
    <h2>Workflows <small class="dim" id="workflow-count"></small></h2>
  </div>
  <div id="workflow-list"></div>
</section>
```

**`app.js`**:
- `async function loadWorkflows(proj)`: `const data = await j('/api/projects/<proj>/workflow')` →
  `renderWorkflows(data)`. Gọi trong `switchProject` và khi bấm `#refresh-btn` (KHÔNG trong vòng
  auto-`refresh()` để tránh re-render/mất trạng thái expand mỗi 3s).
- `function renderWorkflows(data)`:
  - `data.exists === false || workflows rỗng` → `#workflow-list` hiện "Chưa có workflow — chạy 1
    feature để sinh." (dùng class `idle-msg` sẵn có). `#workflow-count` = "".
  - Ngược lại: render mỗi workflow 1 `.wf-card`: header (title + `added`), Trigger, Flow (thu gọn,
    nút bung), Smoke command (mono), Related files. Nút **"Dùng lại ↑"** (`.wf-reuse`, `data-title`).
    Mọi text render qua `esc()`.
  - `#workflow-count` = số workflow.
- `function reuseWorkflow(title)`:
  1. Set mode = `feature`: kích hoạt `.mode-opt[data-mode="feature"]` (dùng lại logic set mode sẵn có).
  2. `#task-input`.value = `Làm tương tự "${title}". Cụ thể: `; dispatch `input` event (để `#send-btn`
     enable + auto-resize như khi gõ tay).
  3. `#task-input`.focus(); đặt con trỏ cuối; `scrollIntoView` composer.
  - Gắn qua event delegation trên `#workflow-list` (click `.wf-reuse` → `reuseWorkflow(dataset.title)`);
    flow (thu gọn) toggle qua click header/nút bung.

**`style.css`** — thêm `.wf-card`, `.wf-reuse`, `.wf-flow`(collapsible), `.wf-smoke`(mono) bám tông
màu/spacing sẵn có (biến CSS/section hiện dùng).

## 4. Data flow & error handling

- Không có workflow.md → section vẫn hiện, báo trạng thái rỗng (không lỗi HTTP).
- workflow.md malformed / section khuyết field → parse mềm, field trống, không vỡ trang.
- Project không hợp lệ → `_valid_proj` trả 400 (như các route khác).
- Path traversal → `_safe_join` chặn (như `task_detail`).
- `read_workflow` không chạy lệnh gì (chỉ đọc + parse) → không rủi ro thực thi. `smoke_cmd` chỉ để
  **hiển thị** (web không chạy).

## 5. Testing

- **Unit python** (`tests/test_web_workflow.py`, style `test_server_chat_upload.py` — `unittest`):
  - `read_workflow` với workflow.md mẫu (≥2 section, có/thiếu field) → assert: đúng số section,
    `title`/`trigger`/`added` đúng, `flow` là list các bước, `smoke_cmd` trích trong backtick,
    `related` là list tách phẩy.
  - `read_workflow` khi file không tồn tại → `exists=False, workflows=[]`.
  - (Tuỳ chọn) path traversal proj name → chặn.
- Frontend: kiểm thủ công qua `pagent web` (render card + reuse prefill). Không thêm test JS
  (repo chưa có harness JS).

## 6. Ngoài phạm vi

- Không sửa/xoá/tạo workflow trên web (CLI `pagent workflow new` lo).
- Không chạy Smoke test command từ web.
- Không đụng backend pipeline/agent (độc lập migration opencode).
- Không phân trang/tìm kiếm workflow (YAGNI — số section nhỏ; thêm sau nếu cần).
