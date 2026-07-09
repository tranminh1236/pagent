# Web opencode combo model select — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cho pagent web chọn & quản lý (thêm/xóa) combo model 9router cho backend opencode, default `9router/FREE`, và web là nguồn sự thật cho `PAGENT_MODEL` khi spawn.

**Architecture:** Combo list lưu **global** (`REPORTS/opencode-models.json`, endpoint `/api/settings/opencode-models`); combo đang chọn lưu **per-project** (`opencode_model` trong `settings.json`). `_spawn_pagent` set `env["PAGENT_MODEL"]` từ per-project setting → đè giá trị leak từ shell. `.env.pagent` đổi sang `${PAGENT_MODEL:-}` để không leak `9router/Claude`.

**Tech Stack:** Python stdlib `http.server` (`kit/web/server.py`), vanilla JS (`kit/web/app.js`), bash (`pagent`, `.env.pagent`). Tests: `unittest`, node `assert`, bash.

## Global Constraints

- `opencode_model` / mỗi phần tử combo list: dạng `provider/model`, regex `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$`, dài ≤ 128; `opencode_model` cho phép **rỗng** (= không override).
- Combo list global: mảng 1..30 phần tử, dedup giữ thứ tự; POST sai bất kỳ → 400 không ghi.
- Default combo: `9router/FREE`. Default list: `["9router/FREE", "9router/Claude"]`.
- Pure JS helpers (`backendSelectorHtml`, `addOpencodeModel`, `removeOpencodeModel`) ở **module scope** (ngoài guard `if (typeof document !== 'undefined')` tại [app.js:1003](../../../kit/web/app.js)) để node test `require` được; event listener đặt **trong** guard.
- Web spawn set `PAGENT_MODEL` chỉ khi `opencode_model` non-empty.
- Không tự fetch `/v1/models` từ gateway — combo do user quản tay.

---

### Task 1: `.env.pagent` không leak `PAGENT_MODEL`

**Files:**
- Modify: `.env.pagent:14-17`
- Modify: `.env.pagent.example:13`
- Test: `tests/test_env_provider.sh`

**Interfaces:**
- Produces: `.env.pagent` khi source cho `PAGENT_MODEL` rỗng (mặc định) nhưng giữ giá trị nếu env đã set trước.

- [ ] **Step 1: Thêm test "respects preset env" vào test_env_provider.sh**

Chèn ngay sau khối test 1 (sau dòng `fi` của check `PAGENT_MODEL dạng provider/model`, ~dòng 24):

```bash
# ── 1b. Source .env.pagent KHÔNG được clobber PAGENT_MODEL đã set sẵn (web/shell) ─────
preset="$(bash -c "export PAGENT_MODEL='9router/FREE'; set -a; . '$ENV_FILE' 2>/dev/null; set +a; printf '%s' \"\$PAGENT_MODEL\"")"
if [[ "$preset" == "9router/FREE" ]]; then
  ok "PAGENT_MODEL set sẵn được giữ nguyên qua source (không clobber)"
else
  bad "source .env.pagent clobber PAGENT_MODEL đã set sẵn" "got: '$preset' (mong '9router/FREE')"
fi
```

- [ ] **Step 2: Chạy test — kỳ vọng FAIL**

Run: `bash tests/test_env_provider.sh`
Expected: FAIL ở "PAGENT_MODEL set sẵn được giữ nguyên" (got `9router/Claude` — hard-assign clobber).

- [ ] **Step 3: Đổi `.env.pagent` sang dạng tôn trọng env**

Sửa `.env.pagent` dòng 14-17. Thay:

```sh
# Backend MẶC ĐỊNH là opencode CLI (từ 2026-07-04) → PAGENT_MODEL dạng "provider/model"
# theo chuẩn opencode (vd "9router/Claude" — provider 9router trong opencode.json).
# Rỗng/bỏ set → opencode dùng model default trong ~/.config/opencode/opencode.json.
PAGENT_MODEL="9router/Claude"
```

thành:

