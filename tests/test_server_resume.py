#!/usr/bin/env python3
"""Tests for kit/web/server.py — resume gate endpoints (max_turns → cấp thêm lượt).

Spec: docs/superpowers/specs/2026-07-03-resume-max-turns-design.md
- GET  /api/projects/<proj>/resume/<tid>  → {pending: [{agent, session_id, used_turns, default_turns}]}
- POST /api/projects/<proj>/resume/<tid>  body {agent, extra_turns?, action?}
       → ghi runs/<tid>/resume.decision.<agent>.json (atomic) cho pagent poll.
- _spawn_pagent: setdefault PAGENT_RESUME=1 (web spawn luôn bật gate).
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


def _write_pending(tmpdir, proj, tid, agent, sid="sid-1", used=9, default=20):
    rundir = os.path.join(tmpdir, proj, "runs", tid)
    os.makedirs(rundir, exist_ok=True)
    p = os.path.join(rundir, f"resume.pending.{agent}.json")
    with open(p, "w") as f:
        json.dump({"agent": agent, "session_id": sid,
                   "used_turns": used, "default_turns": default}, f)
    return rundir


def _req(port, method, path, payload=None):
    body = json.dumps(payload).encode() if payload is not None else None
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    headers = {"Content-Type": "application/json"} if body else {}
    conn.request(method, path, body=body, headers=headers)
    resp = conn.getresponse()
    data = json.loads(resp.read())
    conn.close()
    return resp.status, data


class TestResumeEndpoints(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="pagent_resume_test_")
        cls.proj = "resproj"
        cls.src = _make_proj(cls.tmp, cls.proj)
        cls.server, cls.port = _start_server(cls.tmp)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        import shutil; shutil.rmtree(cls.tmp, ignore_errors=True)

    def _get(self, tid):
        return _req(self.port, "GET", f"/api/projects/{self.proj}/resume/{tid}")

    def _post(self, tid, payload):
        return _req(self.port, "POST", f"/api/projects/{self.proj}/resume/{tid}", payload)

    # ── GET pending ──
    def test_get_no_rundir_returns_empty(self):
        status, data = self._get("20260703T170000-1-0001")
        self.assertEqual(status, 200)
        self.assertEqual(data.get("pending"), [])

    def test_get_lists_pending_agents(self):
        tid = "20260703T170001-1-0002"
        _write_pending(self.tmp, self.proj, tid, "coder", used=30, default=30)
        _write_pending(self.tmp, self.proj, tid, "security", used=12, default=15)
        status, data = self._get(tid)
        self.assertEqual(status, 200)
        agents = {p["agent"]: p for p in data["pending"]}
        self.assertEqual(set(agents), {"coder", "security"})
        self.assertEqual(agents["coder"]["used_turns"], 30)
        self.assertEqual(agents["coder"]["default_turns"], 30)
        self.assertEqual(agents["security"]["session_id"], "sid-1")

    def test_get_skips_corrupt_pending(self):
        tid = "20260703T170002-1-0003"
        rundir = _write_pending(self.tmp, self.proj, tid, "coder")
        with open(os.path.join(rundir, "resume.pending.broken.json"), "w") as f:
            f.write("{đang ghi dở")
        status, data = self._get(tid)
        self.assertEqual(status, 200)
        self.assertEqual([p["agent"] for p in data["pending"]], ["coder"])

    # ── POST decision ──
    def test_post_writes_decision_atomic(self):
        tid = "20260703T170003-1-0004"
        rundir = _write_pending(self.tmp, self.proj, tid, "coder")
        status, data = self._post(tid, {"agent": "coder", "extra_turns": 25})
        self.assertEqual(status, 200, data)
        dec = os.path.join(rundir, "resume.decision.coder.json")
        self.assertTrue(os.path.isfile(dec))
        self.assertFalse(os.path.exists(dec + ".tmp"))
        with open(dec) as f:
            d = json.load(f)
        self.assertEqual(d, {"action": "resume", "extra_turns": 25})

    def test_post_clamps_extra_turns_to_ceiling(self):
        tid = "20260703T170004-1-0005"
        rundir = _write_pending(self.tmp, self.proj, tid, "coder")
        status, data = self._post(tid, {"agent": "coder", "extra_turns": 99999})
        self.assertEqual(status, 200, data)
        with open(os.path.join(rundir, "resume.decision.coder.json")) as f:
            self.assertEqual(json.load(f)["extra_turns"], 60)

    def test_post_missing_turns_uses_pending_default(self):
        tid = "20260703T170005-1-0006"
        rundir = _write_pending(self.tmp, self.proj, tid, "coder", default=33)
        status, data = self._post(tid, {"agent": "coder"})
        self.assertEqual(status, 200, data)
        with open(os.path.join(rundir, "resume.decision.coder.json")) as f:
            self.assertEqual(json.load(f)["extra_turns"], 33)

    def test_post_non_int_turns_returns_400(self):
        tid = "20260703T170006-1-0007"
        _write_pending(self.tmp, self.proj, tid, "coder")
        status, data = self._post(tid, {"agent": "coder", "extra_turns": "lots"})
        self.assertEqual(status, 400, data)

    def test_post_action_stop(self):
        tid = "20260703T170007-1-0008"
        rundir = _write_pending(self.tmp, self.proj, tid, "coder")
        status, data = self._post(tid, {"agent": "coder", "action": "stop"})
        self.assertEqual(status, 200, data)
        with open(os.path.join(rundir, "resume.decision.coder.json")) as f:
            self.assertEqual(json.load(f)["action"], "stop")

    def test_post_agent_not_pending_returns_409(self):
        tid = "20260703T170008-1-0009"
        _write_pending(self.tmp, self.proj, tid, "coder")
        status, data = self._post(tid, {"agent": "reviewer", "extra_turns": 10})
        self.assertEqual(status, 409, data)

    def test_post_rejects_unsafe_agent_name(self):
        tid = "20260703T170009-1-0010"
        _write_pending(self.tmp, self.proj, tid, "coder")
        for bad in ("../coder", "a/b", "", "co der", "x" * 200):
            status, data = self._post(tid, {"agent": bad, "extra_turns": 10})
            self.assertEqual(status, 400, f"agent={bad!r}: {data}")

    def test_post_invalid_tid_returns_400(self):
        status, data = self._post("bad..tid", {"agent": "coder", "extra_turns": 10})
        self.assertEqual(status, 400, data)

    def test_post_bad_action_returns_400(self):
        tid = "20260703T170010-1-0011"
        _write_pending(self.tmp, self.proj, tid, "coder")
        status, data = self._post(tid, {"agent": "coder", "action": "yolo"})
        self.assertEqual(status, 400, data)


class TestSpawnEnablesResumeGate(unittest.TestCase):
    """_spawn_pagent phải bật PAGENT_RESUME=1 mặc định (web spawn luôn có gate) —
    nhưng KHÔNG đè khi env đã set tường minh (vd PAGENT_RESUME=0 tắt chủ động)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="pagent_resume_spawn_")
        import server as srv
        srv.REPORTS = os.path.realpath(self.tmp)
        self.srv = srv
        os.makedirs(os.path.join(self.tmp, "p"), exist_ok=True)

    def tearDown(self):
        import shutil; shutil.rmtree(self.tmp, ignore_errors=True)

    def _spawn(self):
        with patch("server.subprocess.Popen") as mock_popen, \
             patch("server._pagent_bin", return_value="/fake/pagent"):
            mock_popen.return_value = MagicMock()
            err, status = self.srv._spawn_pagent("p", self.tmp, "feature", "t",
                                                 "20260703T170011-1-0012")
            self.assertIsNone(err, err)
            return mock_popen.call_args[1]["env"]

    def test_spawn_sets_resume_gate_default(self):
        env_clean = {k: v for k, v in os.environ.items() if k != "PAGENT_RESUME"}
        with patch.dict(os.environ, env_clean, clear=True):
            env = self._spawn()
        self.assertEqual(env.get("PAGENT_RESUME"), "1")

    def test_spawn_respects_explicit_off(self):
        with patch.dict(os.environ, {"PAGENT_RESUME": "0"}):
            env = self._spawn()
        self.assertEqual(env.get("PAGENT_RESUME"), "0")


if __name__ == "__main__":
    unittest.main(verbosity=2)
