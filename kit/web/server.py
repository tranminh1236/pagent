#!/usr/bin/env python3
"""pagent web dashboard — single-file HTTP server, Python stdlib only."""
import os, json, re, sys, random, shutil, subprocess, signal, threading, time
from datetime import datetime, timezone, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, unquote, parse_qs

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
    for kind in ("features", "bugs", "chores", "findings"):
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
    for kind in ("features", "bugs", "chores", "findings"):
        p = _safe_join(root, kind, task_filename + ".md")
        if p and os.path.isfile(p):
            with open(p) as f: content = f.read()
            # parse task_id để lấy timeline từ tokens
            m = re.match(r"^\d{4}-\d{2}-\d{2}-(.+)$", task_filename)
            tid = m.group(1) if m else task_filename
            timeline = _task_timeline(proj, tid)
            return {"kind": kind, "content": content, "timeline": timeline, "task_id": tid}
    return {"error": "not found"}

def read_workflow(proj):
    """Đọc + parse REPORTS/<proj>/workflow.md thành list section có cấu trúc.
    Trả {exists, path, workflows:[{title, trigger, preconditions, flow[], expected,
    smoke_cmd, related[], added}]}. File thiếu / proj traversal → exists=False.
    Chỉ đọc + parse; smoke_cmd chỉ để hiển thị (web không chạy)."""
    path = _safe_join(REPORTS, proj, "workflow.md")
    if not path or not os.path.isfile(path):
        return {"exists": False, "path": path or "", "workflows": []}
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()

    def _field(line, label):
        m = re.match(r"^\*\*" + re.escape(label) + r":\*\*\s*(.*)$", line)
        return m.group(1).strip() if m else None

    workflows, cur, in_flow = [], None, False
    for line in lines:
        h = re.match(r"^##\s+(.*)$", line)
        if h:
            cur = {"title": h.group(1).strip(), "trigger": "", "preconditions": "",
                   "flow": [], "expected": "", "smoke_cmd": "", "related": [], "added": ""}
            workflows.append(cur)
            in_flow = False
            continue
        if cur is None:
            continue  # bỏ preamble (# Workflow Log …)
        for label, key in (("Trigger", "trigger"), ("Preconditions", "preconditions"),
                           ("Expected outcome", "expected"), ("Added", "added")):
            v = _field(line, label)
            if v is not None:
                cur[key] = v; in_flow = False; break
        else:
            v = _field(line, "Smoke test command")
            if v is not None:
                mb = re.search(r"`([^`]+)`", v)
                cur["smoke_cmd"] = mb.group(1).strip() if mb else v.strip("` ")
                in_flow = False; continue
            v = _field(line, "Related files")
            if v is not None:
                cur["related"] = [x.strip() for x in v.split(",") if x.strip()]
                in_flow = False; continue
            if re.match(r"^\*\*Flow:\*\*", line):
                in_flow = True; continue
            if in_flow:
                fm = re.match(r"^\s*\d+\.\s+(.*)$", line)
                if fm:
                    cur["flow"].append(fm.group(1).strip())
                elif line.strip() != "":
                    in_flow = False
    return {"exists": True, "path": path, "workflows": workflows}

def read_agent_workflow(proj):
    """Đọc + parse REPORTS/<proj>/agent-workflow.md — spec điều phối AI (pseudo-spec
    framework-agnostic do workflow-extractor sinh). Nguồn RIÊNG với read_workflow
    (workflow.md log); KHÔNG chia sẻ parser/schema.
    Trả {exists, path, content, blocks:[{heading, body}]}. File thiếu / proj traversal
    → exists=False. Parser chịu file rỗng/format lệch (không heading) không vỡ: blocks=[]
    nhưng content raw giữ nguyên. Chỉ đọc + hiển thị (read-only, không exec)."""
    path = _safe_join(REPORTS, proj, "agent-workflow.md")
    if not path or not os.path.isfile(path):
        return {"exists": False, "path": path or "", "content": "", "blocks": []}
    with open(path, encoding="utf-8") as f:
        content = f.read()
    blocks, cur = [], None
    for line in content.splitlines():
        h = re.match(r"^##\s+(.*)$", line)
        if h:
            cur = {"heading": h.group(1).strip(), "body": []}
            blocks.append(cur)
            continue
        if cur is not None:
            cur["body"].append(line)
    for b in blocks:
        b["body"] = "\n".join(b["body"]).strip("\n")
    return {"exists": True, "path": path, "content": content, "blocks": blocks}

def read_chat_log(proj, tid, offset=0):
    """Đọc tail log per-task (REPORTS/<proj>/logs/<tid>.log) kể từ byte `offset`.
    Trả {data, offset}: offset mới = vị trí đọc tiếp theo để client tail incremental."""
    try:
        off = max(0, int(offset))
    except (ValueError, TypeError):
        off = 0
    # tid là raw task_id (<ts>-<pid>-<rand>) — dùng _ID_RE như upload task id; _valid_tid
    # chỉ khớp report-file stem (YYYY-MM-DD-…) nên không áp dụng được ở đây.
    if not (_ID_RE.fullmatch(tid or "") and ".." not in (tid or "")):
        return {"error": "task id không hợp lệ"}
    logpath = _safe_join(REPORTS, proj, "logs", tid + ".log")
    if not logpath:
        return {"error": "đường dẫn log không hợp lệ"}
    if not os.path.isfile(logpath):
        return {"data": "", "offset": off}
    try:
        size = os.path.getsize(logpath)
        if off > size:                 # file bị rút gọn/xoay → đọc lại từ đầu
            off = 0
        with open(logpath, "rb") as f:
            f.seek(off)
            chunk = f.read()
        return {"data": chunk.decode("utf-8", "replace"), "offset": off + len(chunk)}
    except Exception as e:
        return {"error": f"đọc log thất bại: {e}"}

def _valid_rawtid(t):
    """task_id thô (<ts>-<pid>-<rand>) — như chat-log, KHÁC _valid_tid (stem report)."""
    return bool(t) and bool(_ID_RE.fullmatch(t)) and ".." not in t

def _is_cancelled(proj, tid):
    m = _safe_join(REPORTS, proj, "runs", tid, "cancelled")
    return bool(m) and os.path.isfile(m)

