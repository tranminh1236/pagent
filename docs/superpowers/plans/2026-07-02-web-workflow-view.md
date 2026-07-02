# Web Workflow View + Reuse Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Thêm khu vực hiển thị workflow của project trong web dashboard (`pagent web`), đọc từ `$PAGENT_REPORT_DIR/<project>/workflow.md`, với nút "Dùng lại" prefill composer để chạy task mới tương tự.

**Architecture:** Backend `read_workflow(proj)` (server.py, thuần) parse workflow.md → JSON sections, phục vụ qua `GET /api/projects/<proj>/workflow`. Frontend thêm 1 `<section>` render cards; nút "Dùng lại" set mode + đổ prefill vào `#task-input` + focus composer (không endpoint mới). Bám đúng pattern SPA sẵn có.

**Tech Stack:** Python stdlib (http.server) cho backend; vanilla JS + CSS cho frontend; `unittest` cho test.

## Global Constraints

- Chỉ **xem + reuse-prefill**. KHÔNG edit/xoá/tạo/chạy-smoke workflow trên web (YAGNI).
- Reuse prefill = **`Làm tương tự "<title>". Cụ thể: `** (đúng chuỗi này, có dấu cách cuối, con trỏ ở cuối), set mode = `feature`.
- Backend `read_workflow` **chỉ đọc + parse**, không chạy lệnh; `smoke_cmd` chỉ để hiển thị.
- Dùng lại guard bảo mật sẵn có: `_safe_join(REPORTS, proj, "workflow.md")` (chặn path traversal), `_valid_proj` (route).
- Nạp workflow khi **đổi project** + khi bấm **↻ refresh**, KHÔNG trong vòng auto-`refresh()` mỗi 3s.
- Mọi text render qua `esc()` (chống XSS). Bám CSS token sẵn có (`--panel`, `--panel-2`, `--border`, `--dim`, `--accent`, `--mono`, `--feature`).
- Không đụng backend pipeline/agent (độc lập nhánh migration opencode).

**Spec:** `docs/superpowers/specs/2026-07-02-web-workflow-view-design.md`

---

## File Structure

| File | Trách nhiệm |
|------|-------------|
| `kit/web/server.py` (sửa) | `read_workflow(proj)` + route `/workflow` trong `do_GET`. |
| `kit/web/index.html` (sửa) | `<section id="workflow-section">` sau chat, trước live. |
| `kit/web/app.js` (sửa) | `loadWorkflows`, `renderWorkflows`, `reuseWorkflow` + wiring (switchProject, refresh-btn, delegation). |
| `kit/web/style.css` (sửa) | `.wf-card`, `.wf-reuse`, `.wf-flow`, `.wf-smoke`, `.wf-related`. |
| `tests/test_web_workflow.py` (mới) | Unit `read_workflow` (parse, file-missing, path-traversal) + route smoke. |
| `tests/fixtures/workflow-sample.md` (mới) | workflow.md mẫu cho test. |

---

## Task 1: Backend `read_workflow` + route

**Files:**
- Modify: `kit/web/server.py` (thêm hàm sau `task_detail` ~dòng 193; thêm route trong `do_GET` ~dòng 699-706)
- Create: `tests/test_web_workflow.py`, `tests/fixtures/workflow-sample.md`

**Interfaces:**
- Produces: `read_workflow(proj) -> dict` = `{"exists": bool, "path": str, "workflows": list[dict]}`; mỗi workflow = `{"title": str, "trigger": str, "preconditions": str, "flow": list[str], "expected": str, "smoke_cmd": str, "related": list[str], "added": str}`. Route: `GET /api/projects/<proj>/workflow` → JSON đó.

- [ ] **Step 1: Tạo fixture + test fail**

Tạo `tests/fixtures/workflow-sample.md`:

```markdown
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
```

Tạo `tests/test_web_workflow.py`:

```python
#!/usr/bin/env python3
"""Tests for read_workflow + /workflow route in kit/web/server.py."""
import os, sys, shutil, tempfile, threading, unittest
import http.client
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "kit", "web"))
import server as srv

FIXTURE = os.path.join(os.path.dirname(__file__), "fixtures", "workflow-sample.md")


class ReadWorkflowTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        srv.REPORTS = os.path.realpath(self.tmp)
        self.proj = "demo"
        os.makedirs(os.path.join(self.tmp, self.proj), exist_ok=True)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _put_workflow(self):
        shutil.copy(FIXTURE, os.path.join(self.tmp, self.proj, "workflow.md"))

    def test_missing_file(self):
        r = srv.read_workflow(self.proj)
        self.assertFalse(r["exists"])
        self.assertEqual(r["workflows"], [])

    def test_parses_sections(self):
        self._put_workflow()
        r = srv.read_workflow(self.proj)
        self.assertTrue(r["exists"])
        self.assertEqual(len(r["workflows"]), 2)
        a = r["workflows"][0]
        self.assertEqual(a["title"], "Thêm tính năng A")
        self.assertEqual(a["trigger"], "Khi user làm X trong pipeline.")
        self.assertEqual(a["flow"], ["Bước một đọc input.", "Bước hai xử lý.", "Bước ba xuất kết quả."])
        self.assertEqual(a["smoke_cmd"], "bash tests/test_a.sh")
        self.assertEqual(a["related"], ["kit/foo.md", "pagent", "tests/test_a.sh"])
        self.assertEqual(a["added"], "2026-06-01")
        b = r["workflows"][1]
        self.assertEqual(b["title"], "Sửa bug B")
        self.assertEqual(b["flow"], ["Chỉ một bước."])
        self.assertEqual(b["related"], ["bar.sh"])

    def test_preamble_ignored(self):
        # Dòng "# Workflow Log — demo" trước section đầu không tạo workflow rỗng.
        self._put_workflow()
        r = srv.read_workflow(self.proj)
        self.assertEqual(r["workflows"][0]["title"], "Thêm tính năng A")

    def test_path_traversal_blocked(self):
        # proj chứa .. → _safe_join trả None → exists False, không đọc ngoài REPORTS.
        r = srv.read_workflow("../../etc")
        self.assertFalse(r["exists"])


class WorkflowRouteTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        srv.REPORTS = os.path.realpath(self.tmp)
        os.makedirs(os.path.join(self.tmp, "demo"), exist_ok=True)
        shutil.copy(FIXTURE, os.path.join(self.tmp, "demo", "workflow.md"))
        self.s = ThreadingHTTPServer(("127.0.0.1", 0), srv.H)
        threading.Thread(target=self.s.serve_forever, daemon=True).start()
        self.port = self.s.server_address[1]

    def tearDown(self):
        self.s.shutdown(); shutil.rmtree(self.tmp, ignore_errors=True)

    def _get(self, path):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("GET", path); resp = c.getresponse()
        import json
        return resp.status, json.loads(resp.read())

    def test_route_returns_workflows(self):
        st, body = self._get("/api/projects/demo/workflow")
        self.assertEqual(st, 200)
        self.assertTrue(body["exists"])
        self.assertEqual(len(body["workflows"]), 2)

    def test_route_invalid_project(self):
        st, body = self._get("/api/projects/nope/workflow")
        self.assertEqual(st, 400)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Chạy test, xác nhận FAIL**

Run: `python3 tests/test_web_workflow.py`
Expected: FAIL — `AttributeError: module 'server' has no attribute 'read_workflow'`.

- [ ] **Step 3: Thêm `read_workflow` vào `server.py`**

Chèn sau hàm `task_detail` (~dòng 193):

```python
def read_workflow(proj):
    """Đọc + parse REPORTS/<proj>/workflow.md thành list section có cấu trúc.
    Trả {exists, path, workflows:[{title, trigger, preconditions, flow[], expected,
    smoke_cmd, related[], added}]}. File thiếu / proj traversal → exists=False.
    Chỉ đọc + parse; smoke_cmd chỉ để hiển thị (web không chạy)."""
    path = _safe_join(REPORTS, proj, "workflow.md")
    if not path or not os.path.isfile(path):
        return {"exists": False, "path": path or "", "workflows": []}
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()

    def _field(line, label):
        m = re.match(r"^\*\*" + re.escape(label) + r":\*\*\s*(.*)$", line)
        return m.group(1).strip() if m else None

    workflows, cur, in_flow = [], None, False
    for line in lines:
        h = re.match(r"^##\s+(.*)$", line)
        if h:
            cur = {"title": h.group(1).strip(), "trigger": "", "preconditions": "",
                   "flow": [], "expected": "", "smoke_cmd": "", "related": [], "added": ""}
            workflows.append(cur)
            in_flow = False
            continue
        if cur is None:
            continue  # bỏ preamble (# Workflow Log …)
        for label, key in (("Trigger", "trigger"), ("Preconditions", "preconditions"),
                           ("Expected outcome", "expected"), ("Added", "added")):
            v = _field(line, label)
            if v is not None:
                cur[key] = v; in_flow = False; break
        else:
            v = _field(line, "Smoke test command")
            if v is not None:
                mb = re.search(r"`([^`]+)`", v)
                cur["smoke_cmd"] = mb.group(1).strip() if mb else v.strip("` ")
                in_flow = False; continue
            v = _field(line, "Related files")
            if v is not None:
                cur["related"] = [x.strip() for x in v.split(",") if x.strip()]
                in_flow = False; continue
            if re.match(r"^\*\*Flow:\*\*", line):
                in_flow = True; continue
            if in_flow:
                fm = re.match(r"^\s*\d+\.\s+(.*)$", line)
                if fm:
                    cur["flow"].append(fm.group(1).strip())
                elif line.strip() != "":
                    in_flow = False
    return {"exists": True, "path": path, "workflows": workflows}
