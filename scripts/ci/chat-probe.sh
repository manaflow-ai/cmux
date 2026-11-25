#!/usr/bin/env bash
# Fleet chat probe: one no-folder chat through a given DEV build's own acpmux, under the leased Mac's real home,
# and its reply printed. It answers "does a chat in this build reply on a real account, and with what": a harness
# login, a route or an error message is read exactly as the build sees it on that Mac.
#
#   cmux-ci run --class light --script scripts/ci/chat-probe.sh --ref <feat-cmux-next tip> \
#     --arg=--app=sha256:<the build's artifact digest> [--arg=--harness=claude|codex|cmux|...] \
#     [--arg=--prompt-b64=<base64 of the prompt>] [--arg=--seconds=N]
#
# --app is a finished fleet cmux build's artifact (`cmux-ci status BUILD_ID`, its "artifact"): the zip of the app,
# fetched from the controller and checked against that digest. The probe runs the app's
# Contents/Resources/bin/acpmux with its own ACPMUX_HOME (an empty one inside the step, so it never touches or
# talks to a daemon the Mac already runs), HOME set to the step user's real home (where that account's harness
# logins live), no --cwd (acpmux gives the chat a scratch folder: a no-folder chat) and `--on-permission deny`; `--` ends the flags, so a prompt that starts with `-` is text.
# --harness is acpmux's -m head (default claude). --seconds bounds the turn (default 120, at most 600); a watchdog
# ends the run 60 s after that whatever it does.
#
# Output: `chat-probe: reply: <text>` and exit 0 when the chat replied; `chat-probe: error: <message>` and exit 1
# when acpmux or the harness refused (not signed in, no route, timeout): the message is what the build would show.
# Exit 2 is a usage or setup failure (no app, wrong digest, not macOS). It prints the reply or error text only,
# never the environment, a config or a daemon log; token-shaped strings in the text are replaced by <redacted>.
#
# On exit, TERM, INT or HUP the trap shuts down the probe's own daemon (its ACPMUX_HOME, `daemon shutdown
# --end-agents`) and removes the work folder. The worker runs this only when its bytes equal the version on
# feat-cmux-next or main (cmuxterm-hq build-fleet/cmd/worker/step_reviewed.go).
set -euo pipefail

usage() { echo "chat-probe: $*" >&2; exit 2; }

app_digest="" harness="claude" prompt="Reply with exactly the two words PROBE OK and nothing else." seconds=120
for arg in "$@"; do
  case "$arg" in
    --app=sha256:*) app_digest="${arg#--app=}" ;;
    --harness=*) harness="${arg#--harness=}" ;;
    --prompt-b64=*) prompt="$(printf '%s' "${arg#--prompt-b64=}" | /usr/bin/base64 -D 2>/dev/null)" || usage "--prompt-b64 is not base64" ;;
    --seconds=*) seconds="${arg#--seconds=}" ;;
    *) usage "unknown argument $arg (takes --app=sha256:HEX, --harness=H, --prompt-b64=B64, --seconds=N)" ;;
  esac