def cancel_task(proj, tid):
    """Dừng task đang chạy: ghi marker `cancelled` (live ẩn ngay) + kill cây process pagent.
    pagent ghi runs/<tid>/pagent.pid lúc khởi chạy. Web spawn start_new_session=True nên
    pid = group leader → killpg hạ cả claude con. Run khởi từ CLI (pid != pgid) → chỉ kill
    pagent (an toàn, không đụng shell của user)."""
    if not _valid_rawtid(tid):
        return {"error": "task id không hợp lệ"}
    rundir = _safe_join(REPORTS, proj, "runs", tid)
    if not rundir or not os.path.isdir(rundir):
        return {"error": "run dir không tồn tại (task đã xong hoặc chưa khởi chạy?)"}
    # Marker trước khi kill — live_tasks ẩn task ngay cả khi post-hook không ghi 'end'.
    marker = _safe_join(rundir, "cancelled")
    if marker:
        try:
            tmp = marker + ".tmp"
            with open(tmp, "w") as f:
                f.write("1")
            os.replace(tmp, marker)
        except Exception:
            pass
    killed = False
    pidf = _safe_join(rundir, "pagent.pid")
    if pidf and os.path.isfile(pidf):
        try:
            with open(pidf) as f:
                pid = int(f.readline().strip())
        except Exception:
            pid = 0
        if pid > 1:
            try:
                pgid = os.getpgid(pid)
                if pgid == pid:                    # web-spawned: nhóm cô lập → kill cả cây
                    os.killpg(pgid, signal.SIGTERM)
                else:                              # CLI-spawned: chỉ pagent (tránh kill shell)
                    os.kill(pid, signal.SIGTERM)
                killed = True
            except ProcessLookupError:
                killed = False                     # đã thoát rồi
            except Exception:
                pass
    return {"ok": True, "killed": killed}

def plan_pending(proj, tid):
    """Plan đang chờ user xác nhận (pagent ghi runs/<tid>/plan.pending.json khi PAGENT_CONFIRM=1).
    {pending: bool, plan?: {...}}."""
    if not _valid_rawtid(tid):
        return {"error": "task id không hợp lệ"}
    pend = _safe_join(REPORTS, proj, "runs", tid, "plan.pending.json")
    if not pend or not os.path.isfile(pend):
        return {"pending": False}
    try:
        with open(pend) as f:
            plan = json.load(f)
    except Exception:
        return {"pending": False}     # đang ghi dở / hỏng → coi như chưa sẵn sàng
    return {"pending": True, "plan": plan}

_AGENT_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")

# ───────── Settings per-project (công tắc backend web: opencode ↔ claude direct) ─────────
_SETTINGS_DEFAULTS = {"provider": "opencode", "claude_model": "sonnet",
                      "opencode_model": "9router/FREE",
                      "tasks": "0", "jira_url": "", "jira_personal_token": ""}
_PROVIDER_WHITELIST = {"opencode", "claude"}
_CLAUDE_MODEL_RE = re.compile(r"^[A-Za-z0-9.-]{1,64}$")   # tên trần, KHÔNG provider/model
# opencode dùng model dạng provider/model (vd "9router/FREE"); rỗng = không override.
_OPENCODE_MODEL_RE = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")

# Gate task-tracker (Jira Server/DC PAT) — 3 key này KHÔNG nằm ở settings.json mà ở
# .env.pagent của source project: pagent tự source file đó (xem `pagent` auto-load), nên
# đây là single source of truth và KHÔNG cần truyền qua env_extra của _spawn_pagent.
_ENV_SETTINGS = {"tasks": "PAGENT_TASKS", "jira_url": "JIRA_URL",
                 "jira_personal_token": "JIRA_PERSONAL_TOKEN"}
_SECRET_SETTINGS = ("jira_personal_token",)
_SETTINGS_MASK = "********"     # GET trả mask; client gửi lại mask = giữ nguyên giá trị cũ
# URL GỐC của site Jira, https bắt buộc (PAT không đi qua http) — chỉ host, KHÔNG path.
_JIRA_URL_RE = re.compile(r"^https://[A-Za-z0-9._-]+(:\d{1,5})?/?$")
_JIRA_HOST_DENY_RE = re.compile(r"^([0-9]+\.)*[0-9]+$|^localhost$|\.localhost$")
# PAT chỉ nhận charset an toàn cho shell: `pagent` chạy `set -a && . .env.pagent` nên ký tự
# $ ` " ' ; | & \ ( ) trong value = thực thi lệnh. Charset này phủ mọi PAT Jira Server/DC.
_JIRA_PAT_RE = re.compile(r"^[A-Za-z0-9._~+/=-]{1,512}$")

def _jira_url_ok(u):
    """URL gốc Jira hợp lệ: https, chỉ host (+port tuỳ chọn), host là TÊN MIỀN — không IP
    trần, không localhost. Host của JIRA_URL được `taskref_host_fetchable` miễn kiểm dải IP
    nội bộ, nên IP trần ở đây = SSRF metadata service kèm PAT."""
    if not _JIRA_URL_RE.fullmatch(u):
        return False
    host = u[len("https://"):].rstrip("/").split(":", 1)[0].lower()
    return not _JIRA_HOST_DENY_RE.search(host)

# ───────── Settings global (combo list opencode model — dùng chung mọi project) ─────────
_GLOBAL_DEFAULTS = {"opencode_models": ["9router/FREE", "9router/Claude"]}
_OPENCODE_MODELS_MAX = 30

def _global_settings_path():
    return os.path.join(REPORTS, "opencode-models.json")

def read_global_settings():
    """Combo list global (dùng chung mọi project). Thiếu/hỏng → default êm."""
    out = dict(_GLOBAL_DEFAULTS)
    p = _global_settings_path()
    if os.path.isfile(p):
        try:
            with open(p) as f:
                d = json.load(f)
            v = d.get("opencode_models")
            if isinstance(v, list) and v:
                out["opencode_models"] = v
        except Exception:
            pass
    return out

def write_global_settings(models):
    p = _global_settings_path()
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"opencode_models": models}, f)
    os.replace(tmp, p)

def _settings_path(proj):
    return _safe_join(REPORTS, proj, "settings.json")

def read_settings(proj):
    """Settings per-project — merge default. File hỏng/thiếu → default êm."""
    out = dict(_SETTINGS_DEFAULTS)
    p = _settings_path(proj)
    if p and os.path.isfile(p):
        try:
            with open(p) as f:
                d = json.load(f)
            for k in _SETTINGS_DEFAULTS:
                if k in d and k not in _ENV_SETTINGS:
                    out[k] = d[k]
        except Exception:
            pass
    out.update(read_env_settings(proj))
    return out

def _env_pagent_path(proj):
    """.env.pagent mà `pagent` THẬT SỰ nạp — walk-up từ source lên `/`, dừng ở file ĐẦU TIÊN,
    cùng thuật toán `load_env` trong `pagent`. Ghi file mới ở source khi đang có file ở thư mục
    cha sẽ CHE mất file cha (mất ANTHROPIC_BASE_URL/PAGENT_MODEL…) nên phải walk-up cả khi ghi.
    Không tìm thấy file nào → path mặc định ngay tại source."""
    src = _project_source(proj)
    if not src or not os.path.isdir(src):
        return None
    src = os.path.realpath(src)
    d = src
    while d != os.path.dirname(d):
        p = os.path.join(d, ".env.pagent")
        if os.path.isfile(p):
            return p
        d = os.path.dirname(d)
    return os.path.join(src, ".env.pagent")