```sh
# Backend MẶC ĐỊNH là opencode CLI → PAGENT_MODEL dạng "provider/model" (vd "9router/FREE").
# ĐỂ RỖNG ở đây: pagent web là nguồn sự thật (settings per-project opencode_model, default
# 9router/FREE) và đè giá trị này khi spawn. Dạng ${PAGENT_MODEL:-} TÔN TRỌNG env web/shell
# truyền vào (KHÔNG dùng hard-assign PAGENT_MODEL="" — set -a source sẽ clobber về rỗng).
# Rỗng + chạy CLI tay → opencode dùng model default trong ~/.config/opencode/opencode.json.
PAGENT_MODEL="${PAGENT_MODEL:-}"
```

- [ ] **Step 4: Đồng bộ `.env.pagent.example:13`**

Thay dòng 13 `PAGENT_MODEL="claude-opus-4-8"` thành:

```sh
PAGENT_MODEL="${PAGENT_MODEL:-}"   # rỗng: web quản (opencode_model); CLI tay → opencode.json default
```

- [ ] **Step 5: Chạy test — kỳ vọng PASS**

Run: `bash tests/test_env_provider.sh`
Expected: tất cả PASS (gồm test 1 "rỗng hoặc provider/model" và test 1b "giữ nguyên preset").

- [ ] **Step 6: Commit**

```bash
git add .env.pagent .env.pagent.example tests/test_env_provider.sh
git commit -m "fix(pagent): .env.pagent PAGENT_MODEL dạng \${PAGENT_MODEL:-} — web là nguồn sự thật, không leak"
```

---

### Task 2: Server — per-project `opencode_model`

**Files:**
- Modify: `kit/web/server.py:366` (`_SETTINGS_DEFAULTS`)
- Modify: `kit/web/server.py:368` (thêm `_OPENCODE_MODEL_RE`)
- Modify: `kit/web/server.py:860` (`_settings_post` — nhánh opencode_model)
- Modify: `kit/web/server.py:652` (`_spawn_pagent` — inject `PAGENT_MODEL`)
- Test: `tests/test_server_settings.py`

**Interfaces:**
- Consumes: `read_settings(proj)` (đã merge default), `_spawn_pagent`.
- Produces: settings key `opencode_model` (str, default `"9router/FREE"`); `env["PAGENT_MODEL"]` set khi non-empty. Regex `_OPENCODE_MODEL_RE`.

- [ ] **Step 1: Viết failing test (validation + default + spawn) vào `tests/test_server_settings.py`**

Trong `class TestSettingsEndpoints`, thêm các method:

```python
    def test_get_defaults_has_opencode_model(self):
        status, data = self._get()
        self.assertEqual(status, 200)
        self.assertEqual(data.get("opencode_model"), "9router/FREE")

    def test_post_opencode_model_valid_and_empty(self):
        status, data = self._post({"opencode_model": "9router/Claude"})
        self.assertEqual(status, 200, data)
        self.assertEqual(data["opencode_model"], "9router/Claude")
        status, data = self._post({"opencode_model": ""})   # rỗng = không override
        self.assertEqual(status, 200, data)
        self.assertEqual(data["opencode_model"], "")
        self._post({"opencode_model": "9router/FREE"})       # reset cho test sau

    def test_post_rejects_bad_opencode_model(self):
        for bad in ("Claude", "9router/", "/Claude", "a b/c", "x" * 200, 5):
            status, data = self._post({"opencode_model": bad})
            self.assertEqual(status, 400, f"opencode_model={bad!r}: {data}")
```

Trong `class TestSpawnInjectsSettings`, thêm:

```python
    def test_spawn_sets_pagent_model_from_opencode_model(self):
        self._write_settings({"provider": "opencode", "opencode_model": "9router/FREE"})
        with patch.dict(os.environ, {"PAGENT_MODEL": "9router/Claude"}):   # leak từ shell
            env = self._spawn()
        self.assertEqual(env.get("PAGENT_MODEL"), "9router/FREE")          # web đè leak

    def test_spawn_empty_opencode_model_leaves_env(self):
        self._write_settings({"provider": "opencode", "opencode_model": ""})
        with patch.dict(os.environ, {"PAGENT_MODEL": "9router/Claude"}):
            env = self._spawn()
        self.assertEqual(env.get("PAGENT_MODEL"), "9router/Claude")        # không đụng
```

