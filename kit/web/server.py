#!/usr/bin/env python3
"""pagent web dashboard — single-file HTTP server, Python stdlib only."""
import os, json, re, sys, random, shutil, subprocess
from datetime import datetime, timezone, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, unquote

MAX_BODY = int(os.environ.get("PAGENT_MAX_UPLOAD", str(50 * 1024 * 1024)))  # 50MB
_IMG_EXT = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp"}
_ID_RE = re.compile(r"^[A-Za-z0-9_.-]+$")

LIVE_WINDOW_MIN = int(os.environ.get("PAGENT_LIVE_WINDOW_MIN", "15"))

REPORTS = os.path.realpath(os.environ.get("PAGENT_REPORT_DIR", os.path.expanduser("~/.pagent-reports")))
HERE = os.path.dirname(os.path.abspath(__file__))

# ───────── Input validation ─────────
_PROJ_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
_TID_RE  = re.compile(r"^\d{4}-\d{2}-\d{2}-[A-Za-z0-9_.-]+$")

def _valid_proj(p):
    return bool(p) and bool(_PROJ_RE.fullmatch(p)) and p not in (".", "..") and p in list_projects()

def _valid_tid(t):
    return bool(t) and bool(_TID_RE.fullmatch(t)) and ".." not in t

def _safe_join(*parts):
    """Join + verify final path nằm trong REPORTS."""
    p = os.path.realpath(os.path.join(*parts))
    if not (p == REPORTS or p.startswith(REPORTS + os.sep)):
        return None
    return p

def _within_reports(p):
    p = os.path.realpath(p)
    return p == REPORTS or p.startswith(REPORTS + os.sep)

# ───────── Chat / upload helpers ─────────

def _is_image(p):
    return os.path.splitext(p)[1].lower() in _IMG_EXT

def _project_source(proj):
    """Đọc source path đã ghi bởi pagent (REPORTS/<proj>/.source). None nếu chưa có."""
    src = _safe_join(REPORTS, proj, ".source")
    if not src:
        return None
    try:
        with open(src) as fh:
            s = fh.readline().strip()
        return s or None
    except Exception:
        return None

def _pagent_bin():
    cand = os.environ.get("PAGENT_BIN")
    if cand and os.path.isfile(cand):
        return cand
    w = shutil.which("pagent")
    if w:
        return w
    guess = os.path.realpath(os.path.join(HERE, "..", "..", "pagent"))
    return guess if os.path.isfile(guess) else None

def _new_task_id():
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    return f"{ts}-{os.getpid()}-{random.randint(1000, 9999)}"

def _compose_task(task, attachments, figma_url):
    """Chèn đường dẫn file + figma url vào task text để coder/reviewer Read (ảnh = vision)."""
    lines = [task]
    if attachments:
        lines += ["", "## ĐÍNH KÈM (đọc bằng Read; ảnh xem bằng vision)"]
        for p in attachments:
            lines.append(f"- [{'ảnh' if _is_image(p) else 'file'}] {p}")
    if figma_url:
        lines += ["", "## FIGMA (so sánh design)", figma_url]
    return "\n".join(lines)

def _parse_multipart(body, boundary):
    """Parse multipart/form-data thủ công (KHÔNG dùng cgi — deprecated py3.13).
    Trả list dict {name, filename, data(bytes)}."""
    delim = b"--" + boundary
    parts = []
    for seg in body.split(delim):
        if not seg or seg[:2] == b"--":      # preamble rỗng / closing "--"
            continue
        if seg[:2] == b"\r\n":
            seg = seg[2:]
        if seg[-2:] == b"\r\n":
            seg = seg[:-2]
        idx = seg.find(b"\r\n\r\n")
        if idx < 0:
            continue
        headers = seg[:idx].decode("utf-8", "replace")
        data = seg[idx + 4:]
        name = filename = None
        for hline in headers.split("\r\n"):
            if hline.lower().startswith("content-disposition"):
                nm = re.search(r'name="([^"]*)"', hline)
                fn = re.search(r'filename="([^"]*)"', hline)
                if nm: name = nm.group(1)
                if fn: filename = fn.group(1)
        parts.append({"name": name, "filename": filename, "data": data})
    return parts

