#!/usr/bin/env bash
# Offline tests for the manifest and bin/varlatch-menu. Each test runs in a
# throwaway HOME, with the plugin linked where Omarchy puts it and
# stand-ins for the varlatch CLI (tests/fake-varlatch), curl, notify-send,
# and the omarchy commands. Needs bash, jq, python3, Node.js 22 or newer (the
# CLI up to 0.23 runs on it), and cc (to build tests/fake-native.c, a
# stand-in for the native CLI); with qrencode installed, the QR code is
# checked too.
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
out=""; url=""; head=false; write_code=false
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    -w) write_code=true; shift ;;
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
  */releases/download/*)
    if [[ "$url" == */SHA256SUMS ]] && [ -n "${FAKE_SUMS_STATUS:-}" ]; then
      $write_code && { printf '%s' "$FAKE_SUMS_STATUS"; exit 0; }
      exit 22
    fi
    file="$HOME/releases/${url#*/releases/download/}"
    if [ ! -f "$file" ]; then
      $write_code && { printf '404'; exit 0; }
      exit 22
    fi ;;
  *) exit 6 ;;
esac
$head && exit 0
if [ -n "$file" ]; then
  if [ -n "$out" ]; then cp "$file" "$out"; else cat "$file"; fi
elif [ -n "$out" ]; then printf '%s' "$body" > "$out"
else printf '%s\n' "$body"
fi
$write_code && printf '200'
exit 0
EOF
  chmod +x "$T"/stub/*
  export PATH="$T/stub:$BASE_PATH"
  H="$T/.config/omarchy/plugins/varlatch/bin/varlatch-menu"
  S="$T/.local/state/varlatch-omarchy"
  L="$S/login.json"; U="$S/update.json"
  MENU="$T/.config/omarchy/extensions/omarchy-menu.jsonc"
  widget '{}'
  unset FAKE_VERSION FAKE_WAIT FAKE_CHOICE FAKE_LOGIN_RC FAKE_LOGIN_SLEEP FAKE_START_FAIL \
    FAKE_LATEST FAKE_CURL_FAIL FAKE_SUMS_STATUS FAKE_SERVER_VERSION FAKE_STDERR FAKE_STATUS_FAIL FAKE_STATUS_SLEEP VARLATCH_SERVER
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

# A release of the TypeScript CLI: a stand-in for its single file, which can
# update itself, and its SHA256SUMS.
make_release() { # <version>
  local d="$T/releases/v$1"
  mkdir -p "$d"
  cat > "$d/varlatch-cli-$1.cjs" <<EOF
#!/usr/bin/env node
/*! Varlatch CLI. Copyright 2026 Robotsson. (test stand-in) */
const [command, version] = process.argv.slice(2);
if (command === "--version") console.log("varlatch $1 (migration 0)");
else if (command === "self-update") require("fs").appendFileSync(process.env.HOME + "/calls.log", "typescript self-update " + version + "\\n");
else console.log("Usage: varlatch <command>\\n  varlatch self-update");
EOF
  (cd "$d" && sha256sum "varlatch-cli-$1.cjs" > SHA256SUMS)
}

# A release with native programs, as from 0.50: no single file, SHA256SUMS
# signed. The stand-in "breaks" where its flags say (tests/fake-native.c).
case "$(uname -m)" in x86_64 | amd64) ARCH=amd64 ;; *) ARCH=arm64 ;; esac
make_native_release() { # <version> [cc flag...]
  local d="$T/releases/v$1" version=$1; shift
  mkdir -p "$d"
  cc -o "$d/varlatch-$version-linux-$ARCH" -DVERSION="\"$version\"" "$@" "$ROOT/tests/fake-native.c" || exit 1
  echo '{}' > "$d/SHA256SUMS.sigstore.json"
  (cd "$d" && sha256sum "varlatch-$version-linux-$ARCH" > SHA256SUMS
    printf '%064d  varlatch-%s-darwin-arm64\n' 0 "$version" >> SHA256SUMS)
}

