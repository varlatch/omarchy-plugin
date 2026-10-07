#!/usr/bin/env bash
# Offline tests for the manifest and bin/varlatch-menu. Each test runs in a
# throwaway HOME, with the plugin linked where Omarchy puts it and
# stand-ins for the varlatch CLI (tests/fake-varlatch), curl, notify-send,
# and the omarchy commands. Needs bash, jq, python3, and Node.js 22 or
# newer; with qrencode installed, the QR code is checked too.
#
#   tests/run.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAKE_CLI="$ROOT/tests/fake-varlatch"
# PATH without any real varlatch CLI, so "missing" means missing.
BASE_PATH=$(printf '%s' "$PATH" | tr ':' '\n' | while read -r dir; do
  [ -n "$dir" ] && [ ! -x "$dir/varlatch" ] && printf '%s:' "$dir"
done)
BASE_PATH=${BASE_PATH%:}
BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
HOMES=()
passed=0; failed=0

ok() { passed=$((passed + 1)); echo "ok    $1"; }
not_ok() {
  failed=$((failed + 1)); echo "FAIL  $1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'
  return 0
}
# check <label> <shell condition>
check() { if eval "$2"; then ok "$1"; else not_ok "$1" "${3:-}"; fi; }
section() { echo; echo "== $1"; }

cleanup() { for h in "${HOMES[@]}"; do rm -rf "$h"; done; }
trap cleanup EXIT

new_home() {
  T=$(mktemp -d); HOMES+=("$T")
  export HOME=$T
  mkdir -p "$T/.config/omarchy/plugins" "$T/.config/omarchy/extensions" "$T/stub" \
    "$T/.local/state/varlatch-omarchy"
  ln -s "$ROOT" "$T/.config/omarchy/plugins/varlatch"
  for c in omarchy omarchy-shell xdg-open wl-copy omarchy-launch-floating-terminal-with-presentation; do
    printf '#!/bin/sh\necho "%s $*" >> "$HOME/calls.log"\n' "$c" > "$T/stub/$c"
  done
  # notify-send answers a --wait with $FAKE_CHOICE.
  cat > "$T/stub/notify-send" <<'EOF'
#!/bin/sh
echo "notify-send $*" >> "$HOME/calls.log"
case " $* " in *" --wait "*) [ -n "${FAKE_CHOICE:-}" ] && echo "$FAKE_CHOICE" ;; esac
exit 0
EOF
  # curl serves the release API, a server's /v1/meta, and release assets
  # from $T/releases; every request is recorded in $HOME/curl.log.
  cat > "$T/stub/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$HOME/curl.log"
out=""; url=""; head=false
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    http*) url=$1 ;;
    --*) ;;
    -*I*) head=true ;;
  esac
  shift
done
[ -n "${FAKE_CURL_FAIL:-}" ] && exit 7
body=""; file=""
case "$url" in
  */releases/latest) body="{\"tag_name\":\"v${FAKE_LATEST:-0.15.1}\"}" ;;
  */v1/meta) [ -n "${FAKE_SERVER_VERSION:-}" ] || exit 22; body="{\"serverVersion\":\"$FAKE_SERVER_VERSION\"}" ;;
  */releases/download/*) file="$HOME/releases/${url#*/releases/download/}"; [ -f "$file" ] || exit 22 ;;
  *) exit 6 ;;
esac
$head && exit 0
if [ -n "$file" ]; then
  if [ -n "$out" ]; then cp "$file" "$out"; else cat "$file"; fi
