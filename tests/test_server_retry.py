#!/usr/bin/env python3
"""Tests for kit/web/server.py — POST /api/projects/<proj>/retry/<tid>.

Retry re-spawns a dead-of-max_turns run: reads task+mode FROM DISK (runs/<tid>/),
clamps max_turns server-side, spawns a NEW tid via the shared _spawn_pagent helper.
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


def _setup_run(tmpdir, proj, tid, mode, task, terminal_reason="max_turns"):
    """Create runs/<tid>/{task.txt,mode.txt} + a tokens event pair whose end
    step carries `terminal_reason` (so the timeline reports why it died)."""
    rundir = os.path.join(tmpdir, proj, "runs", tid)
    os.makedirs(rundir, exist_ok=True)
    with open(os.path.join(rundir, "task.txt"), "w") as f:
        f.write(task + "\n")
    if mode is not None:
        with open(os.path.join(rundir, "mode.txt"), "w") as f:
            f.write(mode + "\n")
    tokdir = os.path.join(tmpdir, proj, "tokens")
    os.makedirs(tokdir, exist_ok=True)
    evs = [
        {"event": "start", "task_id": tid, "agent": "coder", "ts": "2026-07-03T10:00:00Z"},
        {"event": "end", "task_id": tid, "agent": "coder", "ts": "2026-07-03T10:05:00Z",
         "terminal_reason": terminal_reason},
    ]
    with open(os.path.join(tokdir, "2026-07-03.jsonl"), "w") as f:
        for e in evs:
            f.write(json.dumps(e) + "\n")
    return rundir


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


class TestRetryEndpoint(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="pagent_retry_test_")
        cls.proj = "retryproj"
        cls.src = _make_proj(cls.tmp, cls.proj)
        cls.server, cls.port = _start_server(cls.tmp)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        import shutil; shutil.rmtree(cls.tmp, ignore_errors=True)

    def _retry(self, tid, payload=None):
        return _post_json(self.port, f"/api/projects/{self.proj}/retry/{tid}",
                          payload if payload is not None else {})

    # ── validation ──
    def test_unknown_project_returns_400(self):
        status, data = _post_json(self.port, "/api/projects/nope/retry/x", {})
        self.assertEqual(status, 400)

    def test_invalid_rawtid_returns_400(self):
        # ".." in tid → _valid_rawtid rejects
        status, data = self._retry("bad..tid")
        self.assertEqual(status, 400)

    def test_missing_run_dir_returns_400(self):
        status, data = self._retry("20260703T090000-111-2222")
        self.assertEqual(status, 400)

    # ── refuse runs that did NOT die of max_turns ──
    def test_refuse_run_not_dead_of_max_turns(self):
        tid = "20260703T090100-111-3333"
        _setup_run(self.tmp, self.proj, tid, "feature", "do a thing",
                   terminal_reason="end_turn")
        status, data = self._retry(tid)
        self.assertEqual(status, 400, data)

    # ── missing mode.txt (pre-feature run) → 400 ──
    def test_missing_mode_file_returns_400(self):
        tid = "20260703T090200-111-4444"
        _setup_run(self.tmp, self.proj, tid, None, "legacy task")
        status, data = self._retry(tid)
        self.assertEqual(status, 400, data)

    # ── happy path: spawns new tid, mode read from disk ──
    def test_retry_happy_spawns_new_tid(self):
        tid = "20260703T090300-111-5555"
        _setup_run(self.tmp, self.proj, tid, "feature", "build the feature")
        with patch("server.subprocess.Popen") as mock_popen, \
             patch("server._pagent_bin", return_value="/fake/pagent"):
            mock_popen.return_value = MagicMock()
            status, data = self._retry(tid, {"max_turns": 40})
        self.assertEqual(status, 200, data)
        self.assertTrue(data.get("ok"))
        self.assertIn("task_id", data)
        self.assertNotEqual(data["task_id"], tid)   # NEW tid, not the old one
        self.assertEqual(data["mode"], "feature")   # mode from disk
        cmd = mock_popen.call_args[0][0]
        self.assertEqual(cmd[1], "feature")         # spawn mode from disk
        self.assertEqual(cmd[2], "build the feature")  # task from disk

    # ── mode 'hotfix' (dispatch vocab) read from disk must NOT be rejected ──
    def test_retry_hotfix_mode_from_disk(self):
        tid = "20260703T090400-111-6666"
        _setup_run(self.tmp, self.proj, tid, "hotfix", "urgent patch")
        with patch("server.subprocess.Popen") as mock_popen, \
             patch("server._pagent_bin", return_value="/fake/pagent"):
            mock_popen.return_value = MagicMock()
            status, data = self._retry(tid, {"max_turns": 30})
        self.assertEqual(status, 200, data)
        self.assertEqual(data["mode"], "hotfix")
        self.assertEqual(mock_popen.call_args[0][0][1], "hotfix")

    # ── clamp: huge max_turns → capped at ceiling (default 60) ──
    def test_max_turns_clamped_to_ceiling(self):
        tid = "20260703T090500-111-7777"
        _setup_run(self.tmp, self.proj, tid, "feature", "t")
        with patch("server.subprocess.Popen") as mock_popen, \
             patch("server._pagent_bin", return_value="/fake/pagent"):
            mock_popen.return_value = MagicMock()
            status, data = self._retry(tid, {"max_turns": 99999})
        self.assertEqual(status, 200, data)
        env = mock_popen.call_args[1]["env"]
        self.assertEqual(env["PAGENT_MAX_TURNS"], "60")

    # ── clamp lower bound: 0/negative → 1 ──
    def test_max_turns_clamped_lower_bound(self):
        tid = "20260703T090600-111-8888"
        _setup_run(self.tmp, self.proj, tid, "feature", "t")
        with patch("server.subprocess.Popen") as mock_popen, \
             patch("server._pagent_bin", return_value="/fake/pagent"):
            mock_popen.return_value = MagicMock()
            status, data = self._retry(tid, {"max_turns": 0})
        self.assertEqual(status, 200, data)
        env = mock_popen.call_args[1]["env"]
        self.assertEqual(env["PAGENT_MAX_TURNS"], "1")

    # ── non-int max_turns → 400 ──
    def test_non_int_max_turns_returns_400(self):
        tid = "20260703T090700-111-9999"
        _setup_run(self.tmp, self.proj, tid, "feature", "t")
        status, data = self._retry(tid, {"max_turns": "lots"})
        self.assertEqual(status, 400, data)

    # ── default bump when client omits max_turns → env set within [1, ceiling] ──
    def test_default_bump_when_omitted(self):
        tid = "20260703T090800-111-aaaa"
        _setup_run(self.tmp, self.proj, tid, "feature", "t")
        with patch("server.subprocess.Popen") as mock_popen, \
             patch("server._pagent_bin", return_value="/fake/pagent"):
            mock_popen.return_value = MagicMock()
            status, data = self._retry(tid, {})
        self.assertEqual(status, 200, data)
        env = mock_popen.call_args[1]["env"]
        n = int(env["PAGENT_MAX_TURNS"])
        self.assertTrue(1 <= n <= 60, env["PAGENT_MAX_TURNS"])

    # ── response must NOT echo source path / full env ──
    def test_response_does_not_leak_source(self):
        tid = "20260703T090900-111-bbbb"
        _setup_run(self.tmp, self.proj, tid, "feature", "t")
        with patch("server.subprocess.Popen") as mock_popen, \
             patch("server._pagent_bin", return_value="/fake/pagent"):
            mock_popen.return_value = MagicMock()
            status, data = self._retry(tid, {"max_turns": 20})
        self.assertNotIn("source", data)
        self.assertNotIn(self.src, json.dumps(data))

    # ── dedup re-retry: 2nd retry of same (dead) run → 409 (chống double-spawn) ──
    def test_second_retry_same_run_returns_409(self):
        tid = "20260703T091100-111-dddd"
        _setup_run(self.tmp, self.proj, tid, "feature", "t")
        with patch("server.subprocess.Popen") as mock_popen, \
             patch("server._pagent_bin", return_value="/fake/pagent"):
            mock_popen.return_value = MagicMock()
            s1, d1 = self._retry(tid, {"max_turns": 20})
            s2, d2 = self._retry(tid, {"max_turns": 20})
        self.assertEqual(s1, 200, d1)
        self.assertEqual(s2, 409, d2)          # marker `retried` chặn spawn lần 2
        self.assertEqual(mock_popen.call_count, 1)  # chỉ spawn 1 lần

    # ── spawn failure must NOT leave a blocking `retried` marker ──
    def test_spawn_failure_allows_retry_again(self):
        tid = "20260703T091200-111-eeee"
        _setup_run(self.tmp, self.proj, tid, "feature", "t")
        with patch("server.subprocess.Popen", side_effect=OSError("boom")), \
             patch("server._pagent_bin", return_value="/fake/pagent"):
            s1, d1 = self._retry(tid, {"max_turns": 20})
        self.assertEqual(s1, 500, d1)          # spawn hỏng
        with patch("server.subprocess.Popen") as mock_popen, \
             patch("server._pagent_bin", return_value="/fake/pagent"):
            mock_popen.return_value = MagicMock()
            s2, d2 = self._retry(tid, {"max_turns": 20})
        self.assertEqual(s2, 200, d2)          # marker đã gỡ → retry lại được

    # ── new tid set via env PAGENT_TASK_ID (isolates aggregation) ──
    def test_new_tid_passed_via_env(self):
        tid = "20260703T091000-111-cccc"
        _setup_run(self.tmp, self.proj, tid, "feature", "t")
        with patch("server.subprocess.Popen") as mock_popen, \
             patch("server._pagent_bin", return_value="/fake/pagent"):
            mock_popen.return_value = MagicMock()
            status, data = self._retry(tid, {"max_turns": 20})
        env = mock_popen.call_args[1]["env"]
        self.assertEqual(env["PAGENT_TASK_ID"], data["task_id"])
        self.assertNotEqual(env["PAGENT_TASK_ID"], tid)

    # ── SECURITY / DoS: mọi input bị từ chối KHÔNG được spawn pagent (CWE-400) ──
    # Bổ trợ các test validation ở trên (chỉ check status) — ở đây khẳng định call_count==0.
    def test_rejected_inputs_never_spawn(self):
        good = "20260703T091300-111-f001"
        _setup_run(self.tmp, self.proj, good, "feature", "t")
        cases = [
            # (proj, tid, payload, expected_status, nhãn)
            ("nope", "20260703T091300-111-f002", {}, 400, "unknown project"),
            (self.proj, "../../etc/passwd", {}, 400, "path-traversal tid"),
            (self.proj, "bad..tid", {}, 400, "'..' trong tid"),
            (self.proj, "20260703T099999-999-dead", {}, 400, "tid không tồn tại"),
            (self.proj, good, {"max_turns": "lots"}, 400, "max_turns không phải số"),
            (self.proj, good, {"max_turns": [1, 2]}, 400, "max_turns kiểu list"),
        ]
        with patch("server.subprocess.Popen") as mock_popen, \
             patch("server._pagent_bin", return_value="/fake/pagent"):
            mock_popen.return_value = MagicMock()
            for proj, tid, payload, want, label in cases:
                status, data = _post_json(
                    self.port, f"/api/projects/{proj}/retry/{tid}", payload)
                self.assertEqual(status, want, f"{label}: {data}")
            self.assertEqual(mock_popen.call_count, 0,
                             "input xấu KHÔNG được spawn pagent (DoS/cost)")

    # ── BUSINESS: nút "Tăng lượt & chạy tiếp" → run mới thực sự có ngân sách lượt CAO hơn
    #    và nối lineage về run gốc (chạy tiếp đúng nhiệm vụ, không phải task tuỳ ý). ──
    def test_retry_raises_turns_and_links_parent(self):
        tid = "20260703T091400-111-f003"
        _setup_run(self.tmp, self.proj, tid, "feature", "finish the job")
        with patch("server.subprocess.Popen") as mock_popen, \
             patch("server._pagent_bin", return_value="/fake/pagent"):
            mock_popen.return_value = MagicMock()
            status, data = self._retry(tid, {"max_turns": 45})
        self.assertEqual(status, 200, data)
        env = mock_popen.call_args[1]["env"]
        self.assertEqual(env["PAGENT_MAX_TURNS"], "45")   # đúng ngân sách user tăng lên
        self.assertEqual(env["PAGENT_PARENT"], tid)       # lineage về run gốc
        self.assertEqual(env["PAGENT_CONFIRM"], "0")      # user đã chủ động bấm → không handshake
        # task/mode giữ đúng run gốc (chạy tiếp, không đổi nhiệm vụ)
        cmd = mock_popen.call_args[0][0]
        self.assertEqual(cmd[1], "feature")
        self.assertEqual(cmd[2], "finish the job")

    # ── source path chưa biết → 409, KHÔNG spawn (project chưa từng chạy từ source) ──
    def test_source_unknown_returns_409_no_spawn(self):
        # project hợp lệ, có run chết-max_turns nhưng THIẾU .source
        proj = "nosrcproj"
        os.makedirs(os.path.join(self.tmp, proj), exist_ok=True)  # có dir, không .source
        tid = "20260703T091500-111-f004"
        _setup_run(self.tmp, proj, tid, "feature", "t")
        with patch("server.subprocess.Popen") as mock_popen, \
             patch("server._pagent_bin", return_value="/fake/pagent"):
            mock_popen.return_value = MagicMock()
            status, data = _post_json(
                self.port, f"/api/projects/{proj}/retry/{tid}", {"max_turns": 20})
        self.assertEqual(status, 409, data)
        self.assertEqual(mock_popen.call_count, 0)


class TestSpawnHelperReused(unittest.TestCase):
    """_chat + retry must both go through _spawn_pagent (no duplicated Popen)."""

    def test_spawn_helper_exists(self):
        import server as srv
        self.assertTrue(hasattr(srv, "_spawn_pagent"),
                        "_spawn_pagent helper missing — spawn logic duplicated")


if __name__ == "__main__":
    unittest.main(verbosity=2)