def _env_quote(val):
    """Bọc single-quote (escape `'` thành `'\\''`) — `pagent` nạp file bằng
    `set -a && . .env.pagent`, single-quote là dạng DUY NHẤT bash không expand."""
    return "'" + val.replace("'", "'\\''") + "'"

def _parse_env_line(line):
    """'export FOO="bar"' → ('FOO', 'bar'). Comment/dòng lạ → (None, '')."""
    s = line.strip()
    if not s or s.startswith("#") or "=" not in s:
        return None, ""
    if s.startswith("export "):
        s = s[7:].lstrip()
    key, _, val = s.partition("=")
    key = key.strip()
    val = val.strip()
    if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
        quote = val[0]
        val = val[1:-1]
        if quote == "'":
            val = val.replace("'\\''", "'")
    return key, val

def read_env_settings(proj):
    """3 key gate task-tracker đọc từ .env.pagent của source. Thiếu file/hỏng → default êm.
    Giá trị trả về là PLAINTEXT — đường ra HTTP phải đi qua mask_settings()."""
    out = {k: _SETTINGS_DEFAULTS[k] for k in _ENV_SETTINGS}
    p = _env_pagent_path(proj)
    if not p or not os.path.isfile(p):
        return out
    by_env = {v: k for k, v in _ENV_SETTINGS.items()}
    try:
        with open(p) as f:
            for line in f:
                key, val = _parse_env_line(line)
                if key in by_env:
                    out[by_env[key]] = val
    except Exception:
        pass
    return out

def write_env_settings(proj, updates):
    """Merge {ENV_NAME: value} vào .env.pagent của source — giữ nguyên mọi dòng khác, atomic,
    mode 0600 (file chứa PAT). Value rỗng → XOÁ dòng thay vì ghi key rỗng."""
    p = _env_pagent_path(proj)
    if not p:
        return False
    lines = []
    if os.path.isfile(p):
        with open(p) as f:
            lines = f.read().splitlines()
    kept, seen = [], set()
    for line in lines:
        key, _ = _parse_env_line(line)
        if key not in updates:
            kept.append(line)
            continue
        seen.add(key)
        if updates[key]:
            kept.append("%s=%s" % (key, _env_quote(updates[key])))
    for key, val in updates.items():
        if val and key not in seen:
            kept.append("%s=%s" % (key, _env_quote(val)))
    tmp = p + ".tmp"
    fd = os.open(tmp, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(kept) + "\n")
    os.replace(tmp, p)
    os.chmod(p, 0o600)
    return True

def mask_settings(st):
    """Che secret trước khi ra HTTP — GET /settings KHÔNG BAO GIỜ trả PAT plaintext."""
    out = dict(st)
    for k in _SECRET_SETTINGS:
        if out.get(k):
            out[k] = _SETTINGS_MASK
    return out

def resume_pending(proj, tid):
    """Agents đang chờ cấp thêm lượt sau max_turns (pagent ghi runs/<tid>/
    resume.pending.<agent>.json rồi poll decision — xem kit/lib/resume.sh).
    {pending: [{agent, session_id, used_turns, default_turns}...]}."""
    if not _valid_rawtid(tid):
        return {"pending": []}
    rundir = _safe_join(REPORTS, proj, "runs", tid)
    if not rundir or not os.path.isdir(rundir):
        return {"pending": []}
    out = []
    for name in sorted(os.listdir(rundir)):
        if not (name.startswith("resume.pending.") and name.endswith(".json")):
            continue
        try:
            with open(os.path.join(rundir, name)) as f:
                d = json.load(f)
            out.append({"agent": d["agent"], "session_id": d.get("session_id", ""),
                        "used_turns": d.get("used_turns", 0),
                        "default_turns": d.get("default_turns", 20)})
        except Exception:
            continue      # đang ghi dở / hỏng → bỏ qua, poll sau sẽ thấy
    return {"pending": out}

def _step_models(e):
    """Danh sách TẤT CẢ model 1 lượt agent đã dùng. Ưu tiên field `models` (post.sh mới);
    fallback model đơn (event cũ) để không vỡ timeline lịch sử."""
    ms = e.get("models")
    if isinstance(ms, list) and ms:
        return ms
    m = e.get("model")
    if m and m != "unknown":
        return [{"model": m, "input_tokens": e.get("input_tokens", 0),
                 "output_tokens": e.get("output_tokens", 0),
                 "cache_read": e.get("cache_read", 0),
                 "cost_usd": e.get("cost_usd", 0)}]
    return []

def _merge_models(lists):
    """Gộp nhiều models[] (union theo tên model, cộng tokens/cost) — cho node cha fan-out."""
    acc = {}
    order = []
    for ms in lists:
        for m in ms or []:
            k = m.get("model", "")
            if k not in acc:
                acc[k] = {"model": k, "input_tokens": 0, "output_tokens": 0,
                          "cache_read": 0, "cost_usd": 0.0}
                order.append(k)
            acc[k]["input_tokens"] += m.get("input_tokens", 0) or 0
            acc[k]["output_tokens"] += m.get("output_tokens", 0) or 0
            acc[k]["cache_read"] += m.get("cache_read", 0) or 0
            acc[k]["cost_usd"] += m.get("cost_usd", 0) or 0
    return [acc[k] for k in order]

