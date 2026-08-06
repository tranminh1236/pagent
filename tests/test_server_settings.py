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


_ISOLATE_PREFIXES = ("PAGENT_", "JIRA_")


def _scrub_env(tc, **overrides):
    """Cô lập env TƯỜNG MINH: suite này hay chạy BÊN TRONG chính pipeline pagent, nên
    process kế thừa PAGENT_SOURCE/PAGENT_MODEL/JIRA_* của run cha. Không xoá thì assert
    'process env không leak vào settings' xanh giả (biến vốn đã không tồn tại)."""
    clean = {k: v for k, v in os.environ.items()
             if not k.startswith(_ISOLATE_PREFIXES)}
    clean.update(overrides)
    p = patch.dict(os.environ, clean, clear=True)
    p.start()
    tc.addCleanup(p.stop)


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


class TestJiraTasksSettings(unittest.TestCase):
    """PAGENT_TASKS / JIRA_URL / JIRA_PERSONAL_TOKEN — ghi xuống .env.pagent của source
    (pagent tự source file này), PAT mask khi GET, không bao giờ vào settings.json."""

    def setUp(self):
        _scrub_env(self)                # PAGENT_*/JIRA_* của run cha không được lọt vào
        self.tmp = tempfile.mkdtemp(prefix="pagent_jira_settings_")
        self.proj = "jiraproj"
        self.src = _make_proj(self.tmp, self.proj)
        self.server, self.port = _start_server(self.tmp)

    def tearDown(self):
        self.server.shutdown()
        import shutil; shutil.rmtree(self.tmp, ignore_errors=True)

    def _get(self):
        return _req(self.port, "GET", f"/api/projects/{self.proj}/settings")

    def _post(self, payload):
        return _req(self.port, "POST", f"/api/projects/{self.proj}/settings", payload)

    def _envfile(self):
        with open(os.path.join(self.src, ".env.pagent")) as f:
            return f.read()

    def test_get_defaults_has_tasks_and_jira(self):
        status, data = self._get()
        self.assertEqual(status, 200)
        self.assertEqual(data.get("tasks"), "0")               # fail-closed
        self.assertEqual(data.get("jira_url"), "")
        self.assertEqual(data.get("jira_personal_token"), "")

    def test_post_writes_env_pagent_not_settings_json(self):
        status, data = self._post({"tasks": True, "jira_url": "https://jira.cty.vn",
                                   "jira_personal_token": "PAT-secret-123"})
        self.assertEqual(status, 200, data)
        env = self._envfile()
        self.assertIn("PAGENT_TASKS='1'", env)
        self.assertIn("JIRA_URL='https://jira.cty.vn'", env)
        self.assertIn("JIRA_PERSONAL_TOKEN='PAT-secret-123'", env)
        with open(os.path.join(self.tmp, self.proj, "settings.json")) as f:
            disk = json.load(f)
        for k in ("tasks", "jira_url", "jira_personal_token"):
            self.assertNotIn(k, disk)

    def test_pat_masked_on_get_and_post_response(self):
        secret = "PAT-secret-123"
        status, data = self._post({"jira_personal_token": secret})
        self.assertEqual(status, 200, data)
        self.assertNotEqual(data["jira_personal_token"], secret)
        self.assertNotIn(secret, json.dumps(data))
        status, data = self._get()
        self.assertEqual(data["jira_personal_token"], "********")
        self.assertNotIn(secret, json.dumps(data))
        self.assertIn(secret, self._envfile())          # plaintext CHỈ ở .env.pagent

    def test_post_mask_echo_keeps_previous_pat(self):
        self._post({"jira_personal_token": "PAT-secret-123"})
        status, data = self._post({"jira_url": "https://jira.cty.vn",
                                   "jira_personal_token": "********"})
        self.assertEqual(status, 200, data)
        self.assertIn("JIRA_PERSONAL_TOKEN='PAT-secret-123'", self._envfile())

    def test_empty_value_removes_line_and_keeps_other_lines(self):
        with open(os.path.join(self.src, ".env.pagent"), "w") as f:
            f.write('PAGENT_MODEL="9router/FREE"\n')
        self._post({"tasks": True, "jira_url": "https://jira.cty.vn",
                    "jira_personal_token": "PAT-secret-123"})
        status, data = self._post({"tasks": False, "jira_url": "",
                                   "jira_personal_token": ""})
        self.assertEqual(status, 200, data)
        env = self._envfile()
        self.assertIn('PAGENT_MODEL="9router/FREE"', env)     # dòng khác giữ nguyên
        for k in ("PAGENT_TASKS", "JIRA_URL", "JIRA_PERSONAL_TOKEN"):
            self.assertNotIn(k, env)                          # rỗng → không ghi rác
        status, data = self._get()
        self.assertEqual(data["tasks"], "0")
        self.assertEqual(data["jira_url"], "")

    def test_post_rejects_bad_values_without_writing(self):
        for payload in ({"tasks": "yes"}, {"tasks": 1}, {"tasks": None},
                        {"jira_url": "http://jira.cty.vn"},          # http → PAT qua clear-text
                        {"jira_url": "jira.cty.vn"},
                        {"jira_url": "https://jira.cty.vn/browse/AB-1 x"},
                        {"jira_url": "https://" + "a" * 300},
                        {"jira_url": 5},
                        {"jira_personal_token": "tok en"},           # có khoảng trắng
                        {"jira_personal_token": "x" * 513},
                        {"jira_personal_token": 5}):
            status, data = self._post(payload)
            self.assertEqual(status, 400, f"{payload!r}: {data}")
            self.assertFalse(os.path.exists(os.path.join(self.src, ".env.pagent")),
                             f"{payload!r} không được ghi .env.pagent")

    def test_error_message_never_echoes_pat(self):
        status, data = self._post({"jira_personal_token": "leak me please"})
        self.assertEqual(status, 400)
        self.assertNotIn("leak me please", json.dumps(data))

    def test_env_pagent_is_owner_only(self):
        self._post({"jira_personal_token": "PAT-secret-123"})
        mode = os.stat(os.path.join(self.src, ".env.pagent")).st_mode & 0o777
        self.assertEqual(mode, 0o600)

    def test_settings_json_cannot_inject_jira_keys(self):
        with open(os.path.join(self.tmp, self.proj, "settings.json"), "w") as f:
            json.dump({"provider": "claude", "jira_personal_token": "PLANTED",
                       "tasks": "1"}, f)
        status, data = self._get()
        self.assertEqual(data["jira_personal_token"], "")   # .env.pagent là nguồn duy nhất
        self.assertEqual(data["tasks"], "0")

    def test_pat_rejects_shell_metachars(self):
        """`pagent` chạy `set -a && . .env.pagent` → value có $(...)/`` /; bị bash THỰC THI.
        Charset PAT phải chặn ngay ở API, không dựa vào escape ở tầng ghi."""
        for tok in ("$(id>/tmp/pagent_rce)", "`id`", 'a";id;"b', "a;id", "a$b",
                    "a|b", "a&b", "a>b", "a'b", 'a"b', "a\\b", "a(b)"):
            status, data = self._post({"jira_personal_token": tok})
            self.assertEqual(status, 400, f"{tok!r} phải bị từ chối: {data}")
            self.assertFalse(os.path.exists(os.path.join(self.src, ".env.pagent")),
                             f"{tok!r} không được ghi .env.pagent")

    def test_pat_accepts_normal_token_charset(self):
        for tok in ("PAT-secret-123", "NDk2N.abc_XY~9+/=", "x" * 512):
            status, data = self._post({"jira_personal_token": tok})
            self.assertEqual(status, 200, f"{tok!r} phải được chấp nhận: {data}")

    def test_env_values_written_single_quoted(self):
        """Mọi value ghi ra .env.pagent phải bọc single-quote (escape `'` kiểu '\\''),
        để `. .env.pagent` không bao giờ expand/thực thi nội dung."""
        self._post({"tasks": True, "jira_url": "https://jira.cty.vn",
                    "jira_personal_token": "PAT-secret-123"})
        env = self._envfile()
        self.assertIn("PAGENT_TASKS='1'", env)
        self.assertIn("JIRA_URL='https://jira.cty.vn'", env)
        self.assertIn("JIRA_PERSONAL_TOKEN='PAT-secret-123'", env)

    def test_env_file_sourced_by_bash_has_no_side_effect(self):
        """Đọc lại bằng chính cơ chế của pagent (`set -a && . file`) — giá trị phải
        round-trip nguyên vẹn và không sinh side-effect nào."""
        import subprocess
        self._post({"jira_url": "https://jira.cty.vn",
                    "jira_personal_token": "PAT-secret-123"})
        p = os.path.join(self.src, ".env.pagent")
        out = subprocess.run(["bash", "-c", f'set -a && . "{p}" && set +a && '
                                            'printf "%s|%s" "$JIRA_URL" "$JIRA_PERSONAL_TOKEN"'],
                             capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout, "https://jira.cty.vn|PAT-secret-123")

    def test_jira_url_rejects_literal_ip_and_localhost(self):
        """`_JIRA_URL_RE` từ chối IP trần + localhost: host của JIRA_URL được miễn kiểm
        dải nội bộ ở helper → literal IP ở đây = SSRF metadata service kèm PAT."""
        for u in ("https://169.254.169.254", "https://127.0.0.1", "https://10.0.0.1:8443",
                  "https://localhost", "https://localhost:8080", "https://[::1]",
                  "https://jira.cty.vn/browse/AB-1"):   # path segment: message hứa URL gốc
            status, data = self._post({"jira_url": u})
            self.assertEqual(status, 400, f"{u!r} phải bị từ chối: {data}")

    def test_env_walks_up_to_parent_env_pagent(self):
        """`load_env` (pagent) dừng ở .env.pagent ĐẦU TIÊN từ cwd đi lên. Web phải walk-up
        cùng thuật toán — nếu không, ghi file mới ở source sẽ che mất file cha."""
        parent = os.path.join(self.src, "sub")
        os.makedirs(parent, exist_ok=True)
        with open(os.path.join(self.src, ".source"), "w"):
            pass
        with open(os.path.join(self.tmp, self.proj, ".source"), "w") as f:
            f.write(parent + "\n")
        os.unlink(os.path.join(self.src, ".source"))
        with open(os.path.join(self.src, ".env.pagent"), "w") as f:
            f.write("PAGENT_MODEL='9router/FREE'\n")
        status, data = self._post({"jira_url": "https://jira.cty.vn"})
        self.assertEqual(status, 200, data)
        self.assertFalse(os.path.exists(os.path.join(parent, ".env.pagent")),
                         "không được tạo file mới che .env.pagent của thư mục cha")
        env = self._envfile()
        self.assertIn("PAGENT_MODEL='9router/FREE'", env)
        self.assertIn("JIRA_URL='https://jira.cty.vn'", env)
        status, data = self._get()
        self.assertEqual(data["jira_url"], "https://jira.cty.vn")   # read cũng walk-up

    # ───── round-trip 3 key mới qua _SETTINGS_DEFAULTS ─────

    def test_three_keys_round_trip_plaintext_on_disk_masked_on_wire(self):
        """POST → .env.pagent → read_env_settings (plaintext, cho pagent) → GET (masked).
        Một vòng đầy đủ cho CẢ 3 key, không chỉ PAT."""
        import server as srv
        self._post({"tasks": True, "jira_url": "https://jira.cty.vn",
                    "jira_personal_token": "PAT-secret-123"})
        plain = srv.read_env_settings(self.proj)
        self.assertEqual(plain["tasks"], "1")
        self.assertEqual(plain["jira_url"], "https://jira.cty.vn")
        self.assertEqual(plain["jira_personal_token"], "PAT-secret-123")
        status, data = self._get()
        self.assertEqual(status, 200)
        self.assertEqual(data["tasks"], "1")                      # không phải secret → nguyên
        self.assertEqual(data["jira_url"], "https://jira.cty.vn")
        self.assertEqual(data["jira_personal_token"], "********")  # secret → mask

    def test_tasks_accepts_string_form_and_round_trips(self):
        """UI có thể gửi "1"/"0" (form) thay vì bool — cả hai dạng phải ra cùng kết quả."""
        for sent, want_env, want_get in (("1", "PAGENT_TASKS='1'", "1"),
                                         ("0", None, "0")):
            status, data = self._post({"tasks": sent})
            self.assertEqual(status, 200, f"tasks={sent!r}: {data}")
            self.assertEqual(data["tasks"], want_get)
            env = self._envfile()
            if want_env:
                self.assertIn(want_env, env)
            else:
                self.assertNotIn("PAGENT_TASKS", env)   # tắt = xoá dòng, không ghi '0'
            self.assertEqual(self._get()[1]["tasks"], want_get)

    def test_get_masks_pat_written_by_hand_outside_web(self):
        """PAT do user tự sửa .env.pagent (không qua POST) vẫn phải bị mask khi GET —
        mask nằm ở đường RA, không phải ở đường ghi."""
        with open(os.path.join(self.src, ".env.pagent"), "w") as f:
            f.write('JIRA_PERSONAL_TOKEN="HAND-EDITED-SECRET"\n'
                    "JIRA_URL='https://jira.cty.vn'\n")
        status, data = self._get()
        self.assertEqual(status, 200)
        self.assertEqual(data["jira_personal_token"], "********")
        self.assertNotIn("HAND-EDITED-SECRET", json.dumps(data))

    # ───── rỗng/không set → không ghi rác ─────

    def test_post_without_jira_fields_creates_no_env_pagent(self):
        """POST chỉ đụng settings.json (provider) → tuyệt đối KHÔNG đẻ .env.pagent rỗng
        trong source project của user."""
        status, data = self._post({"provider": "claude"})
        self.assertEqual(status, 200, data)
        self.assertFalse(os.path.exists(os.path.join(self.src, ".env.pagent")))

    def test_post_empty_strings_on_fresh_source_writes_nothing(self):
        """Chưa có file + gửi rỗng → không có gì để ghi, không tạo file rác."""
        status, data = self._post({"jira_url": "", "jira_personal_token": ""})
        self.assertEqual(status, 200, data)
        p = os.path.join(self.src, ".env.pagent")
        if os.path.exists(p):                       # nếu có tạo thì cũng không có key rác
            env = self._envfile()
            for k in ("JIRA_URL", "JIRA_PERSONAL_TOKEN", "PAGENT_TASKS"):
                self.assertNotIn(k, env)
        self.assertEqual(self._get()[1]["jira_url"], "")

    def test_mask_echo_alone_on_fresh_source_is_noop(self):
        """UI load form (PAT = mask) rồi submit mà không đổi gì → no-op, không ghi mask
        '********' thành PAT thật vào file."""
        status, data = self._post({"jira_personal_token": "********"})
        self.assertEqual(status, 200, data)
        p = os.path.join(self.src, ".env.pagent")
        self.assertFalse(os.path.exists(p) and "********" in self._envfile(),
                         "mask không bao giờ được ghi thành giá trị")

    def test_empty_pat_removes_only_pat_line(self):
        """Xoá PAT không được kéo theo JIRA_URL/PAGENT_TASKS."""
        self._post({"tasks": True, "jira_url": "https://jira.cty.vn",
                    "jira_personal_token": "PAT-secret-123"})
        status, data = self._post({"jira_personal_token": ""})
        self.assertEqual(status, 200, data)
        env = self._envfile()
        self.assertNotIn("JIRA_PERSONAL_TOKEN", env)
        self.assertIn("JIRA_URL='https://jira.cty.vn'", env)
        self.assertIn("PAGENT_TASKS='1'", env)

    # ───── không có key Cloud / Google Sheets ─────

    def test_no_jira_cloud_or_google_keys_in_env_file(self):
        """Chế độ DUY NHẤT là Jira Server/DC + PAT (.env.pagent.example). Google Sheet đọc
        qua CSV export public → KHÔNG credential. File sinh ra chỉ được có đúng 3 key."""
        self._post({"tasks": True, "jira_url": "https://jira.cty.vn",
                    "jira_personal_token": "PAT-secret-123"})
        env = self._envfile()
        for forbidden in ("JIRA_USERNAME", "JIRA_API_TOKEN", "JIRA_EMAIL",
                          "JIRA_CLOUD", "GOOGLE_", "GDRIVE", "GSHEET",
                          "SERVICE_ACCOUNT", "GOOGLE_APPLICATION_CREDENTIALS"):
            self.assertNotIn(forbidden, env, f"{forbidden} không được xuất hiện")
        keys = sorted(k for k, _ in (l.partition("=")[::2] for l in env.splitlines() if l.strip()))
        self.assertEqual(keys, ["JIRA_PERSONAL_TOKEN", "JIRA_URL", "PAGENT_TASKS"])

    def test_post_ignores_cloud_and_google_credential_fields(self):
        """Field lạ kiểu Cloud/Google gửi lên phải bị BỎ (không 500, không ghi xuống đâu)."""
        payload = {"jira_url": "https://jira.cty.vn",
                   "jira_username": "bob@cty.vn", "jira_api_token": "CLOUD-TOKEN",
                   "jira_email": "bob@cty.vn",
                   "google_service_account": '{"private_key":"x"}',
                   "google_sheets_api_key": "AIza-FAKE"}
        status, data = self._post(payload)
        self.assertEqual(status, 200, data)
        blob = json.dumps(data)
        for bad in ("jira_username", "jira_api_token", "google_service_account",
                    "google_sheets_api_key", "CLOUD-TOKEN", "AIza-FAKE"):
            self.assertNotIn(bad, blob, f"{bad} lọt vào response")
        env = self._envfile()
        for bad in ("CLOUD-TOKEN", "AIza-FAKE", "USERNAME", "API_TOKEN", "GOOGLE"):
            self.assertNotIn(bad, env, f"{bad} lọt vào .env.pagent")
        with open(os.path.join(self.tmp, self.proj, "settings.json")) as f:
            disk = json.dumps(json.load(f))
        for bad in ("CLOUD-TOKEN", "AIza-FAKE", "jira_username", "google"):
            self.assertNotIn(bad, disk, f"{bad} lọt vào settings.json")

    # ───── env process không phải nguồn sự thật ─────

    def test_process_env_does_not_leak_into_get(self):
        """`.env.pagent` là single source of truth. PAGENT_TASKS/JIRA_* rơi rớt trong env
        của web server (vd server chạy từ shell đã export) KHÔNG được hiện ra như đã cấu hình."""
        with patch.dict(os.environ, {"PAGENT_TASKS": "1",
                                     "JIRA_URL": "https://evil.example",
                                     "JIRA_PERSONAL_TOKEN": "LEAKED-FROM-SHELL"}):
            status, data = self._get()
        self.assertEqual(status, 200)
        self.assertEqual(data["tasks"], "0")
        self.assertEqual(data["jira_url"], "")
        self.assertEqual(data["jira_personal_token"], "")
        self.assertNotIn("LEAKED-FROM-SHELL", json.dumps(data))