- [ ] **Step 2: Chạy test — kỳ vọng FAIL**

Run: `python3 tests/test_server_settings.py -v`
Expected: FAIL (opencode_model chưa có trong defaults; spawn chưa set PAGENT_MODEL).

- [ ] **Step 3: Thêm default + regex**

`kit/web/server.py:366` — thay:

```python
_SETTINGS_DEFAULTS = {"provider": "opencode", "claude_model": "sonnet"}
```

thành:

```python
_SETTINGS_DEFAULTS = {"provider": "opencode", "claude_model": "sonnet",
                      "opencode_model": "9router/FREE"}
```

`kit/web/server.py:368` — ngay sau dòng `_CLAUDE_MODEL_RE = ...` thêm:

```python
# opencode dùng model dạng provider/model (vd "9router/FREE"); rỗng = không override.
_OPENCODE_MODEL_RE = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")
```

- [ ] **Step 4: Validate trong `_settings_post`**

`kit/web/server.py` — ngay sau khối `if "claude_model" in data:` (kết thúc ở dòng 860 `cur["claude_model"] = m`), thêm:

```python
        if "opencode_model" in data:
            m = data["opencode_model"]
            if not isinstance(m, str) or (m != "" and (len(m) > 128 or not _OPENCODE_MODEL_RE.fullmatch(m))):
                return self._j({"error": "opencode_model phải dạng provider/model (vd 9router/FREE) hoặc rỗng"}, 400)
            cur["opencode_model"] = m
```

- [ ] **Step 5: Inject `PAGENT_MODEL` khi spawn**

`kit/web/server.py:652` — ngay sau `env["PAGENT_CLAUDE_MODEL"] = st["claude_model"]` thêm:

```python
        if st.get("opencode_model"):
            env["PAGENT_MODEL"] = st["opencode_model"]   # web đè giá trị leak từ shell
```

- [ ] **Step 6: Chạy test — kỳ vọng PASS**

Run: `python3 tests/test_server_settings.py -v`
Expected: PASS toàn bộ (gồm test cũ).

- [ ] **Step 7: Commit**

```bash
git add kit/web/server.py tests/test_server_settings.py
git commit -m "feat(web): per-project opencode_model setting + inject PAGENT_MODEL khi spawn"
```

---

### Task 3: Server — global combo list store + endpoints

**Files:**
- Modify: `kit/web/server.py:368` (const global + read/write)
- Modify: `kit/web/server.py:869` (thêm method `_opencode_models_post`)
- Modify: `kit/web/server.py:742` (`do_POST` — route)
- Modify: `kit/web/server.py:1102` (`do_GET` — route)
- Test: `tests/test_server_settings.py`

**Interfaces:**
- Consumes: `REPORTS`, `self._read_body`, `self._j`.
- Produces: `read_global_settings() -> {"opencode_models": [...]}`; `GET/POST /api/settings/opencode-models`. Const `_GLOBAL_DEFAULTS`, `_OPENCODE_MODELS_MAX = 30`.

- [ ] **Step 1: Viết failing test (global list) vào `tests/test_server_settings.py`**

Thêm class mới (dùng `_req` + `_start_server` sẵn có trong file):