# ───────── Data loaders ─────────

def list_projects():
    if not os.path.isdir(REPORTS): return []
    return sorted(d for d in os.listdir(REPORTS)
                  if os.path.isdir(os.path.join(REPORTS, d)) and not d.startswith("."))

def _read_tokens(proj):
    """Trả về list events đã sort theo ts."""
    d = os.path.join(REPORTS, proj, "tokens")
    if not os.path.isdir(d): return []
    evs = []
    for f in sorted(os.listdir(d)):
        if not f.endswith(".jsonl"): continue
        with open(os.path.join(d, f)) as fh:
            for line in fh:
                try: evs.append(json.loads(line))
                except Exception: continue
    evs.sort(key=lambda e: e.get("ts", ""))
    return evs

def list_tasks(proj):
    """Tasks hoàn thành (có report file). Aggregate cost/agents từ tokens."""
    root = os.path.join(REPORTS, proj)
    # Aggregate per task_id
    evs = _read_tokens(proj)
    agg = {}
    for e in evs:
        if e.get("event") != "end": continue
        tid = e.get("task_id");
        if not tid: continue
        a = agg.setdefault(tid, {"cost": 0.0, "duration_ms": 0, "agents": [], "in": 0, "out": 0, "cache_read": 0, "mode": e.get("mode", "")})
        a["cost"] += e.get("cost_usd", 0) or 0
        a["duration_ms"] += e.get("duration_ms", 0) or 0
        a["in"] += e.get("input_tokens", 0) or 0
        a["out"] += e.get("output_tokens", 0) or 0
        a["cache_read"] += e.get("cache_read", 0) or 0
        ag = e.get("agent", "")
        if ag and ag not in a["agents"]: a["agents"].append(ag)
    # Scan report files
    tasks = []
    for kind in ("features", "bugs"):
        d = os.path.join(root, kind)
        if not os.path.isdir(d): continue
        for f in sorted(os.listdir(d), reverse=True):
            if not f.endswith(".md"): continue
            full = os.path.join(d, f)
            # filename = "<YYYY-MM-DD>-<task_id>.md", task_id = "<ts>-<rand>"
            stem = f[:-3]
            m = re.match(r"^\d{4}-\d{2}-\d{2}-(.+)$", stem)
            tid = m.group(1) if m else stem
            try:
                with open(full) as fh: head = fh.readline()
            except Exception: continue
            title = head.lstrip("# ").strip()
            if not title or title.endswith(".md"):
                title = f"({kind[:-1]}) {stem}"
            info = agg.get(tid, {})
            tasks.append({
                "kind": kind, "id": stem, "task_id": tid, "title": title,
                "mtime": os.path.getmtime(full),
                "cost_usd": round(info.get("cost", 0), 4),
                "duration_ms": info.get("duration_ms", 0),
                "agents": info.get("agents", []),
                "input_tokens": info.get("in", 0),
                "output_tokens": info.get("out", 0),
                "cache_read": info.get("cache_read", 0),
                "mode": info.get("mode", kind[:-1]),
            })
    tasks.sort(key=lambda t: t["mtime"], reverse=True)
    return tasks

def task_detail(proj, task_filename):
    """task_filename = <date>-<task_id> (không có .md)"""
    if not _valid_tid(task_filename):
        return {"error": "invalid task id"}
    root = os.path.join(REPORTS, proj)
    for kind in ("features", "bugs"):
        p = _safe_join(root, kind, task_filename + ".md")
        if p and os.path.isfile(p):
            with open(p) as f: content = f.read()
            # parse task_id để lấy timeline từ tokens
            m = re.match(r"^\d{4}-\d{2}-\d{2}-(.+)$", task_filename)
            tid = m.group(1) if m else task_filename
            timeline = _task_timeline(proj, tid)
            return {"kind": kind, "content": content, "timeline": timeline, "task_id": tid}
    return {"error": "not found"}

