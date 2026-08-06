#!/usr/bin/env bash
# task-ref.sh — I/O thuần cho tham chiếu task: fetch (Google Sheet CSV / attachment Jira)
# + parse file → text ra STDOUT. KHÔNG đọc cờ nghiệp vụ PAGENT_*; caller (pagent) quyết
# định có enrich hay không.
#
# CLI:   task-ref.sh <url>              # Sheet public → CSV text; URL khác → chỉ ghi marker
#        task-ref.sh --attachment <url> # tải bằng PAT Jira (header qua stdin) rồi parse
# Lib:   . task-ref.sh  → taskref_enrich / taskref_parse_file / taskref_fetch_sheet_csv
#
# Bất biến:
#   - Allowlist host CỨNG: host của $JIRA_URL + docs.google.com — khác → bỏ qua. (Figma đọc
#     qua mcp__figma, KHÔNG qua helper: mở thêm host chỉ tạo đích redirect để rò PAT.)
#   - PAT KHÔNG BAO GIỜ lên argv (curl --config - qua stdin), không echo/log, và chỉ đi kèm
#     request tới ĐÚNG host của $JIRA_URL — redirect sang host khác thì bỏ header.
#   - MỌI lỗi → 1 dòng stderr, LUÔN exit/return 0 — không bao giờ fail pipeline.
#   - 1 URL/lần gọi (URL thừa bị bỏ) → caller cap được số link/attachment mỗi run.
#   - Không ghi gì ra $PAGENT_SOURCE/$PAGENT_RUN_DIR: file tạm ở mktemp -d 0700, trap xoá.
# shellcheck shell=bash

TASKREF_MAX_BYTES="${TASKREF_MAX_BYTES:-10485760}"   # 10MB trần tải + trần file trước parse
TASKREF_MAX_LINES="${TASKREF_MAX_LINES:-2000}"       # trần dòng output — chống phình prompt
TASKREF_MAX_TIME="${TASKREF_MAX_TIME:-20}"           # trần giây/1 request curl
TASKREF_PARSE_TIMEOUT="${TASKREF_PARSE_TIMEOUT:-15}" # trần giây/1 lần parse
TASKREF_MAX_REDIRS="${TASKREF_MAX_REDIRS:-3}"
TASKREF_MAX_ZIP_ENTRIES="${TASKREF_MAX_ZIP_ENTRIES:-2000}"

_taskref_warn() { printf 'task-ref: %s\n' "$*" >&2; }

