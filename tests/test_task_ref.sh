#!/usr/bin/env bash
# Unit tests cho kit/lib/task-ref.sh — helper fetch+parse tham chiếu task (Jira/Sheet/Figma).
# Chạy OFFLINE: mọi test chặn trước khi curl (allowlist) hoặc parse file local.

PASS=0; FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then echo "PASS: $desc"; ((PASS++))
  else echo "FAIL: $desc"; echo "      expected: |$expected|"; echo "      actual:   |$actual|"; ((FAIL++)); fi
}
assert_contains() {
  local desc="$1" pattern="$2" text="$3"
  if [[ "$text" == *"$pattern"* ]]; then echo "PASS: $desc"; ((PASS++))
  else echo "FAIL: $desc"; echo "      expected to contain: $pattern"; echo "      actual: $text"; ((FAIL++)); fi
}

cd "$(dirname "$0")/.." || exit 1
REPO_DIR="$(pwd)"; LIB="$REPO_DIR/kit/lib/task-ref.sh"

# Cô lập env: suite này có thể chạy TRONG pipeline pagent và kế thừa PAGENT_*/JIRA_*/TASKREF_*
# → mọi biến helper đọc phải do chính test đặt, không phải môi trường gọi.
unset JIRA_URL JIRA_PERSONAL_TOKEN JIRA_ALLOW_PRIVATE
unset TASKREF_MAX_BYTES TASKREF_MAX_LINES TASKREF_MAX_TIME TASKREF_PARSE_TIMEOUT \
      TASKREF_MAX_REDIRS TASKREF_MAX_ZIP_ENTRIES \
      TASKREF_CURL_BIN TASKREF_PDFTOTEXT_BIN TASKREF_UNZIP_BIN
unset PAGENT_SOURCE PAGENT_RUN_DIR

echo "=== task-ref.sh unit tests ==="

if [[ ! -f "$LIB" ]]; then echo "FAIL: $LIB không tồn tại"; exit 1; fi
# shellcheck source=/dev/null
. "$LIB"

# ── 1. taskref_url_host — trích host, chỉ chấp nhận scheme https ────────────
echo "--- taskref_url_host ---"
assert_eq "https: lấy host" "docs.google.com" "$(taskref_url_host 'https://docs.google.com/spreadsheets/d/ID/edit')"
assert_eq "host lowercase" "jira.cty.vn" "$(taskref_url_host 'https://JIRA.CTY.VN/browse/AB-1')"
assert_eq "bỏ userinfo + port" "evil.com" "$(taskref_url_host 'https://docs.google.com@evil.com:8443/x')"
assert_eq "http → rỗng (chỉ https)" "" "$(taskref_url_host 'http://docs.google.com/x')"
assert_eq "rác → rỗng" "" "$(taskref_url_host 'not-a-url')"

# ── 2. taskref_host_allowed — allowlist theo HOST, KHÔNG substring match ───
echo "--- taskref_host_allowed ---"
_t_allowed() { taskref_host_allowed "$1" && echo yes || echo no; }
export JIRA_URL="https://jira.cty.vn/"
assert_eq "docs.google.com allowed" "yes" "$(_t_allowed docs.google.com)"
# figma KHÔNG nằm trong allowlist: Figma đọc qua mcp__figma, helper không có nhánh figma nào →
# mở host thừa chỉ tạo thêm đích để redirect rò PAT sang.
assert_eq "figma.com denied (đọc qua mcp__figma)" "no" "$(_t_allowed figma.com)"
assert_eq "www.figma.com denied" "no" "$(_t_allowed www.figma.com)"
assert_eq "host của JIRA_URL allowed" "yes" "$(_t_allowed jira.cty.vn)"
assert_eq "docs.google.com.evil.com denied" "no" "$(_t_allowed docs.google.com.evil.com)"
assert_eq "evilfigma.com denied" "no" "$(_t_allowed evilfigma.com)"
assert_eq "evil.com denied" "no" "$(_t_allowed evil.com)"
assert_eq "literal IP denied" "no" "$(_t_allowed 169.254.169.254)"
assert_eq "rỗng denied" "no" "$(_t_allowed '')"
JIRA_URL="" assert_eq "JIRA_URL rỗng → jira host denied" "no" "$(JIRA_URL= _t_allowed jira.cty.vn)"

# ── 3. taskref_host_public — chặn literal IP + host resolve về dải nội bộ ──
echo "--- taskref_host_public ---"
_t_public() { taskref_host_public "$1" && echo yes || echo no; }
for ip in 127.0.0.1 10.1.2.3 172.16.0.1 172.31.255.255 192.168.1.1 169.254.169.254 8.8.8.8 ::1 fc00::1; do
  assert_eq "literal IP $ip denied" "no" "$(_t_public "$ip")"
done
taskref_resolve_addrs() { printf '10.0.0.5\n'; }
assert_eq "resolve về 10/8 denied" "no" "$(_t_public internal.corp.vn)"
taskref_resolve_addrs() { printf '142.250.1.1\n'; }
assert_eq "resolve về IP public allowed" "yes" "$(_t_public docs.google.com)"
taskref_resolve_addrs() { printf '142.250.1.1\n192.168.0.9\n'; }
assert_eq "1 IP nội bộ trong tập → denied" "no" "$(_t_public mixed.corp.vn)"
taskref_resolve_addrs() { return 0; }
assert_eq "DNS fail → denied (fail-closed)" "no" "$(_t_public unknown.corp.vn)"
unset -f taskref_resolve_addrs
# shellcheck source=/dev/null
. "$LIB"

# ── 3b. Jira host nội bộ: chỉ được miễn kiểm IP khi JIRA_ALLOW_PRIVATE bật ──
# Cờ này CHỈ đặt được trong .env.pagent (không có đường ghi qua HTTP API) — nếu miễn vô
# điều kiện thì JIRA_URL trỏ host resolve về 169.254.169.254 = SSRF metadata kèm PAT.
echo "--- JIRA_ALLOW_PRIVATE ---"
_t_fetchable() { taskref_host_fetchable "$1" "${2:-}" >/dev/null 2>&1 && echo yes || echo no; }
taskref_resolve_addrs() { printf '169.254.169.254\n'; }
assert_eq "jira host resolve nội bộ + không cờ → denied" "no" \
  "$(JIRA_ALLOW_PRIVATE='' _t_fetchable jira.cty.vn)"