def _task_timeline(proj, task_id):
    """Sequence agent steps cho 1 task_id (orchestrator → coder → reviewer → ...).
    Subtask (coder/tester fan-out, có subtask_id) được gom thành 1 node cha với
    `subagents` để web bung ra xem từng subtask làm gì."""
    evs = _read_tokens(proj)
    steps = []
    pending = {}  # (agent, subtask_id) -> list of start events (FIFO pairing)
    for e in evs:
        if e.get("task_id") != task_id: continue
        ag = e.get("agent")
        if not ag: continue
        key = (ag, e.get("subtask_id") or "")
        if e.get("event") == "start":
            pending[key] = pending.get(key, []) + [e]
        elif e.get("event") == "end":
            starts = pending.get(key, [])
            start_ev = starts.pop(0) if starts else {}
            pending[key] = starts
            steps.append({
                "agent": ag,
                "subtask_id": e.get("subtask_id") or start_ev.get("subtask_id") or "",
                "subtask": e.get("subtask") or start_ev.get("subtask") or "",
                "start": start_ev.get("ts"),
                "end": e.get("ts"),
                "duration_ms": e.get("duration_ms", 0),
                "cost_usd": e.get("cost_usd", 0),
                "input_tokens": e.get("input_tokens", 0),
                "output_tokens": e.get("output_tokens", 0),
                "models": _step_models(e),
                # provider/model: ưu tiên end event (đầy đủ), fallback start (lúc post.sh chưa chạy)
                "model": e.get("model") or start_ev.get("model", ""),
                "provider": e.get("provider") or start_ev.get("provider", "claude"),
                "terminal_reason": e.get("terminal_reason", ""),
                "is_error": e.get("is_error", False),
                "running": False,
            })
    # in-flight (start chưa end)
    for (ag, _sub), starts in pending.items():
        for s in starts:
            steps.append({"agent": ag, "subtask_id": s.get("subtask_id") or "",
                          "subtask": s.get("subtask") or "",
                          "start": s.get("ts"), "end": None,
                          "duration_ms": 0, "cost_usd": 0, "input_tokens": 0, "output_tokens": 0,
                          "models": [], "model": s.get("model", ""),
                          "provider": s.get("provider", "claude"), "running": True})
    steps.sort(key=lambda s: s.get("start") or "")
    return _group_subtasks(steps)

def _group_subtasks(steps):
    """Gom các step có subtask_id thành node cha (1 node/agent), giữ step thường nguyên vẹn."""
    nodes = []
    parents = {}  # agent -> parent node (đã chèn vào nodes)
    for s in steps:
        if not s.get("subtask_id"):
            nodes.append(s)
            continue
        p = parents.get(s["agent"])
        if p is None:
            p = {"agent": s["agent"], "provider": s.get("provider", "claude"),
                 "start": s.get("start"), "end": s.get("end"),
                 "duration_ms": 0, "cost_usd": 0.0, "input_tokens": 0, "output_tokens": 0,
                 "models": [], "running": False, "is_error": False,
                 "terminal_reason": "", "is_group": True, "subagents": []}
            parents[s["agent"]] = p
            nodes.append(p)
        p["subagents"].append(s)
        p["duration_ms"] += s.get("duration_ms", 0) or 0
        p["cost_usd"] += s.get("cost_usd", 0) or 0
        p["input_tokens"] += s.get("input_tokens", 0) or 0
        p["output_tokens"] += s.get("output_tokens", 0) or 0
        p["models"] = _merge_models([p["models"], s.get("models", [])])
        if s.get("running"): p["running"] = True
        if s.get("is_error"): p["is_error"] = True
        if s.get("start") and (not p["start"] or s["start"] < p["start"]):
            p["start"] = s["start"]
        if p["running"]:
            p["end"] = None
        elif s.get("end") and (not p["end"] or s["end"] > p["end"]):
            p["end"] = s["end"]
    nodes.sort(key=lambda n: n.get("start") or "")
    return nodes

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
        if not _is_cancelled(proj, tid)        # task đã bị Cancel → ẩn khỏi Live ngay
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
        # by_model: liệt kê HẾT model đã làm việc (1 lượt có thể >1 model), không chỉ model chính.
        prov = e.get("provider", "claude")
        for mm in _step_models(e):
            key = f"{prov}/{mm.get('model', 'unknown')}"
            m = s["by_model"].setdefault(key, {"runs": 0, "cost": 0.0})
            m["runs"] += 1
            m["cost"] += mm.get("cost_usd", 0) or 0
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

def _tail_log_to_stdout(logpath, is_done, tag, out=None, interval=0.5):
    """Tail log file của 1 run → in ra terminal server (prefix [tag]) để lỗi agent
    hiện ngay nơi chạy `pagent web`. Child ghi TRỰC TIẾP vào file (không pipe) —
    server chết không làm run nghẽn; log file vẫn là nguồn chính cho web UI.
    Kết thúc: is_done() true VÀ đã drain hết phần còn lại của file."""
    out = out or sys.stdout
    pos = 0
    while True:
        done = is_done()          # snapshot TRƯỚC khi đọc — tránh mất dòng ghi xen kẽ
        chunk = b""
        try:
            with open(logpath, "rb") as f:
                f.seek(pos)
                chunk = f.read()
                pos = f.tell()
        except OSError:
            pass                  # file chưa tồn tại / bị xoá → coi như chưa có gì mới
        if chunk:
            for line in chunk.decode("utf-8", "replace").splitlines():
                try:
                    print(f"[{tag}] {line}", file=out, flush=True)
                except Exception:
                    return        # stdout đóng (server tắt) → dừng êm
        if done and not chunk:
            return
        time.sleep(interval)


def _spawn_pagent(proj, source, mode, full_task, tid, env_extra=None):
    """Dựng env + spawn pagent (Popen, start_new_session, log per-task). DÙNG CHUNG cho
    _chat và retry để KHÔNG nhân bản 2 đường spawn (chống drift). env_extra bổ sung/ghi
    đè lên env base. Trả (err_dict, status): err_dict=None khi spawn OK."""
    pbin = _pagent_bin()
    if not pbin:
        return {"error": "không tìm thấy pagent binary (set env PAGENT_BIN)"}, 500
    env = dict(os.environ)
    env["PAGENT_PROJECT"] = proj
    env["PAGENT_REPORT_DIR"] = REPORTS
    env["PAGENT_SOURCE"] = source
    env["PAGENT_TASK_ID"] = tid
    # Công tắc backend từ web (settings.json) — ý định user ĐÈ env kế thừa của shell
    # (bài học PAGENT_MODEL=9router/Claude rơi rớt); env_extra nội bộ vẫn đè được ở dưới.
    sp = _settings_path(proj)
    st = read_settings(proj)                 # luôn merge default (opencode_model=9router/FREE)
    if sp and os.path.isfile(sp):
        env["PAGENT_PROVIDER"] = st["provider"]
        env["PAGENT_CLAUDE_MODEL"] = st["claude_model"]
    # Chỉ set PAGENT_MODEL (dạng provider/model) khi backend là opencode. Provider claude
    # KHÔNG cần — set sẽ leak default '9router/FREE' xuống START event → badge in-flight
    # hiện 'claude · FREE' dù provider=claude (badge END đã đúng nhờ post.sh).
    if st["provider"] == "opencode" and st.get("opencode_model"):
        env["PAGENT_MODEL"] = st["opencode_model"]   # web default đè leak kể cả khi chưa có settings.json
    for k, v in (env_extra or {}).items():
        env[k] = v
    # Web spawn luôn bật resume gate (max_turns → chờ user cấp thêm lượt qua button
    # Live view) — trừ khi env tắt tường minh (PAGENT_RESUME=0).
    env.setdefault("PAGENT_RESUME", "1")
    # Backend mặc định là opencode CLI: PAGENT_MODEL dạng provider/model ("9router/Claude")
    # là format ĐÚNG — không validate model ở đây (provider claude ẩn tự chịu model hợp lệ).
    logdir = _safe_join(REPORTS, proj, "logs")
    if not logdir:
        return {"error": "đường dẫn log không hợp lệ"}, 400
    os.makedirs(logdir, exist_ok=True)
    logpath = _safe_join(logdir, tid + ".log")   # per-task: 1 file/task để tail riêng
    if not logpath:
        return {"error": "đường dẫn log không hợp lệ"}, 400
    try:
        with open(logpath, "ab") as logf:
            proc = subprocess.Popen([pbin, mode, full_task], cwd=source, env=env,
                                    stdin=subprocess.DEVNULL, stdout=logf, stderr=logf,
                                    start_new_session=True)
    except Exception as e:
        return {"error": f"không spawn được pagent: {e}"}, 500
    # Tail log run ra terminal server — lỗi agent hiện ngay nơi chạy `pagent web`
    # thay vì nằm câm trong logs/<tid>.log. PAGENT_WEB_QUIET=1 → tắt.
    if os.environ.get("PAGENT_WEB_QUIET") != "1":
        tag = tid.rsplit("-", 1)[-1]
        threading.Thread(target=_tail_log_to_stdout,
                         args=(logpath, lambda: proc.poll() is not None, tag),
                         daemon=True).start()
    return None, None