# taskref_url_host <url> — in host đã lowercase, rỗng nếu không phải URL https hợp lệ.
# Userinfo (`user@`) bị cắt và port bị bỏ để so khớp allowlist theo host THẬT.
taskref_url_host() {
  local url="${1:-}" rest host
  [[ "$url" == https://* ]] || return 0
  rest="${url#https://}"
  rest="${rest%%/*}"; rest="${rest%%\?*}"; rest="${rest%%#*}"
  host="${rest##*@}"
  host="${host%%:*}"
  [[ "$host" == *.* ]] || return 0
  printf '%s' "$(printf '%s' "$host" | tr 'A-Z' 'a-z')"
}

# taskref_host_allowed <host> — 0 nếu host nằm trong allowlist CỨNG: host($JIRA_URL) hoặc
# docs.google.com. So khớp bằng '==' — KHÔNG substring (docs.google.com.evil.com bị từ chối).
# IP literal không bao giờ khớp → chặn SSRF metadata.
taskref_host_allowed() {
  local host="${1:-}" jira_host
  [[ -n "$host" ]] || return 1
  [[ "$host" == "docs.google.com" ]] && return 0
  jira_host="$(taskref_url_host "${JIRA_URL:-}")"
  [[ -n "$jira_host" && "$host" == "$jira_host" ]]
}

# taskref_ip_private <ip> — 0 nếu IP thuộc dải loopback/private/link-local/ULA.
taskref_ip_private() {
  case "${1:-}" in
    127.*|10.*|192.168.*|169.254.*|0.*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
    ::1|::|fc??:*|fd??:*|fe8?:*|fe9?:*|fea?:*|feb?:*) return 0 ;;
  esac
  return 1
}

# taskref_resolve_addrs <host> — in IP đã resolve (1/dòng). Thiếu python3 → rỗng.
taskref_resolve_addrs() {
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -c 'import socket,sys
try:
    print("\n".join({i[4][0] for i in socket.getaddrinfo(sys.argv[1], None)}))
except Exception:
    pass' "$1" 2>/dev/null
}

# taskref_host_public <host> — 0 nếu host là tên miền resolve HẾT về IP public.
# Literal IP luôn bị từ chối (allowlist đi theo tên miền, IP trần = dấu hiệu SSRF).
# Resolve rỗng/lỗi → từ chối (fail-closed).
taskref_host_public() {
  local host="${1:-}" addrs addr
  [[ -n "$host" ]] || return 1
  [[ "$host" =~ ^[0-9.]+$ || "$host" == *:* ]] && return 1
  addrs="$(taskref_resolve_addrs "$host")"
  [[ -n "$addrs" ]] || return 1
  while IFS= read -r addr; do
    [[ -n "$addr" ]] || continue
    taskref_ip_private "$addr" && return 1
  done <<<"$addrs"
  return 0
}

# taskref_sheet_csv_url <url> — link Google Sheet → URL CSV export (public, không cred).
# Rỗng nếu không phải docs.google.com/spreadsheets/d/<id>. gid lấy từ fragment hoặc query,
# mặc định 0; id/gid phải khớp charset an toàn (chống path traversal nhét vào URL).
taskref_sheet_csv_url() {
  local url="${1:-}" id gid rest
  [[ "$(taskref_url_host "$url")" == "docs.google.com" ]] || return 0
  rest="${url#https://docs.google.com/spreadsheets/d/}"
  [[ "$rest" != "$url" ]] || return 0
  id="${rest%%/*}"; id="${id%%\?*}"; id="${id%%#*}"
  [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || return 0
  gid="${url##*gid=}"; gid="${gid%%[&#?]*}"
  [[ "$gid" =~ ^[0-9]+$ ]] || gid=0
  printf 'https://docs.google.com/spreadsheets/d/%s/export?format=csv&gid=%s' "$id" "$gid"
}

# taskref_cap_output — filter stdin→stdout: cắt còn $TASKREF_MAX_LINES dòng (thêm marker
# khi cắt) và vô hiệu hoá chuỗi delimiter untrusted để dữ liệu ngoài không thoát khỏi
# block bao mà caller dựng quanh nó.
taskref_cap_output() {
  local max="$TASKREF_MAX_LINES"
  LC_ALL=C tr -d '\000' \
    | sed -e 's/JIRA_DATA_UNTRUSTED/[delimiter-removed]/g' \
    | awk -v max="$max" 'NR<=max{print} END{if (NR>max) printf "[… cắt bớt: %d dòng còn lại]\n", NR-max}'
}

_taskref_marker() { printf '[attachment: %s %s — không parse được]\n' "${1:-?}" "${2:-}"; }

_taskref_file_size() { wc -c <"$1" 2>/dev/null | tr -d ' '; }

# Chạy <cmd...> dưới trần thời gian; thiếu timeout/perl → chạy thẳng.
_taskref_run_limited() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return $?; fi
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' -- "$secs" "$@"; return $?
  fi
  "$@"
}

# XML → text: xoá DOCTYPE (kèm internal subset), đổi tag kết đoạn thành xuống dòng, bóc tag,
# giải mã entity chuẩn. KHÔNG dùng XML parser nên entity ngoài (XXE) không bao giờ được resolve.
_taskref_xml_text() {
  local nl=$'\001'
  tr '\r\n' '  ' \
    | sed -e 's/<!DOCTYPE[^[]*\[[^]]*\]>/ /g' -e 's/<!DOCTYPE[^>]*>/ /g' \
          -e "s|</w:p>|$nl|g" -e "s|</a:p>|$nl|g" -e "s|</si>|$nl|g" \
          -e "s|</row>|$nl|g" -e "s|</w:tr>|$nl|g" -e "s|</text:p>|$nl|g" \
    | tr '\001' '\n' \
    | sed -e 's/<[^>]*>//g' \
          -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&#39;/'/g" -e "s/&apos;/'/g" \
          -e 's/&amp;/\&/g' \
          -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//' \
    | grep -v '^$' || true
}

_taskref_parse_pdf() {
  local bin="${TASKREF_PDFTOTEXT_BIN:-pdftotext}"
  command -v "$bin" >/dev/null 2>&1 || { _taskref_warn "thiếu pdftotext — bỏ qua PDF"; return 1; }
  _taskref_run_limited "$TASKREF_PARSE_TIMEOUT" "$bin" -q -layout "$1" - 2>/dev/null
}

# OOXML (docx/xlsx/pptx) = zip: kiểm số entry + tổng kích thước giải nén (chống zip-bomb)
# trước khi bóc XML của phần chứa text.
_taskref_parse_ooxml() {
  local path="$1" ext="$2" bin="${TASKREF_UNZIP_BIN:-unzip}" entries total members m
  command -v "$bin" >/dev/null 2>&1 || { _taskref_warn "thiếu unzip — bỏ qua $ext"; return 1; }
  entries="$("$bin" -Z1 "$path" 2>/dev/null | grep -c . || true)"
  [[ "$entries" =~ ^[0-9]+$ ]] && (( entries > 0 )) || return 1
  (( entries > TASKREF_MAX_ZIP_ENTRIES )) && { _taskref_warn "zip $entries entry — vượt trần"; return 1; }
  total="$("$bin" -l "$path" 2>/dev/null | tail -1 | awk '{print $1}')"
  [[ "$total" =~ ^[0-9]+$ ]] || { _taskref_warn "zip: không đọc được tổng giải nén — bỏ qua"; return 1; }
  (( total > TASKREF_MAX_BYTES )) && { _taskref_warn "zip giải nén ${total}B — vượt trần"; return 1; }
  case "$ext" in
    docx) members=$'word/document.xml\nword/footnotes.xml' ;;
    xlsx) members='xl/sharedStrings.xml' ;;
    pptx) members="$("$bin" -Z1 "$path" 2>/dev/null | grep '^ppt/slides/slide[0-9]*\.xml$' || true)" ;;
  esac
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    _taskref_run_limited "$TASKREF_PARSE_TIMEOUT" "$bin" -p "$path" "$m" 2>/dev/null \
      | head -c "$TASKREF_MAX_BYTES" | _taskref_xml_text
  done <<<"$members"
}

