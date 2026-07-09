#!/usr/bin/env python3
"""Tests for kit/web/server.py — spawn KHÔNG validate PAGENT_MODEL.

Lịch sử: backend claude CLI từng chặn model prefix "9router/" (dạng opencode tự tham
chiếu gateway → claude 404). Từ 2026-07-04 backend mặc định là opencode CLI —
provider/model ("9router/Claude") là format ĐÚNG, spawn phải chấp nhận mọi dạng model
(provider claude ẩn tự chịu trách nhiệm model hợp lệ).
Spec: docs/superpowers/specs/2026-07-04-opencode-backend-design.md
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


class TestModelPassthroughOnSpawn(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="pagent_model_test_")
        cls.proj = "modelproj"
        cls.src = _make_proj(cls.tmp, cls.proj)
        cls.server, cls.port = _start_server(cls.tmp)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        import shutil; shutil.rmtree(cls.tmp, ignore_errors=True)

    def _chat(self):
        return _post_json(self.port, f"/api/projects/{self.proj}/chat",
                          {"mode": "feature", "task": "do a thing"})

    def _spawn_with_model(self, model):
        env = dict(os.environ)
        if model is None:
            env.pop("PAGENT_MODEL", None)
        else:
            env["PAGENT_MODEL"] = model
        with patch.dict(os.environ, env, clear=True), \
             patch("server.subprocess.Popen") as mock_popen, \
             patch("server._pagent_bin", return_value="/fake/pagent"):
            mock_popen.return_value = MagicMock()
            status, data = self._chat()
            return status, data, mock_popen

    # ── provider/model (chuẩn opencode) PHẢI tới pagent NGUYÊN VẸN — không sanitize ──
    # Nguồn model giờ là web settings (opencode_model), KHÔNG phải env passthrough:
    # _spawn_pagent đè PAGENT_MODEL bằng opencode_model → "web là nguồn sự thật".
    # Test này giữ bảo đảm cốt lõi: prefix "9router/" không bị gỡ (sanitizer claude cũ đã biến mất).
    # Spec: docs/superpowers/specs/2026-07-09-web-opencode-model-select-design.md
    def test_9router_provider_model_from_settings_not_sanitized(self):
        settings_path = os.path.join(self.tmp, self.proj, "settings.json")
        with open(settings_path, "w") as f:
            json.dump({"provider": "opencode", "opencode_model": "9router/Claude"}, f)
        try:
            status, data, mock_popen = self._spawn_with_model(None)
            self.assertEqual(status, 200, data)
            self.assertEqual(mock_popen.call_count, 1)
            env = mock_popen.call_args[1]["env"]
            self.assertEqual(env["PAGENT_MODEL"], "9router/Claude",
                             "opencode_model tới pagent nguyên vẹn — không sanitize prefix")
        finally:
            os.remove(settings_path)

    def test_chat_accepts_any_provider_model_form(self):
        for m in ("cc/claude-opus-4-8", "gemini/gemini-3-flash-preview", "Claude"):
            status, data, mock_popen = self._spawn_with_model(m)
            self.assertEqual(status, 200, f"model={m}: {data}")
            self.assertEqual(mock_popen.call_count, 1, f"model={m}")

    def test_chat_accepts_unset_model(self):
        status, data, mock_popen = self._spawn_with_model(None)
        self.assertEqual(status, 200, data)
        self.assertEqual(mock_popen.call_count, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