```

> Lưu ý cú pháp: khối `for label,key in (...): ... else:` dùng **for-else** — nhánh `else` chạy khi
> vòng for KHÔNG `break` (tức không khớp 4 field đơn giản), khi đó mới thử Smoke/Related/Flow.

- [ ] **Step 4: Thêm route trong `do_GET`**

Trong `server.py` `do_GET`, tuple `for suffix, fn in (...)` (~dòng 699-706), thêm dòng (sau `/agents`):

```python
                (r"/workflow",     lambda p:    self._j(read_workflow(p))),
```

- [ ] **Step 5: Chạy test, xác nhận PASS**

Run: `python3 tests/test_web_workflow.py`
Expected: `Ran 6 tests` … `OK`.

- [ ] **Step 6: Commit**

```bash
git add kit/web/server.py tests/test_web_workflow.py tests/fixtures/workflow-sample.md
git commit -m "feat(web): read_workflow + /api/projects/<proj>/workflow endpoint"
```

---

## Task 2: Frontend workflow view + reuse

**Files:**
- Modify: `kit/web/index.html` (thêm section sau `chat-section`, ~dòng 56), `kit/web/app.js` (thêm functions + wiring), `kit/web/style.css` (thêm `.wf-*`)

**Interfaces:**
- Consumes: `GET /api/projects/<proj>/workflow` (Task 1) → `{exists, path, workflows[]}`.
- Produces: (UI) section `#workflow-section` + `#workflow-list`; hàm `loadWorkflows(proj)`, `renderWorkflows(data)`, `reuseWorkflow(title)`. Reuse: set mode `feature` + `#task-input` = `Làm tương tự "<title>". Cụ thể: ` + focus.

- [ ] **Step 1: Thêm section vào `index.html`**

Chèn NGAY SAU `</section>` của `chat-section` (dòng 56, trước `<section id="live-section">`):

```html
  <section id="workflow-section">
    <div class="section-head">
      <h2>Workflows <small class="dim" id="workflow-count"></small></h2>
    </div>
    <div id="workflow-list"></div>
  </section>
```

- [ ] **Step 2: Thêm functions vào `app.js`**

Thêm 3 hàm (đặt gần `renderAgents`/`renderHistory`, vd trước dòng `// wiring` ~dòng 645):