def _task_timeline(proj, task_id):
    """Trả về sequence agent steps cho 1 task_id (orchestrator → coder → reviewer → ...)."""
    evs = _read_tokens(proj)
    steps = []
    pending = {}  # agent -> list of start events
    for e in evs:
        if e.get("task_id") != task_id: continue
        ag = e.get("agent")
        if not ag: continue
        if e.get("event") == "start":
            pending[ag] = pending.get(ag, []) + [e]
        elif e.get("event") == "end":
            starts = pending.get(ag, [])
            start_ev = starts.pop(0) if starts else {}
            pending[ag] = starts
            steps.append({
                "agent": ag,
                "start": start_ev.get("ts"),
                "end": e.get("ts"),
                "duration_ms": e.get("duration_ms", 0),
                "cost_usd": e.get("cost_usd", 0),
                "input_tokens": e.get("input_tokens", 0),
                "output_tokens": e.get("output_tokens", 0),
                # provider/model: ưu tiên end event (đầy đủ), fallback start (lúc post.sh chưa chạy)
                "model": e.get("model") or start_ev.get("model", ""),
                "provider": e.get("provider") or start_ev.get("provider", "claude"),
                "terminal_reason": e.get("terminal_reason", ""),
                "is_error": e.get("is_error", False),
            })
    # in-flight (start chưa end)
    for ag, starts in pending.items():
        for s in starts:
            steps.append({"agent": ag, "start": s.get("ts"), "end": None,
                          "duration_ms": 0, "cost_usd": 0, "input_tokens": 0, "output_tokens": 0,
                          "model": s.get("model", ""), "provider": s.get("provider", "claude"),
                          "running": True})
    steps.sort(key=lambda s: s.get("start") or "")
    return steps

def _parse_ts(s):
    try: return datetime.fromisoformat((s or "").replace("Z", "+00:00"))
    except Exception: return None

def live_tasks(proj):
    """Task_id có agent start chưa end VÀ start nằm trong cửa sổ LIVE_WINDOW_MIN phút.
    Start cũ hơn = orphan (pagent crash hoặc Ctrl+C trước khi post.sh chạy), bỏ qua."""
    evs = _read_tokens(proj)
    cutoff = datetime.now(timezone.utc) - timedelta(minutes=LIVE_WINDOW_MIN)
    last_start = {}  # (tid, agent) -> {ts, provider, model} của start gần nhất
    end_count = {}   # (tid, agent) -> số end gặp
    start_count = {} # (tid, agent) -> số start gặp
    meta = {}
    for e in evs:
        tid = e.get("task_id"); ag = e.get("agent")
        if not tid: continue
        if tid not in meta:
            meta[tid] = {"task": e.get("task", ""), "mode": e.get("mode", ""), "ts": e.get("ts")}
        meta[tid]["ts"] = e.get("ts")
        if not ag: continue
        key = (tid, ag)
        if e.get("event") == "start":
            start_count[key] = start_count.get(key, 0) + 1
            last_start[key] = {"ts": e.get("ts"),
                                "provider": e.get("provider", "claude"),
                                "model": e.get("model", "")}
        elif e.get("event") == "end":
            end_count[key] = end_count.get(key, 0) + 1
    live = {}
    for key, sc in start_count.items():
        ec = end_count.get(key, 0)
        if sc <= ec: continue
        info = last_start.get(key, {})
        ts = _parse_ts(info.get("ts"))
        if not ts or ts < cutoff: continue
        tid, ag = key
        live.setdefault(tid, []).append({
            "agent": ag, "provider": info.get("provider", "claude"),
            "model": info.get("model", ""), "started": info.get("ts"),
        })
    return [
        {"task_id": tid, "active": ags, "task": meta[tid]["task"],
         "mode": meta[tid]["mode"], "last_ts": meta[tid]["ts"],
         "timeline": _task_timeline(proj, tid)}
        for tid, ags in sorted(live.items(), key=lambda x: meta[x[0]]["ts"], reverse=True)
    ]