# taskref_parse_file <path> [name] [url] — in text trích từ file ra stdout.
#   txt/md/csv/tsv/json/log/yaml → đọc thẳng · pdf → pdftotext · docx/xlsx/pptx → unzip+XML
#   loại khác / thiếu tool / quá trần size → chỉ ghi marker tên+URL.
# LUÔN return 0.
taskref_parse_file() {
  local path="${1:-}" name="${2:-}" url="${3:-}" ext size
  name="${name:-${path##*/}}"
  if [[ -z "$path" || ! -f "$path" || ! -r "$path" ]]; then _taskref_marker "$name" "$url"; return 0; fi
  size="$(_taskref_file_size "$path")"
  if [[ -z "$size" ]] || (( size > TASKREF_MAX_BYTES )); then
    _taskref_warn "bỏ qua $name — vượt trần ${TASKREF_MAX_BYTES}B"
    _taskref_marker "$name" "$url"; return 0
  fi
  ext="$(printf '%s' "${name##*.}" | tr 'A-Z' 'a-z')"
  local text=""
  case "$ext" in
    txt|md|markdown|csv|tsv|json|log|yml|yaml) taskref_cap_output <"$path"; return 0 ;;
    pdf)            text="$(_taskref_parse_pdf "$path")" || text="" ;;
    docx|xlsx|pptx) text="$(_taskref_parse_ooxml "$path" "$ext")" || text="" ;;
  esac
  # `case` glob thay vì ${text//[[:space:]]/}: substitution của bash 3.2 (macOS) trên chuỗi
  # cỡ trăm KB treo hàng phút — glob short-circuit ở ký tự non-space đầu tiên.
  case "$text" in
    *[![:space:]]*) : ;;
    *) _taskref_marker "$name" "$url"; return 0 ;;
  esac
  printf '%s\n' "$text" | taskref_cap_output
  return 0
}

