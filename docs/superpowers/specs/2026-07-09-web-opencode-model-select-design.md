# Spec: chọn & quản lý combo model 9router cho backend opencode trên pagent web

**Ngày:** 2026-07-09
**Trạng thái:** đã duyệt hướng (chờ review spec)

## Bối cảnh & vấn đề

Backend web có bất đối xứng về chọn model:

- Backend **claude** → web hiện dropdown thứ 2 (`sonnet`/`opus`) → `_spawn_pagent` set `PAGENT_CLAUDE_MODEL` từ settings ([server.py:652](../../../kit/web/server.py), [app.js:237](../../../kit/web/app.js)).
- Backend **opencode** → web **không** cho chọn model. `PAGENT_MODEL` (dạng `provider/model`, vd `9router/Claude`) chỉ đến từ `.env.pagent` hoặc env kế thừa của shell. `_spawn_pagent` **không** set `PAGENT_MODEL`.

Hệ quả thực tế (sự cố khởi động spec này): task `find` trên project `api-admin` fail với `No active credentials for provider: claude`. Chuỗi lỗi:

1. Gateway 9router (`http://127.0.0.1:20128`) có combo model `Claude` route xuống upstream provider `claude` đang **không có credentials active** → gateway trả 404. Combo `FREE` vẫn chạy (route sang deepseek).
2. Backend opencode dùng `PAGENT_MODEL=9router/Claude`. Giá trị này **leak** từ shell đã source `pipelineAgent/.env.pagent` → vào web server (`env = dict(os.environ)` tại [server.py:641](../../../kit/web/server.py)) → xuống pagent. `api-admin` không có `.env.pagent` riêng để đè → dùng `9router/Claude` hỏng.
3. Không có cách nào đổi combo từ web — phải sửa `.env.pagent` bằng tay.

## Mục tiêu

1. Web cho **chọn** combo 9router khi backend = opencode (đối xứng với dropdown claude model), **default `9router/FREE`** để chạy được ngay cả khi upstream `claude` chưa reconnect.
2. Web cho **thêm/xóa** combo trong một **danh sách global** (dùng chung mọi project — combo vốn là thuộc tính của gateway 9router). Mỗi project chỉ lưu combo **đang chọn**.
3. Web là **nguồn sự thật** cho `PAGENT_MODEL` khi spawn — đè giá trị leak từ shell.
4. `pipelineAgent/.env.pagent` không hard-code `9router/Claude` để không leak, nhưng không clobber env web/shell truyền vào.

## Phi mục tiêu (YAGNI)

- **Không** tự fetch `/v1/models` từ gateway để liệt kê combo. Danh sách do user quản tay (add/remove); seed sẵn `9router/FREE`, `9router/Claude`.
- Không đổi cơ chế backend claude.
- Không sửa credentials trong gateway 9router (việc admin ngoài repo này).
- Không thêm khung "global settings" tổng quát — chỉ đúng 1 khóa `opencode_models`.

## Mô hình dữ liệu

**Global** (dùng chung) — file `REPORTS/opencode-models.json`:
```json
{ "opencode_models": ["9router/FREE", "9router/Claude"] }
```
- Thiếu/hỏng → default seed `["9router/FREE", "9router/Claude"]`.

**Per-project** — `REPORTS/<proj>/settings.json` thêm 1 khóa:
```json
{ "provider": "opencode", "claude_model": "sonnet", "opencode_model": "9router/FREE" }
```
- `opencode_model` = combo đang chọn (string dạng `provider/model`, hoặc rỗng = "không override").

## Thiết kế

### 1. Server — global combo list (`kit/web/server.py`)

- Hằng:
  ```python
  _GLOBAL_DEFAULTS = {"opencode_models": ["9router/FREE", "9router/Claude"]}
  _OPENCODE_MODEL_RE = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")
  _OPENCODE_MODELS_MAX = 30        # trần số combo
  ```
  Regex không whitelist cứng `9router` (còn dùng provider opencode khác).