is_typescript_cli() { head -n 2 "$1" | grep -q 'Varlatch CLI'; }
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
check "one server: Open dashboard opens it" "menu_has '.[\"varlatch.web\"].action | endswith(\"web https://vl.example.com\")'"
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
jq '.servers += [.servers[0] | .server = "https://two.example.com"]' "$T/status.json" > "$T/status2.json"
mv "$T/status2.json" "$T/status.json"; "$H" sync-menu
check "several servers: one dashboard row each" \
  "menu_has '(.[\"varlatch.web0\"].action | endswith(\"web https://vl.example.com\")) and (.[\"varlatch.web1\"].action | endswith(\"web https://two.example.com\")) and (has(\"varlatch.web\") | not)'"
check "several servers: every row has a glyph" "menu_has '[to_entries[] | select(.key | startswith(\"varlatch\")) | .value.icon] | all(. != \"\")'"
: > "$T/calls.log"; "$H" web https://two.example.com; sleep 0.2
check "web opens the given server" "calls | grep -q 'xdg-open https://two.example.com'"
: > "$T/calls.log"; "$H" web; sleep 0.2
check "web with no server opens the first one" "calls | grep -q 'xdg-open https://vl.example.com'"
session https://vl.example.com true
echo '{"current": "0.15.0"}' > "$U"; "$H" sync-menu
check "device sign-in row from CLI 0.14.0" "menu_has '.[\"varlatch.device\"].action | endswith(\"login-device https://vl.example.com\")'"
echo '{"current": "0.13.0"}' > "$U"; "$H" sync-menu
check "no device sign-in row before 0.14.0" "menu_has 'has(\"varlatch.device\") | not'"
echo '{"current": "0.14.0", "latest": "0.15.0", "updateAvailable": true, "install": "release"}' > "$U"; "$H" sync-menu
check "Update CLI row for a release install" "menu_has '.[\"varlatch.update\"].description == \"0.14.0 → 0.15.0\"'"
jq -n --arg e "$(date -u -d '+90 minutes' +%Y-%m-%dT%H:%M:%SZ)" '{version: 1, repo: null, servers: [{server: "https://vl.example.com",
  name: null, issuedAt: "2026-10-07T06:00:00Z", expiresAt: $e, expired: false, expiring: false}]}' > "$T/status.json"
"$H" sync-menu
check "menu counts down in whole hours" "menu_has '.[\"varlatch.session0\"].description == \"Logged in, 1h left\"'" "$(cat "$MENU")"
touch -d '2000-01-01' "$S/servers.json"; "$H" sync-menu
check "same servers leave servers.json alone" "[ \"\$(stat -c %Y '$S/servers.json')\" = \"\$(date -d 2000-01-01 +%s)\" ]"
printf '{\n  "mine": {"label": "x"},\n}\n' > "$MENU"
for _ in 1 2 3 4 5 6; do "$H" sync-menu & done; wait
check "overlapping runs leave one valid block" \
  "menu_has 'has(\"mine\") and has(\"varlatch.session0\")' && [ \$(grep -c '>>> varlatch plugin' \"\$MENU\") -eq 1 ]" "$(cat "$MENU")"
check "no temporary menu file is left" "[ -z \"\$(find '$T/.config/omarchy/extensions' -name '.omarchy-menu.jsonc.*')\" ]"
mkdir -p "$T/dotfiles"; mv "$MENU" "$T/dotfiles/omarchy-menu.jsonc"; ln -s "$T/dotfiles/omarchy-menu.jsonc" "$MENU"
session https://vl.example.com true; "$H" sync-menu
check "a symlinked menu file stays a symlink" "[ -L '$MENU' ] && menu_has 'has(\"mine\") and has(\"varlatch.login\")'"

# --------------------------------------------------------------------------
section "verify (status --probe)"
new_home
jq -n '{version: 1, repo: null, servers: [{server: "https://vl.example.com", name: null,
  issuedAt: "2026-10-07T06:00:00Z", expiresAt: "2099-01-01T00:00:00Z", expired: false, expiring: false,
  probe: {state: "valid"}}]}' > "$T/status.json"