def agent_stats(proj):
    """Per-agent: count, total cost, avg duration, breakdown theo provider/model."""
    evs = _read_tokens(proj)
    stats = {}
    for e in evs:
        if e.get("event") != "end": continue
        ag = e.get("agent");
        if not ag: continue
        s = stats.setdefault(ag, {"runs": 0, "cost": 0.0, "duration_ms": 0,
                                   "tokens_out": 0, "by_model": {}})
        s["runs"] += 1
        s["cost"] += e.get("cost_usd", 0) or 0
        s["duration_ms"] += e.get("duration_ms", 0) or 0
        s["tokens_out"] += e.get("output_tokens", 0) or 0
        key = f"{e.get('provider', 'claude')}/{e.get('model', 'unknown')}"
        m = s["by_model"].setdefault(key, {"runs": 0, "cost": 0.0})
        m["runs"] += 1
        m["cost"] += e.get("cost_usd", 0) or 0
    out = []
    for ag, s in sorted(stats.items(), key=lambda x: -x[1]["cost"]):
        by_model = sorted(
            [{"key": k, "runs": v["runs"], "cost_usd": round(v["cost"], 4)}
             for k, v in s["by_model"].items()],
            key=lambda x: -x["cost_usd"])
        out.append({"agent": ag, "runs": s["runs"],
                    "cost_usd": round(s["cost"], 4),
                    "avg_duration_ms": s["duration_ms"] // max(s["runs"], 1),
                    "total_tokens_out": s["tokens_out"],
                    "by_model": by_model})
    return out

# ───────── HTTP handler ─────────