```python
class TestOpencodeModelsGlobal(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="pagent_ocmodels_")
        cls.server, cls.port = _start_server(cls.tmp)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        import shutil; shutil.rmtree(cls.tmp, ignore_errors=True)

    def _get(self):
        return _req(self.port, "GET", "/api/settings/opencode-models")

    def _post(self, payload):
        return _req(self.port, "POST", "/api/settings/opencode-models", payload)

    def test_get_default_list(self):
        status, data = self._get()
        self.assertEqual(status, 200)
        self.assertEqual(data.get("opencode_models"), ["9router/FREE", "9router/Claude"])

    def test_post_persists_and_dedups(self):
        status, data = self._post({"opencode_models": ["9router/FREE", "9router/Claude", "9router/FREE"]})
        self.assertEqual(status, 200, data)
        self.assertEqual(data["opencode_models"], ["9router/FREE", "9router/Claude"])  # dedup giữ thứ tự
        status, data = self._get()
        self.assertEqual(data["opencode_models"], ["9router/FREE", "9router/Claude"])

    def test_post_rejects_bad(self):
        for bad in ([], "notarray", ["Claude"], [""], ["a/b", 5],
                    [f"9router/m{i}" for i in range(31)]):
            status, data = self._post({"opencode_models": bad})
            self.assertEqual(status, 400, f"list={bad!r}: {data}")
```

- [ ] **Step 2: Chạy test — kỳ vọng FAIL**

Run: `python3 tests/test_server_settings.py TestOpencodeModelsGlobal -v`
Expected: FAIL (endpoint chưa tồn tại → 404).

- [ ] **Step 3: Thêm const + read/write global**

`kit/web/server.py` — ngay sau `_OPENCODE_MODEL_RE` (Task 2 Step 3), thêm:

```python
_GLOBAL_DEFAULTS = {"opencode_models": ["9router/FREE", "9router/Claude"]}
_OPENCODE_MODELS_MAX = 30

def _global_settings_path():
    return os.path.join(REPORTS, "opencode-models.json")

def read_global_settings():
    """Combo list global (dùng chung mọi project). Thiếu/hỏng → default êm."""
    out = dict(_GLOBAL_DEFAULTS)
    p = _global_settings_path()
    if os.path.isfile(p):
        try:
            with open(p) as f:
                d = json.load(f)
            v = d.get("opencode_models")
            if isinstance(v, list) and v:
                out["opencode_models"] = v
        except Exception:
            pass
    return out

def write_global_settings(models):
    p = _global_settings_path()
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"opencode_models": models}, f)
    os.replace(tmp, p)
```

- [ ] **Step 4: Thêm method `_opencode_models_post`**

`kit/web/server.py` — ngay sau `_settings_post` (sau dòng 869 `return self._j(cur)`), thêm:

```python
    def _opencode_models_post(self):
        """POST {opencode_models: [...]} → ghi đè list global (atomic). Mỗi phần tử phải
        dạng provider/model; dedup giữ thứ tự; 1..MAX phần tử. Sai → 400 không ghi."""
        raw = self._read_body()
        if raw is None:
            return self._j({"error": "body quá lớn"}, 413)
        try:
            data = json.loads(raw or b"{}")
        except Exception:
            return self._j({"error": "JSON không hợp lệ"}, 400)
        lst = data.get("opencode_models")
        if not isinstance(lst, list):
            return self._j({"error": "opencode_models phải là mảng"}, 400)
        seen, out = set(), []
        for m in lst:
            if not isinstance(m, str) or m == "" or len(m) > 128 or not _OPENCODE_MODEL_RE.fullmatch(m):
                return self._j({"error": f"combo không hợp lệ: {m!r} (cần provider/model)"}, 400)
            if m not in seen:
                seen.add(m); out.append(m)
        if not (1 <= len(out) <= _OPENCODE_MODELS_MAX):
            return self._j({"error": f"list phải có 1..{_OPENCODE_MODELS_MAX} combo"}, 400)
        write_global_settings(out)
        return self._j({"opencode_models": out})
```

- [ ] **Step 5: Wire routes**

`kit/web/server.py:742` — trong `do_POST`, ngay sau `path = urlparse(self.path).path` thêm:

```python
            if path == "/api/settings/opencode-models":
                return self._opencode_models_post()
```

`kit/web/server.py:1102` — trong `do_GET`, ngay sau `if path == "/api/projects":   return self._j(list_projects())` thêm:

```python
            if path == "/api/settings/opencode-models": return self._j(read_global_settings())
```

- [ ] **Step 6: Chạy test — kỳ vọng PASS**