"$H" verify
check "each server's probe state in the notification" \
  "calls | grep -F 'notify-send -a Varlatch Varlatch https://vl.example.com: valid'" "$(calls)"
NODE_WARNING="varlatch: Node.js 26.12.0 is missing security fixes; update it to 26.12.1 or later. VARLATCH_NODE_CHECK=off hides this warning."
: > "$T/calls.log"; FAKE_STDERR="$NODE_WARNING" "$H" verify
check "a CLI warning on stderr leaves the document readable" \
  "calls | grep -F 'notify-send -a Varlatch Varlatch https://vl.example.com: valid'" "$(calls)"
: > "$T/calls.log"; FAKE_STDERR="$NODE_WARNING" FAKE_STATUS_FAIL=1 "$H" verify && rc=0 || rc=$?
check "a failure notifies what the CLI said on stderr" \
  "[ $rc -eq 1 ] && calls | grep -F 'notify-send -a Varlatch Varlatch verify failed:' && calls | grep -qF 'cannot reach https://vl.example.com'" "$(calls)"
# Its stderr file goes, whether verify succeeds, fails, or is stopped.
mkdir "$T/tmp"
TMPDIR="$T/tmp" "$H" verify
TMPDIR="$T/tmp" FAKE_STATUS_FAIL=1 "$H" verify || true
TMPDIR="$T/tmp" FAKE_STATUS_SLEEP=2 "$H" verify & helper=$!
sleep 0.5; kill -TERM "$helper"; wait "$helper" && rc=0 || rc=$?
check "no temporary file is left, even after SIGTERM" "[ $rc -eq 143 ] && [ -z \"\$(ls -A '$T/tmp')\" ]" "rc=$rc; $(ls -A "$T/tmp")"

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
# Each --wait answer is indented JSON, and a pending code is asked again,
# so the answer is the last of several whole documents.
rm -f "$T/wait-count"; : > "$T/calls.log"
FAKE_WAIT=pending-then-deny "$H" login-device https://vl.example.com
check "denied after a pending answer" "calls | grep -q 'Sign-in to vl.example.com was denied.'"
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
section "plugin updates (plugin-info, notify-plugin-update)"
new_home
# A copy of the plugin, so the test can change its files.
COPY="$T/plugin-copy"; mkdir -p "$COPY"
cp -R "$ROOT/bin" "$ROOT/manifest.json" "$COPY/"; cp "$ROOT"/*.qml "$COPY/"
info() { "$COPY/bin/varlatch-menu" plugin-info; }
first=$(info)
check "plugin-info: version and a code fingerprint, loaded = on disk at first" \
  "jq -e --arg v \"\$(jq -r .version '$ROOT/manifest.json')\" '.version == \$v and (.code | test(\"^[0-9a-f]{64}$\")) and .loadedCode == .code' <<<'$first' >/dev/null"
echo "# notes" >> "$COPY/README.md"
check "a change outside the manifest and QML keeps the fingerprint" '[ "$(info)" = "$first" ]'
echo "// changed" >> "$COPY/Panel.qml"
# shellcheck disable=SC2034 # read by check
second=$(info)
check "a QML change: newer code on disk, the same shell still has the old" \
  '[ "$(jq -r .code <<<"$second")" != "$(jq -r .code <<<"$first")" ] && [ "$(jq -r .loadedCode <<<"$second")" = "$(jq -r .code <<<"$first")" ]'
# A new shell process (here: another parent process) loads what is on disk.
# shellcheck disable=SC2034 # read by check
# (A second command keeps bash from exec'ing the helper in its own place.)
third=$(bash -c '"$1/bin/varlatch-menu" plugin-info; true' _ "$COPY")
check "a new shell process records what is on disk now" \
  '[ "$(jq -r .loadedCode <<<"$third")" = "$(jq -r .code <<<"$second")" ]'
info >/dev/null
check "the next call drops records of exited processes" \
  "[ \"\$(jq 'length' '$S/plugin-loaded.json')\" -eq 1 ]" "$(cat "$S/plugin-loaded.json" 2>/dev/null)"
: > "$T/calls.log"; FAKE_CHOICE=restart "$H" notify-plugin-update 9.9.9
check "notification offers Restart now and restarts the shell" \
  "calls | grep -q -- '-A restart=Restart now --wait Varlatch Varlatch for Omarchy 9.9.9 is installed' && calls | grep -q '^omarchy restart shell'"
: > "$T/calls.log"; FAKE_CHOICE='' "$H" notify-plugin-update 9.9.9
check "dismissed: no restart" "! calls | grep -q '^omarchy restart shell'"
session https://vl.example.com false
"$H" sync-menu --restart 9.9.9
check "menu: Restart to load the newer copy" \
  "menu_has '.[\"varlatch.restart\"] | (.action == \"omarchy restart shell\") and (.label | endswith(\"9.9.9\")) and .icon != \"\"'"
"$H" sync-menu
check "menu: no restart row without newer code" "menu_has 'has(\"varlatch.restart\") | not'"

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
cache 0.50.0 $((now - 100)) $((now - 100))
check "a prerelease CLI is offered its release" \
  "FAKE_VERSION=0.50.0-rc.3 \"\$H\" version-info | jq -e '.updateAvailable and .latest == \"0.50.0\"' >/dev/null"
cache 0.23.0 $((now - 100)) $((now - 100))
check "a prerelease CLI newer than the latest release: no update" \
  "FAKE_VERSION=0.50.0-rc.3 \"\$H\" version-info | jq -e '.updateAvailable == false' >/dev/null"
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
FAKE_LATEST=9.9.9 "$H" upgrade-cli > "$T/out" 2>&1
check "to a release with the single file: the CLI updates itself" \
  "calls | grep -qx 'typescript self-update 9.9.9'" "$(cat "$T/out")"
sed -i 's/self-update/nothing/' "$T/bin/varlatch"
printf 'y\n' | FAKE_LATEST=9.9.9 "$H" upgrade-cli > "$T/out" 2>&1
check "a CLI without self-update is replaced here" "\"\$T/bin/varlatch\" --version | grep -q 9.9.9" "$(cat "$T/out")"
FAKE_LATEST=9.9.9 "$H" upgrade-cli > "$T/out" 2>&1
check "already the latest: up to date" "grep -q 'varlatch 9.9.9 is up to date.' '$T/out'"

section "native releases (install-cli, upgrade-cli)"
NATIVE_VERSION='varlatch 10.0.0'
# No node on PATH: a native release needs none.
no_node() {
  mkdir -p "$T/nonode"
  local c
  for c in bash env sh cat chmod cp cut date dirname git grep head id install jq ln ls mkdir mktemp mv \
      python3 readlink rm rmdir sed seq setsid sha256sum sleep sort tail tee tr uname wc flock kill basename; do
    ln -sf "$(command -v $c)" "$T/nonode/$c"
  done
  PATH="$T/stub:$T/nonode"
}
typescript_cli() { # <path>: 9.9.8, the TypeScript CLI, with a sign-in
  make_release 9.9.8; mkdir -p "$(dirname "$1")" "$T/.config/varlatch"
  install -m 755 "$T/releases/v9.9.8/varlatch-cli-9.9.8.cjs" "$1"
  echo '{"servers":{}}' > "$T/.config/varlatch/credentials.json"
}
leftovers() { find "$1" -name '.varlatch-*'; }

new_home; widget_default_cli '{}'; make_native_release 10.0.0
printf '\ny\n' | (no_node; FAKE_LATEST=10.0.0 "$H" install-cli) > "$T/out" 2>&1; rc=$?
check "the latest release is native: installed, without Node.js" \
  "[ $rc -eq 0 ] && [ \"\$(\"\$T/.local/bin/varlatch\" --version)\" = '$NATIVE_VERSION' ]" "$(cat "$T/out")"
check "the native program checked the release's signature (bootstrap wording without cosign)" \
  "calls | grep -q 'native verify-release --version 10.0.0 --sums .*/SHA256SUMS --bundle .*/SHA256SUMS.sigstore.json --file .*=varlatch-10.0.0-linux-$ARCH' && grep -q 'checked by the downloaded binary (install cosign for an independent check)' '$T/out'" "$(cat "$T/out")"