- `_global_settings_path()` → `os.path.join(REPORTS, "opencode-models.json")` (tên cố định, không nhận input → không traversal).
- `read_global_settings()`: đọc + merge `_GLOBAL_DEFAULTS`; file thiếu/hỏng → default êm (giống `read_settings`).
- `write_global_settings(models)`: ghi atomic (tmp + `os.replace`), giống cách settings per-project ghi.
- **Endpoint mới** (không project-scoped):
  - `GET /api/settings/opencode-models` → `{"opencode_models": [...]}`.
  - `POST /api/settings/opencode-models` body `{"opencode_models": [...]}` → validate rồi ghi đè cả list (frontend gửi full list sau add/remove). Trả list đã lưu.
- Validate list (POST): phải là mảng; mỗi phần tử là string non-empty, khớp `_OPENCODE_MODEL_RE`, dài ≤ 128; **dedup giữ thứ tự**; số phần tử 1..`_OPENCODE_MODELS_MAX`. Sai bất kỳ → 400, không ghi.

### 2. Server — per-project `opencode_model` (`kit/web/server.py`)

- `_SETTINGS_DEFAULTS` thêm `"opencode_model": "9router/FREE"`.
- `_settings_post` ([server.py:840](../../../kit/web/server.py)) thêm nhánh, khuôn với `claude_model`:
  ```python
  if "opencode_model" in data:
      m = data["opencode_model"]
      if not isinstance(m, str) or (m != "" and not _OPENCODE_MODEL_RE.fullmatch(m)):
          return self._j({"error": "opencode_model phải dạng provider/model (vd 9router/FREE) hoặc rỗng"}, 400)
      cur["opencode_model"] = m
  ```
  Không ép `opencode_model` phải nằm trong list global (combo có thể vẫn hợp lệ ở gateway dù đã xóa khỏi list; frontend sẽ chèn nó vào dropdown như custom để vẫn thấy/chọn được).
- `read_settings` không đổi (settings.json cũ tự nhận default `9router/FREE` qua merge).

### 3. Server — spawn (`kit/web/server.py`)

Tại [server.py:648-652](../../../kit/web/server.py), trong nhánh `if sp and os.path.isfile(sp)`, thêm:
```python
if st.get("opencode_model"):
    env["PAGENT_MODEL"] = st["opencode_model"]
```
- Chỉ set khi non-empty → đè giá trị leak từ shell. Rỗng → không đụng, để pagent/opencode default áp.
- `PAGENT_MODEL` chỉ backend opencode dùng; backend claude bỏ qua → set luôn vô hại.

### 4. Frontend (`kit/web/app.js`)

`backendSelectorHtml(s, opencodeModels)` ([app.js:225](../../../kit/web/app.js)) — thêm tham số list (default `['9router/FREE','9router/Claude']` khi thiếu → test cũ 1-arg vẫn chạy). Khi `prov === 'opencode'` render nhóm:
- `<select id="backend-opencode-model">` từ `opencodeModels`, selected = `st.opencode_model || '9router/FREE'`; **chèn** giá trị đang chọn nếu không có trong list (custom passthrough). Escape value/label (`esc`) chống XSS.
- Nút `#backend-opencode-add` ("+") và `#backend-opencode-del` ("×"). Nhóm này có class `hidden` khi `prov !== 'opencode'` (đối xứng `#backend-claude-model` ẩn khi `prov !== 'claude'`).

Hành vi (listener delegation, [app.js:1052](../../../kit/web/app.js)):
- Đổi `#backend-opencode-model` → `saveBackendSettings()` (POST per-project `opencode_model`).
- Bấm `#backend-opencode-add` → `prompt()` xin chuỗi `provider/model` → validate client (regex) → thêm vào list (dedup), `saveOpencodeModels(list)` (POST global) → chọn combo mới → re-render.
- Bấm `#backend-opencode-del` → xóa combo **đang chọn** khỏi list (guard: giữ ≥ 1; không cho xóa phần tử cuối) → `saveOpencodeModels(list)` → chọn phần tử đầu còn lại → re-render.
- `saveBackendSettings` ([app.js:249](../../../kit/web/app.js)): khi `sel.value === 'opencode'` gửi kèm `body.opencode_model = $('#backend-opencode-model').value`.

