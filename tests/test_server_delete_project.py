#!/usr/bin/env python3
"""Tests for kit/web/server.py — soft-delete project from the dashboard.

Spec: docs/superpowers/specs/2026-07-06-web-delete-project-design.md
- POST /api/projects/<proj>/delete → mv REPORTS/<proj> → REPORTS/.trash/<proj>-<ts>.
- Blocked (409) when the project has a live run (live_tasks non-empty).
- Only touches REPORTS/<proj>; never the real source code.
- .trash is hidden from list_projects (dirs starting with '.').
"""
import json, os, sys, tempfile, threading, unittest
from unittest.mock import patch
import http.client
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "kit", "web"))


def _start_server(tmpdir):
    import server as srv
    srv.REPORTS = os.path.realpath(tmpdir)
    s = ThreadingHTTPServer(("127.0.0.1", 0), srv.H)
    t = threading.Thread(target=s.serve_forever, daemon=True)
    t.start()
    return s, s.server_address[1]


def _make_proj(tmpdir, proj):
    """Create REPORTS/<proj>/ with a report file + a .source pointing at a real src dir."""
    pdir = os.path.join(tmpdir, proj)
    os.makedirs(os.path.join(pdir, "features"), exist_ok=True)
    with open(os.path.join(pdir, "features", "x.md"), "w") as f:
        f.write("# report\n")
    src = os.path.join(tmpdir, "_src_" + proj)
    os.makedirs(src, exist_ok=True)
    with open(os.path.join(src, "code.txt"), "w") as f:
        f.write("real source\n")
    with open(os.path.join(pdir, ".source"), "w") as f:
        f.write(src + "\n")
    return src


def _req(port, method, path, payload=None):
    body = json.dumps(payload).encode() if payload is not None else None
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    conn.request(method, path, body=body,
                 headers={"Content-Type": "application/json"} if body else {})
    resp = conn.getresponse()
    raw = resp.read()
    try:
        data = json.loads(raw) if raw else {}
    except Exception:
        data = {"_raw": raw.decode("utf-8", "replace")}
    conn.close()
    return resp.status, data


class TestDeleteProject(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="pagent_delete_test_")
        self.server, self.port = _start_server(self.tmp)
        import server as srv
        self.srv = srv

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _delete(self, proj):
        return _req(self.port, "POST", f"/api/projects/{proj}/delete")

    def test_delete_moves_project_to_trash(self):
        _make_proj(self.tmp, "tmpproj")
        # sanity: listed before delete
        self.assertIn("tmpproj", self.srv.list_projects())

        status, data = self._delete("tmpproj")
        self.assertEqual(status, 200, data)
        self.assertTrue(data.get("ok"), data)

        # gone from the dashboard listing
        self.assertNotIn("tmpproj", self.srv.list_projects())
        # original project dir no longer where it was
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "tmpproj")))
        # moved under .trash/, name prefixed with the project name
        trash = os.path.join(self.tmp, ".trash")
        self.assertTrue(os.path.isdir(trash))
        entries = os.listdir(trash)
        self.assertTrue(any(e.startswith("tmpproj-") for e in entries), entries)
        # the report file survived the move
        moved = os.path.join(trash, entries[0], "features", "x.md")
        self.assertTrue(os.path.isfile(moved))

    def test_delete_never_touches_real_source(self):
        src = _make_proj(self.tmp, "withsrc")
        status, _ = self._delete("withsrc")
        self.assertEqual(status, 200)
        # the real source dir + its file must be untouched
        self.assertTrue(os.path.isfile(os.path.join(src, "code.txt")))

    def test_trash_dir_not_listed_as_project(self):
        _make_proj(self.tmp, "p1")
        status, _ = self._delete("p1")
        self.assertEqual(status, 200)
        # .trash now exists on disk but must never surface as a selectable project
        self.assertTrue(os.path.isdir(os.path.join(self.tmp, ".trash")))
        self.assertNotIn(".trash", self.srv.list_projects())

    def test_delete_blocked_when_running(self):
        _make_proj(self.tmp, "busyproj")
        with patch("server.live_tasks", return_value=[{"task_id": "t", "active": ["coder"]}]):
            status, data = self._delete("busyproj")
        self.assertEqual(status, 409, data)
        # project must still be intact (not moved)
        self.assertTrue(os.path.isdir(os.path.join(self.tmp, "busyproj")))
        self.assertIn("busyproj", self.srv.list_projects())

    def test_delete_rejects_unknown_project(self):
        status, data = self._delete("does-not-exist")
        self.assertEqual(status, 400, data)
        # nothing should have been created under .trash
        self.assertFalse(os.path.isdir(os.path.join(self.tmp, ".trash")))

    def test_delete_dotted_name_project(self):
        # Regression: bug screenshot — project có dấu '.' trong tên (tmp.a2ULCJDEBF)
        # từng trả '404/not found' vì tiến trình web chạy bản stale thiếu route delete.
        # Với server hiện tại: _PROJ_RE cho phép '.', route match → xoá thật (200 ok:true),
        # project biến khỏi list_projects(). Test này fail nếu regression tái hiện.
        proj = "tmp.a2ULCJDEBF"
        _make_proj(self.tmp, proj)
        self.assertIn(proj, self.srv.list_projects())

        status, data = self._delete(proj)
        self.assertEqual(status, 200, data)
        self.assertTrue(data.get("ok"), data)
        # cũ: 404 {"error":"not found"} — phải KHÔNG còn
        self.assertNotEqual(status, 404, data)
        self.assertNotIn("not found", json.dumps(data))

        self.assertNotIn(proj, self.srv.list_projects())
        self.assertFalse(os.path.exists(os.path.join(self.tmp, proj)))
        entries = os.listdir(os.path.join(self.tmp, ".trash"))
        self.assertTrue(any(e.startswith(proj + "-") for e in entries), entries)

    def test_delete_rejects_traversal_name(self):
        _make_proj(self.tmp, "victim")
        # url-encoded traversal must not escape REPORTS nor match a real project
        status, _ = _req(self.port, "POST", "/api/projects/..%2F..%2Fetc/delete")
        self.assertEqual(status, 400)
        self.assertTrue(os.path.isdir(os.path.join(self.tmp, "victim")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