assert_eq "jira host resolve nội bộ + JIRA_ALLOW_PRIVATE=1 → allowed" "yes" \
  "$(JIRA_ALLOW_PRIVATE=1 _t_fetchable jira.cty.vn)"
taskref_resolve_addrs() { printf '203.0.113.9\n'; }
assert_eq "jira host public → allowed dù không cờ" "yes" \
  "$(JIRA_ALLOW_PRIVATE='' _t_fetchable jira.cty.vn)"
unset -f taskref_resolve_addrs
# shellcheck source=/dev/null
. "$LIB"

# ── 4. taskref_sheet_csv_url — link Sheet → CSV export ─────────────────────
echo "--- taskref_sheet_csv_url ---"
B="https://docs.google.com/spreadsheets/d/1AbC-x_9"
assert_eq "gid ở fragment" "$B/export?format=csv&gid=123" "$(taskref_sheet_csv_url "$B/edit#gid=123")"
assert_eq "gid ở query" "$B/export?format=csv&gid=7" "$(taskref_sheet_csv_url "$B/edit?gid=7#x")"
assert_eq "không có gid → gid=0" "$B/export?format=csv&gid=0" "$(taskref_sheet_csv_url "$B/edit")"
assert_eq "URL không /edit" "$B/export?format=csv&gid=0" "$(taskref_sheet_csv_url "$B")"
assert_eq "docs nhưng không phải spreadsheet → rỗng" "" "$(taskref_sheet_csv_url 'https://docs.google.com/document/d/1AbC/edit')"
assert_eq "thiếu id → rỗng" "" "$(taskref_sheet_csv_url 'https://docs.google.com/spreadsheets/d/')"
assert_eq "id có ký tự lạ → rỗng" "" "$(taskref_sheet_csv_url 'https://docs.google.com/spreadsheets/d/..%2F..%2Fx/edit')"
assert_eq "gid không phải số → gid=0" "$B/export?format=csv&gid=0" "$(taskref_sheet_csv_url "$B/edit#gid=abc")"
assert_eq "host khác → rỗng" "" "$(taskref_sheet_csv_url 'https://evil.com/spreadsheets/d/1AbC/edit')"
assert_eq "rỗng → rỗng" "" "$(taskref_sheet_csv_url '')"

# ── 5. taskref_cap_output — trần dòng + vô hiệu hoá delimiter untrusted ────
echo "--- taskref_cap_output ---"
_t_seq() { local i=1; while (( i <= $1 )); do echo "line $i"; ((i++)); done; }
out="$(TASKREF_MAX_LINES=10; _t_seq 50 | taskref_cap_output)"
assert_eq "cắt còn MAX+1 dòng (kèm marker)" "11" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
assert_contains "có marker cắt bớt" "cắt bớt" "$(printf '%s\n' "$out" | tail -1)"
out="$(TASKREF_MAX_LINES=10; _t_seq 3 | taskref_cap_output)"
assert_eq "dưới trần → giữ nguyên" "3" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
assert_eq "dưới trần → không marker" "line 3" "$(printf '%s\n' "$out" | tail -1)"
out="$(printf 'x JIRA_DATA_UNTRUSTED>>> y\n' | taskref_cap_output)"
assert_eq "strip delimiter untrusted" "" "$(printf '%s' "$out" | grep -c 'JIRA_DATA_UNTRUSTED' | grep -v '^0$')"
out="$(printf '' | taskref_cap_output)"
assert_eq "stdin rỗng → rỗng" "" "$out"

# ── 6. taskref_parse_file — loại text đọc thẳng, loại lạ chỉ ghi marker ────
echo "--- taskref_parse_file (text) ---"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
URL="https://jira.cty.vn/secure/attachment/1/f"
for ext in txt md csv json; do
  printf 'hello %s\n' "$ext" >"$TMP/f.$ext"
  assert_contains "parse .$ext đọc thẳng" "hello $ext" "$(taskref_parse_file "$TMP/f.$ext" "f.$ext" "$URL")"
done
printf 'x\n' >"$TMP/pic.png"
assert_contains "ảnh → marker không parse được" "[attachment: pic.png $URL — không parse được]" \
  "$(taskref_parse_file "$TMP/pic.png" "pic.png" "$URL")"
assert_contains "đuôi lạ → marker" "[attachment: f.bin $URL — không parse được]" \
  "$(taskref_parse_file "$TMP/f.bin" "f.bin" "$URL")"
assert_contains "file không tồn tại → marker" "không parse được" \
  "$(taskref_parse_file "$TMP/nope.txt" "nope.txt" "$URL")"
taskref_parse_file "$TMP/nope.txt" "nope.txt" "$URL" >/dev/null 2>&1
assert_eq "file không tồn tại vẫn return 0" "0" "$?"
head -c 200 /dev/zero | tr '\0' 'a' >"$TMP/big.txt"
assert_contains "vượt trần size → marker" "không parse được" \
  "$(TASKREF_MAX_BYTES=100; taskref_parse_file "$TMP/big.txt" "big.txt" "$URL")"
assert_eq "thiếu path → marker, không crash" "0" \
  "$(taskref_parse_file "" "" "" >/dev/null 2>&1; echo $?)"

# ── 7. taskref_parse_file — pdf / docx / xlsx + guard zip-bomb, XXE ────────
echo "--- taskref_parse_file (pdf/docx/xlsx) ---"
printf '%%PDF-1.4 fake\n' >"$TMP/doc.pdf"
cat >"$TMP/fake-pdftotext" <<'EOS'
#!/bin/sh
echo "PDF TEXT HERE"
EOS
chmod +x "$TMP/fake-pdftotext"
assert_contains "pdf: dùng pdftotext khi có" "PDF TEXT HERE" \
  "$(TASKREF_PDFTOTEXT_BIN="$TMP/fake-pdftotext"; taskref_parse_file "$TMP/doc.pdf" "doc.pdf" "$URL")"
assert_contains "pdf: thiếu pdftotext → marker" "[attachment: doc.pdf $URL — không parse được]" \
  "$(TASKREF_PDFTOTEXT_BIN="$TMP/no-such-pdftotext-bin"; taskref_parse_file "$TMP/doc.pdf" "doc.pdf" "$URL")"

