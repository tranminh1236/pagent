#!/usr/bin/env python3
"""Tests for kit/web/server.py — settings per-project (công tắc backend web).

Spec: docs/superpowers/specs/2026-07-04-backend-switch-design.md
- GET/POST /api/projects/<proj>/settings → REPORTS/<proj>/settings.json (atomic).
- _spawn_pagent inject PAGENT_PROVIDER/PAGENT_CLAUDE_MODEL từ settings;
  settings ĐÈ os.environ kế thừa; env_extra nội bộ đè settings.
"""
import json, os, sys, tempfile, threading, unittest
from unittest.mock import patch, MagicMock
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
    pdir = os.path.join(tmpdir, proj)
    os.makedirs(pdir, exist_ok=True)
    src = os.path.join(tmpdir, "_src_" + proj)
    os.makedirs(src, exist_ok=True)
    with open(os.path.join(pdir, ".source"), "w") as f:
        f.write(src + "\n")
    return src


def _req(port, method, path, payload=None):
    body = json.dumps(payload).encode() if payload is not None else None
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    conn.request(method, path, body=body,
                 headers={"Content-Type": "application/json"} if body else {})
    resp = conn.getresponse()
    data = json.loads(resp.read())
    conn.close()
    return resp.status, data


class TestSettingsEndpoints(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="pagent_settings_test_")
        cls.proj = "setproj"
        cls.src = _make_proj(cls.tmp, cls.proj)
        cls.server, cls.port = _start_server(cls.tmp)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        import shutil; shutil.rmtree(cls.tmp, ignore_errors=True)

    def _get(self):
        return _req(self.port, "GET", f"/api/projects/{self.proj}/settings")

    def _post(self, payload):
        return _req(self.port, "POST", f"/api/projects/{self.proj}/settings", payload)

    def test_get_defaults(self):
        status, data = self._get()
        self.assertEqual(status, 200)
        self.assertEqual(data.get("provider"), "opencode")
        self.assertEqual(data.get("claude_model"), "sonnet")

    def test_post_persists_and_merges(self):
        status, data = self._post({"provider": "claude"})
        self.assertEqual(status, 200, data)
        self.assertEqual(data["provider"], "claude")
        # persist trên đĩa
        with open(os.path.join(self.tmp, self.proj, "settings.json")) as f:
            self.assertEqual(json.load(f)["provider"], "claude")
        # merge: đổi claude_model, provider giữ nguyên
        status, data = self._post({"claude_model": "opus"})
        self.assertEqual(status, 200, data)
        self.assertEqual(data["provider"], "claude")
        self.assertEqual(data["claude_model"], "opus")
        # GET phản ánh
        status, data = self._get()
        self.assertEqual(data["provider"], "claude")
        self.assertEqual(data["claude_model"], "opus")
        # reset về opencode cho các test sau
        self._post({"provider": "opencode", "claude_model": "sonnet"})

    def test_post_rejects_bad_provider(self):
        for bad in ("gpt", "", 5, "claude/opus"):
            status, data = self._post({"provider": bad})
            self.assertEqual(status, 400, f"provider={bad!r}: {data}")

    def test_post_rejects_provider_model_form_for_claude_model(self):
        status, data = self._post({"claude_model": "9router/Claude"})
        self.assertEqual(status, 400, data)
        status, data = self._post({"claude_model": "x" * 100})
        self.assertEqual(status, 400, data)

    def test_post_ignores_unknown_fields(self):
        status, data = self._post({"provider": "opencode", "hacker": "1"})
        self.assertEqual(status, 200, data)
        self.assertNotIn("hacker", data)
        with open(os.path.join(self.tmp, self.proj, "settings.json")) as f:
            self.assertNotIn("hacker", json.load(f))

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


class TestSpawnInjectsSettings(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="pagent_settings_spawn_")
        import server as srv
        srv.REPORTS = os.path.realpath(self.tmp)
        self.srv = srv
        os.makedirs(os.path.join(self.tmp, "p"), exist_ok=True)

    def tearDown(self):
        import shutil; shutil.rmtree(self.tmp, ignore_errors=True)

    def _write_settings(self, obj):
        with open(os.path.join(self.tmp, "p", "settings.json"), "w") as f:
            json.dump(obj, f)

    def _spawn(self, env_extra=None):
        with patch("server.subprocess.Popen") as mock_popen, \
             patch("server._pagent_bin", return_value="/fake/pagent"):
            mock_popen.return_value = MagicMock()
            err, _ = self.srv._spawn_pagent("p", self.tmp, "feature", "t",
                                            "20260704T000001-1-0001",
                                            env_extra=env_extra)
            self.assertIsNone(err, err)
            return mock_popen.call_args[1]["env"]

    def test_spawn_injects_provider_and_model_from_settings(self):
        self._write_settings({"provider": "claude", "claude_model": "opus"})
        env = self._spawn()
        self.assertEqual(env.get("PAGENT_PROVIDER"), "claude")
        self.assertEqual(env.get("PAGENT_CLAUDE_MODEL"), "opus")

    def test_settings_override_inherited_environ(self):
        # env rơi rớt từ shell (bài học 9router/Claude) — ý định user từ web phải thắng
        self._write_settings({"provider": "claude"})
        with patch.dict(os.environ, {"PAGENT_PROVIDER": "opencode"}):
            env = self._spawn()
        self.assertEqual(env.get("PAGENT_PROVIDER"), "claude")

    def test_env_extra_overrides_settings(self):
        self._write_settings({"provider": "claude"})
        env = self._spawn(env_extra={"PAGENT_PROVIDER": "opencode"})
        self.assertEqual(env.get("PAGENT_PROVIDER"), "opencode")

    def test_no_settings_file_no_injection(self):
        env_clean = {k: v for k, v in os.environ.items() if k != "PAGENT_PROVIDER"}
        with patch.dict(os.environ, env_clean, clear=True):
            env = self._spawn()
        self.assertNotIn("PAGENT_PROVIDER", env)

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

    def test_spawn_injects_default_opencode_model_without_settings_file(self):
        # KHÔNG có settings.json → default merge 9router/FREE vẫn override PAGENT_MODEL leak
        with patch.dict(os.environ, {"PAGENT_MODEL": "9router/Claude"}):
            env = self._spawn()
        self.assertEqual(env.get("PAGENT_MODEL"), "9router/FREE")


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


if __name__ == "__main__":
    unittest.main(verbosity=2)