done
[[ "$(uname -s)" == Darwin ]] || usage "runs only on macOS (the build is a Mac app)"
[[ "$app_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || usage "needs --app=sha256:<64 lowercase hex> (a fleet cmux build's artifact)"
[[ "$harness" =~ ^[a-z0-9][a-z0-9._-]{0,63}(/[A-Za-z0-9._/:-]{1,128})?$ ]] || usage "--harness must be an acpmux -m value"
if ! [[ "$seconds" =~ ^[1-9][0-9]{1,2}$ ]] || (( seconds < 10 || seconds > 600 )); then usage "--seconds must be 10 to 600"; fi
[[ -n "$prompt" ]] || usage "the prompt is empty"

real_home="$(/usr/bin/dscl . -read "/Users/$(/usr/bin/id -un)" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')"
[[ -n "$real_home" && -d "$real_home" ]] || usage "cannot read the real home of $(/usr/bin/id -un)"

work="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/chat-probe.XXXXXX")"
acpmux_home="$work/acpmux"
acpmux=""
run_pid="" watchdog_pid=""

# shellcheck disable=SC2317,SC2329 # run by the traps below
cleanup() {
  trap - EXIT TERM INT HUP
  if [[ -n "$watchdog_pid" ]]; then
    # The watchdog subshell and its sleep (its children by parent PID: started here, never found by name).
    # shellcheck disable=SC2046 # one PID per word
    kill $(/usr/bin/pgrep -P "$watchdog_pid" 2>/dev/null) "$watchdog_pid" 2>/dev/null || true
  fi
  if [[ -n "$run_pid" ]] && kill -0 "$run_pid" 2>/dev/null; then
    kill -TERM "$run_pid" 2>/dev/null || true  # the run this script started, by its PID
    wait "$run_pid" 2>/dev/null || true
  fi
  if [[ -n "$acpmux" && -d "$acpmux_home" ]]; then
    HOME="$real_home" ACPMUX_HOME="$acpmux_home" "$acpmux" daemon shutdown --end-agents >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
# shellcheck disable=SC2317,SC2329 # run by the traps below
on_signal() { echo "chat-probe: signal $1; ending the probe" >&2; cleanup; exit $((128 + $2)); }
trap cleanup EXIT
trap 'on_signal TERM 15' TERM
trap 'on_signal INT 2' INT
trap 'on_signal HUP 1' HUP

# The app zip: the controller's signed store URL first, else its own GET (a fleet build's zip may sit only in the
# controller cache), checked against the digest either way (scripts/cmux-next/ensure-remote-browser-host.sh).
controller="${CMUX_CI_CONTROLLER:-http://100.89.225.106:18765}"
zip="$work/app.zip"
hex="${app_digest#sha256:}"
signed="$(curl --fail --silent --connect-timeout 5 --max-time 30 -A cmux-chat-probe \
  "${controller%/}/v1/artifacts/sha256:$hex/url" 2>/dev/null |
  /usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("url", ""))' 2>/dev/null || true)"
fetched=0
case "$signed" in https://*|http://*)
  curl --fail --silent --location --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 900 \
    -A cmux-chat-probe -o "$zip" "$signed" 2>/dev/null && fetched=1 ;;
esac
unset signed  # a read capability: never printed
if (( ! fetched )); then
  curl --fail --silent --show-error --retry 3 --retry-delay 2 --connect-timeout 5 --max-time 900 \
    -A cmux-chat-probe -o "$zip" "${controller%/}/v1/artifacts/sha256:$hex" || usage "could not download $app_digest"
fi
actual="$(/usr/bin/shasum -a 256 "$zip" | /usr/bin/awk '{print $1}')"
[[ "$actual" == "$hex" ]] || usage "the download is sha256:$actual, not $app_digest"
mkdir -p "$work/app"
/usr/bin/ditto -x -k "$zip" "$work/app" || usage "$app_digest is not an app zip"
rm -f "$zip"
app="$(/usr/bin/find "$work/app" -maxdepth 2 -name '*.app' -type d | /usr/bin/head -n 1)"
[[ -n "$app" ]] || usage "no .app in $app_digest"
acpmux="$app/Contents/Resources/bin/acpmux"
[[ -x "$acpmux" ]] || usage "$(basename "$app") has no Contents/Resources/bin/acpmux"
echo "chat-probe: $(basename "$app") $(awk -F= '$1 == "commit" { print "acpmux " $2; exit }' "$acpmux.version" 2>/dev/null || true)" >&2
echo "chat-probe: $(/usr/bin/id -un) on $(/bin/hostname -s), home $real_home, harness $harness, ${seconds}s" >&2

# The real home's own tools first (its harness installs), then the system's; nothing from the worker's PATH.
mkdir -p "$acpmux_home" "$work/run"
cd "$work/run"
HOME="$real_home" ACPMUX_HOME="$acpmux_home" PATH="$real_home/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$acpmux" --json run -m "$harness" --timeout "$seconds" --on-permission deny -- "$prompt" \
  >"$work/out.json" 2>"$work/err.json" </dev/null &
run_pid=$!
( sleep $((seconds + 60)); kill -TERM "$run_pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
watchdog_pid=$!
status=0
wait "$run_pid" || status=$?
run_pid=""

# One line: the reply, or acpmux's error message (stderr under --json is one {"error": ...} object).
/usr/bin/python3 -I - "$work/out.json" "$work/err.json" "$status" <<'PY'
import json, re, sys
out, err, status = sys.argv[1], sys.argv[2], int(sys.argv[3])
TOKEN = re.compile(r"(sk-[A-Za-z0-9_-]{8,}|(?i:bearer)\s+\S+|gh[pousr]_[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_.-]+|[A-Fa-f0-9]{40,}|[A-Za-z0-9+/]{48,}={0,2})")
def clean(text):
    return TOKEN.sub("<redacted>", str(text or "")).strip()
def load(path):
    try:
        raw = open(path, encoding="utf-8", errors="replace").read().strip()
    except OSError:
        return None, ""
    for line in reversed(raw.splitlines()):
        try:
            return json.loads(line), raw
        except ValueError:
            continue
    return None, raw
reply, _ = load(out)
if isinstance(reply, dict) and str(reply.get("reply") or "").strip():
    print("chat-probe: stop: " + clean(reply.get("stopReason")))
    print("chat-probe: reply: " + clean(reply["reply"]))
    sys.exit(0)
error, raw = load(err)
if isinstance(error, dict) and isinstance(error.get("error"), dict):
    e = error["error"]
    print("chat-probe: error: " + clean(e.get("message")) + " (" + clean(e.get("detail") or e.get("code")) + ")")
elif status in (143, 137):
    print("chat-probe: error: the run did not end within the watchdog bound")
else:
    print("chat-probe: error: no reply (acpmux exit %d): %s" % (status, clean(raw[-400:]) or "no output"))
sys.exit(1)
PY