def _died_of_max_turns(proj, tid):
    """True nếu run đã KẾT THÚC vì chạm max_turns (đọc terminal_reason từ timeline tokens
    — cùng nguồn Live card). Run đang live / xong bình thường → False → chống spawn
    trùng & DoS. `.run.lock` của pagent là hàng rào bổ trợ, không thay bước này."""
    for step in _task_timeline(proj, tid):
        if "max_turns" in (step.get("terminal_reason") or ""):
            return True
        for sub in step.get("subagents") or []:
            if "max_turns" in (sub.get("terminal_reason") or ""):
                return True
    return False

def _retry_wants_design(task_text):
    """Re-derive cờ design khi retry (PAGENT_DESIGN không persist): task.txt còn ảnh
    (đã upload trong REPORTS) hoặc URL figma → bật lại gate design cho agent design-gated."""
    if "figma.com" in task_text.lower():
        return True
    for tok in task_text.split():
        if _is_image(tok) and _within_reports(tok) and os.path.isfile(tok):
            return True
    return False

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
            if path == "/api/settings/opencode-models":
                return self._opencode_models_post()
            md = re.match(r"^/api/projects/([^/]+)/plan/(.+)$", path)
            if md:
                proj = unquote(md.group(1))
                if not _valid_proj(proj):
                    return self._j({"error": "invalid or unknown project"}, 400)
                return self._decision(proj, unquote(md.group(2)))
            mc = re.match(r"^/api/projects/([^/]+)/cancel/(.+)$", path)
            if mc:
                proj = unquote(mc.group(1))
                if not _valid_proj(proj):
                    return self._j({"error": "invalid or unknown project"}, 400)
                return self._j(cancel_task(proj, unquote(mc.group(2))))
            mr = re.match(r"^/api/projects/([^/]+)/retry/(.+)$", path)
            if mr:
                proj = unquote(mr.group(1))
                if not _valid_proj(proj):
                    return self._j({"error": "invalid or unknown project"}, 400)
                return self._retry(proj, unquote(mr.group(2)))
            mz = re.match(r"^/api/projects/([^/]+)/resume/(.+)$", path)
            if mz:
                proj = unquote(mz.group(1))
                if not _valid_proj(proj):
                    return self._j({"error": "invalid or unknown project"}, 400)
                return self._resume_decision(proj, unquote(mz.group(2)))
            ms = re.match(r"^/api/projects/([^/]+)/settings$", path)
            if ms:
                proj = unquote(ms.group(1))
                if not _valid_proj(proj):
                    return self._j({"error": "invalid or unknown project"}, 400)
                return self._settings_post(proj)
            mdel = re.match(r"^/api/projects/([^/]+)/delete$", path)
            if mdel:
                proj = unquote(mdel.group(1))
                if not _valid_proj(proj):
                    return self._j({"error": "invalid or unknown project"}, 400)
                return self._delete_project(proj)
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

    def _delete_project(self, proj):
        """Soft-delete: mv REPORTS/<proj> → REPORTS/.trash/<proj>-<UTC-ts>.

        Chỉ đụng thư mục reports của project (KHÔNG đụng source code thật). Từ chối khi
        project đang có run live (tránh xoá giữa chừng). .trash bị list_projects() ẩn (dir
        bắt đầu bằng '.') nên project biến khỏi dashboard; muốn sạch đĩa thì xoá .trash tay.
        """
        if live_tasks(proj):
            return self._j({"error": "project đang có run chạy — dừng trước khi xoá"}, 409)
        src = _safe_join(REPORTS, proj)
        if not src or not os.path.isdir(src):
            return self._j({"error": "invalid or unknown project"}, 400)
        ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
        dest = _safe_join(REPORTS, ".trash", f"{proj}-{ts}")
        if not dest:
            return self._j({"error": "đường dẫn thùng rác không hợp lệ"}, 400)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.move(src, dest)
        return self._j({"ok": True, "trashed_to": dest})

    def _decision(self, proj, tid):
        """Web POST quyết định plan → ghi runs/<tid>/decision.json để pagent đọc (atomic)."""
        if not _valid_rawtid(tid):
            return self._j({"error": "task id không hợp lệ"}, 400)
        raw = self._read_body()
        if raw is None:
            return self._j({"error": "body quá lớn"}, 413)
        try:
            data = json.loads(raw or b"{}")
        except Exception:
            return self._j({"error": "JSON không hợp lệ"}, 400)
        action = data.get("action")
        if action not in ("run", "edit", "cancel"):
            return self._j({"error": "action phải là run|edit|cancel"}, 400)
        extra = (data.get("extra") or "").strip()
        if action == "edit" and not extra:
            return self._j({"error": "cần nội dung sửa plan"}, 400)
        rundir = _safe_join(REPORTS, proj, "runs", tid)
        if not rundir or not os.path.isdir(rundir):
            return self._j({"error": "run dir không tồn tại (task đã xong hoặc chưa khởi chạy?)"}, 409)
        decpath = _safe_join(rundir, "decision.json")
        if not decpath:
            return self._j({"error": "đường dẫn không hợp lệ"}, 400)
        tmp = decpath + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"action": action, "extra": extra}, f)
        os.replace(tmp, decpath)   # atomic — pagent không bao giờ đọc file ghi dở
        return self._j({"ok": True, "action": action})

    def _settings_post(self, proj):
        """POST {provider?, claude_model?, opencode_model?} → merge vào REPORTS/<proj>/
        settings.json; {tasks?, jira_url?, jira_personal_token?} → merge vào .env.pagent của
        source (cả hai atomic). Whitelist chặt — field lạ bị bỏ; sai → 400 không ghi gì."""
        raw = self._read_body()
        if raw is None:
            return self._j({"error": "body quá lớn"}, 413)
        try:
            data = json.loads(raw or b"{}")
        except Exception:
            return self._j({"error": "JSON không hợp lệ"}, 400)
        cur = read_settings(proj)
        if "provider" in data:
            p = data["provider"]
            if not isinstance(p, str) or p not in _PROVIDER_WHITELIST:
                return self._j({"error": "provider phải là opencode|claude"}, 400)
            cur["provider"] = p
        if "claude_model" in data:
            m = data["claude_model"]
            if not isinstance(m, str) or not _CLAUDE_MODEL_RE.fullmatch(m):
                return self._j({"error": "claude_model phải là tên trần (vd sonnet, opus) — không phải provider/model"}, 400)
            cur["claude_model"] = m
        if "opencode_model" in data:
            m = data["opencode_model"]
            if not isinstance(m, str) or (m != "" and (len(m) > 128 or not _OPENCODE_MODEL_RE.fullmatch(m))):
                return self._j({"error": "opencode_model phải dạng provider/model (vd 9router/FREE) hoặc rỗng"}, 400)
            cur["opencode_model"] = m
        env_updates = {}
        if "tasks" in data:
            t = data["tasks"]
            if not (t is True or t is False or t in ("0", "1")):
                return self._j({"error": "tasks phải là true|false (hoặc \"0\"|\"1\")"}, 400)
            on = t is True or t == "1"
            cur["tasks"] = "1" if on else "0"
            env_updates["PAGENT_TASKS"] = "1" if on else ""
        if "jira_url" in data:
            u = data["jira_url"]
            if not isinstance(u, str) or (u != "" and (len(u) > 256 or not _jira_url_ok(u))):
                return self._j({"error": "jira_url phải là URL gốc https theo tên miền "
                                         "(vd https://jira.cty.vn) — không kèm /browse/<KEY>, "
                                         "không IP trần, không localhost"}, 400)
            cur["jira_url"] = u
            env_updates["JIRA_URL"] = u
        # PAT: mask = client echo lại giá trị đã che → no-op. Lỗi KHÔNG echo giá trị.
        if "jira_personal_token" in data and data["jira_personal_token"] != _SETTINGS_MASK:
            tok = data["jira_personal_token"]
            if not isinstance(tok, str) or (tok != "" and not _JIRA_PAT_RE.fullmatch(tok)):
                return self._j({"error": "jira_personal_token không hợp lệ (chuỗi in được, ≤512 ký tự)"}, 400)
            cur["jira_personal_token"] = tok
            env_updates["JIRA_PERSONAL_TOKEN"] = tok
        # Validate CẢ hai đích TRƯỚC mọi write — .env.pagent và settings.json là 2 store riêng,
        # ghi store đầu rồi mới phát hiện store sau hỏng sẽ để lại trạng thái nửa vời.
        path = _settings_path(proj)
        if not path:
            return self._j({"error": "đường dẫn không hợp lệ"}, 400)
        if env_updates and not write_env_settings(proj, env_updates):
            return self._j({"error": f"chưa biết source path của '{proj}' — không ghi được .env.pagent"}, 409)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump({k: v for k, v in cur.items() if k not in _ENV_SETTINGS}, f)
        os.replace(tmp, path)
        return self._j(mask_settings(cur))

    def _opencode_models_post(self):
        """POST {opencode_models: [...]} → ghi đè list global (atomic). Mỗi phần tử phải
        dạng provider/model; dedup giữ thứ tự; 1..MAX phần tử. Sai → 400 không ghi."""
        raw = self._read_body()
        if raw is None:
            return self._j({"error": "body quá lớn"}, 413)
        try:
            data = json.loads(raw or b"{}")
        except Exception:
            return self._j({"error": "JSON không hợp lệ"}, 400)
        lst = data.get("opencode_models")
        if not isinstance(lst, list):
            return self._j({"error": "opencode_models phải là mảng"}, 400)
        seen, out = set(), []
        for m in lst:
            if not isinstance(m, str) or m == "" or len(m) > 128 or not _OPENCODE_MODEL_RE.fullmatch(m):
                return self._j({"error": f"combo không hợp lệ: {m!r} (cần provider/model)"}, 400)
            if m not in seen:
                seen.add(m); out.append(m)
        if not (1 <= len(out) <= _OPENCODE_MODELS_MAX):
            return self._j({"error": f"list phải có 1..{_OPENCODE_MODELS_MAX} combo"}, 400)
        write_global_settings(out)
        return self._j({"opencode_models": out})

    def _resume_decision(self, proj, tid):
        """POST {agent, extra_turns?, action?} → ghi runs/<tid>/resume.decision.<agent>.json
        (atomic) cho pagent đang poll (kit/lib/resume.sh). Chỉ chấp nhận agent ĐANG có
        pending file — không tin client tạo decision tuỳ ý; extra_turns clamp server-side."""
        if not _valid_rawtid(tid):
            return self._j({"error": "task id không hợp lệ"}, 400)
        raw = self._read_body()
        if raw is None:
            return self._j({"error": "body quá lớn"}, 413)
        try:
            data = json.loads(raw or b"{}")
        except Exception:
            return self._j({"error": "JSON không hợp lệ"}, 400)
        agent = data.get("agent") or ""
        if not isinstance(agent, str) or not _AGENT_RE.fullmatch(agent):
            return self._j({"error": "agent không hợp lệ"}, 400)
        action = data.get("action", "resume")
        if action not in ("resume", "stop"):
            return self._j({"error": "action phải là resume|stop"}, 400)
        rundir = _safe_join(REPORTS, proj, "runs", tid)
        pend = _safe_join(rundir or "", f"resume.pending.{agent}.json") if rundir else None
        if not pend or not os.path.isfile(pend):
            return self._j({"error": f"agent '{agent}' không chờ resume (đã xử lý hoặc chưa cạn lượt?)"}, 409)
        # extra_turns: thiếu/rỗng → default_turns của pending; không phải số → 400; clamp [1, ceiling]
        ceiling = int(os.environ.get("PAGENT_MAX_TURNS_CEILING", "60"))
        turns = data.get("extra_turns")
        if turns is None or turns == "":
            try:
                with open(pend) as f:
                    turns = int(json.load(f).get("default_turns", 20))
            except Exception:
                turns = 20
        if isinstance(turns, bool) or not isinstance(turns, int):
            try:
                turns = int(str(turns).strip())
            except (ValueError, TypeError):
                return self._j({"error": "extra_turns phải là số nguyên"}, 400)
        turns = max(1, min(turns, ceiling))
        dec = os.path.join(rundir, f"resume.decision.{agent}.json")
        tmp = dec + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"action": action, "extra_turns": turns}, f)
        os.replace(tmp, dec)   # atomic — pagent không bao giờ đọc file ghi dở
        return self._j({"ok": True, "agent": agent, "action": action, "extra_turns": turns})

    def _retry(self, proj, tid):
        """Retry 1 run chết vì max_turns: đọc task+mode TỪ ĐĨA (runs/<tid>/), clamp
        max_turns server-side, spawn tid MỚI qua _spawn_pagent. Client chỉ gửi max_turns
        (task/mode KHÔNG tin client — chống biến retry thành spawn tuỳ ý)."""
        if not _valid_rawtid(tid):
            return self._j({"error": "task id không hợp lệ"}, 400)
        rundir = _safe_join(REPORTS, proj, "runs", tid)
        if not rundir or not os.path.isdir(rundir):
            return self._j({"error": "run dir không tồn tại"}, 400)
        # Chỉ retry run THỰC SỰ chết vì max_turns (không đụng run live / xong bình thường).
        if not _died_of_max_turns(proj, tid):
            return self._j({"error": "run không kết thúc vì max_turns — từ chối retry"}, 400)
        raw = self._read_body()
        if raw is None:
            return self._j({"error": "body quá lớn"}, 413)
        try:
            data = json.loads(raw or b"{}")
        except Exception:
            return self._j({"error": "JSON không hợp lệ"}, 400)
        # Clamp max_turns server-side vào [1, CEILING] (vá CWE-400 cost/DoS). Không gửi →
        # bump = CEILING (cho retry cơ hội chạy xong, vẫn trong trần cost).
        ceiling = int(os.environ.get("PAGENT_MAX_TURNS_CEILING", "60"))
        if ceiling < 1:
            ceiling = 1
        if data.get("max_turns") is None:
            max_turns = ceiling
        else:
            try:
                max_turns = int(data["max_turns"])
            except (ValueError, TypeError):
                return self._j({"error": "max_turns phải là số nguyên"}, 400)
        max_turns = max(1, min(max_turns, ceiling))
        # Tái dựng task + mode ĐỌC TỪ ĐĨA qua _safe_join (không tin client).
        taskf = _safe_join(rundir, "task.txt")
        modef = _safe_join(rundir, "mode.txt")
        if not taskf or not os.path.isfile(taskf):
            return self._j({"error": "task.txt không tồn tại — không thể retry"}, 400)
        if not modef or not os.path.isfile(modef):
            return self._j({"error": "mode.txt không tồn tại (run cũ trước khi hỗ trợ retry)"}, 400)
        try:
            with open(taskf) as f:
                full_task = f.read().rstrip("\n")
            with open(modef) as f:
                mode = f.readline().strip()
        except Exception as e:
            return self._j({"error": f"đọc run cũ thất bại: {e}"}, 500)
        if not full_task:
            return self._j({"error": "task rỗng"}, 400)
        # Validate mode theo từ vựng ĐÃ-DISPATCH pagent thực ghi vào mode.txt
        # (feature|hotfix|chore|find — `fix`/`bug` đã đổi→`hotfix` TRƯỚC khi set PAGENT_MODE).
        # KHÔNG theo whitelist _chat (sẽ reject oan 'hotfix').
        if not re.fullmatch(r"feature|hotfix|chore|find", mode):
            return self._j({"error": f"mode không hợp lệ trên đĩa: {mode}"}, 400)
        source = _project_source(proj)
        if not source or not os.path.isdir(source):
            return self._j({"error": f"chưa biết source path của '{proj}'"}, 409)
        # Dedup re-retry: `_died_of_max_turns` là thuộc tính VĨNH VIỄN của run cũ → rapid-click
        # / nhiều tab / concurrent POST đều qua gate → mỗi lần spawn 1 pipeline tới ceiling.
        # Marker exclusive `runs/<old_tid>/retried` cho phép retry ĐÚNG MỘT lần; O_EXCL atomic
        # (create-if-not-exists) đóng race concurrent — mẫu marker `cancelled`. (CWE-400 cost.)
        retried = _safe_join(rundir, "retried")
        if not retried:
            return self._j({"error": "đường dẫn không hợp lệ"}, 400)
        # tid MỚI cho lần retry — tránh trộn 2 run trong cùng runs/<tid> + aggregation.
        new_tid = _new_task_id()
        try:
            fd = os.open(retried, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            try:
                os.write(fd, (new_tid + "\n").encode())
            finally:
                os.close(fd)
        except FileExistsError:
            return self._j({"error": "run này đã được retry — từ chối spawn trùng"}, 409)
        except OSError as e:
            return self._j({"error": f"không ghi được marker retry: {e}"}, 500)
        env_extra = {
            "PAGENT_MAX_TURNS": str(max_turns),
            "PAGENT_CONFIRM": "0",     # user đã chủ động bấm Retry → không handshake lại
            "PAGENT_PARENT": tid,      # lineage: liên kết run cũ (cơ chế @<tid> sẵn có)
        }
        if _retry_wants_design(full_task):
            env_extra["PAGENT_DESIGN"] = "1"
        err, status = _spawn_pagent(proj, source, mode, full_task, new_tid, env_extra)
        if err:
            try:
                os.unlink(retried)   # spawn hỏng → gỡ marker để run cũ retry lại được
            except OSError:
                pass
            return self._j(err, status)
        return self._j({"ok": True, "task_id": new_tid, "mode": mode})

    def _chat(self, proj):
        raw = self._read_body()
        if raw is None:
            return self._j({"error": "body quá lớn"}, 413)
        try:
            data = json.loads(raw or b"{}")
        except Exception:
            return self._j({"error": "JSON không hợp lệ"}, 400)

        mode = data.get("mode")
        if mode not in ("feature", "fix", "chore", "find"):
            return self._j({"error": "mode phải là 'feature', 'fix', 'chore' hoặc 'find'"}, 400)
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

        tid = _new_task_id()
        design = has_image or bool(figma_url)
        # Web LUÔN bắt xác nhận plan (handshake qua file) — trừ khi client tắt rõ ràng.
        env_extra = {"PAGENT_CONFIRM": "0" if data.get("no_confirm") is True else "1"}
        if design:
            env_extra["PAGENT_DESIGN"] = "1"   # gate figma/canvas MCP (xem pagent call_agent)

        full_task = _compose_task(task, safe_atts, figma_url)
        err, status = _spawn_pagent(proj, source, mode, full_task, tid, env_extra)
        if err:
            return self._j(err, status)
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
            parsed = urlparse(self.path)
            path = parsed.path
            qs = parse_qs(parsed.query)
            if path == "/":               return self._f("index.html", "text/html; charset=utf-8")
            if path == "/app.js":         return self._f("app.js", "application/javascript")
            if path == "/style.css":      return self._f("style.css", "text/css")
            if path == "/api/projects":   return self._j(list_projects())
            if path == "/api/settings/opencode-models": return self._j(read_global_settings())

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
                (r"/chat-log/(.+)",lambda p, t: self._j(read_chat_log(p, t, (qs.get("offset") or ["0"])[0]))),
                (r"/plan/(.+)",    lambda p, t: self._j(plan_pending(p, t))),
                (r"/resume/(.+)",  lambda p, t: self._j(resume_pending(p, t))),
                (r"/settings",     lambda p:    self._j(mask_settings(read_settings(p)))),
                (r"/live",         lambda p:    self._j(live_tasks(p))),
                (r"/agents",       lambda p:    self._j(agent_stats(p))),
                (r"/workflow",     lambda p:    self._j(read_workflow(p))),
                (r"/agent-workflow", lambda p:  self._j(read_agent_workflow(p))),
            ):
                if with_proj(fn): return
            self._j({"error": "not found"}, 404)
        except Exception as e:
            self._safe_error(e)

    def log_message(self, fmt, *args): pass  # silent