_t_mkzip() { python3 -c 'import sys,zipfile
z=zipfile.ZipFile(sys.argv[1],"w")
for i in range(2,len(sys.argv),2): z.writestr(sys.argv[i],sys.argv[i+1])
z.close()' "$@"; }
_t_mkzip "$TMP/d.docx" word/document.xml '<w:document><w:body><w:p><w:t>Hello docx</w:t></w:p><w:p><w:t>Second &amp; line</w:t></w:p></w:body></w:document>'
out="$(taskref_parse_file "$TMP/d.docx" "d.docx" "$URL")"
assert_contains "docx: trích text" "Hello docx" "$out"
assert_contains "docx: giải mã entity chuẩn" "Second & line" "$out"
assert_eq "docx: không còn tag XML" "" "$(printf '%s' "$out" | grep -c '<w:' | grep -v '^0$')"

_t_mkzip "$TMP/s.xlsx" xl/sharedStrings.xml '<sst><si><t>CellVal</t></si><si><t>Other</t></si></sst>'
out="$(taskref_parse_file "$TMP/s.xlsx" "s.xlsx" "$URL")"
assert_contains "xlsx: trích sharedStrings" "CellVal" "$out"
assert_contains "xlsx: trích ô thứ 2" "Other" "$out"

_t_mkzip "$TMP/xxe.docx" word/document.xml '<!DOCTYPE r [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><w:document><w:t>&xxe;</w:t></w:document>'
out="$(taskref_parse_file "$TMP/xxe.docx" "xxe.docx" "$URL")"
assert_eq "docx: KHÔNG resolve external entity (XXE)" "" "$(printf '%s' "$out" | grep -c 'root:' | grep -v '^0$')"
assert_eq "docx: DOCTYPE bị loại khỏi output" "" "$(printf '%s' "$out" | grep -c 'DOCTYPE' | grep -v '^0$')"

_t_mkzip "$TMP/bomb.docx" word/document.xml '<w:t>x</w:t>' a.xml 'x' b.xml 'x' c.xml 'x'
assert_contains "zip nhiều entry hơn trần → marker" "không parse được" \
  "$(TASKREF_MAX_ZIP_ENTRIES=2; taskref_parse_file "$TMP/bomb.docx" "bomb.docx" "$URL")"
assert_contains "docx: thiếu unzip → marker" "không parse được" \
  "$(TASKREF_UNZIP_BIN="$TMP/no-such-unzip"; taskref_parse_file "$TMP/d.docx" "d.docx" "$URL")"
printf 'not a zip\n' >"$TMP/broken.docx"
assert_contains "docx hỏng → marker, không crash" "không parse được" \
  "$(taskref_parse_file "$TMP/broken.docx" "broken.docx" "$URL")"

# unzip giả: `-l` trả tổng KHÔNG numeric (locale/format khác) → guard phải fail-CLOSED,
# không được bỏ qua check rồi giải nén tiếp.
cat >"$TMP/fake-unzip" <<'EOS'
#!/bin/sh
case "$1" in
  -Z1) echo word/document.xml ;;
  -l)  echo "  Length      Date"; echo "n/a  1 file" ;;
  -p)  echo '<w:t>SHOULD NOT APPEAR</w:t>' ;;
esac
exit 0
EOS
chmod +x "$TMP/fake-unzip"
out="$(TASKREF_UNZIP_BIN="$TMP/fake-unzip"; taskref_parse_file "$TMP/d.docx" "d.docx" "$URL" 2>/dev/null)"
assert_contains "zip: tổng giải nén không numeric → fail-closed (marker)" "không parse được" "$out"
assert_eq "zip: fail-closed → KHÔNG giải nén nội dung" "" \
  "$(printf '%s' "$out" | grep -c 'SHOULD NOT APPEAR' | grep -v '^0$')"

# `unzip -l` khai tổng NHỎ nhưng `-p` phun ra nhiều (zip nói dối / directory lệch data) →
# head -c phải cắt trước khi nạp vào $( ); timeout bọc unzip KHÔNG chặn được phình RAM.
cat >"$TMP/lying-unzip" <<'EOS'
#!/bin/sh
case "$1" in
  -Z1) echo word/document.xml ;;
  -l)  echo "  Length      Date"; echo "40  1 file" ;;
  -p)  [ "$3" = word/document.xml ] || exit 0
       printf '<w:t>'; head -c 300000 /dev/zero | tr '\0' 'x'; printf '</w:t>\n' ;;
esac
exit 0
EOS
chmod +x "$TMP/lying-unzip"
out="$(TASKREF_UNZIP_BIN="$TMP/lying-unzip" TASKREF_MAX_BYTES=50000 TASKREF_MAX_LINES=99999 \
  taskref_parse_file "$TMP/d.docx" "d.docx" "$URL" 2>/dev/null)"
assert_eq "zip: member phun quá trần bị cắt theo TASKREF_MAX_BYTES" "yes" \
  "$([[ "$(printf '%s' "$out" | wc -c | tr -d ' ')" -le 51000 ]] && echo yes || echo no)"

# ── 8. CLI — mọi nhánh lỗi đều exit 0, không lộ token ──────────────────────
echo "--- CLI guards ---"
_t_cli() { env -u JIRA_PERSONAL_TOKEN JIRA_URL="https://jira.cty.vn" bash "$LIB" "$@"; }
out="$(_t_cli 2>"$TMP/err")"; rc=$?
assert_eq "không tham số → exit 0" "0" "$rc"
assert_eq "không tham số → stdout rỗng" "" "$out"
assert_eq "không tham số → có cảnh báo stderr" "yes" "$([[ -s "$TMP/err" ]] && echo yes || echo no)"

out="$(_t_cli 'https://evil.com/secret' 2>"$TMP/err")"; rc=$?
assert_eq "host ngoài allowlist → exit 0" "0" "$rc"
assert_eq "host ngoài allowlist → stdout rỗng" "" "$out"
assert_contains "host ngoài allowlist → cảnh báo" "allowlist" "$(cat "$TMP/err")"

out="$(_t_cli 'http://docs.google.com/spreadsheets/d/1AbC/edit' 2>"$TMP/err")"; rc=$?
assert_eq "scheme http → exit 0, stdout rỗng" "0-" "$rc-$out"

out="$(_t_cli 'https://169.254.169.254/latest/meta-data' 2>"$TMP/err")"; rc=$?
assert_eq "IP metadata → exit 0, stdout rỗng" "0-" "$rc-$out"