# taskref_host_fetchable <host> — allowlist + chặn IP nội bộ.
#   origin (tuỳ chọn) = host của URL gốc: docs.google.com redirect CSV export sang CDN
#   *.googleusercontent.com nên hop đó được chấp nhận, vẫn phải qua kiểm IP public.
# Host của $JIRA_URL CHỈ được miễn kiểm dải nội bộ khi JIRA_ALLOW_PRIVATE bật — cờ này đặt
# được trong .env.pagent nhưng KHÔNG có đường ghi qua HTTP API, nên miễn trừ là quyết định
# của người vận hành. Miễn vô điều kiện thì một JIRA_URL trỏ host resolve về 169.254.169.254
# biến helper thành đường SSRF vào metadata service, kèm PAT.
taskref_host_fetchable() {
  local host="${1:-}" origin="${2:-}" jira_host
  if [[ "$origin" == "docs.google.com" && "$host" == *.googleusercontent.com ]]; then
    taskref_host_public "$host" || { _taskref_warn "bỏ qua $host — resolve về địa chỉ nội bộ"; return 1; }
    return 0
  fi
  taskref_host_allowed "$host" || { _taskref_warn "bỏ qua $host — ngoài allowlist"; return 1; }
  jira_host="$(taskref_url_host "${JIRA_URL:-}")"
  if [[ -n "$jira_host" && "$host" == "$jira_host" ]]; then
    case "${JIRA_ALLOW_PRIVATE:-0}" in 1|true|TRUE|yes|YES|on|ON) return 0 ;; esac
  fi
  taskref_host_public "$host" || { _taskref_warn "bỏ qua $host — resolve về địa chỉ nội bộ"; return 1; }
  return 0
}

# _taskref_curl_once <out> <hdrfile> <url> <auth> — in HTTP code ra stdout.
# KHÔNG -L (redirect được validate thủ công ở _taskref_fetch_url) và KHÔNG bao giờ đặt
# token lên argv: header đi qua `--config -` trên stdin nên `ps` không thấy được.
_taskref_curl_once() {
  local out="$1" hdrf="$2" url="$3" auth="${4:-}" bin="${TASKREF_CURL_BIN:-curl}"
  local args=(-sS --proto '=https' --connect-timeout 5 --max-time "$TASKREF_MAX_TIME"
    --max-filesize "$TASKREF_MAX_BYTES" -o "$out" -D "$hdrf" -w '%{http_code}' --url "$url")
  if [[ -n "$auth" ]]; then
    printf 'header = "Authorization: Bearer %s"\n' "$auth" | "$bin" --config - "${args[@]}"
  else
    "$bin" "${args[@]}" </dev/null
  fi
}