class TestJiraSettingsSchema(unittest.TestCase):
    """Hằng số schema trong server.py — chốt hình dạng cấu hình (Server/DC + PAT), chặn
    ai đó lặng lẽ thêm nhánh Jira Cloud hay credential Google."""

    def setUp(self):
        _scrub_env(self)
        import server as srv
        self.srv = srv

    def test_defaults_contain_three_new_keys_fail_closed(self):
        d = self.srv._SETTINGS_DEFAULTS
        self.assertEqual(d["tasks"], "0")            # gate mặc định TẮT
        self.assertEqual(d["jira_url"], "")
        self.assertEqual(d["jira_personal_token"], "")

    def test_env_settings_map_is_exactly_three_server_dc_keys(self):
        self.assertEqual(self.srv._ENV_SETTINGS,
                         {"tasks": "PAGENT_TASKS", "jira_url": "JIRA_URL",
                          "jira_personal_token": "JIRA_PERSONAL_TOKEN"})
        self.assertEqual(set(self.srv._ENV_SETTINGS) - set(self.srv._SETTINGS_DEFAULTS), set())
        self.assertIn("jira_personal_token", self.srv._SECRET_SETTINGS)

    def test_no_cloud_or_google_key_anywhere_in_schema(self):
        names = set(self.srv._SETTINGS_DEFAULTS) | set(self.srv._ENV_SETTINGS.values())
        for n in names:
            up = n.upper()
            for bad in ("USERNAME", "EMAIL", "API_TOKEN", "GOOGLE", "SHEET",
                        "GDRIVE", "SERVICE_ACCOUNT", "OAUTH"):
                self.assertNotIn(bad, up, f"key {n!r} chứa {bad} — sai chế độ Server/DC+PAT")

    def test_mask_settings_masks_only_secret_and_only_when_set(self):
        st = {"provider": "claude", "tasks": "1", "jira_url": "https://jira.cty.vn",
              "jira_personal_token": "PAT-secret-123"}
        out = self.srv.mask_settings(st)
        self.assertEqual(out["jira_personal_token"], self.srv._SETTINGS_MASK)
        self.assertEqual(out["jira_url"], "https://jira.cty.vn")
        self.assertEqual(out["tasks"], "1")
        self.assertEqual(st["jira_personal_token"], "PAT-secret-123")   # không mutate input
        self.assertEqual(self.srv.mask_settings({"jira_personal_token": ""})
                         ["jira_personal_token"], "")                   # rỗng ≠ '********'


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

    def test_spawn_provider_claude_does_not_set_pagent_model(self):
        # provider=claude → KHÔNG set PAGENT_MODEL (tránh leak '9router/FREE' xuống START
        # event → badge in-flight hiện 'claude · FREE'). PAGENT_MODEL leak từ shell bị bỏ.
        self._write_settings({"provider": "claude", "opencode_model": "9router/FREE"})
        env_clean = {k: v for k, v in os.environ.items() if k != "PAGENT_MODEL"}
        with patch.dict(os.environ, env_clean, clear=True):
            env = self._spawn()
        self.assertNotIn("PAGENT_MODEL", env)

    def test_spawn_empty_opencode_model_leaves_env(self):
        self._write_settings({"provider": "opencode", "opencode_model": ""})
        with patch.dict(os.environ, {"PAGENT_MODEL": "9router/Claude"}):
            env = self._spawn()
        self.assertEqual(env.get("PAGENT_MODEL"), "9router/Claude")        # không đụng

    def test_spawn_does_not_inject_jira_keys_from_settings_json(self):
        """3 key gate task-tracker sống ở .env.pagent — `pagent` tự source. Web KHÔNG được
        bơm chúng qua env (settings.json bị nhét tay cũng không thành đường tuồn PAT)."""
        _scrub_env(self)
        self._write_settings({"provider": "claude", "tasks": "1",
                              "jira_url": "https://evil.example",
                              "jira_personal_token": "PLANTED-PAT"})
        env = self._spawn()
        for k in ("PAGENT_TASKS", "JIRA_URL", "JIRA_PERSONAL_TOKEN"):
            self.assertNotIn(k, env, f"{k} không được đi qua env của spawn")
        self.assertNotIn("PLANTED-PAT", json.dumps(env))

    def test_spawn_env_extra_carries_pagent_tasks_round_trip(self):
        """env_extra vẫn là đường hợp lệ để gate 1 run cụ thể (giống PAGENT_DESIGN) —
        và nó ĐÈ được env kế thừa."""
        _scrub_env(self, PAGENT_TASKS="0")
        env = self._spawn(env_extra={"PAGENT_TASKS": "1"})
        self.assertEqual(env.get("PAGENT_TASKS"), "1")

    def test_spawn_inherits_jira_env_only_from_process(self):
        """`pagent` con thừa kế env của web server: JIRA_* có sẵn trong process thì đi qua
        nguyên vẹn (không bị web xoá/ghi đè) — nhưng nguồn của nó là shell, không phải
        settings.json (xem test trên)."""
        _scrub_env(self, JIRA_URL="https://jira.cty.vn")
        self._write_settings({"provider": "claude"})
        env = self._spawn()
        self.assertEqual(env.get("JIRA_URL"), "https://jira.cty.vn")

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