out="$(_t_cli --attachment 'https://jira.cty.vn/secure/attachment/1/a.txt' 2>"$TMP/err")"; rc=$?
assert_eq "attachment thiếu PAT → exit 0" "0" "$rc"
assert_contains "attachment thiếu PAT → báo tên biến" "JIRA_PERSONAL_TOKEN" "$(cat "$TMP/err")"

out="$(_t_cli --attachment 2>"$TMP/err")"; rc=$?
assert_eq "--attachment thiếu URL → exit 0" "0" "$rc"

both="$(JIRA_URL="https://jira.cty.vn" JIRA_PERSONAL_TOKEN="SUPERSECRETVALUE" \
  bash "$LIB" 'https://evil.com/x' 2>&1)"
assert_eq "KHÔNG lộ token ra stdout/stderr" "" "$(printf '%s' "$both" | grep -c 'SUPERSECRETVALUE' | grep -v '^0$')"
assert_eq "PAT không bao giờ lên argv của curl" "" \
  "$(grep -n 'Authorization: Bearer' "$LIB" | grep -v -- '--config' | grep -c 'curl' | grep -v '^0$')"
assert_eq "header auth đẩy qua --config stdin (dòng code, không phải comment)" "yes" \
  "$(grep -v '^[[:space:]]*#' "$LIB" | grep -q -- '--config -' && echo yes || echo no)"

# ── 9. fetch thật với curl giả — redirect, sheet private, PAT qua stdin ────
echo "--- fetch (fake curl) ---"
cat >"$TMP/fake-curl" <<'EOS'
#!/usr/bin/env bash
# Ghi TOÀN BỘ argv TRƯỚC vòng lặp: sau khi shift hết thì "$*" rỗng, assert
# "PAT không lên command line" sẽ luôn đúng một cách rỗng nghĩa.
printf '%s\n' "$*" >>"$FAKE_ARGV_LOG"
out=""; hdr=""; url=""; cfg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -D) hdr="$2"; shift 2 ;;
    --url) url="$2"; shift 2 ;;
    --config) cfg="$(cat)"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s ||| %s\n' "$url" "${cfg//$'\n'/ }" >>"$FAKE_CFG_LOG"
case "$url" in
  *gid=11*) printf 'HTTP/1.1 307\r\nLocation: https://doc-99.googleusercontent.com/pub/x\r\n' >"$hdr"; printf 302 ;;
  *gid=12*) printf 'HTTP/1.1 307\r\nLocation: https://169.254.169.254/meta\r\n' >"$hdr"; printf 302 ;;
  *gid=13*) printf 'HTTP/1.1 307\r\nLocation: https://evil.com/x\r\n' >"$hdr"; printf 302 ;;
  *gid=14*) printf '<!DOCTYPE html><html>login</html>\n' >"$out"; printf 200 ;;
  *gid=15*) printf 403 ;;
  *redirected.csv*) printf 'HTTP/1.1 302\r\nLocation: https://docs.google.com/leak\r\n' >"$hdr"; printf 302 ;;
  *relroot.txt*) printf 'HTTP/1.1 302\r\nLocation: /secure/final/root.txt\r\n' >"$hdr"; printf 302 ;;
  *secure/final/root.txt*) printf 'ROOT RELATIVE BODY\n' >"$out"; printf 200 ;;
  *queryonly.txt\?q=9*) printf 'QUERY ONLY BODY\n' >"$out"; printf 200 ;;
  *queryonly.txt*) printf 'HTTP/1.1 302\r\nLocation: ?q=9\r\n' >"$hdr"; printf 302 ;;
  *reldir.txt*) printf 'HTTP/1.1 302\r\nLocation: sib.txt?q=1\r\n' >"$hdr"; printf 302 ;;
  *sib.txt*) printf 'SIBLING BODY\n' >"$out"; printf 200 ;;
  *protorel.txt*) printf 'HTTP/1.1 302\r\nLocation: //docs.google.com/leak2\r\n' >"$hdr"; printf 302 ;;
  *leak2*) printf 'PROTO REL BODY\n' >"$out"; printf 200 ;;
  *plainhttp.txt*)  printf 'HTTP/1.1 302\r\nLocation: http://jira.cty.vn/x\r\n' >"$hdr"; printf 302 ;;
  *singleslash.txt*) printf 'HTTP/1.1 302\r\nLocation: https:/jira.cty.vn/x\r\n' >"$hdr"; printf 302 ;;
  *jsloc.txt*)      printf 'HTTP/1.1 302\r\nLocation: javascript:alert(1)\r\n' >"$hdr"; printf 302 ;;
  *protoevil.txt*)  printf 'HTTP/1.1 302\r\nLocation: //evil.tld/secret\r\n' >"$hdr"; printf 302 ;;
  *fragloc.txt*)    printf 'HTTP/1.1 302\r\nLocation: /secure/final/root.txt#frag\r\n' >"$hdr"; printf 302 ;;
  *absself.txt*)    printf 'HTTP/1.1 302\r\nLocation: https://jira.cty.vn/secure/final/root.txt\r\n' >"$hdr"; printf 302 ;;
  *absevil.txt*)    printf 'HTTP/1.1 302\r\nLocation: https://evil.tld/steal\r\n' >"$hdr"; printf 302 ;;
  *redirloop.txt*)  printf 'HTTP/1.1 302\r\nLocation: /secure/attachment/9/redirloop.txt\r\n' >"$hdr"; printf 302 ;;
  *noloc.txt*)      printf 'HTTP/1.1 302\r\nX-Note: khong co Location\r\n' >"$hdr"; printf 302 ;;
  *docs.google.com/leak*) printf 'LEAK TARGET BODY\n' >"$out"; printf 200 ;;
  *googleusercontent.com*) printf 'r,s\n9,8\n' >"$out"; printf 200 ;;
  *att.txt*) printf 'ATTACHMENT BODY\n' >"$out"; printf 200 ;;
  *) printf 'a,b\n1,2\n' >"$out"; printf 200 ;;
esac
exit 0
EOS
chmod +x "$TMP/fake-curl"
export FAKE_ARGV_LOG="$TMP/argv.log" FAKE_CFG_LOG="$TMP/cfg.log"
: >"$FAKE_ARGV_LOG"; : >"$FAKE_CFG_LOG"
export TASKREF_CURL_BIN="$TMP/fake-curl"
taskref_resolve_addrs() { printf '142.250.1.1\n'; }
S="https://docs.google.com/spreadsheets/d/1AbC"