new_home; widget_default_cli '{}'; make_release 9.9.8; make_native_release 10.0.0
printf 'vl.example.com\ny\nn\n' | FAKE_SERVER_VERSION=9.9.8 FAKE_LATEST=10.0.0 "$H" install-cli > "$T/out" 2>&1
check "a server of the TypeScript generation: its single file" \
  "\"\$T/.local/bin/varlatch\" --version | grep -q 9.9.8" "$(cat "$T/out")"
new_home; widget_default_cli '{}'; make_release 9.9.8; make_native_release 10.0.0
printf 'vl.example.com\ny\nn\n' | FAKE_SERVER_VERSION=10.0.0 FAKE_LATEST=9.9.8 "$H" install-cli > "$T/out" 2>&1
check "a native server while the latest release is not: its program" \
  "[ \"\$(\"\$T/.local/bin/varlatch\" --version)\" = '$NATIVE_VERSION' ]" "$(cat "$T/out")"
new_home; widget_default_cli '{}'; make_release 9.9.8; make_native_release 10.0.0-rc.1
printf 'vl.example.com\ny\nn\n' | FAKE_SERVER_VERSION=10.0.0-rc.1 FAKE_LATEST=9.9.8 "$H" install-cli > "$T/out" 2>&1
check "a server on a prerelease: that prerelease" \
  "[ \"\$(\"\$T/.local/bin/varlatch\" --version)\" = 'varlatch 10.0.0-rc.1' ]" "$(cat "$T/out")"