Run: `python3 tests/test_server_settings.py -v`
Expected: PASS toàn bộ.

- [ ] **Step 7: Commit**

```bash
git add kit/web/server.py tests/test_server_settings.py
git commit -m "feat(web): global combo list store + GET/POST /api/settings/opencode-models"
```

---

### Task 4: Frontend — render combo dropdown + nút add/del

**Files:**
- Modify: `kit/web/app.js:225-238` (`backendSelectorHtml`)
- Modify: `kit/web/app.js:1115` (`module.exports`)
- Test: `tests/test_web_backend.js`

**Interfaces:**
- Produces: `backendSelectorHtml(s, opencodeModels)` — khi opencode render `#backend-opencode-model` + `#backend-opencode-add` + `#backend-opencode-del` trong `#backend-opencode-wrap`; const `OPENCODE_MODELS_DEFAULT`.

- [ ] **Step 1: Cập nhật `tests/test_web_backend.js`**

Thay test dòng 10-15 (`opencode selected mặc định, không hiện model select`) bằng:

```javascript
t('opencode selected → hiện combo select + nút add/del, default 9router/FREE', () => {
  const html = backendSelectorHtml({ provider: 'opencode' });
  assert.ok(/value="opencode"[^>]*selected/.test(html), 'opencode selected');
  const wrap = html.match(/<span[^>]*backend-opencode-wrap[^>]*>/)?.[0] || '';
  assert.ok(/backend-opencode-wrap/.test(html) && !/hidden/.test(wrap), 'wrap opencode hiện');
  assert.ok(/backend-opencode-add/.test(html) && /backend-opencode-del/.test(html), 'có nút add/del');
  assert.ok(/value="9router\/FREE"[^>]*selected/.test(html), 'default 9router/FREE selected');
  const cm = html.match(/<select[^>]*backend-claude-model[^>]*>/)?.[0] || '';
  assert.ok(/hidden/.test(cm), 'claude model select ẩn khi opencode');
});

t('opencode: list truyền vào render đúng + chèn combo custom đang chọn', () => {
  const html = backendSelectorHtml(
    { provider: 'opencode', opencode_model: '9router/Custom' },
    ['9router/FREE', '9router/Claude']);
  assert.ok(/value="9router\/Custom"[^>]*selected/.test(html), 'custom được chèn & selected');
  assert.ok(/value="9router\/Claude"/.test(html), 'list item render');
});

t('escape combo opencode_model lạ (XSS)', () => {
  const html = backendSelectorHtml({ provider: 'opencode', opencode_model: '"><img>' });
  assert.ok(!/"><img>/.test(html), 'phải escape');
});
```

Cập nhật test claude (dòng 17-23) thêm assert wrap opencode ẩn — chèn vào cuối callback:

```javascript
  const ocWrap = html.match(/<span[^>]*backend-opencode-wrap[^>]*>/)?.[0] || '';
  assert.ok(/hidden/.test(ocWrap), 'wrap opencode ẩn khi claude');
```

- [ ] **Step 2: Chạy test — kỳ vọng FAIL**

Run: `node tests/test_web_backend.js`
Expected: FAIL (chưa có `backend-opencode-wrap`).

- [ ] **Step 3: Rewrite `backendSelectorHtml` + const**

`kit/web/app.js` — ngay TRƯỚC `function backendSelectorHtml` (dòng 225) thêm const module-scope:

```javascript
const OPENCODE_MODELS_DEFAULT = ['9router/FREE', '9router/Claude'];
```

Thay toàn bộ `function backendSelectorHtml(s) { ... }` (dòng 225-238) bằng:

