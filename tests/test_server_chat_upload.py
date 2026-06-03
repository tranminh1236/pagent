#!/usr/bin/env python3
"""Tests for kit/web/server.py — chat, upload, security, regression."""
import io, json, os, sys, tempfile, threading, unittest
from unittest.mock import patch, MagicMock
import urllib.request, urllib.error

# Make server importable
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "kit", "web"))

# ──────────────────────────────────────────
# Helpers: spin up the server in a thread
# ──────────────────────────────────────────
from http.server import ThreadingHTTPServer
import http.client


def _start_server(tmpdir):
    """Start H on a free port against tmpdir as REPORTS. Returns (server, port)."""
    import server as srv
    srv.REPORTS = os.path.realpath(tmpdir)
    # patch list_projects to avoid filesystem races
    server_mod = srv
    from functools import partial

    class _H(srv.H):
        pass

    s = ThreadingHTTPServer(("127.0.0.1", 0), _H)
    t = threading.Thread(target=s.serve_forever, daemon=True)
    t.start()
    return s, s.server_address[1]


def _make_proj(tmpdir, proj):
    """Create minimal project structure inside REPORTS."""
    pdir = os.path.join(tmpdir, proj)
    os.makedirs(pdir, exist_ok=True)
    # Write a real source path (a tmpdir subdir that exists)
    src = os.path.join(tmpdir, "_src_" + proj)
    os.makedirs(src, exist_ok=True)
    with open(os.path.join(pdir, ".source"), "w") as f:
        f.write(src + "\n")
    return src


def _post_json(port, path, payload):
    body = json.dumps(payload).encode()
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    conn.request("POST", path, body=body,
                 headers={"Content-Type": "application/json",
                          "Content-Length": str(len(body))})
    resp = conn.getresponse()
    data = json.loads(resp.read())
    conn.close()
    return resp.status, data


def _post_multipart(port, path, fields, filename, filecontent, content_type="image/png"):
    boundary = b"----TESTBOUNDARY"
    body = b""
    for k, v in fields.items():
        body += b"--" + boundary + b"\r\n"
        body += f'Content-Disposition: form-data; name="{k}"\r\n\r\n'.encode()
        body += v.encode() + b"\r\n"
    if filename is not None:
        body += b"--" + boundary + b"\r\n"
        body += f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'.encode()
        body += f"Content-Type: {content_type}\r\n\r\n".encode()
        body += filecontent + b"\r\n"
    body += b"--" + boundary + b"--\r\n"

    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    conn.request("POST", path, body=body, headers={
        "Content-Type": f"multipart/form-data; boundary={boundary.decode()}",
        "Content-Length": str(len(body)),
    })
    resp = conn.getresponse()
    data = json.loads(resp.read())
    conn.close()
    return resp.status, data