class H(BaseHTTPRequestHandler):
    def _j(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def _safe_error(self, exc):
        """Luôn cố trả JSON 500 khi handler ném exception ngoài dự kiến —
        tránh để stdlib phát trang HTML (gây 'Unexpected token <' phía client)."""
        try:
            self._j({"error": f"lỗi server: {exc}"}, 500)
        except Exception:
            pass  # response đã gửi dở — không thể ghi đè

    def _f(self, name, mime):
        try:
            with open(os.path.join(HERE, name), "rb") as f: body = f.read()
        except FileNotFoundError:
            self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def _read_body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except (ValueError, TypeError):
            n = 0
        if n <= 0:
            return b""
        if n > MAX_BODY:
            return None  # signal too-large
        return self.rfile.read(n)

    def do_POST(self):
        try:
            path = urlparse(self.path).path
            m = re.match(r"^/api/projects/([^/]+)/(chat|upload)$", path)
            if not m:
                return self._j({"error": "not found"}, 404)
            proj = unquote(m.group(1))
            if not _valid_proj(proj):
                return self._j({"error": "invalid or unknown project"}, 400)
            if m.group(2) == "chat":
                return self._chat(proj)
            return self._upload(proj)
        except Exception as e:
            self._safe_error(e)

    def _chat(self, proj):
        raw = self._read_body()
        if raw is None:
            return self._j({"error": "body quá lớn"}, 413)
        try:
            data = json.loads(raw or b"{}")
        except Exception:
            return self._j({"error": "JSON không hợp lệ"}, 400)

        mode = data.get("mode")
        if mode not in ("feature", "fix"):
            return self._j({"error": "mode phải là 'feature' hoặc 'fix'"}, 400)
        task = (data.get("task") or "").strip()
        if not task:
            return self._j({"error": "task rỗng"}, 400)
        figma_url = (data.get("figma_url") or "").strip()

        source = _project_source(proj)
        if not source:
            return self._j({"error": f"chưa biết source path của '{proj}' — chạy `pagent feature/fix` "
                                     "một lần trong source để ghi REPORTS/<proj>/.source"}, 409)
        if not os.path.isdir(source):
            return self._j({"error": f"source path không tồn tại: {source}"}, 409)

        # Chỉ nhận attachment nằm trong REPORTS (đã upload qua /upload).
        safe_atts, has_image = [], False
        for a in (data.get("attachments") or []):
            if not isinstance(a, str):
                continue
            p = os.path.realpath(a)
            if _within_reports(p) and os.path.isfile(p):
                safe_atts.append(p)
                has_image = has_image or _is_image(p)

        pbin = _pagent_bin()
        if not pbin:
            return self._j({"error": "không tìm thấy pagent binary (set env PAGENT_BIN)"}, 500)

        tid = _new_task_id()
        design = has_image or bool(figma_url)
        env = dict(os.environ)
        env["PAGENT_PROJECT"] = proj
        env["PAGENT_REPORT_DIR"] = REPORTS
        env["PAGENT_SOURCE"] = source
        env["PAGENT_TASK_ID"] = tid
        if design:
            env["PAGENT_DESIGN"] = "1"   # gate figma/canvas MCP (xem pagent call_agent)

        full_task = _compose_task(task, safe_atts, figma_url)
        logpath = _safe_join(REPORTS, proj, "chat.log")
        if not logpath:
            return self._j({"error": "đường dẫn log không hợp lệ"}, 400)
        try:
            with open(logpath, "ab") as logf:
                subprocess.Popen([pbin, mode, full_task], cwd=source, env=env,
                                 stdin=subprocess.DEVNULL, stdout=logf, stderr=logf,
                                 start_new_session=True)
        except Exception as e:
            return self._j({"error": f"không spawn được pagent: {e}"}, 500)
        return self._j({"ok": True, "task_id": tid, "mode": mode, "design": design})

    def _upload(self, proj):
        ctype = self.headers.get("Content-Type", "")
        if "multipart/form-data" not in ctype:
            return self._j({"error": "cần multipart/form-data"}, 400)
        bm = re.search(r'boundary=("?)([^";]+)\1', ctype)
        if not bm:
            return self._j({"error": "thiếu boundary"}, 400)
        body = self._read_body()
        if body is None:
            return self._j({"error": "file quá lớn"}, 413)

        parts = _parse_multipart(body, bm.group(2).encode())
        fields, filepart = {}, None
        for p in parts:
            if p["filename"] is not None:
                filepart = p
            elif p["name"]:
                fields[p["name"]] = p["data"].decode("utf-8", "replace").strip()
        if not filepart or not filepart["filename"]:
            return self._j({"error": "thiếu file"}, 400)

        task = fields.get("task", "")
        if not _ID_RE.fullmatch(task) or ".." in task:
            return self._j({"error": "task id không hợp lệ"}, 400)
        fname = os.path.basename(filepart["filename"].replace("\\", "/"))
        if not fname or ".." in fname or not re.fullmatch(r"[A-Za-z0-9_.\- ]+", fname):
            return self._j({"error": "tên file không hợp lệ"}, 400)

        dest_dir = _safe_join(REPORTS, proj, "uploads", task)
        if not dest_dir:
            return self._j({"error": "đường dẫn không hợp lệ"}, 400)
        os.makedirs(dest_dir, exist_ok=True)
        dest = _safe_join(dest_dir, fname)
        if not dest:
            return self._j({"error": "đường dẫn không hợp lệ"}, 400)
        with open(dest, "wb") as f:
            f.write(filepart["data"])
        return self._j({"ok": True, "path": dest, "name": fname,
                        "is_image": _is_image(dest), "size": len(filepart["data"])})

    def do_GET(self):
        try:
            path = urlparse(self.path).path
            if path == "/":               return self._f("index.html", "text/html; charset=utf-8")
            if path == "/app.js":         return self._f("app.js", "application/javascript")
            if path == "/style.css":      return self._f("style.css", "text/css")
            if path == "/api/projects":   return self._j(list_projects())

            def with_proj(handler):
                m = re.match(rf"^/api/projects/([^/]+){suffix}$", path)
                if not m: return False
                proj = unquote(m.group(1))
                if not _valid_proj(proj):
                    self._j({"error": "invalid or unknown project"}, 400); return True
                extras = [unquote(g) for g in m.groups()[1:]]
                handler(proj, *extras); return True

            for suffix, fn in (
                (r"/tasks",        lambda p:    self._j(list_tasks(p))),
                (r"/tasks/(.+)",   lambda p, t: self._j(task_detail(p, t))),
                (r"/live",         lambda p:    self._j(live_tasks(p))),
                (r"/agents",       lambda p:    self._j(agent_stats(p))),
            ):
                if with_proj(fn): return
            self._j({"error": "not found"}, 404)
        except Exception as e:
            self._safe_error(e)

    def log_message(self, fmt, *args): pass  # silent

if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8765"))
    host = os.environ.get("HOST", "127.0.0.1")
    print(f"pagent dashboard → http://{host}:{port}", flush=True)
    print(f"  reports: {REPORTS}", flush=True)
    print(f"  stop:    Ctrl+C", flush=True)
    try:
        ThreadingHTTPServer((host, port), H).serve_forever()
    except KeyboardInterrupt:
        print("\nbye"); sys.exit(0)