refused() { # <label> <message>: an install of 10.0.0 that must not happen
  printf '\ny\n' | FAKE_LATEST=10.0.0 "$H" install-cli > "$T/out" 2>&1; rc=$?
  check "$1" "[ $rc -ne 0 ] && grep -q '$2' '$T/out' && [ ! -e '$T/.local/bin/varlatch' ]" "$(cat "$T/out")"
}
new_home; widget_default_cli '{}'; make_native_release 10.0.0
SUMS="$T/releases/v10.0.0/SHA256SUMS"
sed -i -E "s/^[0-9a-f]{64}(  .*-linux-)/$(printf '%064d' 0)\\1/" "$SUMS"
refused "checksum mismatch: nothing installed" 'does not match SHA256SUMS'
check "a program that does not match is never run" "! calls | grep -q '^native'"
new_home; widget_default_cli '{}'; make_native_release 10.0.0
SUMS="$T/releases/v10.0.0/SHA256SUMS"; sed -i '/-linux-/d' "$SUMS"
refused "not listed in SHA256SUMS: nothing installed" 'has no CLI for this machine'
make_native_release 10.0.0; grep -e -linux- "$SUMS" | tee -a "$SUMS" >/dev/null
refused "listed twice: nothing installed" 'has no CLI for this machine'
rm "$SUMS"
refused "no SHA256SUMS: nothing installed" 'has no SHA256SUMS'
new_home; widget_default_cli '{}'; make_native_release 10.0.0; rm "$T/releases/v10.0.0/SHA256SUMS.sigstore.json"
refused "an unsigned native release: nothing installed" 'carries no signature'
new_home; widget_default_cli '{}'; make_native_release 10.0.0 -DBAD_SIGNATURE
refused "a signature that does not verify: nothing installed" 'does NOT verify'
new_home; widget_default_cli '{}'; make_native_release 10.0.0 -DREPORTS='"9.0.0"'
refused "a program of another version: nothing installed" 'reports version "9.0.0"'
new_home; widget_default_cli '{}'; make_native_release 10.0.0
printf '#!/bin/sh\necho riscv64\n' > "$T/stub/uname"; chmod +x "$T/stub/uname"
refused "a machine without a program: nothing installed" 'no CLI for this machine (riscv64)'
new_home; widget_default_cli '{}'; make_native_release 10.0.0 -DBREAKS_IN_PLACE
refused "a program that does not run in its place is removed again" 'it was removed again'
check "nothing is left behind" "[ -z \"\$(leftovers '$T/.local/bin')\" ]" "$(leftovers "$T/.local/bin")"