```javascript
// ───────── Workflows ─────────
async function loadWorkflows(proj) {
  if (!proj) return;
  try {
    const data = await j(`/api/projects/${encodeURIComponent(proj)}/workflow`);
    renderWorkflows(data);
  } catch (e) { /* transient; bỏ qua */ }
}

function renderWorkflows(data) {
  const list = $('#workflow-list');
  const count = $('#workflow-count');
  const wfs = (data && data.workflows) || [];
  if (!data || !data.exists || !wfs.length) {
    list.innerHTML = '<div class="idle-msg">Chưa có workflow — chạy 1 feature để sinh.</div>';
    count.textContent = '';
    return;
  }
  count.textContent = wfs.length;
  list.innerHTML = wfs.map((w, i) => {
    const flow = (w.flow || []).map(s => `<li>${esc(s)}</li>`).join('');
    const related = (w.related || []).map(r => `<code>${esc(r)}</code>`).join(' ');
    return `<div class="wf-card">
      <div class="wf-head">
        <span class="wf-title">${esc(w.title)}</span>
        <span class="wf-added dim">${esc(w.added || '')}</span>
        <button class="wf-reuse" data-title="${esc(w.title)}" title="Prefill composer để chạy task tương tự">Dùng lại ↑</button>
      </div>
      ${w.trigger ? `<div class="wf-trigger"><b>Trigger:</b> ${esc(w.trigger)}</div>` : ''}
      ${flow ? `<button class="wf-flow-toggle" data-i="${i}">Flow (${(w.flow||[]).length}) ▸</button>
                <ol class="wf-flow hidden" data-i="${i}">${flow}</ol>` : ''}
      ${w.smoke_cmd ? `<div class="wf-smoke"><b>Smoke:</b> <code>${esc(w.smoke_cmd)}</code></div>` : ''}
      ${related ? `<div class="wf-related dim">${related}</div>` : ''}
    </div>`;
  }).join('');
}

function reuseWorkflow(title) {
  setMode('feature');
  const ta = $('#task-input');
  ta.value = `Làm tương tự "${title}". Cụ thể: `;
  autoGrow();
  updateSendState();
  ta.focus();
  ta.setSelectionRange(ta.value.length, ta.value.length);
  $('#chat-section').scrollIntoView({ behavior: 'smooth', block: 'start' });
}
```

- [ ] **Step 3: Wire vào lifecycle + delegation trong `app.js`**

3a. Trong `switchProject` (sau `refresh();` ~dòng 91), thêm:
```javascript
  loadWorkflows(newProj);
```

3b. Đổi handler `#refresh-btn` (dòng `$('#refresh-btn').addEventListener('click', refresh);` ~667) thành:
```javascript
$('#refresh-btn').addEventListener('click', () => { refresh(); loadWorkflows(project); });
```