```javascript
function backendSelectorHtml(s, opencodeModels) {
  const st = s || {};
  const prov = st.provider === 'claude' ? 'claude' : 'opencode';
  const curModel = String(st.claude_model || 'sonnet');
  const models = ['sonnet', 'opus'].includes(curModel) ? ['sonnet', 'opus'] : ['sonnet', 'opus', curModel];
  const modelOpts = models.map(m =>
    `<option value="${esc(m)}"${m === curModel ? ' selected' : ''}>${esc(m)}</option>`).join('');
  // opencode combo (global list) — chèn giá trị đang chọn nếu không có trong list
  const curOc = String(st.opencode_model || '9router/FREE');
  let ocList = Array.isArray(opencodeModels) && opencodeModels.length ? opencodeModels.slice() : OPENCODE_MODELS_DEFAULT.slice();
  if (!ocList.includes(curOc)) ocList = [curOc, ...ocList];
  const ocOpts = ocList.map(m =>
    `<option value="${esc(m)}"${m === curOc ? ' selected' : ''}>${esc(m)}</option>`).join('');
  return `
    <select id="backend-select" title="Backend cho MỌI run kế tiếp của project này (persist server-side)">
      <option value="opencode"${prov === 'opencode' ? ' selected' : ''}>⚡ opencode · 9router (việc nhỏ)</option>
      <option value="claude"${prov === 'claude' ? ' selected' : ''}>🧠 claude · subscription (việc lớn)</option>
    </select>
    <select id="backend-claude-model" class="${prov === 'claude' ? '' : 'hidden'}" title="Model claude (tên trần — direct subscription)">${modelOpts}</select>
    <span id="backend-opencode-wrap" class="${prov === 'opencode' ? '' : 'hidden'}">
      <select id="backend-opencode-model" title="Combo model 9router cho backend opencode">${ocOpts}</select>
      <button type="button" id="backend-opencode-add" title="Thêm combo (provider/model)">+</button>
      <button type="button" id="backend-opencode-del" title="Xóa combo đang chọn">×</button>
    </span>`;
}
```

- [ ] **Step 4: Chạy test — kỳ vọng PASS**

Run: `node tests/test_web_backend.js`
Expected: PASS toàn bộ.

- [ ] **Step 5: Commit**

```bash
git add kit/web/app.js tests/test_web_backend.js
git commit -m "feat(web): backendSelectorHtml render combo opencode + nút add/del"
```

---

### Task 5: Frontend — wiring add/remove/select + fetch list

**Files:**
- Modify: `kit/web/app.js` (helpers module-scope + hàm wiring + listeners trong guard 1003)
- Modify: `kit/web/app.js:1115` (`module.exports`)
- Test: `tests/test_web_backend.js` (helpers thuần)

**Interfaces:**
- Consumes: `backendSelectorHtml`, `saveBackendSettings`, `loadBackendSettings`, `parseJson`, `j`, `$`, `project`, `OPENCODE_MODELS_DEFAULT`.
- Produces: `addOpencodeModel(list, value) -> {list, added?, error?}`; `removeOpencodeModel(list, value) -> {list, removed?, error?}`.

- [ ] **Step 1: Viết failing test cho helpers vào `tests/test_web_backend.js`**

Thêm require ở đầu file (dòng 5) — đổi:

```javascript
const { backendSelectorHtml } = require('../kit/web/app.js');
```

thành:

```javascript
const { backendSelectorHtml, addOpencodeModel, removeOpencodeModel } = require('../kit/web/app.js');
```

Thêm test (trước dòng `console.log`):

```javascript
t('addOpencodeModel: hợp lệ thì append, dedup, chặn dạng sai', () => {
  assert.deepStrictEqual(addOpencodeModel(['9router/FREE'], '9router/Claude').list,
    ['9router/FREE', '9router/Claude']);
  assert.deepStrictEqual(addOpencodeModel(['9router/FREE'], '9router/FREE').list,
    ['9router/FREE'], 'không nhân đôi');
  assert.ok(addOpencodeModel(['9router/FREE'], 'Claude').error, 'thiếu / → error');
  assert.ok(addOpencodeModel(['9router/FREE'], '  ').error, 'rỗng → error');
});

t('removeOpencodeModel: xóa combo, giữ ≥1', () => {
  assert.deepStrictEqual(removeOpencodeModel(['9router/FREE', '9router/Claude'], '9router/Claude').list,
    ['9router/FREE']);
  assert.ok(removeOpencodeModel(['9router/FREE'], '9router/FREE').error, 'không xóa phần tử cuối');
});
```