`loadBackendSettings` ([app.js:240](../../../kit/web/app.js)): fetch **song song** per-project settings + `GET /api/settings/opencode-models`, truyền cả hai vào `backendSelectorHtml`. Lỗi list global → fallback default hardcode (không chặn composer).

### 5. `.env.pagent` (repo pipelineAgent)

Đổi hard-assign `PAGENT_MODEL="9router/Claude"` thành dạng tôn trọng env có sẵn:
```sh
PAGENT_MODEL="${PAGENT_MODEL:-}"
```
**Vì sao không dùng `PAGENT_MODEL=""`:** [pagent:31](../../../pagent) source bằng `set -a && . file`. Hard-assign (kể cả `=""`) sẽ **ghi đè** giá trị web/shell truyền vào → clobber về rỗng, mất config. Dạng `${PAGENT_MODEL:-}` giữ giá trị đã set, chỉ default rỗng khi chưa có. Cập nhật comment quanh dòng + đồng bộ `.env.pagent.example` nếu nó cũng hard-code.

## Quy tắc precedence (chốt)

Web run (cwd = project đích, vd api-admin không có `.env.pagent`):
1. `_spawn_pagent` set `env["PAGENT_MODEL"] = opencode_model` (default `9router/FREE`).
2. pagent source `.env.pagent` project đích (nếu có) — api-admin: không → không đè.
3. [pagent:54](../../../pagent) `PAGENT_MODEL="${PAGENT_MODEL:-}"` giữ giá trị web. ✓

CLI run trong pipelineAgent:
1. Shell source `pipelineAgent/.env.pagent` → `PAGENT_MODEL` rỗng (trừ khi user tự export).
2. Rỗng → pagent không truyền `-m` → opencode dùng `model` default trong `~/.config/opencode/opencode.json`.

## Tương thích ngược

- settings.json cũ (thiếu `opencode_model`) → merge default `9router/FREE`. Lần chạy web kế tiếp của project opencode dùng FREE thay vì Claude. **Có chủ đích** (Claude đang hỏng; user chọn lại Claude khi upstream reconnect).
- Chưa có `opencode-models.json` → seed default `["9router/FREE","9router/Claude"]`.

## Kiểm thử

- **`tests/test_server_settings.py` / `tests/test_server_model_validation.py`:**
  - Per-project `opencode_model`: hợp lệ (`9router/FREE`) → 200 persist; rỗng → 200; sai (`Claude` không `/`, ký tự lạ) → 400 không ghi; GET project mới → `opencode_model == "9router/FREE"`.
  - Global list: GET mặc định → `["9router/FREE","9router/Claude"]`; POST list hợp lệ → 200 persist + dedup; POST có phần tử sai/rỗng/quá `_OPENCODE_MODELS_MAX` → 400 không ghi; POST không phải mảng → 400.
- **`tests/test_env_provider.sh`:** settings có `opencode_model` → `_spawn_pagent` set `PAGENT_MODEL` đúng và **đè** `os.environ` leak (env sẵn `9router/Claude` → thành giá trị settings). `opencode_model` rỗng → không set (giữ env cũ).
- **`tests/test_web_backend.js`:** cập nhật test [dòng 10-14](../../../tests/test_web_backend.js) (đang assert opencode KHÔNG hiện model select) → opencode **có** `#backend-opencode-model` (không `hidden`) + nút add/del, default `9router/FREE` selected; claude vẫn ẩn nhóm opencode. Thêm: list truyền vào render đúng options; combo custom (không trong list) vẫn được chèn & selected; escape XSS cho combo lạ.

## File đụng tới

- `kit/web/server.py` — global list (const/read/write/endpoint/validate), per-project `opencode_model`, spawn env.
- `kit/web/app.js` — `backendSelectorHtml` (thêm arg list + nút add/del), `saveBackendSettings`, `saveOpencodeModels`, `loadBackendSettings`, listeners.
- `.env.pagent`, `.env.pagent.example` — dạng `PAGENT_MODEL` + comment.
- `tests/test_server_model_validation.py`, `tests/test_server_settings.py`, `tests/test_env_provider.sh`, `tests/test_web_backend.js`.