elif [ -n "$out" ]; then printf '%s' "$body" > "$out"
else printf '%s\n' "$body"
fi
EOF
  chmod +x "$T"/stub/*
  export PATH="$T/stub:$BASE_PATH"
  H="$T/.config/omarchy/plugins/varlatch/bin/varlatch-menu"
  S="$T/.local/state/varlatch-omarchy"
  L="$S/login.json"; U="$S/update.json"
  MENU="$T/.config/omarchy/extensions/omarchy-menu.jsonc"
  widget '{}'
  unset FAKE_VERSION FAKE_WAIT FAKE_CHOICE FAKE_LOGIN_RC FAKE_LOGIN_SLEEP FAKE_START_FAIL \
    FAKE_LATEST FAKE_CURL_FAIL FAKE_SERVER_VERSION VARLATCH_SERVER
}

# The widget's entry in shell.json: the fake CLI plus the given settings.
widget() {
  jq -n --arg cli "$FAKE_CLI" --argjson w "$1" \
    '{bar: {layout: {right: [({id: "varlatch", varlatchCommand: $cli} + $w)]}}}' \
    > "$T/.config/omarchy/shell.json"
}
# The same without varlatchCommand: `varlatch` from PATH.
widget_default_cli() {
  jq -n --argjson w "$1" '{bar: {layout: {right: [({id: "varlatch"} + $w)]}}}' > "$T/.config/omarchy/shell.json"
}

session() { # <server> <expired true|false>
  jq -n --arg s "$1" --argjson e "$2" '{version: 1, repo: null, servers: [{server: $s, name: null,
    issuedAt: "2026-10-07T06:00:00Z", expiresAt: (if $e then "2026-10-07T07:00:00Z" else "2099-01-01T00:00:00Z" end),
    expired: $e, expiring: false}]}' > "$T/status.json"
}

# The menu file as Omarchy's MenuModel reads it: full-line // comments and
# a comma before a closing brace dropped, then strict JSON.
menu_json() {
  python3 - "$MENU" <<'PY'
import json, re, sys
raw = open(sys.argv[1], encoding="utf-8").read()
raw = re.sub(r"^\s*//[^\n]*(\n|$)", "", raw, flags=re.M)
raw = re.sub(r",(\s*[}\]])", r"\1", raw)
print(json.dumps(json.loads(raw)))
PY
}
menu_has() { menu_json | jq -e "$1" >/dev/null 2>&1; }

wait_for() { # <jq filter on login.json>
  for _ in $(seq 1 50); do jq -e "$1" "$L" >/dev/null 2>&1 && return 0; sleep 0.1; done
  return 1
}

make_release() { # <version>: a release CLI stand-in and its SHA256SUMS
  local d="$T/releases/v$1"
  mkdir -p "$d"
  printf '#!/usr/bin/env node\n// Varlatch CLI (test stand-in)\nif (process.argv[2] === "--version") console.log("varlatch %s (migration 0)");\nelse console.log("Usage: varlatch <command>");\n' \
    "$1" > "$d/varlatch-cli-$1.cjs"
  (cd "$d" && sha256sum "varlatch-cli-$1.cjs" > SHA256SUMS)
}

calls() { cat "$T/calls.log" 2>/dev/null; }

# --------------------------------------------------------------------------
section manifest
check "manifest is valid and complete" "python3 - '$ROOT' <<'PY'
import json, os, re, sys
root = sys.argv[1]
m = json.load(open(os.path.join(root, 'manifest.json'), encoding='utf-8'))
assert m['id'] == 'varlatch'
assert re.fullmatch(r'\d+\.\d+\.\d+', m['version']), m['version']
for path in m['entryPoints'].values():
    assert os.path.isfile(os.path.join(root, path)), path
bw = m['barWidget']
for field in bw['schema']:
    key = field['key']
    assert bw['defaults'].get(key) == field['defaultValue'], key
    if field['type'] == 'enum':
        assert field['defaultValue'] in field['options'], key
    if field['type'] == 'integer':
        assert field['min'] <= field['defaultValue'] <= field['max'], key
assert set(bw['defaults']) == {f['key'] for f in bw['schema']}
PY"
version=$(jq -r .version "$ROOT/manifest.json")
check "CHANGELOG.md has a section for $version" "grep -q '^## $version' '$ROOT/CHANGELOG.md'"