# ──────────────────────────────────────────
# Test suite
# ──────────────────────────────────────────
class TestChatEndpoint(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="pagent_test_")
        cls.proj = "testproj"
        cls.src = _make_proj(cls.tmp, cls.proj)
        cls.server, cls.port = _start_server(cls.tmp)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        import shutil; shutil.rmtree(cls.tmp, ignore_errors=True)

    # ── invalid project → not 200 (404 from routing or 400 from validator) ──
    def test_invalid_project_url_traversal_rejected(self):
        # URL path /api/projects/../../etc/chat — routing regex won't match
        # multi-segment traversal, so server returns 404 (not routed), not 200.
        status, data = _post_json(self.port, "/api/projects/../../etc/chat",
                                  {"mode": "feature", "task": "x"})
        self.assertNotEqual(status, 200)
        self.assertIn("error", data)

    def test_unknown_project_returns_400(self):
        status, data = _post_json(self.port, "/api/projects/doesnotexist/chat",
                                  {"mode": "feature", "task": "x"})
        self.assertEqual(status, 400)

    # ── bad mode → 400 ──
    def test_bad_mode_returns_400(self):
        status, data = _post_json(self.port, f"/api/projects/{self.proj}/chat",
                                  {"mode": "hack", "task": "x"})
        self.assertEqual(status, 400)
        self.assertIn("mode", data["error"])

    # ── empty task → 400 ──
    def test_empty_task_returns_400(self):
        status, data = _post_json(self.port, f"/api/projects/{self.proj}/chat",
                                  {"mode": "feature", "task": "  "})
        self.assertEqual(status, 400)
        self.assertIn("task", data["error"])

    # ── happy path: feature → spawns pagent, returns task_id ──
    def test_chat_feature_returns_task_id(self):
        with patch("server.subprocess.Popen") as mock_popen, \
             patch("server._pagent_bin", return_value="/fake/pagent"):
            mock_popen.return_value = MagicMock()
            status, data = _post_json(self.port, f"/api/projects/{self.proj}/chat",
                                      {"mode": "feature", "task": "add login button"})
        self.assertEqual(status, 200, data)
        self.assertTrue(data.get("ok"))
        self.assertIn("task_id", data)
        self.assertEqual(data["mode"], "feature")

    # ── happy path: fix → spawns pagent ──
    def test_chat_fix_returns_task_id(self):
        with patch("server.subprocess.Popen") as mock_popen, \
             patch("server._pagent_bin", return_value="/fake/pagent"):
            mock_popen.return_value = MagicMock()
            status, data = _post_json(self.port, f"/api/projects/{self.proj}/chat",
                                      {"mode": "fix", "task": "fix crash on login"})
        self.assertEqual(status, 200, data)
        self.assertEqual(data["mode"], "fix")
        self.assertIn("task_id", data)

    # ── Popen called with correct mode arg ──
    def test_chat_popen_receives_mode_arg(self):
        with patch("server.subprocess.Popen") as mock_popen, \
             patch("server._pagent_bin", return_value="/fake/pagent"):
            mock_popen.return_value = MagicMock()
            _post_json(self.port, f"/api/projects/{self.proj}/chat",
                       {"mode": "fix", "task": "crash fix"})
            args = mock_popen.call_args[0][0]  # first positional → cmd list
        self.assertIn("fix", args)

    # ── figma_url present → design=True ──
    def test_chat_figma_url_sets_design_flag(self):
        with patch("server.subprocess.Popen") as mock_popen, \
             patch("server._pagent_bin", return_value="/fake/pagent"):
            mock_popen.return_value = MagicMock()
            status, data = _post_json(self.port, f"/api/projects/{self.proj}/chat",
                                      {"mode": "feature", "task": "match figma",
                                       "figma_url": "https://figma.com/file/abc"})
        self.assertEqual(status, 200)
        self.assertTrue(data.get("design"))

    # ── task text contains figma_url when provided ──
    def test_compose_task_includes_figma_url(self):
        import server as srv
        result = srv._compose_task("my task", [], "https://figma.com/file/xyz")
        self.assertIn("https://figma.com/file/xyz", result)
        self.assertIn("FIGMA", result)

    # ── task text contains image path ──
    def test_compose_task_includes_image_path(self):
        import server as srv
        result = srv._compose_task("task", ["/tmp/shot.png"], "")
        self.assertIn("/tmp/shot.png", result)
        self.assertIn("ảnh", result)

    # ── no pagent binary → 500 ──
    def test_no_pagent_bin_returns_500(self):
        with patch("server._pagent_bin", return_value=None):
            status, data = _post_json(self.port, f"/api/projects/{self.proj}/chat",
                                      {"mode": "feature", "task": "something"})
        self.assertEqual(status, 500)

    # ── malformed Content-Length → reads 0 bytes, no crash ──
    def test_malformed_content_length_no_crash(self):
        """_read_body must handle non-int Content-Length gracefully (new fix)."""
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("POST", f"/api/projects/{self.proj}/chat",
                     body=b'{"mode":"feature","task":"x"}',
                     headers={"Content-Type": "application/json",
                              "Content-Length": "NOT_A_NUMBER"})
        resp = conn.getresponse()
        # Server must not crash — any HTTP response is acceptable
        self.assertIn(resp.status, (400, 200, 409, 500))
        conn.close()


class TestUploadEndpoint(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="pagent_upload_test_")
        cls.proj = "uploadproj"
        _make_proj(cls.tmp, cls.proj)
        cls.server, cls.port = _start_server(cls.tmp)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        import shutil; shutil.rmtree(cls.tmp, ignore_errors=True)

    # ── happy path: image saved to uploads/<task>/ ──
    def test_upload_saves_file_to_uploads_dir(self):
        status, data = _post_multipart(
            self.port, f"/api/projects/{self.proj}/upload",
            fields={"task": "task001"},
            filename="screenshot.png",
            filecontent=b"\x89PNG\r\n",
        )
        self.assertEqual(status, 200, data)
        self.assertTrue(data.get("ok"))
        dest = data["path"]
        self.assertTrue(os.path.isfile(dest), f"file not on disk: {dest}")
        self.assertIn("uploads", dest)
        self.assertIn("task001", dest)
        self.assertTrue(data["is_image"])

    # ── path traversal in filename: server neutralizes via basename, stores safely ──
    def test_upload_path_traversal_in_filename_neutralized(self):
        # os.path.basename strips "../../../etc/" → stores as "passwd" in the
        # correct uploads dir, never outside REPORTS.
        status, data = _post_multipart(
            self.port, f"/api/projects/{self.proj}/upload",
            fields={"task": "task001"},
            filename="../../../etc/passwd",
            filecontent=b"evil",
        )
        if status == 200:
            # Verify the stored path is inside REPORTS (traversal was neutralized)
            import server as srv
            stored = data["path"]
            self.assertTrue(os.path.realpath(stored).startswith(
                os.path.realpath(self.tmp)), f"path escaped REPORTS: {stored}")
            self.assertEqual(data["name"], "passwd")
        else:
            # Outright rejection (400) is also acceptable
            self.assertEqual(status, 400)

    # ── path traversal in task field rejected ──
    def test_upload_rejects_dotdot_in_task(self):
        status, data = _post_multipart(
            self.port, f"/api/projects/{self.proj}/upload",
            fields={"task": "../evil"},
            filename="ok.png",
            filecontent=b"data",
        )
        self.assertEqual(status, 400, data)

    # ── missing file part ──
    def test_upload_missing_file_part_returns_400(self):
        boundary = b"----TESTBOUNDARY2"
        body = b"--" + boundary + b"\r\n"
        body += b'Content-Disposition: form-data; name="task"\r\n\r\ntask001\r\n'
        body += b"--" + boundary + b"--\r\n"
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("POST", f"/api/projects/{self.proj}/upload", body=body, headers={
            "Content-Type": f"multipart/form-data; boundary={boundary.decode()}",
            "Content-Length": str(len(body)),
        })
        resp = conn.getresponse()
        data = json.loads(resp.read())
        conn.close()
        self.assertEqual(resp.status, 400)

    # ── invalid project → 400 before processing ──
    def test_upload_invalid_project_returns_400(self):
        status, data = _post_multipart(
            self.port, "/api/projects/../upload",
            fields={"task": "t1"},
            filename="f.png",
            filecontent=b"x",
        )
        self.assertEqual(status, 400)


