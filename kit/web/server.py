#!/usr/bin/env python3
"""pagent web dashboard — single-file HTTP server, Python stdlib only."""
import os, json, re, sys
from datetime import datetime, timezone, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, unquote

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
    # group theo (task_id, agent) pair, pick start+end
    steps = []
    pending = {}  # agent -> start_ts
    seen_keys = set()
    for e in evs:
        if e.get("task_id") != task_id: continue
        ag = e.get("agent")
        if not ag: continue
        if e.get("event") == "start":
            pending[ag] = pending.get(ag, []) + [e]
        elif e.get("event") == "end":
            # match với start gần nhất chưa kết thúc
            starts = pending.get(ag, [])
            start_ts = starts.pop(0)["ts"] if starts else None
            pending[ag] = starts
            steps.append({
                "agent": ag,
                "start": start_ts,
                "end": e.get("ts"),
                "duration_ms": e.get("duration_ms", 0),
                "cost_usd": e.get("cost_usd", 0),
                "input_tokens": e.get("input_tokens", 0),
                "output_tokens": e.get("output_tokens", 0),
                "model": e.get("model", ""),
            })
    # in-flight (start chưa end)
    for ag, starts in pending.items():
        for s in starts:
            steps.append({"agent": ag, "start": s["ts"], "end": None, "duration_ms": 0,
                          "cost_usd": 0, "input_tokens": 0, "output_tokens": 0, "model": "", "running": True})
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
    last_start = {}  # (tid, agent) -> ts của start gần nhất
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
            last_start[key] = e.get("ts")
        elif e.get("event") == "end":
            end_count[key] = end_count.get(key, 0) + 1
    live = {}
    for key, sc in start_count.items():
        ec = end_count.get(key, 0)
        if sc <= ec: continue  # tất cả start đã có end
        ts = _parse_ts(last_start.get(key))
        if not ts or ts < cutoff: continue  # orphan, ngoài cửa sổ live
        tid, ag = key
        live.setdefault(tid, []).append(ag)
    return [
        {"task_id": tid, "active_agents": ags, "task": meta[tid]["task"],
         "mode": meta[tid]["mode"], "last_ts": meta[tid]["ts"]}
        for tid, ags in sorted(live.items(), key=lambda x: meta[x[0]]["ts"], reverse=True)
    ]

def agent_stats(proj):
    """Per-agent: count, total cost, avg duration."""
    evs = _read_tokens(proj)
    stats = {}
    for e in evs:
        if e.get("event") != "end": continue
        ag = e.get("agent");
        if not ag: continue
        s = stats.setdefault(ag, {"runs": 0, "cost": 0.0, "duration_ms": 0, "tokens_out": 0})
        s["runs"] += 1
        s["cost"] += e.get("cost_usd", 0) or 0
        s["duration_ms"] += e.get("duration_ms", 0) or 0
        s["tokens_out"] += e.get("output_tokens", 0) or 0
    out = []
    for ag, s in sorted(stats.items(), key=lambda x: -x[1]["cost"]):
        out.append({"agent": ag, "runs": s["runs"],
                    "cost_usd": round(s["cost"], 4),
                    "avg_duration_ms": s["duration_ms"] // max(s["runs"], 1),
                    "total_tokens_out": s["tokens_out"]})
    return out

# ───────── HTTP handler ─────────

class H(BaseHTTPRequestHandler):
    def _j(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def _f(self, name, mime):
        try:
            with open(os.path.join(HERE, name), "rb") as f: body = f.read()
        except FileNotFoundError:
            self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self):
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
