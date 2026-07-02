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
        self.assertEqual(a["preconditions"], "File `foo.md` tồn tại; gate bật.")
        self.assertEqual(a["expected"], "Kết quả đúng; 10/10 test pass.")
        b = r["workflows"][1]
        self.assertEqual(b["title"], "Sửa bug B")
        self.assertEqual(b["flow"], ["Chỉ một bước."])
        self.assertEqual(b["related"], ["bar.sh"])
        self.assertEqual(b["preconditions"], "")
        self.assertEqual(b["expected"], "Bug hết.")
        self.assertEqual(b["smoke_cmd"], "echo ok")
        self.assertEqual(b["added"], "2026-06-02")

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
        self.s.shutdown()
        self.s.server_close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _get(self, path):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        try:
            c.request("GET", path)
            resp = c.getresponse()
            import json
            return resp.status, json.loads(resp.read())
        finally:
            c.close()

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