class TestProjectSourceSecurity(unittest.TestCase):
    """Unit tests for _project_source path traversal protection (new fix)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="pagent_src_test_")
        import server as srv
        srv.REPORTS = os.path.realpath(self.tmp)
        self.srv = srv

    def tearDown(self):
        import shutil; shutil.rmtree(self.tmp, ignore_errors=True)

    def test_valid_source_file_is_read(self):
        proj = "goodproj"
        pdir = os.path.join(self.tmp, proj)
        os.makedirs(pdir)
        src_path = os.path.join(self.tmp, "src")
        os.makedirs(src_path)
        with open(os.path.join(pdir, ".source"), "w") as f:
            f.write(src_path + "\n")
        result = self.srv._project_source(proj)
        self.assertEqual(result, src_path)

    def test_path_traversal_proj_returns_none(self):
        # _safe_join should block a traversal attempt
        result = self.srv._project_source("../../../etc")
        self.assertIsNone(result)

    def test_missing_source_file_returns_none(self):
        proj = "noproj"
        os.makedirs(os.path.join(self.tmp, proj))
        result = self.srv._project_source(proj)
        self.assertIsNone(result)


class TestGetRegression(unittest.TestCase):
    """do_GET endpoints must not be broken by the new changes."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="pagent_get_test_")
        cls.server, cls.port = _start_server(cls.tmp)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        import shutil; shutil.rmtree(cls.tmp, ignore_errors=True)

    def _get(self, path):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("GET", path)
        resp = conn.getresponse()
        body = resp.read()
        conn.close()
        return resp.status, body

    def test_get_projects_returns_200_json_list(self):
        status, body = self._get("/api/projects")
        self.assertEqual(status, 200)
        data = json.loads(body)
        self.assertIsInstance(data, list)

    def test_get_root_returns_html(self):
        status, body = self._get("/")
        # 200 if index.html exists, 404 if not — both are fine; must not 500
        self.assertIn(status, (200, 404))

    def test_get_unknown_route_returns_404(self):
        status, body = self._get("/api/nonexistent")
        self.assertEqual(status, 404)

    def test_get_invalid_project_tasks_returns_400(self):
        status, body = self._get("/api/projects/../tasks")
        # either 400 (validation) or 404 (routing mismatch) — must not 200
        self.assertNotEqual(status, 200)


class TestReadBodyMalformedHeader(unittest.TestCase):
    """Unit-test _read_body directly for the ValueError/TypeError fix."""

    def _make_handler(self, content_length_value):
        import server as srv
        from io import BytesIO

        class FakeHeaders(dict):
            def get(self, key, default=None):
                return self.get_raw(key, default)
            def get_raw(self, key, default=None):
                return super().get(key, default)

        class FakeHeaders2:
            def __init__(self, cl):
                self._cl = cl
            def get(self, key, default=None):
                if key == "Content-Length":
                    return self._cl
                return default

        # Build a minimal handler-like object
        h = object.__new__(srv.H)
        h.headers = FakeHeaders2(content_length_value)
        h.rfile = BytesIO(b"")
        return h

    def test_integer_string_works(self):
        h = self._make_handler("10")
        # Should not raise; returns b"" because rfile is empty
        import server as srv
        result = srv.H._read_body(h)
        # 10 bytes requested but rfile empty — read returns b""
        self.assertIsNotNone(result)

    def test_not_a_number_returns_empty(self):
        h = self._make_handler("GARBAGE")
        import server as srv
        result = srv.H._read_body(h)
        self.assertEqual(result, b"")

    def test_none_content_length_returns_empty(self):
        h = self._make_handler(None)
        import server as srv
        result = srv.H._read_body(h)
        self.assertEqual(result, b"")


if __name__ == "__main__":
    unittest.main(verbosity=2)