new_home; make_native_release 10.0.0; typescript_cli "$T/bin/varlatch"
widget "{\"varlatchCommand\": \"$T/bin/varlatch\"}"
printf 'n\n' | FAKE_LATEST=10.0.0 "$H" upgrade-cli > "$T/out" 2>&1; rc=$?
check "update to a native release, declined: the CLI stays" \
  "[ $rc -eq 130 ] && is_typescript_cli '$T/bin/varlatch'" "$(cat "$T/out")"
printf 'y\n' | FAKE_LATEST=10.0.0 "$H" upgrade-cli > "$T/out" 2>&1; rc=$?
check "update to a native release: replaces the TypeScript CLI" \
  "[ $rc -eq 0 ] && [ \"\$(\"\$T/bin/varlatch\" --version)\" = '$NATIVE_VERSION' ]" "$(cat "$T/out")"
check "its self-update, which would refuse, is not run" "! calls | grep -q 'typescript self-update'"
check "the sign-ins are left alone" "[ \"\$(cat '$T/.config/varlatch/credentials.json')\" = '{\"servers\":{}}' ]"
check "no copy of the old CLI is left" "[ \"\$(ls -A '$T/bin')\" = varlatch ]" "$(ls -A "$T/bin")"
check "a native CLI counts as a release install" "\"\$H\" version-info | jq -e '.install == \"release\" and .current == \"10.0.0\"' >/dev/null"
: > "$T/calls.log"; "$H" upgrade-cli 10.0.1 > "$T/out" 2>&1
check "a native CLI updates itself, not through node" "calls | grep -qx 'native self-update 10.0.1'" "$(calls)"

new_home; make_native_release 10.0.0 -DBREAKS_IN_PLACE; typescript_cli "$T/bin/varlatch"
widget "{\"varlatchCommand\": \"$T/bin/varlatch\"}"
printf 'y\n' | FAKE_LATEST=10.0.0 "$H" upgrade-cli > "$T/out" 2>&1; rc=$?
check "the new one does not run in its place: the TypeScript CLI is back" \
  "[ $rc -ne 0 ] && grep -q 'the one that was there is back' '$T/out' && \"\$T/bin/varlatch\" --version | grep -q 9.9.8 && [ \"\$(ls -A '$T/bin')\" = varlatch ]" "$(cat "$T/out")"
mkdir "$T/opt"; mv "$T/bin/varlatch" "$T/opt/varlatch.cjs"; ln -s ../opt/varlatch.cjs "$T/bin/varlatch"
printf 'y\n' | FAKE_LATEST=10.0.0 "$H" upgrade-cli > "$T/out" 2>&1
check "through a symlink: the link is back" \
  "[ \"\$(readlink '$T/bin/varlatch')\" = ../opt/varlatch.cjs ] && \"\$T/bin/varlatch\" --version | grep -q 9.9.8" "$(cat "$T/out")"
new_home; make_native_release 10.0.0; typescript_cli "$T/bin/varlatch"
widget "{\"varlatchCommand\": \"$T/bin/varlatch\"}"
sed -i -E "s/^[0-9a-f]{64}(  .*-linux-)/$(printf '%064d' 0)\\1/" "$T/releases/v10.0.0/SHA256SUMS"
printf 'y\n' | FAKE_LATEST=10.0.0 "$H" upgrade-cli > "$T/out" 2>&1; rc=$?
check "update, checksum mismatch: the CLI stays" \
  "[ $rc -ne 0 ] && grep -q 'does not match SHA256SUMS' '$T/out' && \"\$T/bin/varlatch\" --version | grep -q 9.9.8"