# --------------------------------------------------------------------------
section "menu (sync-menu)"
new_home
"$H" sync-menu
check "no server known: Connect to a server" \
  "menu_has '.[\"varlatch.connect\"].action == \"omarchy-shell varlatch connect\" and (has(\"varlatch.login\") | not)'" "$(cat "$MENU")"
echo '["https://vl.example.com"]' > "$S/servers.json"
"$H" sync-menu
check "remembered server: Log in to it" "menu_has '.[\"varlatch.login\"].action | endswith(\"login https://vl.example.com\")'"
rm "$S/servers.json"
VARLATCH_SERVER=https://env.example.com "$H" sync-menu
check "VARLATCH_SERVER: Log in to it" "menu_has '.[\"varlatch.login\"].action | endswith(\"login https://env.example.com\")'"
widget '{"varlatchCommand": "varlatch-not-installed"}'
"$H" sync-menu
check "missing CLI: Install the CLI, nothing else" \
  "menu_has 'has(\"varlatch.install\") and (has(\"varlatch.status\") | not) and (has(\"varlatch.login\") | not) and .varlatch.description == \"CLI not installed\"'"
widget '{}'
session https://vl.example.com false
"$H" sync-menu
check "live session: session, renew, log out, verify, dashboard" \
  "menu_has 'has(\"varlatch.session0\") and has(\"varlatch.renew0\") and has(\"varlatch.logout\") and has(\"varlatch.verify\") and has(\"varlatch.web\") and (has(\"varlatch.connect\") | not)'"
check "every row has a glyph" "menu_has '[to_entries[] | select(.key | startswith(\"varlatch\")) | .value.icon] | all(. != \"\")'"
# shellcheck disable=SC2034 # read by check
before=$(cat "$MENU"); "$H" sync-menu
check "unchanged state leaves the file alone" '[ "$before" = "$(cat "$MENU")" ]'
printf '{\n  "mine": {"label": "x"},\n}\n' > "$MENU"; "$H" sync-menu
check "added after an entry with a trailing comma" "menu_has 'has(\"mine\") and has(\"varlatch.renew0\")'"
printf '{\n  "mine": {"label": "x"}\n}\n' > "$MENU"; "$H" sync-menu
check "added after an entry without a trailing comma" "menu_has 'has(\"mine\") and has(\"varlatch.renew0\")'"
session https://vl.example.com true
"$H" sync-menu
check "managed block rewritten in place, user entries kept" \
  "menu_has 'has(\"mine\") and has(\"varlatch.login\")' && [ \$(grep -c '>>> varlatch plugin' \"\$MENU\") -eq 1 ]"
echo '{"current": "0.15.0"}' > "$U"; "$H" sync-menu
check "device sign-in row from CLI 0.14.0" "menu_has '.[\"varlatch.device\"].action | endswith(\"login-device https://vl.example.com\")'"
echo '{"current": "0.13.0"}' > "$U"; "$H" sync-menu
check "no device sign-in row before 0.14.0" "menu_has 'has(\"varlatch.device\") | not'"
echo '{"current": "0.14.0", "latest": "0.15.0", "updateAvailable": true, "install": "release"}' > "$U"; "$H" sync-menu
check "Update CLI row for a release install" "menu_has '.[\"varlatch.update\"].description == \"0.14.0 → 0.15.0\"'"

# --------------------------------------------------------------------------
section "sign-in state (login, login-check, login-cancel)"
new_home
pending() { # <pid> [boot]
  jq -n --argjson p "$1" --arg b "${2-$BOOT}" \
    '{state: "pending", server: "https://vl.example.com", url: "", pid: $p} + (if $b == "" then {} else {boot: $b} end)' > "$L"
}
sleep 30 & live=$!
pending 999999; "$H" login-check
check "a sign-in whose process is gone is forgotten" "jq -e '.state == \"idle\"' '$L' >/dev/null"
pending "$live" other-boot; "$H" login-check
check "a sign-in from another boot is forgotten" "jq -e '.state == \"idle\"' '$L' >/dev/null"
pending "$live"; "$H" login-check
check "a running sign-in is kept" "jq -e '.state == \"pending\"' '$L' >/dev/null"
pending "$live" ""; "$H" login-check
check "a running sign-in without a boot id is kept" "jq -e '.state == \"pending\"' '$L' >/dev/null"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
pending 999999; "$H" login-cancel
check "cancel forgets a sign-in whose process is gone" "jq -e '.state == \"idle\"' '$L' >/dev/null"
: > "$T/calls.log"; "$H" login
check "log in with no server known opens the address form" "calls | grep -q 'omarchy-shell varlatch connect'"

