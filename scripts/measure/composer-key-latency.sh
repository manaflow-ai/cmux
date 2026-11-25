#!/usr/bin/env bash
# Keypress-to-glyph latency of the chat composer in cmux NEXT (the newest NEXT nightly) against Zed's agent panel
# and Warp's input, on one Mac with one harness: keys injected with CGEventPostToPid, the first changed pixel of the
# app's window found in ScreenCaptureKit frames (scripts/measure/composer-key-latency.swift; the method of hq
# docs/reading/2026-11-21-zed-120fps-gpu-rendering.md item 1). The in-app rows (acp.<engine>.typing.to_frame,
# chat-typing-ab.sh) cannot time a competitor; this does, from outside every app alike.
#   cmux-ci run --class exclusive --measurement --display \
#     --script scripts/measure/composer-key-latency.sh --ref <sha> [--arg=rounds=4] [--arg=per-round=10] \
#     [--arg=gap-ms=100] [--arg=dmg=nightly|https://...] \
#     --artifact .build/composer-key-latency/report.json --artifact .build/composer-key-latency/report.tgz --timeout 3600
#   rounds=N      rounds (1 to 10, default 4); every round types into each app in turn, the order rotating
#   per-round=N   measured 'm' + Delete pairs per app per round (1 to 30, default 10): N = rounds x per-round
#   gap-ms=MS     between keys (default 100: ten keys a second)
#   dmg=          the cmux NEXT DMG: nightly (the NIGHTLY feed's newest, default) or one https URL
# Each app runs from a fresh temporary HOME: cmux through scripts/ci/fresh_home_launch_smoke.py (its fresh root,
# release control socket; palette.newAgentChat opens the composer), Zed with cursor_blink off (cmd-? focuses its
# agent panel; when no glyph shows there, as without a provider, it falls back to cmd-n's plain buffer and says so),
# Warp as it opens (an input behind a login wall shows nothing: "blocked: no-echo", no account is ever made).
# Prints KEYLAT <app> n <N> p50 <ms> p95 <ms> min <ms> hz <refresh> (and KEYLAT-DEL for the deletes);
# report.json has every sample, the app versions and the host; report.tgz adds screenshots and logs.
# Everything it makes is removed at the end (downloads, app copies, homes, the helper binary, preference domains
# the apps created); the checkout's .build/composer-key-latency keeps only the report.
# Exit 0: cmux and at least one other app measured; 1: fewer; 3: could not run (no GUI session, no download).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
here="$PWD"
out="$here/.build/composer-key-latency"
rm -rf "$out" && mkdir -p "$out/shots" && chmod -R 0777 "$out"
rounds=4 per_round=10 gap_ms=100 dmg=nightly
for arg in "$@"; do
  case "$arg" in
    rounds=*) rounds="${arg#rounds=}" ;;
    per-round=*) per_round="${arg#per-round=}" ;;
    gap-ms=*) gap_ms="${arg#gap-ms=}" ;;
    dmg=nightly|dmg=https://*) dmg="${arg#dmg=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ "$rounds" =~ ^[0-9]+$ ]] && (( rounds >= 1 && rounds <= 10 )) || { echo "rounds= must be 1 to 10" >&2; exit 2; }
[[ "$per_round" =~ ^[0-9]+$ ]] && (( per_round >= 1 && per_round <= 30 )) || { echo "per-round= must be 1 to 30" >&2; exit 2; }
[[ "$gap_ms" =~ ^[0-9]+$ ]] && (( gap_ms >= 30 && gap_ms <= 1000 )) || { echo "gap-ms= must be 30 to 1000" >&2; exit 2; }