def _serve():
    """Chạy web server trong tiến trình hiện tại (single process, không watcher).
    Đường này dùng cho: child do supervisor spawn, và opt-out PAGENT_WEB_RELOAD=0."""
    port = int(os.environ.get("PORT", "8765"))
    host = os.environ.get("HOST", "127.0.0.1")
    print(f"pagent dashboard → http://{host}:{port}", flush=True)
    print(f"  reports: {REPORTS}", flush=True)
    print(f"  stop:    Ctrl+C", flush=True)
    try:
        ThreadingHTTPServer((host, port), H).serve_forever()
    except KeyboardInterrupt:
        print("\nbye"); sys.exit(0)


def _web_reload_enabled():
    """Auto-reload BẬT mặc định cho mọi `pagent web`; PAGENT_WEB_RELOAD=0 → TẮT
    (rơi về _serve trực tiếp, không supervisor — dùng cho production)."""
    return os.environ.get("PAGENT_WEB_RELOAD", "1") != "0"


def _is_supervised_child():
    """True khi tiến trình này là child do supervisor spawn (marker _PAGENT_WEB_CHILD=1)
    → chạy _serve, KHÔNG tự làm supervisor lần nữa."""
    return os.environ.get("_PAGENT_WEB_CHILD") == "1"


def _reload_next_backoff(cur, cap=8.0):
    """Backoff mũ có cap chống restart-loop khi child crash liên tục (0.5→1→2→4→8s)."""
    return min(cur * 2.0, cap)