FAKE_LOGIN_SLEEP=1 "$H" login https://vl.example.com & helper=$!
check "the pending record carries the sign-in link and boot id" \
  "wait_for '.state == \"pending\" and (.url | test(\"/enroll\")) and .boot != \"\"'" "$(cat "$L" 2>/dev/null)"
wait "$helper"
check "browser sign-in: notified, then idle" \
  "calls | grep -q 'Logged in to vl.example.com.' && jq -e '.state == \"idle\"' '$L' >/dev/null"
: > "$T/calls.log"
FAKE_LOGIN_SLEEP=30 "$H" login https://vl.example.com & helper=$!
wait_for '.state == "pending" and .url != ""'; "$H" login-cancel; wait "$helper"
check "browser sign-in cancelled" "calls | grep -q 'Sign-in to vl.example.com cancelled.'"

section "session length (sessionHours)"
ttl_of() { # <sessionHours> -> the login command line
  widget "{\"sessionHours\": $1}"; : > "$T/calls.log"; "$H" login https://vl.example.com; calls | grep '^cli login'
}
check "24 hours: --ttl 86400" "ttl_of 24 | grep -q -- '--ttl 86400'"
check "0: the server's default (no --ttl)" "! ttl_of 0 | grep -q -- '--ttl'"
check "out of range: the server's default" "! ttl_of 30 | grep -q -- '--ttl'"
widget '{"sessionHours": 8}'; : > "$T/calls.log"; "$H" login-device https://vl.example.com
check "device sign-in: --start --ttl 28800" "calls | grep -q -- '--start --json --ttl 28800'"

# --------------------------------------------------------------------------
section "device sign-in (login-device)"
new_home
FAKE_WAIT=pending-once "$H" login-device https://vl.example.com & helper=$!
check "pending record: address, code, waiter pid" \
  "wait_for '.mode == \"device\" and .code == \"BCDF-GHJK\" and .url == \"https://vl.example.com/device\" and (.pid | type) == \"number\"'" "$(cat "$L" 2>/dev/null)"
if command -v qrencode >/dev/null 2>&1; then
  # shellcheck disable=SC2034 # read by check
  qr=$(jq -r '.qr' "$L")
  check "QR code of the address, named after the code" '[[ "$qr" == */device-qr-BCDF-GHJK.png ]] && [ -s "$qr" ]'
else
  echo "skip  QR code (qrencode not installed)"
fi
wait "$helper"
check "approved after a pending round" "calls | grep -q 'Logged in to vl.example.com.' && [ \"\$(cat \"\$T/wait-count\")\" -eq 2 ]"
check "idle afterwards, QR code removed" "jq -e '.state == \"idle\"' '$L' >/dev/null && ! ls '$S'/device-qr-* >/dev/null 2>&1"
FAKE_WAIT=deny "$H" login-device https://vl.example.com
check "denied" "calls | grep -q 'Sign-in to vl.example.com was denied.'"
FAKE_WAIT=expire "$H" login-device https://vl.example.com
check "the code expired" "calls | grep -q 'expired before it was approved'"
FAKE_START_FAIL=1 "$H" login-device https://vl.example.com
check "a refused start shows the CLI's reason" "calls | grep -q 'failed: varlatch login: the server refused to start a sign-in'"
: > "$T/calls.log"
FAKE_WAIT=hang "$H" login-device https://vl.example.com & helper=$!
wait_for '.mode == "device"'; waiter=$(jq -r .pid "$L")
"$H" login-cancel; wait "$helper"
check "cancel stops the waiter and everything it started" \
  "calls | grep -q 'cancelled' && jq -e '.state == \"idle\"' '$L' >/dev/null && ! pgrep -g '$waiter' >/dev/null"