new_home; make_native_release 10.0.0; typescript_cli "$T/bin/varlatch"
widget "{\"varlatchCommand\": \"$T/bin/varlatch\"}"; mkdir "$T/compose"; touch "$T/compose/docker-compose.yml"
printf 'y\n' | VARLATCH_COMPOSE_DIR="$T/compose" FAKE_LATEST=10.0.0 "$H" upgrade-cli > "$T/out" 2>&1
check "on a Compose host: the TypeScript CLI stays, as varlatch-ts" \
  "[ \"\$(\"\$T/bin/varlatch\" --version)\" = '$NATIVE_VERSION' ] && \"\$T/bin/varlatch-ts\" --version | grep -q 9.9.8" "$(cat "$T/out")"
new_home; make_native_release 10.0.0; typescript_cli "$T/bin/varlatch"; echo mine > "$T/bin/varlatch-ts"
widget "{\"varlatchCommand\": \"$T/bin/varlatch\"}"; mkdir "$T/compose"; touch "$T/compose/varlatch-install.json"
printf 'y\n' | VARLATCH_COMPOSE_DIR="$T/compose" FAKE_LATEST=10.0.0 "$H" upgrade-cli > "$T/out" 2>&1; rc=$?
check "on a Compose host: another varlatch-ts is never replaced" \
  "[ $rc -ne 0 ] && [ \"\$(cat '$T/bin/varlatch-ts')\" = mine ] && \"\$T/bin/varlatch\" --version | grep -q 9.9.8" "$(cat "$T/out")"

new_home; make_native_release 10.0.0
mkdir -p "$T/linuxbrew/Cellar/varlatch/10.0.0/bin" "$T/linuxbrew/bin"
cp "$T/releases/v10.0.0/varlatch-10.0.0-linux-$ARCH" "$T/linuxbrew/Cellar/varlatch/10.0.0/bin/varlatch"
ln -s ../Cellar/varlatch/10.0.0/bin/varlatch "$T/linuxbrew/bin/varlatch"
widget "{\"varlatchCommand\": \"$T/linuxbrew/bin/varlatch\"}"
"$H" upgrade-cli 10.0.1 > "$T/out" 2>&1; rc=$?
check "Homebrew's copy is Homebrew's to update" \
  "[ $rc -ne 0 ] && grep -q 'brew upgrade varlatch' '$T/out' && ! calls | grep -q self-update" "$(cat "$T/out")"
: > "$T/calls.log"; "$H" notify-update 10.0.0 10.0.1 homebrew
check "its notification names brew, without an Update button" \
  "calls | grep -q 'brew upgrade varlatch' && ! calls | grep -q -- '-A update='" "$(calls)"
new_home; make_native_release 10.0.0-dev
mkdir "$T/bin"; cp "$T/releases/v10.0.0-dev/varlatch-10.0.0-dev-linux-$ARCH" "$T/bin/varlatch"
widget "{\"varlatchCommand\": \"$T/bin/varlatch\"}"
check "a native development build is updated by hand" "\"\$H\" version-info | jq -e '.install == \"custom\"' >/dev/null"

widget '{}'
"$H" upgrade-cli > "$T/out" 2>&1
check "a source checkout is updated by hand" "grep -q 'built from a source checkout' '$T/out'" "$(cat "$T/out")"

section "security and hardening (review fixes)"
new_home; widget '{"checkUpdates": "on"}'
now=$(date +%s)
jq -n --argjson c $((now - 50000)) --argjson a $((now - 50000)) '{latest: "0.15.0", checkedAt: $c, attemptedAt: $a, notified: ""}' > "$U"
FAKE_LATEST='0.50.0;touch /tmp/should-not-run' "$H" version-info > "$T/vout" 2>&1
check "hostile GitHub release tag is rejected and never cached" \
  "jq -e '.latest == \"0.15.0\" and .updateAvailable == false' '$T/vout' >/dev/null" "$(cat "$T/vout")"
jq -n --argjson c "$now" --argjson a "$now" '{latest: "0.99.0$(id)", checkedAt: $c, attemptedAt: $a, notified: ""}' > "$U"
"$H" version-info > "$T/vout" 2>&1
check "hostile cached version in update.json is ignored on read" \
  "jq -e '.latest == \"\" and .updateAvailable == false' '$T/vout' >/dev/null" "$(cat "$T/vout")"