def _supervise():
    """Supervisor reload: spawn CHÍNH file này làm child web server; watch mtime của
    kit/web/server.py (chỉ .py — asset js/html/css serve tươi mỗi request qua _f nên
    không cần restart). File đổi → SIGTERM child → waitpid (BLOCK tới khi child thoát
    hẳn + port free) → spawn child mới → hết phục vụ bản stale (root cause '404 not
    found').

    Bất biến: CHỈ quản child web server — KHÔNG đọc runs/<tid>/pagent.pid, không kill
    run pipeline detached. Ctrl+C/SIGTERM → forward xuống child → waitpid → exit sạch
    (không orphan). stdlib-only: os.stat mtime polling."""
    watch_path = os.path.abspath(__file__)
    child_env = dict(os.environ, _PAGENT_WEB_CHILD="1")  # giữ nguyên PORT/HOST/PAGENT_REPORT_DIR
    grace = float(os.environ.get("PAGENT_WEB_RELOAD_GRACE", "5"))
    poll = float(os.environ.get("PAGENT_WEB_RELOAD_POLL", "1"))
    state = {"child": None, "stopping": False}

    def _mtime():
        try:
            return os.stat(watch_path).st_mtime
        except OSError:
            return None

    def _stop_child():
        """SIGTERM child rồi BLOCK chờ thoát hẳn (port free) TRƯỚC khi trả về —
        chống double-bind/EADDRINUSE khi spawn child kế; escalate SIGKILL nếu quá grace."""
        p = state["child"]
        if not p or p.poll() is not None:
            return
        try:
            p.terminate()
        except OSError:
            pass
        try:
            p.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            try:
                p.kill()
            except OSError:
                pass
            try:
                p.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                pass

    def _on_signal(signum, frame):
        state["stopping"] = True
        _stop_child()
        print("\nbye", flush=True)
        sys.exit(0)

    signal.signal(signal.SIGINT, _on_signal)
    signal.signal(signal.SIGTERM, _on_signal)

    print("pagent web: auto-reload BẬT (đặt PAGENT_WEB_RELOAD=0 để tắt)", flush=True)
    backoff = 0.5
    while not state["stopping"]:
        last_mtime = _mtime()
        state["child"] = subprocess.Popen([sys.executable, watch_path], env=child_env,
                                           start_new_session=True)
        started = time.monotonic()
        reason = None
        while not state["stopping"]:
            if state["child"].poll() is not None:
                reason = "crash"
                break
            if _mtime() != last_mtime:
                reason = "change"
                break
            time.sleep(poll)
        if state["stopping"]:
            break
        if reason == "change":
            print("pagent web: server.py đổi → restart", flush=True)
            _stop_child()  # BLOCK tới khi child cũ chết + port free rồi mới loop spawn
            backoff = 0.5
            continue
        # child tự thoát: chạy đủ lâu → healthy, respawn ngay; crash sớm → backoff
        rc = state["child"].poll()
        alive = time.monotonic() - started
        if alive < grace:
            print(f"pagent web: child thoát (rc={rc}) sau {alive:.1f}s → backoff {backoff:.1f}s",
                  flush=True)
            time.sleep(backoff)
            backoff = _reload_next_backoff(backoff)
        else:
            backoff = 0.5


if __name__ == "__main__":
    # Child do supervisor spawn, hoặc opt-out PAGENT_WEB_RELOAD=0 → serve trực tiếp.
    # Mặc định (không child, reload BẬT) → supervisor tự restart child khi server.py đổi.
    if _is_supervised_child() or not _web_reload_enabled():
        _serve()
    else:
        _supervise()
