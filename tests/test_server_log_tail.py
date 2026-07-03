#!/usr/bin/env python3
"""Tests for kit/web/server.py — tail log run ra terminal `pagent web`.

Bug UX (2026-07-03): run spawn từ web ghi log vào REPORTS/<proj>/logs/<tid>.log,
terminal chạy `pagent web` im lặng hoàn toàn → agent chết không ai biết tại sao.
Fix: _spawn_pagent khởi động daemon thread _tail_log_to_stdout đọc log file mới
ghi thêm → in ra stdout server với prefix [tag]. Child vẫn ghi TRỰC TIẾP vào file
(không pipe) — server chết không làm run nghẽn; file vẫn là nguồn cho web UI.
PAGENT_WEB_QUIET=1 → tắt tail.
"""
import io, os, sys, tempfile, threading, time, unittest
from unittest.mock import patch, MagicMock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "kit", "web"))
import server as srv


class TestTailLogToStdout(unittest.TestCase):
    def test_streams_lines_with_prefix_until_done(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".log", delete=False) as f:
            path = f.name
            f.write("dòng 1\n")
        out = io.StringIO()
        done = {"v": False}
        th = threading.Thread(
            target=srv._tail_log_to_stdout,
            args=(path, lambda: done["v"], "5162"),
            kwargs={"out": out, "interval": 0.01}, daemon=True)
        th.start()
        time.sleep(0.1)
        with open(path, "a") as f:
            f.write("⚠ agent coder fail (reason=API Error: 401)\n")
        time.sleep(0.1)
        done["v"] = True
        th.join(timeout=2)
        self.assertFalse(th.is_alive(), "tail phải tự kết thúc khi run xong")
        text = out.getvalue()
        self.assertIn("[5162] dòng 1", text)
        self.assertIn("[5162] ⚠ agent coder fail (reason=API Error: 401)", text)
        os.unlink(path)

    def test_drains_remaining_lines_after_done(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".log", delete=False) as f:
            path = f.name
        out = io.StringIO()
        done = {"v": False}
        th = threading.Thread(
            target=srv._tail_log_to_stdout,
            args=(path, lambda: done["v"], "t"),
            kwargs={"out": out, "interval": 0.01}, daemon=True)
        th.start()
        # Ghi dòng CUỐI rồi lập tức báo done — tail vẫn phải kịp in dòng này.
        with open(path, "a") as f:
            f.write("dòng cuối trước khi chết\n")
        done["v"] = True
        th.join(timeout=2)
        self.assertIn("dòng cuối trước khi chết", out.getvalue())
        os.unlink(path)

    def test_missing_file_no_crash(self):
        out = io.StringIO()
        srv._tail_log_to_stdout("/nonexistent/x.log", lambda: True, "t",
                                out=out, interval=0.01)
        # không raise là pass


class TestSpawnStartsTail(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="pagent_tail_spawn_")
        srv.REPORTS = os.path.realpath(self.tmp)
        os.makedirs(os.path.join(self.tmp, "p"), exist_ok=True)

    def tearDown(self):
        import shutil; shutil.rmtree(self.tmp, ignore_errors=True)

    def _spawn(self):
        with patch("server.subprocess.Popen") as mock_popen, \
             patch("server._pagent_bin", return_value="/fake/pagent"), \
             patch("server._tail_log_to_stdout") as mock_tail:
            mock_popen.return_value = MagicMock()
            err, status = srv._spawn_pagent("p", self.tmp, "feature", "t",
                                            "20260703T170012-1-5162")
            self.assertIsNone(err, err)
            for _ in range(100):          # thread daemon gọi mock_tail — chờ tối đa 1s
                if mock_tail.called:
                    break
                time.sleep(0.01)
            return mock_tail

    def test_spawn_starts_tail_thread(self):
        mock_tail = self._spawn()
        self.assertTrue(mock_tail.called, "spawn phải khởi động tail log ra terminal")
        logpath = mock_tail.call_args[0][0]
        self.assertTrue(logpath.endswith("20260703T170012-1-5162.log"))
        tag = mock_tail.call_args[0][2]
        self.assertEqual(tag, "5162", "tag = segment cuối của tid (ngắn gọn cho prefix)")

    def test_quiet_env_disables_tail(self):
        with patch.dict(os.environ, {"PAGENT_WEB_QUIET": "1"}):
            mock_tail = self._spawn()
        self.assertFalse(mock_tail.called, "PAGENT_WEB_QUIET=1 → không tail")


if __name__ == "__main__":
    unittest.main(verbosity=2)