assert_contains "sheet public → CSV text" "1,2" "$(taskref_fetch_sheet_csv "$S/edit#gid=0")"
assert_contains "redirect sang googleusercontent → đi tiếp" "9,8" "$(taskref_fetch_sheet_csv "$S/edit#gid=11")"
out="$(taskref_fetch_sheet_csv "$S/edit#gid=12" 2>"$TMP/err")"
assert_eq "redirect sang IP nội bộ → chặn, stdout rỗng" "" "$out"
assert_contains "redirect nội bộ → có cảnh báo" "bỏ qua" "$(cat "$TMP/err")"
out="$(taskref_fetch_sheet_csv "$S/edit#gid=13" 2>/dev/null)"
assert_eq "redirect sang host lạ → chặn" "" "$out"
out="$(taskref_fetch_sheet_csv "$S/edit#gid=14" 2>"$TMP/err")"
assert_eq "sheet private (HTML login) → stdout rỗng" "" "$out"
assert_eq "sheet private → im lặng, không stderr" "" "$(cat "$TMP/err")"
out="$(taskref_fetch_sheet_csv "$S/edit#gid=15" 2>/dev/null)"
assert_eq "HTTP 403 → stdout rỗng" "" "$out"
assert_eq "fetch lỗi vẫn return 0" "0" "$(taskref_fetch_sheet_csv "$S/edit#gid=15" >/dev/null 2>&1; echo $?)"

export JIRA_PERSONAL_TOKEN="TOKENVALUE123"
export TMPDIR="$TMP/tmproot"; mkdir -p "$TMPDIR"
out="$(taskref_fetch_attachment 'https://jira.cty.vn/secure/attachment/9/att.txt' 2>/dev/null)"
assert_contains "attachment: tải + parse ra text" "ATTACHMENT BODY" "$out"
assert_contains "PAT đi qua --config trên stdin" "Bearer TOKENVALUE123" "$(cat "$FAKE_CFG_LOG")"
assert_eq "PAT KHÔNG có trong argv của curl" "" "$(grep -c 'TOKENVALUE123' "$FAKE_ARGV_LOG" | grep -v '^0$')"
assert_eq "file tạm bị xoá sau khi parse" "0" "$(find "$TMPDIR" -maxdepth 1 -name 'taskref.*' | grep -c . | tr -d ' ')"
out="$(taskref_fetch_attachment 'https://evil.com/secure/attachment/9/att.txt' 2>"$TMP/err")"
assert_eq "attachment host ngoài allowlist → stdout rỗng" "" "$out"
assert_contains "attachment host ngoài allowlist → cảnh báo" "allowlist" "$(cat "$TMP/err")"
assert_eq "attachment host lạ → KHÔNG gọi curl (token không rời máy)" "" \
  "$(grep -c 'evil.com' "$FAKE_ARGV_LOG" | grep -v '^0$')"

# Redirect SANG HOST KHÁC (kể cả host trong allowlist) → PHẢI bỏ Authorization, nếu không
# Jira redirect attachment là đường gửi Bearer PAT cho bên thứ ba.
: >"$FAKE_CFG_LOG"
out="$(taskref_fetch_attachment 'https://jira.cty.vn/secure/attachment/9/redirected.csv' 2>/dev/null)"
assert_contains "redirect cross-host: vẫn tải được nội dung" "LEAK TARGET BODY" "$out"
assert_contains "hop 1 (đúng host Jira) CÓ Bearer" "Bearer TOKENVALUE123" \
  "$(grep -F 'jira.cty.vn' "$FAKE_CFG_LOG")"
assert_eq "hop 2 (host khác) KHÔNG gửi Bearer" "" \
  "$(grep -F 'docs.google.com/leak' "$FAKE_CFG_LOG" | grep -c 'Bearer' | grep -v '^0$')"

# ── 9b. Location TƯƠNG ĐỐI: resolve theo URL hop hiện tại, validate lại mỗi hop ─
echo "--- redirect Location tương đối ---"
: >"$FAKE_CFG_LOG"
out="$(taskref_fetch_attachment 'https://jira.cty.vn/secure/attachment/9/relroot.txt' 2>/dev/null)"
assert_contains "Location '/path' → resolve theo host hop hiện tại" "ROOT RELATIVE BODY" "$out"
assert_contains "Location '/path' → URL hop 2 đúng gốc" \
  'https://jira.cty.vn/secure/final/root.txt |||' "$(cat "$FAKE_CFG_LOG")"

: >"$FAKE_CFG_LOG"
out="$(taskref_fetch_attachment 'https://jira.cty.vn/secure/attachment/9/reldir.txt?v=2' 2>/dev/null)"
assert_contains "Location 'path?q=' → ghép theo thư mục cha của hop hiện tại" "SIBLING BODY" "$out"
assert_contains "Location 'path?q=' → base cắt query trước khi ghép" \
  'https://jira.cty.vn/secure/attachment/9/sib.txt?q=1 |||' "$(cat "$FAKE_CFG_LOG")"

# Location chỉ có query → RFC 3986: GIỮ path hop hiện tại, chỉ thay query (không ghép
# theo thư mục cha, tránh rơi segment cuối).
: >"$FAKE_CFG_LOG"
out="$(taskref_fetch_attachment 'https://jira.cty.vn/secure/attachment/9/queryonly.txt?v=2' 2>/dev/null)"
assert_contains "Location '?q=' → giữ nguyên path hop hiện tại" "QUERY ONLY BODY" "$out"
assert_contains "Location '?q=' → chỉ thay query, không rơi segment cuối" \
  'https://jira.cty.vn/secure/attachment/9/queryonly.txt?q=9 |||' "$(cat "$FAKE_CFG_LOG")"

# '//host/path' = ĐỔI HOST (không phải path) → phải drop Bearer, không nối vào host Jira.
: >"$FAKE_CFG_LOG"
out="$(taskref_fetch_attachment 'https://jira.cty.vn/secure/attachment/9/protorel.txt' 2>/dev/null)"
assert_contains "Location '//host/path' → resolve thành https://host/path" \
  'https://docs.google.com/leak2 |||' "$(cat "$FAKE_CFG_LOG")"