"$H" notify-update 0.15.0 '0.50.0;id' release > "$T/out" 2>&1; rc=$?
check "notify-update rejects a hostile version" "[ $rc -ne 0 ]"
: > "$T/calls.log"; FAKE_CHOICE=update "$H" notify-update 0.15.0 0.50.0 release > "$T/out" 2>&1
check "notify-update shell-quotes helper path and version" \
  "calls | grep -Fq \"'$H' upgrade-cli '0.50.0'\"" "$(calls)"
"$H" upgrade-cli '0.50.0;id' > "$T/out" 2>&1; rc=$?
check "upgrade-cli rejects a hostile version argument" "[ $rc -ne 0 ] && grep -q 'invalid version' '$T/out'" "$(cat "$T/out")"

new_home; make_native_release 10.0.0 -DBREAKS_WHEN_STAGED; typescript_cli "$T/bin/varlatch"
widget "{\"varlatchCommand\": \"$T/bin/varlatch\"}"
printf 'y\n' | FAKE_LATEST=10.0.0 "$H" upgrade-cli > "$T/out" 2>&1; rc=$?
check "a binary that fails staged launch-test never touches the CLI" \
  "[ $rc -ne 0 ] && grep -q 'staged CLI does not run' '$T/out' && \"\$T/bin/varlatch\" --version | grep -q 9.9.8 && [ -z \"\$(leftovers '$T/bin')\" ]" "$(cat "$T/out")"

new_home; make_native_release 10.0.0; typescript_cli "$T/bin/varlatch"
widget "{\"varlatchCommand\": \"$T/bin/varlatch\"}"
mkdir "$T/bin/.varlatch-install.lock"
printf 'y\n' | FAKE_LATEST=10.0.0 "$H" upgrade-cli > "$T/out" 2>&1; rc=$?
check "a held per-target lock refuses the replacement" \
  "[ $rc -ne 0 ] && grep -q 'another install or update is running' '$T/out' && \"\$T/bin/varlatch\" --version | grep -q 9.9.8" "$(cat "$T/out")"
rmdir "$T/bin/.varlatch-install.lock"

new_home; mkdir -p "$T/bin"
printf '#!/bin/sh\n# installed with Homebrew\necho "varlatch 0.23.0"\n' > "$T/bin/varlatch"
chmod +x "$T/bin/varlatch"
widget "{\"varlatchCommand\": \"$T/bin/varlatch\"}"
"$H" upgrade-cli 10.0.0 > "$T/out" 2>&1; rc=$?
check "legacy Homebrew wrapper marker is recognized as Homebrew" \
  "[ $rc -ne 0 ] && grep -q 'brew upgrade varlatch' '$T/out'" "$(cat "$T/out")"

new_home; widget_default_cli '{}'; make_release 9.9.9
printf 'vl.example.com\ny\nn\n' | FAKE_SERVER_VERSION=9.9.8 FAKE_SUMS_STATUS=500 FAKE_LATEST=9.9.9 "$H" install-cli > "$T/out" 2>&1; rc=$?
check "install-cli treats a failed manifest fetch as a failure, not no release CLI" \
  "[ $rc -ne 0 ] && grep -q 'could not fetch SHA256SUMS' '$T/out' && ! grep -q 'has no release CLI' '$T/out' && [ ! -e '$T/.local/bin/varlatch' ]" "$(cat "$T/out")"
new_home; make_release 9.9.9; typescript_cli "$T/bin/varlatch"
widget "{\"varlatchCommand\": \"$T/bin/varlatch\"}"
FAKE_SUMS_STATUS=500 "$H" upgrade-cli 9.9.9 > "$T/out" 2>&1; rc=$?
check "upgrade-cli treats a failed manifest fetch as a failure" \
  "[ $rc -ne 0 ] && grep -q 'could not fetch SHA256SUMS' '$T/out' && \"\$T/bin/varlatch\" --version | grep -q 9.9.8" "$(cat "$T/out")"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