: > "$T/calls.log"; rm -f "$T/wait-count"
FAKE_LOGIN_RC=1 FAKE_CHOICE=device "$H" login https://vl.example.com
check "failed browser sign-in: Use another device, then signed in" \
  "calls | grep -q -- '-A device=Use another device --wait' && calls | grep -q -- '--start --json' && calls | grep -q 'Logged in to vl.example.com.'"
: > "$T/calls.log"
FAKE_LOGIN_SLEEP=30 "$H" login https://vl.example.com & browser=$!
wait_for '.state == "pending" and .url != ""'
"$H" login-device https://vl.example.com; wait "$browser"
check "other device takes over a waiting browser sign-in, quietly" \
  "! calls | grep -q cancelled && calls | grep -q 'Logged in to vl.example.com.' && jq -e '.state == \"idle\"' '$L' >/dev/null"
: > "$T/calls.log"
FAKE_VERSION=0.13.0 "$H" login-device https://vl.example.com
check "CLI 0.13.0: refused" "calls | grep -q 'needs Varlatch CLI 0.14.0' && ! calls | grep -q -- '--start'"
: > "$T/calls.log"
FAKE_VERSION=0.13.0 FAKE_LOGIN_RC=1 "$H" login https://vl.example.com
check "CLI 0.13.0: no device button on a failure" "! calls | grep notify-send | grep -q -- '-A device'"
: > "$T/calls.log"; "$H" notify-session https://vl.example.com warning "expires soon"
check "expiry notification: Renew now and Another device" "calls | grep -q -- '-A login=Renew now -A device=Another device --wait'"

# --------------------------------------------------------------------------
section "release check (version-info)"
new_home
widget '{"checkUpdates": "on"}'
now=$(date +%s)
cache() { jq -n --arg l "$1" --argjson c "$2" --argjson a "$3" '{latest: $l, checkedAt: $c, attemptedAt: $a, notified: ""}' > "$U"; }
asks() { : > "$T/curl.log"; "$H" version-info "$@" >/dev/null; [ -s "$T/curl.log" ]; }
cache 0.15.0 $((now - 100)) $((now - 100));       check "fresh cache: no check" "! asks"
cache 0.15.0 $((now - 4000)) $((now - 4000));     check "panel, cache 66m old: checks" "asks --max-age 3600"
cache 0.15.0 $((now - 1000)) $((now - 1000));     check "panel, cache 16m old: no check" "! asks --max-age 3600"
cache 0.15.0 $((now - 4000)) $((now - 4000));     check "background, cache 66m old: no check" "! asks"
cache 0.15.0 $((now - 50000)) $((now - 50000));   check "background, cache 14h old: checks" "asks"
cache 0.15.0 $((now - 50000)) $((now - 100));     check "14h old, but tried 2m ago: no check" "! asks"
cache 0.14.3 $((now - 7200)) $((now - 7200));     check "cache older than the installed CLI: checks" "asks"
cache 0.14.3 $((now - 7200)) $((now - 100));      check "same, but tried 2m ago: no check" "! asks"
cache 0.15.0 $((now - 100)) $((now - 100));       check "--force: checks" "asks --force"
jq -n --argjson c $((now - 50000)) '{latest: "0.15.0", checkedAt: $c, notified: ""}' > "$U"
check "an older cache without attemptedAt" "asks"
cache 0.15.0 $((now - 50000)) $((now - 50000))
FAKE_CURL_FAIL=1 "$H" version-info >/dev/null
check "a failed check keeps the cache and records the attempt" \
  "jq -e '.checkedAt == $((now - 50000)) and .attemptedAt >= $now and .latest == \"0.15.0\"' '$U' >/dev/null"