3c. Thêm event delegation cho `#workflow-list` (đặt cạnh các listener khác, ~dòng 676):
```javascript
$('#workflow-list').addEventListener('click', (e) => {
  const reuse = e.target.closest('.wf-reuse');
  if (reuse) { reuseWorkflow(reuse.dataset.title); return; }
  const tog = e.target.closest('.wf-flow-toggle');
  if (tog) {
    const ol = $(`#workflow-list .wf-flow[data-i="${tog.dataset.i}"]`);
    if (ol) { ol.classList.toggle('hidden'); tog.textContent = tog.textContent.replace(/[▸▾]/, ol.classList.contains('hidden') ? '▸' : '▾'); }
  }
});
```

- [ ] **Step 4: Thêm CSS vào `style.css`**

Thêm cuối `kit/web/style.css`:

```css
/* ───────── Workflows ───────── */
#workflow-list { display: flex; flex-direction: column; gap: 8px; }
.wf-card {
  background: var(--panel-2); border: 1px solid var(--border);
  border-left: 3px solid var(--feature); border-radius: 6px; padding: 10px 14px;
}
.wf-head { display: flex; align-items: center; gap: 10px; }
.wf-title { font-weight: 600; }
.wf-added { font-size: 11px; margin-left: auto; }
.wf-reuse {
  background: var(--panel); color: var(--accent); border: 1px solid var(--border);
  padding: 3px 10px; border-radius: 6px; font-size: 12px; cursor: pointer;
}
.wf-reuse:hover { border-color: var(--accent); }
.wf-trigger, .wf-smoke, .wf-related { margin-top: 6px; font-size: 12px; }
.wf-flow-toggle {
  margin-top: 6px; background: none; border: none; color: var(--dim);
  padding: 0; font-size: 12px; cursor: pointer;
}
.wf-flow-toggle:hover { color: var(--accent); }
.wf-flow { margin: 6px 0 0; padding-left: 20px; font-size: 12px; color: var(--text); }
.wf-flow.hidden { display: none; }
.wf-smoke code, .wf-related code { font-family: var(--mono); font-size: 11px; background: var(--panel); padding: 1px 5px; border-radius: 4px; }
```

> `.hidden` có thể đã tồn tại (modal dùng). Nếu có, `.wf-flow.hidden{display:none}` vẫn đúng; giữ.

- [ ] **Step 5: Verify — syntax + static + manual smoke**

```bash
# JS/HTML syntax (node có sẵn vì opencode chạy trên node)
node --check kit/web/app.js && echo "app.js OK"
# static: các mảnh đã có mặt
grep -q 'id="workflow-section"' kit/web/index.html && echo "html OK"
grep -q 'function reuseWorkflow' kit/web/app.js && grep -q 'loadWorkflows' kit/web/app.js && echo "js fns OK"
grep -q '.wf-card' kit/web/style.css && echo "css OK"
# backend test vẫn xanh
python3 tests/test_web_workflow.py
```
Expected: tất cả in "OK" / test `OK`.

**Manual smoke (bắt buộc, ghi lại kết quả):** chạy dashboard trỏ vào reports thật có workflow.md:
```bash
PAGENT_REPORT_DIR="$HOME/.pagent-reports" PORT=8799 python3 kit/web/server.py &
SRV=$!; sleep 1
curl -s "http://127.0.0.1:8799/api/projects/pipelineAgent/workflow" | python3 -m json.tool | head -30
kill $SRV
```
Expected: JSON có `"exists": true` + list `workflows` với title/flow/smoke_cmd. (Kiểm giao diện + nút "Dùng lại" prefill đúng chuỗi bằng mở trình duyệt `http://127.0.0.1:8799` nếu môi trường cho phép; nếu không, xác nhận qua đọc code + curl và ghi rõ phần UI cần user kiểm thủ công.)

- [ ] **Step 6: Commit**

```bash
git add kit/web/index.html kit/web/app.js kit/web/style.css
git commit -m "feat(web): workflow view + 'Dùng lại' prefill composer"
```

---

## Task 3: Regression

- [ ] **Step 1: Chạy toàn bộ test web + battery**

```bash
python3 tests/test_web_workflow.py
python3 tests/test_server_chat_upload.py
for t in tests/*.sh; do bash "$t" >/dev/null 2>&1 || echo "FAIL: $t"; done
node --check kit/web/app.js && echo "app.js syntax OK"
```
Expected: 2 python suite `OK`; không `FAIL:`; app.js OK. (Các test bash không liên quan web nhưng chạy để chắc không vỡ gì.)

---

## Self-Review

**Spec coverage:**
- Mục 3.1 (read_workflow + route) → Task 1. ✓
- Mục 3.2 (section + renderWorkflows + reuseWorkflow + load strategy + delegation) → Task 2 Steps 1-3. ✓
- Mục 2 (prefill chuỗi chính xác + mode feature) → Task 2 Step 2 `reuseWorkflow`. ✓
- Mục 4 (error/traversal) → Task 1 (`_safe_join`, missing→exists False) + test path-traversal. ✓
- Mục 5 (test) → Task 1 (`test_web_workflow.py`) + Task 2 Step 5 (syntax/static/manual) + Task 3. ✓
- Mục 6 (YAGNI ngoài phạm vi) → không có task nào thêm edit/run. ✓

**Placeholder scan:** không TBD/TODO; mọi step có code/lệnh đầy đủ. Manual smoke (Task 2 Step 5) có lệnh cụ thể + nêu rõ phần UI cần user kiểm nếu không mở được browser — không phải placeholder.

**Type consistency:** `read_workflow` trả `{exists, path, workflows[]}` với field `{title, trigger, preconditions, flow[], expected, smoke_cmd, related[], added}` — dùng nhất quán ở test (Task 1) và `renderWorkflows` (Task 2). Route path `/workflow` khớp `loadWorkflows` fetch. `reuseWorkflow` dùng `setMode`/`autoGrow`/`updateSendState` (đã tồn tại trong app.js). Prefill chuỗi khớp Global Constraints.