- [ ] **Step 2: Chạy test — kỳ vọng FAIL**

Run: `node tests/test_web_backend.js`
Expected: FAIL (`addOpencodeModel is not a function`).

- [ ] **Step 3: Thêm helpers thuần (module scope)**

`kit/web/app.js` — ngay sau `function backendSelectorHtml(...) { ... }` (Task 4) thêm:

```javascript
// Thêm combo vào list (validate provider/model, dedup). Trả {list, added?} hoặc {list, error}.
function addOpencodeModel(list, value) {
  const v = String(value || '').trim();
  if (!/^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/.test(v) || v.length > 128) {
    return { list: Array.isArray(list) ? list : [], error: 'combo phải dạng provider/model (vd 9router/Claude)' };
  }
  const base = Array.isArray(list) ? list.slice() : [];
  if (base.includes(v)) return { list: base, added: v };
  return { list: [...base, v], added: v };
}
// Xóa combo khỏi list, luôn giữ ≥1. Trả {list, removed?} hoặc {list, error}.
function removeOpencodeModel(list, value) {
  const base = Array.isArray(list) ? list.slice() : [];
  if (base.length <= 1) return { list: base, error: 'phải giữ ít nhất 1 combo' };
  return { list: base.filter(m => m !== value), removed: value };
}
```

- [ ] **Step 4: Cập nhật `module.exports`**

`kit/web/app.js:1115` — thêm `addOpencodeModel, removeOpencodeModel` vào object export:

```javascript
if (typeof module !== 'undefined' && module.exports) module.exports = { paginate, PAGE_SIZE, fmtCompact, fmtSpend, computeStats, aiWorkflowModel, renderAgentWorkflow, liveMaxTurnsHit, retryControlHtml, resumeControlHtml, liveSignature, backendSelectorHtml, addOpencodeModel, removeOpencodeModel, pollTickHasActivity };
```

- [ ] **Step 5: Chạy test — kỳ vọng PASS**

Run: `node tests/test_web_backend.js`
Expected: PASS toàn bộ.

- [ ] **Step 6: Wiring DOM (state cache + fetch list + save/select)**

`kit/web/app.js` — ngay sau `let project = null;` (dòng ~36) thêm cache module-scope:

```javascript
let opencodeModels = OPENCODE_MODELS_DEFAULT.slice();  // list global, nạp ở loadBackendSettings
```

Thay `loadBackendSettings` (dòng 240-247) bằng:

```javascript
async function loadBackendSettings() {
  if (!project) return;
  try {
    const [s, g] = await Promise.all([
      j(`/api/projects/${encodeURIComponent(project)}/settings`),
      j(`/api/settings/opencode-models`).catch(() => ({ opencode_models: OPENCODE_MODELS_DEFAULT })),
    ]);
    opencodeModels = (g && Array.isArray(g.opencode_models) && g.opencode_models.length)
      ? g.opencode_models : OPENCODE_MODELS_DEFAULT.slice();
    const wrap = $('#backend-wrap');
    if (wrap) wrap.innerHTML = backendSelectorHtml(s, opencodeModels);
  } catch { /* endpoint lỗi → giữ UI cũ, không chặn composer */ }
}
```

Trong `saveBackendSettings` (dòng 249-263), sau khối `if (ms && sel.value === 'claude') body.claude_model = ms.value;` (dòng 254) thêm:

```javascript
  const oms = $('#backend-opencode-model');
  if (oms && sel.value === 'opencode') body.opencode_model = oms.value;
```

Ngay sau `saveBackendSettings` thêm các hàm:

```javascript
// POST list global rồi cập nhật cache. Trả true nếu OK.
async function saveOpencodeModels(list) {
  try {
    const r = await parseJson(await fetch('/api/settings/opencode-models',
      { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ opencode_models: list }) }));
    if (r.error) { alert(r.error); return false; }
    opencodeModels = r.opencode_models || list;
    return true;
  } catch (e) { alert(String(e)); return false; }
}
// Chọn combo cho project hiện tại (persist opencode_model).
async function selectOpencodeModel(value) {
  try {
    const r = await parseJson(await fetch(`/api/projects/${encodeURIComponent(project)}/settings`,
      { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ opencode_model: value }) }));
    if (r.error) { alert(r.error); return; }
  } catch (e) { alert(String(e)); }
}
async function onOpencodeAdd() {
  const v = prompt('Thêm combo 9router (dạng provider/model, vd 9router/Claude):');
  if (v == null) return;
  const res = addOpencodeModel(opencodeModels, v);
  if (res.error) { alert(res.error); return; }
  if (await saveOpencodeModels(res.list)) { await selectOpencodeModel(res.added); await loadBackendSettings(); }
}
async function onOpencodeDel() {
  const cur = $('#backend-opencode-model');
  if (!cur) return;
  const res = removeOpencodeModel(opencodeModels, cur.value);
  if (res.error) { alert(res.error); return; }
  if (await saveOpencodeModels(res.list)) { await selectOpencodeModel(res.list[0]); await loadBackendSettings(); }
}
```

- [ ] **Step 7: Đăng ký listeners (trong guard `typeof document`)**

`kit/web/app.js:1052` — thay dòng điều kiện change:

```javascript
  if (e.target.id === 'backend-select' || e.target.id === 'backend-claude-model') saveBackendSettings();
```

thành:

```javascript
  if (e.target.id === 'backend-select' || e.target.id === 'backend-claude-model'
      || e.target.id === 'backend-opencode-model') saveBackendSettings();
```

Ngay sau block `document.addEventListener('change', ...)` (kết ở dòng 1053) thêm:

```javascript
document.addEventListener('click', (e) => {
  if (e.target.id === 'backend-opencode-add') { onOpencodeAdd(); return; }
  if (e.target.id === 'backend-opencode-del') onOpencodeDel();
});
```

- [ ] **Step 8: Chạy lại test JS + verify tay**

Run: `node tests/test_web_backend.js`
Expected: PASS.

Verify tay (khởi web, mở 1 project):
```
pagent web    # hoặc lệnh khởi web server của repo
```
- Chọn backend opencode → thấy dropdown combo (default `9router/FREE`) + nút `+`/`×`.
- Bấm `+`, gõ `9router/Claude` → combo mới xuất hiện & được chọn; reload trang vẫn còn (list global).
- Bấm `×` khi đang chọn 1 combo → combo biến mất, nhảy về combo đầu; không cho xóa combo cuối.
- Đổi sang backend claude → nhóm opencode ẩn, hiện dropdown sonnet/opus.

- [ ] **Step 9: Commit**

```bash
git add kit/web/app.js tests/test_web_backend.js
git commit -m "feat(web): wiring add/xóa/chọn combo opencode + fetch list global"
```

---

## Self-Review

**Spec coverage:**
- Mục tiêu 1 (chọn combo, default FREE) → Task 2 (default) + Task 4 (dropdown). ✓
- Mục tiêu 2 (thêm/xóa global list) → Task 3 (store/endpoint) + Task 5 (wiring). ✓
- Mục tiêu 3 (web nguồn sự thật `PAGENT_MODEL`) → Task 2 Step 5 (inject, đè leak). ✓
- Mục tiêu 4 (`.env.pagent` không leak) → Task 1. ✓
- Precedence / tương thích ngược → Task 1 (respects-env test) + Task 2 (default merge). ✓
- Kiểm thử: server (Task 2,3), env (Task 1), web (Task 4,5). ✓

**Placeholder scan:** không có TBD/TODO; mọi step có code/lệnh thật.

**Type consistency:** `opencode_model` (str), `opencode_models` (list) nhất quán server↔client; `addOpencodeModel/removeOpencodeModel` trả `{list, added?/removed?, error?}` dùng đúng ở Task 5; regex provider/model đồng nhất server (`_OPENCODE_MODEL_RE`) và client (inline trong helper).