check "after a failure, the next check waits an hour" "! asks"
widget '{"checkUpdates": "off"}'; cache 0.15.0 $((now - 50000)) $((now - 50000))
check "checkUpdates off: never" "! asks --force"
widget '{"checkUpdates": "on"}'; cache 0.15.0 $((now - 50000)) $((now - 50000))
check "a newer release is available, and notified once" \
  "FAKE_LATEST=0.16.0 \"\$H\" version-info | jq -e '.updateAvailable and .latest == \"0.16.0\" and .notified == \"0.16.0\"' >/dev/null"

# --------------------------------------------------------------------------
section "install and update the CLI (install-cli, upgrade-cli)"
new_home
widget_default_cli '{}'
make_release 9.9.8; make_release 9.9.9
printf 'vl.example.com/\ny\nn\n' | FAKE_SERVER_VERSION=9.9.8 FAKE_LATEST=9.9.9 "$H" install-cli > "$T/out" 2>&1; rc=$?
check "installs the version the server runs" \
  "[ $rc -eq 0 ] && [ \"\$(\"\$T/.local/bin/varlatch\" --version)\" = 'varlatch 9.9.8 (migration 0)' ]" "$(cat "$T/out")"
check "remembers the server" "jq -e '.[0] == \"https://vl.example.com\"' '$S/servers.json' >/dev/null"
check "the widget finds it, on PATH or through varlatchCommand" \
  "bash -lc 'command -v varlatch' >/dev/null 2>&1 || calls | grep -q 'omarchy bar set varlatch varlatchCommand $T/.local/bin/varlatch'"
new_home; widget_default_cli '{}'; make_release 9.9.9
printf 'vl.example.com\ny\nn\n' | FAKE_SERVER_VERSION=9.9.8 FAKE_LATEST=9.9.9 "$H" install-cli > "$T/out" 2>&1
check "server version without a release CLI: the latest" \
  "grep -q 'has no release CLI' '$T/out' && \"\$T/.local/bin/varlatch\" --version | grep -q 9.9.9" "$(cat "$T/out")"
new_home; widget_default_cli '{}'; make_release 9.9.9
printf '\nn\n' | FAKE_LATEST=9.9.9 "$H" install-cli > "$T/out" 2>&1; rc=$?
check "declined: nothing installed (exit 130)" "[ $rc -eq 130 ] && [ ! -e '$T/.local/bin/varlatch' ]"
echo "0000000000000000000000000000000000000000000000000000000000000000  varlatch-cli-9.9.9.cjs" > "$T/releases/v9.9.9/SHA256SUMS"
printf '\ny\n' | FAKE_LATEST=9.9.9 "$H" install-cli > "$T/out" 2>&1; rc=$?
check "checksum mismatch: nothing installed" \
  "[ $rc -ne 0 ] && grep -q 'does not match SHA256SUMS' '$T/out' && [ ! -e '$T/.local/bin/varlatch' ]"

new_home; make_release 9.9.8; make_release 9.9.9
mkdir -p "$T/bin"; install -m 755 "$T/releases/v9.9.8/varlatch-cli-9.9.8.cjs" "$T/bin/varlatch"
widget "{\"varlatchCommand\": \"$T/bin/varlatch\"}"
printf 'y\n' | FAKE_LATEST=9.9.9 "$H" upgrade-cli > "$T/out" 2>&1
check "update replaces a release install" "\"\$T/bin/varlatch\" --version | grep -q 9.9.9" "$(cat "$T/out")"
FAKE_LATEST=9.9.9 "$H" upgrade-cli > "$T/out" 2>&1
check "already the latest: up to date" "grep -q 'varlatch 9.9.9 is up to date.' '$T/out'"
widget '{}'
"$H" upgrade-cli > "$T/out" 2>&1
check "a source checkout is updated by hand" "grep -q 'built from a source checkout' '$T/out'" "$(cat "$T/out")"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