# A cancelled or timed-out step gets SIGTERM, which skips an EXIT trap unless the signal is trapped.
trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP
work="$(mktemp -d "${TMPDIR:-/tmp}/composer-key-latency.XXXXXX")"
chmod 0755 "$work"
mkdir -p "$work/bin" "$work/dl" "$work/apps" "$work/mnt" "$work/homes"
chmod 0777 "$work/homes" # the driver may run as the console user (console-session.sh)
domains_made=()
cleanup() {
  local code=$?
  for mount in "$work"/mnt/*; do [ -d "$mount" ] && hdiutil detach -quiet -force "$mount" >/dev/null 2>&1; done
  for domain in ${domains_made[@]+"${domains_made[@]}"}; do
    defaults read "$domain" >/dev/null 2>&1 && defaults delete "$domain" >/dev/null 2>&1 && echo "KEYLAT-LOG removed preference domain $domain"
  done
  rm -rf "$work"
  echo "KEYLAT-LOG disk free after: $(df -h "$here" | awk 'NR==2 {print $4}')"
  exit "$code"
}
trap cleanup EXIT

facts() { echo "$*" | tee -a "$out/facts.log"; }
facts "KEYLAT host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)) session $(launchctl managername)"
echo "KEYLAT-LOG disk free before: $(df -h "$here" | awk 'NR==2 {print $4}')"
if ! session="$(python3 scripts/cmux-next/bench_launch.py session 2>&1)"; then
  echo "KEYLAT no-gui-session: $session" >&2
  exit 3
fi

# The helper first: a compile error costs no download.
swiftc -O -swift-version 5 -o "$work/bin/keylat" scripts/measure/composer-key-latency.swift 2>&1 | tail -n 30
[ -x "$work/bin/keylat" ] || { echo "KEYLAT could not build the helper"; exit 3; }

fetch() { # fetch NAME URL: the DMG at dl/NAME.dmg
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A composer-key-latency/1 -o "$work/dl/$1.dmg" "$2" \
    && echo "KEYLAT-LOG $1 $(du -h "$work/dl/$1.dmg" | cut -f1) from $2"
}
unpack() { # unpack NAME: copies the DMG's one .app to apps/, prints its path
  local mount="$work/mnt/$1" app
  mkdir -p "$mount"
  yes | hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mount" "$work/dl/$1.dmg" >/dev/null 2>&1 || return 1
  app="$(find "$mount" -maxdepth 1 -name '*.app' -print -quit)"
  [ -n "$app" ] && ditto "$app" "$work/apps/$(basename "$app")"
  hdiutil detach -quiet -force "$mount" >/dev/null 2>&1
  rm -f "$work/dl/$1.dmg"
  [ -n "$app" ] && echo "$work/apps/$(basename "$app")"
}
version() { [[ -f "$1/Contents/Info.plist" ]] || return 0; /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }

if [[ "$dmg" == nightly ]]; then
  dmg="$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors -H "Cache-Control: no-cache" https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
fi
[[ "$dmg" == https://* ]] || { echo "KEYLAT no nightly DMG in the feed"; exit 3; }
fetch cmux "$dmg" || { echo "KEYLAT cmux download failed"; exit 3; }
zed="" warp=""
fetch zed https://zed.dev/api/releases/stable/latest/Zed-aarch64.dmg && zed="$(unpack zed)"
fetch warp "https://app.warp.dev/download?package=dmg" && warp="$(unpack warp)"
[ -n "$zed" ] || echo "KEYLAT zed blocked: download or unpack failed"
[ -n "$warp" ] || echo "KEYLAT warp blocked: download or unpack failed"
for app in "$zed" "$warp"; do
  [ -n "$app" ] || continue
  domain="$(version "$app" CFBundleIdentifier)"
  # Their defaults go to the account's preferences whatever HOME says: remove a domain only if this run made it.
  [ -n "$domain" ] && ! defaults read "$domain" >/dev/null 2>&1 && domains_made+=("$domain")
  facts "KEYLAT version $(basename "$app" .app) $(version "$app" CFBundleShortVersionString) ($(version "$app" CFBundleVersion)) $domain"
done
facts "KEYLAT version cmux-dmg $(basename "$dmg")"

source scripts/ci/lib/signing-runtime-guard.sh
cmux_signing_runtime_guard || exit 3

# The driver: the smoke launches cmux from a fresh home and calls this once Home has rendered; it opens a new agent
# chat, launches Zed and Warp from their own fresh homes, runs the helper on the three, and stops what it started.
cat >"$work/bin/journey.py" <<'PY'
import json, os, signal, socket, subprocess, sys, time
from pathlib import Path
here, out, work, keylat, zed, warp, rounds, per_round, gap_ms, dmg = sys.argv[1:11]
sys.path.insert(0, os.path.join(here, "scripts", "ci"))
import fresh_home_launch_smoke as smoke  # noqa: E402

def rpc(sock_path, method, params=None, timeout=30.0):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(str(sock_path))
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while b"\n" not in buf:
                chunk = conn.recv(1 << 22)
                if not chunk:
                    break
                buf += chunk
        reply = json.loads(buf.split(b"\n", 1)[0])
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}

def fresh_home(name):
    home = Path(work) / "homes" / name
    for sub in ("Library/Preferences", "Library/Application Support", "Library/Caches", "Library/Logs", "tmp"):
        (home / sub).mkdir(parents=True, exist_ok=True)
    (home / ".zshrc").touch()
    user = os.environ.get("USER") or os.environ.get("LOGNAME") or ""
    return home, {"HOME": str(home), "CFFIXED_USER_HOME": str(home), "TMPDIR": str(home / "tmp") + "/",
                  "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "USER": user, "LOGNAME": user, "LANG": "en_US.UTF-8",
                  "SHELL": "/bin/zsh"}

def start(name, app, executable_hint):
    macos = Path(app) / "Contents" / "MacOS"
    info = smoke.bundle_info(Path(app))
    binary = macos / info[1] if (macos / info[1]).exists() else macos / executable_hint
    home, env = fresh_home(name)
    if name == "zed":
        (home / ".config" / "zed").mkdir(parents=True, exist_ok=True)
        (home / ".config" / "zed" / "settings.json").write_text(json.dumps(
            {"cursor_blink": False, "auto_update": False, "telemetry": {"diagnostics": False, "metrics": False}}))
    log = open(Path(out) / f"{name}.log", "wb")
    process = subprocess.Popen([str(binary)], env=env, cwd=str(home), stdin=subprocess.DEVNULL, stdout=log,
                               stderr=subprocess.STDOUT, start_new_session=True)
    print(f"KEYLAT-LOG started {name} pid {process.pid} ({binary})", flush=True)
    return process

def stop(process):
    for sig, wait in ((signal.SIGTERM, 5), (signal.SIGKILL, 3)):
        try:
            os.killpg(process.pid, sig)
        except OSError:
            return
        try:
            process.wait(timeout=wait)
            return
        except subprocess.TimeoutExpired:
            pass

def journey(process, socket_path, env, app, run_out, report):
    import plistlib
    with open(Path(app) / "Contents" / "Info.plist", "rb") as handle:
        info = plistlib.load(handle)
    print(f"KEYLAT version cmux {info.get('CFBundleShortVersionString')} ({info.get('CFBundleVersion')}) "
          f"{info.get('CFBundleIdentifier')}", flush=True)
    reply = rpc(socket_path, "action.run", {"action": "palette.newAgentChat", "args": {}, "focus": True, "origin": "script"},
                timeout=60)
    print(f"KEYLAT-LOG cmux new agent chat: {json.dumps(reply)[:300]}", flush=True)
    time.sleep(6)  # harness: the chat page loads and its composer takes the caret
    others = []
    try:
        specs = [f"cmux|{process.pid}|"]
        if zed:
            others.append(start("zed", zed, "zed"))
            specs.append(f"zed-agent|{others[-1].pid}|escape cmd-shift-slash|zed-buffer|escape cmd-n")
        if warp:
            others.append(start("warp", warp, "stable"))
            specs.append(f"warp|{others[-1].pid}|")
        time.sleep(15)  # harness: both open their first window
        for other in others:
            if other.poll() is not None:
                print(f"KEYLAT-LOG pid {other.pid} exited {other.returncode}", flush=True)
        done = subprocess.run([keylat, str(Path(out) / "keylat.json"), str(Path(out) / "shots"), rounds, per_round,
                               gap_ms, *specs], timeout=2400)
        report["keylat_exit"] = done.returncode
    finally:
        for other in others:
            stop(other)
    return []

smoke.AFTER_RENDER = journey
sys.exit(smoke.main(["--dmg", dmg, "--out", str(Path(out) / "cmux-smoke"), "--seconds", "5", "--startup-timeout", "120"]))
PY
GITHUB_WORKSPACE="$here" scripts/ci/frame-pacing/console-session.sh python3 -I "$work/bin/journey.py" \
  "$here" "$out" "$work" "$work/bin/keylat" "$zed" "$warp" "$rounds" "$per_round" "$gap_ms" "$work/dl/cmux.dmg" 2>&1 \
  | tee "$out/run.log"
rc=${PIPESTATUS[0]}
echo "KEYLAT-LOG driver exit $rc"

# report.json: the helper's numbers plus the host and versions this script printed.
python3 -I - "$out" <<'PY'
import json, re, sys
from pathlib import Path
out = Path(sys.argv[1])
log = "".join((out / name).read_text(errors="replace") for name in ("facts.log", "run.log") if (out / name).exists())
try:
    report = json.loads((out / "keylat.json").read_text())
except (OSError, ValueError):
    report = {"apps": []}
report["lines"] = [line for line in log.splitlines() if re.match(r"KEYLAT(-DEL)? |KEYLAT version ", line)]
(out / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True))
PY
tar -czf "$work/report.tgz" -C "$out" . 2>/dev/null && mv "$work/report.tgz" "$out/report.tgz"
measured="$(grep -cE '^KEYLAT [a-z-]+ n [0-9]+ p50 [0-9]' "$out/run.log" 2>/dev/null)"
grep -qE '^KEYLAT cmux n [0-9]+ p50 [0-9]' "$out/run.log" 2>/dev/null && (( measured >= 2 )) && exit 0
exit 1