# _taskref_resolve_url <base> <loc> — Location (tuyệt đối/tương đối) → URL https tuyệt đối.
# return 1 (fail-closed) khi loc rỗng, có khoảng trắng/CR/LF, hoặc mang scheme ≠ https://.
# Host của kết quả LUÔN được validate lại ở hop kế — hàm này chỉ dựng chuỗi.
_taskref_resolve_url() {
  local base="${1:-}" loc="${2:-}" authority path dir seg
  [[ -n "$loc" && "$loc" != *[[:space:]]* ]] || return 1
  loc="${loc%%#*}"
  [[ -n "$loc" ]] || return 1
  case "$loc" in
    https://*) printf '%s' "$loc"; return 0 ;;
    //*) printf 'https:%s' "$loc"; return 0 ;;
  esac
  seg="${loc%%\?*}"; seg="${seg%%/*}"
  [[ "$seg" == *:* ]] && return 1
  [[ "$base" == https://* ]] || return 1
  authority="${base#https://}"
  authority="${authority%%/*}"; authority="${authority%%\?*}"
  [[ -n "$authority" ]] || return 1
  case "$loc" in
    /*) printf 'https://%s%s' "$authority" "$loc"; return 0 ;;
  esac
  path="${base#https://}"; path="${path%%\?*}"; path="${path%%#*}"
  path="${path#"$authority"}"
  case "$loc" in
    \?*) printf 'https://%s%s%s' "$authority" "$path" "$loc"; return 0 ;;
  esac
  dir="${path%/*}/"
  printf 'https://%s%s%s' "$authority" "$dir" "$loc"
}

# _taskref_fetch_url <out> <url> [auth] — tải về <out>, tự đi redirect tối đa
# $TASKREF_MAX_REDIRS hop và validate lại host ở TỪNG hop. In HTTP code cuối ra stdout.
# Header Authorization CHỈ đi kèm hop có host TRÙNG host của URL gốc: redirect sang host khác
# (kể cả host trong allowlist) mà vẫn giữ header = gửi Bearer PAT cho bên thứ ba.
_taskref_fetch_url() {
  local out="$1" url="$2" auth="${3:-}" hop=0 code hdrf loc origin host
  command -v "${TASKREF_CURL_BIN:-curl}" >/dev/null 2>&1 || { _taskref_warn "thiếu curl"; return 1; }
  hdrf="$out.hdr"
  origin="$(taskref_url_host "$url")"
  while (( hop <= TASKREF_MAX_REDIRS )); do
    host="$(taskref_url_host "$url")"
    taskref_host_fetchable "$host" "$origin" || return 1
    [[ "$host" == "$origin" ]] || auth=""
    : >"$hdrf"
    code="$(_taskref_curl_once "$out" "$hdrf" "$url" "$auth" 2>/dev/null)" || code=""
    case "$code" in
      200) printf '%s' "$code"; return 0 ;;
      30[1-8])
        loc="$(awk 'tolower($1)=="location:"{print $2}' "$hdrf" 2>/dev/null | tr -d '\r' | tail -1)"
        [[ -n "$loc" ]] || { _taskref_warn "redirect thiếu Location"; return 1; }
        url="$(_taskref_resolve_url "$url" "$loc")" || url=""
        [[ -n "$url" ]] || { _taskref_warn "redirect Location không dùng được"; return 1; }
        hop=$((hop + 1)) ;;
      *) printf '%s' "${code:-000}"; return 1 ;;
    esac
  done
  _taskref_warn "quá $TASKREF_MAX_REDIRS redirect — bỏ qua"
  return 1
}

_taskref_is_html() { head -c 512 "$1" 2>/dev/null | grep -qi '<html\|<!doctype html'; }

# taskref_fetch_sheet_csv <url> — Google Sheet public → CSV text ra stdout.
# Sheet private (401/403 hoặc redirect về trang login HTML) → bỏ qua IM LẶNG, không cred.
taskref_fetch_sheet_csv() {
  local url="${1:-}" csv
  csv="$(taskref_sheet_csv_url "$url")"
  [[ -n "$csv" ]] || return 0
  (
    umask 077
    local tmpd code
    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/taskref.XXXXXX")" || exit 0
    trap 'rm -rf "$tmpd"' EXIT INT TERM
    code="$(_taskref_fetch_url "$tmpd/sheet.csv" "$csv")" || exit 0
    [[ "$code" == "200" && -s "$tmpd/sheet.csv" ]] || exit 0
    _taskref_is_html "$tmpd/sheet.csv" && exit 0
    taskref_cap_output <"$tmpd/sheet.csv"
  )
  return 0
}

# _taskref_url_name <url> — tên file suy từ URL, đã lọc ký tự lạ (tên KHÔNG BAO GIỜ
# được dùng làm đường dẫn ghi đĩa — file tạm luôn đặt tên cố định).
_taskref_url_name() {
  local n="${1%%\?*}"; n="${n%%#*}"; n="${n##*/}"
  n="$(printf '%s' "$n" | LC_ALL=C tr -cd 'A-Za-z0-9._-')"
  printf '%s' "${n:0:100}"
}

# taskref_fetch_attachment <url> — tải attachment Jira bằng PAT rồi parse ra text.
# File tạm nằm trong mktemp -d 0700 và bị XOÁ ngay sau khi parse.
taskref_fetch_attachment() {
  local url="${1:-}" name ext
  [[ -n "$url" ]] || { _taskref_warn "--attachment thiếu URL"; return 0; }
  name="$(_taskref_url_name "$url")"; name="${name:-attachment}"
  if [[ -z "${JIRA_PERSONAL_TOKEN:-}" ]]; then
    _taskref_warn "thiếu JIRA_PERSONAL_TOKEN — bỏ qua attachment $name"
    return 0
  fi
  taskref_host_fetchable "$(taskref_url_host "$url")" || return 0
  # Charset PAT: `"` phá cú pháp dòng curl-config, xuống dòng chèn được option curl tuỳ ý.
  # Đồng bộ với _JIRA_PAT_RE ở kit/web/server.py (glob thay regex: bash 3.2 không hỗ trợ
  # interval {n,m} trong =~). Báo lỗi KHÔNG kèm giá trị/độ dài.
  case "$JIRA_PERSONAL_TOKEN" in
    *[![:alnum:]._~+/=-]*)
      _taskref_warn "JIRA_PERSONAL_TOKEN có ký tự không hợp lệ — bỏ qua attachment $name"
      _taskref_marker "$name" "$url"
      return 0 ;;
  esac
  ext="$(printf '%s' "${name##*.}" | tr 'A-Z' 'a-z')"
  [[ "$ext" =~ ^[a-z0-9]{1,8}$ ]] || ext="bin"
  (
    umask 077
    local tmpd code
    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/taskref.XXXXXX")" || exit 0
    trap 'rm -rf "$tmpd"' EXIT INT TERM
    if ! code="$(_taskref_fetch_url "$tmpd/att.$ext" "$url" "$JIRA_PERSONAL_TOKEN")"; then
      _taskref_warn "tải attachment $name lỗi (HTTP ${code:-?})"
      _taskref_marker "$name" "$url"
      exit 0
    fi
    taskref_parse_file "$tmpd/att.$ext" "$name" "$url"
  )
  return 0
}

# taskref_enrich [--attachment] <url> — điểm vào của caller: in text đã trích ra stdout.
# LUÔN return 0; URL ngoài allowlist / lỗi bất kỳ → 1 dòng stderr, stdout rỗng.
taskref_enrich() {
  local mode="url" url=""
  while (( $# > 0 )); do
    case "$1" in
      --attachment) mode="attachment" ;;
      -*) _taskref_warn "tham số lạ: $1" ;;
      *) [[ -z "$url" ]] && url="$1" ;;
    esac
    shift
  done
  if [[ -z "$url" ]]; then _taskref_warn "cần 1 URL (dùng: task-ref.sh [--attachment] <url>)"; return 0; fi
  if [[ "$mode" == "attachment" ]]; then taskref_fetch_attachment "$url"; return 0; fi
  local host; host="$(taskref_url_host "$url")"
  if ! taskref_host_allowed "$host"; then
    _taskref_warn "bỏ qua ${host:-$url} — ngoài allowlist (JIRA_URL, docs.google.com)"
    return 0
  fi
  taskref_fetch_sheet_csv "$url"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  taskref_enrich "$@"
  exit 0
fi
