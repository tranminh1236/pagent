#!/usr/bin/env python3
"""Tests for kit/web/server.py — auto-reload supervisor cho `pagent web`.

Root cause fix: tiến trình web chạy bản stale → thiếu route → 404 "not found".
Supervisor (server.py __main__) watch mtime kit/web/server.py; file đổi → restart
child web server → hết phục vụ bản stale. BẬT mặc định; PAGENT_WEB_RELOAD=0 → tắt.

Chia 2 tầng:
- Unit: các helper quyết định thuần (reload on/off, child-marker, backoff).
- Integration: chạy supervisor thật (subprocess) → child bind port, touch file →
  child restart (pid đổi), SIGTERM supervisor → không orphan.
"""
import os, sys, time, signal, shutil, socket, tempfile, subprocess, unittest
import http.client

WEB_DIR = os.path.join(os.path.dirname(__file__), "..", "kit", "web")
sys.path.insert(0, WEB_DIR)


class TestReloadHelpers(unittest.TestCase):
    def setUp(self):
        import server as srv
        self.srv = srv
        self._saved = {k: os.environ.get(k)
                       for k in ("PAGENT_WEB_RELOAD", "_PAGENT_WEB_CHILD")}

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    # ── _web_reload_enabled: BẬT mặc định + opt-out qua env ──
    def test_reload_enabled_by_default(self):
        os.environ.pop("PAGENT_WEB_RELOAD", None)
        self.assertTrue(self.srv._web_reload_enabled())

    def test_reload_disabled_when_zero(self):
        os.environ["PAGENT_WEB_RELOAD"] = "0"
        self.assertFalse(self.srv._web_reload_enabled())

    def test_reload_enabled_for_other_values(self):
        os.environ["PAGENT_WEB_RELOAD"] = "1"
        self.assertTrue(self.srv._web_reload_enabled())
        os.environ["PAGENT_WEB_RELOAD"] = "yes"
        self.assertTrue(self.srv._web_reload_enabled())

    # ── _is_supervised_child: chỉ True khi marker == "1" ──
    def test_child_marker_true_only_for_one(self):
        os.environ["_PAGENT_WEB_CHILD"] = "1"
        self.assertTrue(self.srv._is_supervised_child())

    def test_child_marker_false_when_absent(self):
        os.environ.pop("_PAGENT_WEB_CHILD", None)
        self.assertFalse(self.srv._is_supervised_child())

    def test_child_marker_false_for_other_values(self):
        os.environ["_PAGENT_WEB_CHILD"] = "0"
        self.assertFalse(self.srv._is_supervised_child())

    # ── _reload_next_backoff: mũ có cap, chống tight-loop ──
    def test_backoff_doubles(self):
        self.assertEqual(self.srv._reload_next_backoff(0.5), 1.0)
        self.assertEqual(self.srv._reload_next_backoff(1.0), 2.0)

    def test_backoff_capped(self):
        self.assertEqual(self.srv._reload_next_backoff(8.0), 8.0)
        self.assertEqual(self.srv._reload_next_backoff(100.0), 8.0)

    def test_backoff_custom_cap(self):
        self.assertEqual(self.srv._reload_next_backoff(4.0, cap=4.0), 4.0)


# ───────── Integration: supervisor thật ─────────

def _free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _wait_http_ok(port, path="/api/projects", timeout=10.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
            conn.request("GET", path)
            resp = conn.getresponse()
            resp.read()
            conn.close()
            if resp.status == 200:
                return True
        except OSError:
            time.sleep(0.1)
    return False


def _child_pids(sup_pid):
    """PID các child trực tiếp của supervisor (child web spawn qua Popen)."""
    try:
        out = subprocess.check_output(["pgrep", "-P", str(sup_pid)], text=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []
    return [int(x) for x in out.split()]


def _alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


@unittest.skipUnless(shutil.which("pgrep"), "cần pgrep để lần child pid")
class TestSupervisorReload(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="pagent_reload_")
        self.server_copy = os.path.join(self.tmp, "server.py")
        shutil.copy(os.path.join(WEB_DIR, "server.py"), self.server_copy)
        self.port = _free_port()
        self.sup = None

    def tearDown(self):
        if self.sup and self.sup.poll() is None:
            try:
                self.sup.terminate()
                self.sup.wait(timeout=5)
            except Exception:
                self.sup.kill()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _start_supervisor(self, reload="1"):
        env = dict(os.environ, PORT=str(self.port), HOST="127.0.0.1",
                   PAGENT_REPORT_DIR=self.tmp, PAGENT_WEB_RELOAD=reload,
                   PAGENT_WEB_RELOAD_POLL="0.2", PAGENT_WEB_RELOAD_GRACE="3")
        env.pop("_PAGENT_WEB_CHILD", None)
        self.sup = subprocess.Popen([sys.executable, self.server_copy], env=env)

    def test_supervisor_serves_then_restarts_on_change(self):
        self._start_supervisor(reload="1")
        self.assertTrue(_wait_http_ok(self.port), "child web không phục vụ")
        # supervisor phải có đúng 1 child đang chạy
        deadline = time.time() + 5
        pids = []
        while time.time() < deadline and not pids:
            pids = _child_pids(self.sup.pid)
            time.sleep(0.1)
        self.assertTrue(pids, "không thấy child web dưới supervisor")
        pid_before = pids[0]

        # chạm mtime server.py copy (mô phỏng edit) → supervisor restart child
        future = time.time() + 10
        os.utime(self.server_copy, (future, future))

        # child mới (pid khác) phải lên phục vụ lại
        deadline = time.time() + 10
        pid_after = pid_before
        while time.time() < deadline:
            cur = _child_pids(self.sup.pid)
            if cur and cur[0] != pid_before:
                pid_after = cur[0]
                break
            time.sleep(0.2)
        self.assertNotEqual(pid_after, pid_before, "child không restart khi file đổi")
        self.assertFalse(_alive(pid_before), "child cũ chưa chết → nguy cơ double-bind")
        self.assertTrue(_wait_http_ok(self.port), "child mới không phục vụ lại port")

    def test_sigterm_kills_child_no_orphan(self):
        self._start_supervisor(reload="1")
        self.assertTrue(_wait_http_ok(self.port))
        deadline = time.time() + 5
        pids = []
        while time.time() < deadline and not pids:
            pids = _child_pids(self.sup.pid)
            time.sleep(0.1)
        self.assertTrue(pids)
        child = pids[0]

        self.sup.send_signal(signal.SIGTERM)
        self.sup.wait(timeout=8)
        # child không được orphan
        deadline = time.time() + 5
        while time.time() < deadline and _alive(child):
            time.sleep(0.1)
        self.assertFalse(_alive(child), "child bị orphan sau khi supervisor thoát")

    def test_reload_off_serves_directly_no_child(self):
        self._start_supervisor(reload="0")
        self.assertTrue(_wait_http_ok(self.port), "server không phục vụ khi reload tắt")
        # reload=0 → exec trực tiếp, KHÔNG có child supervisor
        time.sleep(0.5)
        self.assertEqual(_child_pids(self.sup.pid), [],
                         "reload=0 vẫn fork child → sai đường opt-out")


if __name__ == "__main__":
    unittest.main(verbosity=2)
