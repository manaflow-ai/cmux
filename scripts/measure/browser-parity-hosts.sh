#!/usr/bin/env bash
# Fleet entry for the browser REPL conformance suite on the app's engines
# (plans/cmux-next/browser-classic-parity.md, "host-cef and host-webkit"): builds
# a tagged cmux-next DEV app at this checkout, launches it without activation
# (scratch HOME), and runs tests/browser-parity/run.mjs check --backend host-cef
# and host-webkit through the app's bundled cmux-browser-host against the app
# daemon's host, which the app connects to as its engine provider. Prints one
# "browser-parity-hosts: <backend> <N>/<M>" line per backend and writes
# artifacts/browser-parity-hosts.json. Runs alone on the worker because it
# launches an app:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/browser-parity-hosts.sh \
#     --ref <sha> --artifact artifacts/browser-parity-hosts.json [--arg=--backend=host-cef] [--arg=--only=NN]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# A step's checkout has empty submodules: reload.sh needs Ghostty's headers
# (GhosttyKit itself comes from the pinned cache) and ghostty-next for the bundled cmux-tui.
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
backends=(host-cef host-webkit) only=()
for arg in "$@"; do
  case "$arg" in
    --backend=*) backends=("${arg#--backend=}") ;;
    --only=*) only=(--only "${arg#--only=}") ;;
    *) echo "browser-parity-hosts: unknown argument $arg" >&2; exit 2 ;;
  esac
done
for backend in "${backends[@]}"; do
  case "$backend" in host-cef|host-webkit) ;; *) echo "browser-parity-hosts: --backend must be host-cef or host-webkit" >&2; exit 2 ;; esac
done
tag="bparity"
out="$(mktemp -d)"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log" | tail -n 40
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "browser-parity-hosts: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
host_bin="$app/Contents/Resources/bin/cmux-browser-host"
[[ -x "$host_bin" ]] || { echo "browser-parity-hosts: $host_bin is missing (the bundle has no browser host)" >&2; exit 1; }
echo "browser-parity-hosts: ref $(git rev-parse HEAD)"
(cd tests/browser-parity && npm ci --no-audit --no-fund >/dev/null)
mkdir -p artifacts
# The app runs from a scratch HOME (bench_memory.launch, direct: a fleet step has
# no LaunchServices session); the daemon's host socket is bh-*/browser-host.sock
# under that HOME's state directory (cmux-tui-core browser_host.rs).
CMUX_BENCH_LAUNCH=direct exec python3 - "$app" "$host_bin" "$PWD/artifacts/browser-parity-hosts.json" "${backends[@]}" -- ${only[@]+"${only[@]}"} <<'PY'
import glob, json, os, re, subprocess, sys, time
sys.path.insert(0, os.path.join(os.getcwd(), "scripts", "cmux-next"))
import bench_memory as bm

app, host_bin, report = sys.argv[1:4]
rest = sys.argv[4:]
split = rest.index("--")
backends, only = rest[:split], rest[split + 1:]
pid, control, scratch = bm.launch(app, {})
results = {}
try:
    home = os.path.join(scratch, "home")
    deadline = time.monotonic() + 60
    socket = None
    while time.monotonic() < deadline and not socket:
        # Beside the daemon socket, else the short fallback directory when that path is too long
        # (an exclusive measure worker runs no other daemon there).
        found = glob.glob(os.path.join(home, ".local", "state", "cmux", "**", "bh-*", "browser-host.sock"), recursive=True) \
            or glob.glob(f"/tmp/cmux-tui-{os.getuid()}/bh-*/browser-host.sock")
        socket = found[0] if found else None
        if not socket:
            time.sleep(1)  # test script: waiting for the launched app's daemon to bind its host socket
    if not socket:
        raise SystemExit(f"browser-parity-hosts: the app's daemon bound no browser host socket under {home} within 60 s")
    for backend in backends:
        env = dict(os.environ, PARITY_HOST_BIN=host_bin, PARITY_HOST_SOCKET=socket)
        run = subprocess.run(["node", "tests/browser-parity/run.mjs", "check", "--backend", backend, *only],
                             env=env, capture_output=True, text=True, timeout=3600)
        text = run.stdout + run.stderr
        sys.stdout.write(text)
        match = re.search(r"(\d+)/(\d+) scenarios match", text)
        failed = re.findall(r"^FAIL (\S+)", text, re.M)
        results[backend] = {"match": int(match.group(1)) if match else None,
                            "total": int(match.group(2)) if match else None,
                            "failed": failed, "exit": run.returncode}
        print(f"browser-parity-hosts: {backend} {match.group(0) if match else 'no summary (exit %d)' % run.returncode}")
finally:
    bm.end_bundle(app)
with open(report, "w") as handle:
    json.dump({"ref": subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip(),
               "results": results}, handle, indent=2)
sys.exit(0 if results and all(r["exit"] == 0 for r in results.values()) else 1)
PY