assert_eq "Location '//host/path' → hop đổi host KHÔNG gửi Bearer" "" \
  "$(grep -F 'docs.google.com/leak2' "$FAKE_CFG_LOG" | grep -c 'Bearer' | grep -v '^0$')"
assert_eq "Location '//host/path' → KHÔNG nối như path vào host Jira" "" \
  "$(grep -c 'jira.cty.vn//' "$FAKE_CFG_LOG" | grep -v '^0$')"

# Scheme ≠ https:// (kể cả 'https:/' một gạch) → fail-closed, KHÔNG ghép như path tương đối.
for bad in plainhttp singleslash jsloc; do
  : >"$FAKE_CFG_LOG"
  out="$(taskref_fetch_attachment "https://jira.cty.vn/secure/attachment/9/$bad.txt" 2>/dev/null)"
  assert_contains "Location scheme lạ ($bad) → marker, không đi tiếp" "không parse được" "$out"
  assert_eq "Location scheme lạ ($bad) → chỉ 1 hop curl" "1" "$(grep -c . "$FAKE_CFG_LOG" | tr -d ' ')"
done

: >"$FAKE_CFG_LOG"; : >"$FAKE_ARGV_LOG"
out="$(taskref_fetch_attachment 'https://jira.cty.vn/secure/attachment/9/protoevil.txt' 2>/dev/null)"
assert_contains "'//evil.tld' → chặn allowlist, chỉ marker" "không parse được" "$out"
assert_eq "'//evil.tld' → KHÔNG gọi curl tới host lạ (PAT không rời máy)" "" \
  "$(grep -c 'evil.tld' "$FAKE_ARGV_LOG" | grep -v '^0$')"

: >"$FAKE_CFG_LOG"
out="$(taskref_fetch_attachment 'https://jira.cty.vn/secure/attachment/9/fragloc.txt' 2>/dev/null)"
assert_contains "Location có fragment → strip trước khi fetch" "ROOT RELATIVE BODY" "$out"
assert_eq "Location có fragment → '#' không lọt vào URL" "" \
  "$(grep -c '#frag' "$FAKE_CFG_LOG" | grep -v '^0$')"

# Resolve KHÔNG được tự nới allowlist: hop cùng host vẫn giữ Bearer, hop khác host mất Bearer.
assert_contains "hop tương đối cùng host → GIỮ Bearer" "Bearer TOKENVALUE123" \
  "$(grep -F 'secure/final/root.txt' "$FAKE_CFG_LOG")"

# ── 9c. Location tuyệt đối, trần hop, và các nhánh chặn NGAY TẠI HOP REDIRECT ─
echo "--- redirect: tuyệt đối / trần hop / fail-closed ---"

# Location tuyệt đối CÙNG host: đi tiếp bình thường và VẪN giữ Bearer (host không đổi).
: >"$FAKE_CFG_LOG"
out="$(taskref_fetch_attachment 'https://jira.cty.vn/secure/attachment/9/absself.txt' 2>/dev/null)"
assert_contains "Location tuyệt đối cùng host → tải được nội dung" "ROOT RELATIVE BODY" "$out"
assert_contains "Location tuyệt đối cùng host → GIỮ Bearer" "Bearer TOKENVALUE123" \
  "$(grep -F 'secure/final/root.txt' "$FAKE_CFG_LOG")"
assert_eq "Location tuyệt đối cùng host → đúng 2 hop curl" "2" "$(grep -c . "$FAKE_CFG_LOG" | tr -d ' ')"

# Location tuyệt đối sang host NGOÀI allowlist → chặn trước khi curl (PAT không rời máy).
: >"$FAKE_CFG_LOG"; : >"$FAKE_ARGV_LOG"
out="$(taskref_fetch_attachment 'https://jira.cty.vn/secure/attachment/9/absevil.txt' 2>"$TMP/err")"
assert_contains "Location tuyệt đối host lạ → chỉ marker" "không parse được" "$out"
assert_contains "Location tuyệt đối host lạ → cảnh báo allowlist" "allowlist" "$(cat "$TMP/err")"
assert_eq "Location tuyệt đối host lạ → KHÔNG gọi curl tới host đó" "" \
  "$(grep -c 'evil.tld' "$FAKE_ARGV_LOG" | grep -v '^0$')"

# Vòng redirect: dừng đúng TASKREF_MAX_REDIRS+1 hop, không treo, không tràn hop.
: >"$FAKE_CFG_LOG"
out="$(TASKREF_MAX_REDIRS=2; taskref_fetch_attachment 'https://jira.cty.vn/secure/attachment/9/redirloop.txt' 2>"$TMP/err")"
assert_contains "vòng redirect vượt trần → chỉ marker" "không parse được" "$out"
assert_contains "vòng redirect vượt trần → cảnh báo nêu đúng trần" "quá 2 redirect" "$(cat "$TMP/err")"
assert_eq "vòng redirect (MAX=2) → curl gọi đúng 3 lần" "3" "$(grep -c . "$FAKE_CFG_LOG" | tr -d ' ')"
: >"$FAKE_CFG_LOG"
out="$(taskref_fetch_attachment 'https://jira.cty.vn/secure/attachment/9/redirloop.txt' 2>/dev/null)"
assert_eq "vòng redirect (trần mặc định 3) → curl gọi đúng 4 lần" "4" "$(grep -c . "$FAKE_CFG_LOG" | tr -d ' ')"
assert_eq "vòng redirect → vẫn return 0 (không fail pipeline)" "0" \
  "$(taskref_fetch_attachment 'https://jira.cty.vn/secure/attachment/9/redirloop.txt' >/dev/null 2>&1; echo $?)"

# 3xx nhưng THIẾU header Location → bỏ qua êm: 1 dòng stderr, marker, return 0, dừng luôn.
: >"$FAKE_CFG_LOG"
out="$(taskref_fetch_attachment 'https://jira.cty.vn/secure/attachment/9/noloc.txt' 2>"$TMP/err")"
assert_contains "redirect thiếu Location → chỉ marker" "không parse được" "$out"
assert_contains "redirect thiếu Location → có cảnh báo" "redirect thiếu Location" "$(cat "$TMP/err")"
assert_eq "redirect thiếu Location → dừng ngay, chỉ 1 hop curl" "1" "$(grep -c . "$FAKE_CFG_LOG" | tr -d ' ')"
assert_eq "redirect thiếu Location → vẫn return 0" "0" \
  "$(taskref_fetch_attachment 'https://jira.cty.vn/secure/attachment/9/noloc.txt' >/dev/null 2>&1; echo $?)"

# Hop redirect (host TRONG allowlist) resolve về dải nội bộ → chặn tại hop đó, không curl.
taskref_resolve_addrs() { case "$1" in docs.google.com) printf '10.0.0.5\n' ;; *) printf '142.250.1.1\n' ;; esac; }
: >"$FAKE_CFG_LOG"
out="$(taskref_fetch_attachment 'https://jira.cty.vn/secure/attachment/9/redirected.csv' 2>"$TMP/err")"
assert_eq "hop redirect resolve nội bộ → KHÔNG lấy được nội dung" "yes" \
  "$([[ "$out" != *"LEAK TARGET BODY"* ]] && echo yes || echo no)"
assert_contains "hop redirect resolve nội bộ → cảnh báo nội bộ" "địa chỉ nội bộ" "$(cat "$TMP/err")"
assert_eq "hop redirect resolve nội bộ → KHÔNG gọi curl tới hop đó" "" \
  "$(grep -F 'docs.google.com/leak' "$FAKE_CFG_LOG" | grep -c . | grep -v '^0$')"
# hop 1 PHẢI đã chạy — nếu 0 thì assert âm phía trên đúng một cách rỗng nghĩa.
assert_eq "hop redirect resolve nội bộ → dừng ĐÚNG ở hop 2 (hop 1 vẫn chạy)" "1" \
  "$(grep -c . "$FAKE_CFG_LOG" | tr -d ' ')"

# DNS fail ở hop redirect → fail-closed y hệt (resolve rỗng = từ chối, không "cho qua").
taskref_resolve_addrs() { case "$1" in docs.google.com) return 0 ;; *) printf '142.250.1.1\n' ;; esac; }
: >"$FAKE_CFG_LOG"
out="$(taskref_fetch_attachment 'https://jira.cty.vn/secure/attachment/9/redirected.csv' 2>"$TMP/err")"
assert_eq "hop redirect DNS fail → KHÔNG lấy được nội dung (fail-closed)" "yes" \
  "$([[ "$out" != *"LEAK TARGET BODY"* ]] && echo yes || echo no)"
assert_eq "hop redirect DNS fail → KHÔNG gọi curl tới hop đó" "" \
  "$(grep -F 'docs.google.com/leak' "$FAKE_CFG_LOG" | grep -c . | grep -v '^0$')"
assert_eq "hop redirect DNS fail → dừng ĐÚNG ở hop 2 (hop 1 vẫn chạy)" "1" \
  "$(grep -c . "$FAKE_CFG_LOG" | tr -d ' ')"
assert_eq "hop redirect DNS fail → vẫn return 0" "0" \
  "$(taskref_fetch_attachment 'https://jira.cty.vn/secure/attachment/9/redirected.csv' >/dev/null 2>&1; echo $?)"
taskref_resolve_addrs() { printf '142.250.1.1\n'; }

# PAT charset lạ → từ chối trước khi dựng dòng curl-config (`"` phá header, `\n` chèn option)
: >"$FAKE_ARGV_LOG"
for badtok in 'tok"en' 'a
b' 'tok en'; do
  out="$(JIRA_PERSONAL_TOKEN="$badtok" taskref_fetch_attachment 'https://jira.cty.vn/secure/attachment/9/att.txt' 2>/dev/null)"
  assert_eq "PAT charset lạ → không tải, stdout chỉ marker" "yes" \
    "$([[ "$out" != *"ATTACHMENT BODY"* ]] && echo yes || echo no)"
done
assert_eq "PAT charset lạ → KHÔNG gọi curl" "" \
  "$(grep -c 'att.txt' "$FAKE_ARGV_LOG" | grep -v '^0$')"
unset JIRA_PERSONAL_TOKEN TASKREF_CURL_BIN TMPDIR
unset -f taskref_resolve_addrs
# shellcheck source=/dev/null
. "$LIB"

# ── 10. CLI end-to-end với `curl` + `python3` stub trên PATH ───────────────
# Chạy helper như process thật (bash "$LIB") nên không stub được hàm shell: mọi I/O ra ngoài
# đi qua PATH shim → KHÔNG chạm mạng/DNS. env truyền bằng `env -i` + danh sách tường minh:
# suite chạy trong pipeline pagent sẽ kế thừa PAGENT_*/JIRA_* của run cha.
echo "--- CLI + PATH shim (curl stub) ---"
SHIM="$TMP/shim"; mkdir -p "$SHIM"
SHIM_ARGV="$TMP/shim-argv.log"; SHIM_CFG="$TMP/shim-cfg.log"
CLI_TMPDIR="$TMP/cli-tmp"; mkdir -p "$CLI_TMPDIR"

cat >"$SHIM/curl" <<'EOS'
#!/usr/bin/env bash
# argv ghi TRƯỚC khi parse — đây là nguồn duy nhất để assert "PAT không lên command line".
printf '%s\n' "$*" >>"$FAKE_ARGV_LOG"
out=""; hdr=""; url=""; cfg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -D) hdr="$2"; shift 2 ;;
    --url) url="$2"; shift 2 ;;
    --config) cfg="$(cat)"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s ||| %s\n' "$url" "${cfg//$'\n'/ }" >>"$FAKE_CFG_LOG"
case "$url" in
  *notfound*) printf 404 ;;
  *timeout*)  exit 28 ;;                      # curl chết: exit != 0, KHÔNG in http_code
  *pic.png*)  printf 'PNGBINARYDATA\n' >"$out"; printf 200 ;;
  *att.txt*)  printf 'ATTACHMENT BODY\n' >"$out"; printf 200 ;;
  *format=csv*) printf 'a,b\n1,2\n' >"$out"; printf 200 ;;
  *)          printf 'other\n' >"$out"; printf 200 ;;
esac
exit 0
EOS
# Chỉ phục vụ taskref_resolve_addrs (argv: -c <script> <host>) — không DNS thật.
cat >"$SHIM/python3" <<'EOS'
#!/bin/sh
case "$3" in
  *internal*|*.lan) echo 10.0.0.5 ;;
  *) echo 203.0.113.9 ;;
esac
EOS
chmod +x "$SHIM/curl" "$SHIM/python3"

CLI_JIRA="https://jira.cty.vn"
CLI_ENV=()
_t_shim() {
  : >"$SHIM_ARGV"; : >"$SHIM_CFG"
  env -i PATH="$SHIM:$PATH" HOME="$HOME" TMPDIR="$CLI_TMPDIR" \
    FAKE_ARGV_LOG="$SHIM_ARGV" FAKE_CFG_LOG="$SHIM_CFG" \
    JIRA_URL="$CLI_JIRA" "${CLI_ENV[@]}" bash "$LIB" "$@"
}
_t_curl_calls() { grep -c . "$SHIM_ARGV" | tr -d ' '; }
_t_tmp_left()   { find "$CLI_TMPDIR" -mindepth 1 2>/dev/null | grep -c . | tr -d ' '; }

# (1) URL ngoài allowlist → KHÔNG fetch, exit 0
for bad in 'https://docs.google.com.evil.com/spreadsheets/d/1AbC/edit' \
           'file:///etc/passwd' \
           'https://10.0.0.5/secret' \
           'https://192.168.1.10/browse/AB-1' \
           'https://jira.cty.vn.evil.com/secure/attachment/1/a.txt'; do
  out="$(_t_shim "$bad" 2>"$TMP/err")"; rc=$?
  assert_eq "ngoài allowlist ($bad) → exit 0 + stdout rỗng" "0-" "$rc-$out"
  assert_eq "ngoài allowlist ($bad) → KHÔNG gọi curl" "0" "$(_t_curl_calls)"
done
# jira host TRONG allowlist nhưng resolve về dải nội bộ (không JIRA_ALLOW_PRIVATE) → không fetch
CLI_JIRA="https://jira.internal.lan"
CLI_ENV=(JIRA_PERSONAL_TOKEN=SECRETPAT987)
out="$(_t_shim --attachment 'https://jira.internal.lan/secure/attachment/9/att.txt' 2>"$TMP/err")"; rc=$?
assert_eq "jira host resolve nội bộ → exit 0" "0" "$rc"
assert_eq "jira host resolve nội bộ → KHÔNG gọi curl (PAT không rời máy)" "0" "$(_t_curl_calls)"
CLI_JIRA="https://jira.cty.vn"; CLI_ENV=()

# (2) link Google Sheet → đổi đúng sang /export?format=csv
out="$(_t_shim 'https://docs.google.com/spreadsheets/d/1AbC-x_9/edit#gid=42' 2>/dev/null)"
assert_contains "sheet CLI → in ra CSV" "1,2" "$out"
assert_contains "sheet CLI → curl gọi URL /export?format=csv&gid=42" \
  '--url https://docs.google.com/spreadsheets/d/1AbC-x_9/export?format=csv&gid=42' "$(cat "$SHIM_ARGV")"
assert_eq "sheet CLI → KHÔNG kèm Authorization" "" "$(grep -c 'Bearer' "$SHIM_CFG" | grep -v '^0$')"
assert_eq "sheet CLI → file tạm đã dọn" "0" "$(_t_tmp_left)"

# (3) attachment Jira: PAT qua stdin/config, KHÔNG lên argv, KHÔNG lộ stdout/stderr
CLI_ENV=(JIRA_PERSONAL_TOKEN=SECRETPAT987)
both="$(_t_shim --attachment 'https://jira.cty.vn/secure/attachment/9/att.txt' 2>&1)"; rc=$?
assert_eq "attachment CLI → exit 0" "0" "$rc"
assert_contains "attachment CLI → parse ra text" "ATTACHMENT BODY" "$both"
assert_eq "PAT KHÔNG có trong argv curl nhận được" "" \
  "$(grep -c 'SECRETPAT987' "$SHIM_ARGV" | grep -v '^0$')"
assert_contains "PAT đi qua --config trên stdin" "Bearer SECRETPAT987" "$(cat "$SHIM_CFG")"
assert_contains "argv có '--config -' (đọc header từ stdin)" "--config -" "$(cat "$SHIM_ARGV")"
assert_eq "PAT KHÔNG lộ ra stdout/stderr" "" "$(printf '%s' "$both" | grep -c 'SECRETPAT987' | grep -v '^0$')"

# (4) file tạm bị xoá sau khi chạy
assert_eq "file tạm bị xoá sau khi chạy (nhánh thành công)" "0" "$(_t_tmp_left)"

# (5) loại file không parse được → dòng [attachment: …] + exit 0
PIC='https://jira.cty.vn/secure/attachment/9/pic.png'
out="$(_t_shim --attachment "$PIC" 2>/dev/null)"; rc=$?
assert_eq "loại file không parse được → exit 0" "0" "$rc"
assert_contains "loại file không parse được → in dòng [attachment: …]" \
  "[attachment: pic.png $PIC — không parse được]" "$out"
assert_eq "loại file không parse được → file tạm đã dọn" "0" "$(_t_tmp_left)"

# (6) curl lỗi / 404 / timeout → exit 0, không rò PAT, dọn file tạm
for u in 'https://jira.cty.vn/secure/attachment/9/notfound.txt' \
         'https://jira.cty.vn/secure/attachment/9/timeout.txt'; do
  both="$(_t_shim --attachment "$u" 2>&1)"; rc=$?
  assert_eq "attachment lỗi ($u) → exit 0" "0" "$rc"
  assert_contains "attachment lỗi → chỉ marker, không nội dung" "không parse được" "$both"
  assert_eq "attachment lỗi → KHÔNG lộ PAT" "" "$(printf '%s' "$both" | grep -c 'SECRETPAT987' | grep -v '^0$')"
  assert_eq "attachment lỗi → file tạm đã dọn" "0" "$(_t_tmp_left)"
done
CLI_ENV=()
for u in 'https://docs.google.com/spreadsheets/d/notfoundID/edit' \
         'https://docs.google.com/spreadsheets/d/timeoutID/edit'; do
  out="$(_t_shim "$u" 2>"$TMP/err")"; rc=$?
  assert_eq "sheet lỗi ($u) → exit 0 + stdout rỗng" "0-" "$rc-$out"
  assert_eq "sheet lỗi → im lặng, không stderr" "" "$(cat "$TMP/err")"
  assert_eq "sheet lỗi → file tạm đã dọn" "0" "$(_t_tmp_left)"
done

echo
echo "=== $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
