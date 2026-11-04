#!/usr/bin/env bash
# Live code correctness matrix (manaflow-ai/cmuxterm-hq#7111, track 3): for each row, one seeded
# minimal change is applied two ways to the same tree, and the pixels are compared.
#   - prebuilt + patch: the seeded base's Debug view shell (built once, the "prebuilt"), running
#     headless, takes the change through Prototypes/ViewShell/inject.sh;
#   - full build: the changed tree built from scratch into its own folder and drawn fresh.
# A row is `match` when both draw the badge at the same width, `refused` or `inject_failed` when
# the patch path detects it and falls back, and `MISMATCH` when the patch applied but drew other
# pixels than the full build (a silent wrong result). Each row's change moves one mechanism's term
# from 0 to 16 pt, so the badge is 64 px wider at 2x when the new code runs and unchanged when the
# old code still runs.
# Evidence class: SUPPORTING only. These are controlled pixels in the Debug view-shell prototype: they
# say which language mechanisms a patch gets right. They are not proof of either real-app experience
# (an isolated real cmux instance with the PR applied, or an in-place swap into a running real cmux),
# which need a real-app functional probe (hq#7111).
#   scripts/measure/live-apply-matrix.sh OUT [ROW...]   (OUT: logs, PNGs, diffs, rows.jsonl, result.json)
#   scripts/measure/live-apply-matrix.sh inplace OUT PR  (experience 2, a real cmux; see inplace() below)
# LIVE_APPLY_MATRIX_DIFFS_ONLY=1 writes each row's change.diff and stops: no build, any host.
set -euo pipefail
# Experience 2 (hq#7111): the change applied IN PLACE to an already-running real cmux, a lab
# instance (fresh home, own socket and tag; never the person's app), for a real merged PR:
#   scripts/measure/live-apply-matrix.sh inplace OUT PR      (PR: one of the fixtures below)
# 1. identity: the PR's squash commit (its tree is the PR as merged) and its parent, the base; the
#    lab app is the real cmux app built at that base (reload.sh tagged Debug, as fresh-home-launch.sh),
#    its executable's sha256, version and CMUXCommit recorded. The published NIGHTLY is not this base
#    (each fixture is already in it), which the row records rather than skipping.
# 2. the lab instance starts from a fresh home (scripts/ci/fresh_home_launch_smoke.py, mock agent
#    pane) and is seeded: two terminal workspaces running a printing loop (scrollback grows), and an
#    open agent chat. Its state is read: pid (system.identify), workspaces, windows and chat tabs
#    (snapshot.get), each loop's shell pid and scrollback rows (the tag's cmux-tui daemon).
# 3. the PR-specific probe runs on the base (it must fail there), then the change is applied in
#    place by the only path a running app has for it (web: build the head's web bundles and install
#    them as the web overlay; Swift: none, no in-app loader and a binary that exports nothing),
#    then the same pid and state are checked, the probe runs again, the change is reverted (overlay
#    off) and the probe runs a third time.
# 4. parity and fallback: the head is built (incremental on the same tag) and launched fresh, and
#    the probe runs there. For a change with no in-place path that build is the fallback, and its
#    seconds are the row's.
# Seconds count from the PR's selection (this script's start): fetch, build, launch, seed, apply, probe.
# Writes OUT/inplace-PR.json and OUT/inplace-PR.tgz (logs, reports).
inplace() {
  local out="$1" pr="$2" sha base head_app status=0
  # Globals, not locals: the EXIT trap reads them after this function returns.
  base_app="" scratch="" srcdir=""
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  mkdir -p "$out"; out="$(cd "$out" && pwd)"
  local t_select; t_select=$(python3 -c 'import time; print(f"{time.time():.3f}")')
  # PR|squash commit on feat-cmux-next|stratum|probe
  local fixtures=(
    "30543|5a273091bbef97cbeaaee8346088a3499b0a1acc|web functional fix|chat_scroll_jumps"
    "30861|c8d5bdf751d329a15f40202575b45278f0faf028|Swift functional fix|post_frame_feeds_mark"
    "31874|64b25664427c1a79b0e8d9d5b0f03ce5cf7dc40a|invalidation (new conformance)|close_key_turn"
    "30752|0e9e8dd0f1ed254d5a58e813b3baae5efc7ab5ab|N/A (daemon)|none"
  )
  local spec="" f
  for f in "${fixtures[@]}"; do [[ "${f%%|*}" == "$pr" ]] && spec="$f"; done
  [[ -n "$spec" ]] || { echo "inplace: no fixture for PR $pr" >&2; return 2; }
  local stratum probe
  IFS='|' read -r _ sha stratum probe <<<"$spec"
  cd "$here"
  if ! git cat-file -e "$sha^{commit}" 2>/dev/null; then
    local depth=(); [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth 2)
    for remote in origin /Users/Shared/cmux-build-fleet/git/cmux.git https://github.com/manaflow-ai/cmux.git; do
      git fetch --quiet ${depth[@]+"${depth[@]}"} "$remote" "$sha" 2>/dev/null && break
    done
  fi
  git cat-file -e "$sha^{commit}" 2>/dev/null || { echo "inplace: cannot fetch $sha" >&2; return 3; }
  git cat-file -e "$sha^^{commit}" 2>/dev/null || git fetch --quiet --deepen 1 origin "$sha" 2>/dev/null || true
  base="$(git rev-parse "$sha^")"
  python3 "$here/scripts/cmux-next/live_apply.py" --repo "$here" --json "$base" "$sha" >"$out/classifier-$pr.json" || true
  scratch="$(mktemp -d)"
  srcdir="$scratch/src"
  local tag="liveapply-${pr}"
  # Under set -e a failing step in the trap would become the script's exit status: none may fail it.
  cleanup_inplace() {
    local code=$?
    set +e
    [[ -n "${base_app:-}" ]] && python3 "$here/scripts/cmux-next/tag_teardown.py" "$base_app" >/dev/null 2>&1
    if [[ -n "${scratch:-}" ]]; then
      git -C "$here" worktree remove --force "$srcdir" >/dev/null 2>&1
      git -C "$here" worktree remove --force "$scratch/head" >/dev/null 2>&1
      rm -rf "$scratch"
    fi
    exit "$code"
  }
  trap cleanup_inplace EXIT
  if [[ "$probe" == none ]]; then
    python3 - "$out/inplace-$pr.json" "$pr" "$sha" "$base" "$stratum" "$t_select" <<'PY'
import json, sys, time
path, pr, sha, base, stratum, t0 = sys.argv[1:]
json.dump({"label": "IMPLEMENTED", "experience": "2: in-place swap into a running real cmux", "pr": int(pr),
           "applied_commit": sha, "base": base, "stratum": stratum, "verdict": "not_applicable",
           "why": "a daemon (cmux-tui) change: no path ships a PR's daemon into an installed app; "
                  "recorded in the N/A stratum, never counted as covered",
           "total_s": round(time.time() - float(t0), 2)}, open(path, "w"), indent=2)
PY
    cat "$out/inplace-$pr.json"; return 0
  fi
  git worktree add --quiet --detach "$srcdir" "$base" || return 3
  (
    cd "$srcdir"
    for sub in ghostty ghostty-next; do [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub" || exit 3; done
    if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
      rm -rf GhosttyKit.xcframework
      [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ] && export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
      ./scripts/download-prebuilt-ghosttykit.sh || exit 3
    fi
  ) || return 3
  # bun, node and Rust live under the account's home, as fresh-home-launch.sh finds them.
  local account_home tool_dir work
  account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin" "$account_home/.cargo/bin"; do
    [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
  done
  if [ -n "$account_home" ]; then
    [ -z "${RUSTUP_HOME:-}" ] && [ -d "$account_home/.rustup" ] && export RUSTUP_HOME="$account_home/.rustup"
    [ -z "${CARGO_HOME:-}" ] && [ -d "$account_home/.cargo" ] && export CARGO_HOME="$account_home/.cargo"
  fi
  work="$scratch/work"; mkdir -p "$work"
  (cd "$srcdir" && RUNNER_TEMP="$work" GITHUB_PATH="$work/bun-path" ./scripts/cmux-next/private-bun.sh) || return 3
  PATH="$(tail -n 1 "$work/bun-path"):$PATH"; export PATH
  if [[ -z "${CMUX_TUI_CLIENT_LOCAL:-}" ]] && ! (cd "$srcdir" && ./scripts/cmux-next/pin-cmux-tui.sh probe 2>/dev/null | grep -q ': ready ('); then
    export CMUX_TUI_CLIENT_TARGET_DIR="${CMUX_TUI_CLIENT_TARGET_DIR:-${CI_SHARED_CACHE_DIR:-/Users/Shared/cmux-build-fleet/cache}/live-apply-inplace/cmux-tui-target}"
    mkdir -p "$CMUX_TUI_CLIENT_TARGET_DIR" "$srcdir/cmux-tui/target"
    CMUX_TUI_CLIENT_LOCAL="$(cd "$srcdir" && CI=1 ./scripts/cmux-next/build-cmux-tui-client.sh --print-path 2>"$out/cmux-tui-build-$pr.log")" || { tail -40 "$out/cmux-tui-build-$pr.log" >&2; return 3; }
    export CMUX_TUI_CLIENT_LOCAL
  fi
  local tb0 tb1
  tb0=$(python3 -c 'import time; print(f"{time.time():.3f}")')
  (cd "$srcdir" && CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --no-global-cli-links) >"$out/reload-base-$pr.log" 2>&1 || true
  tb1=$(python3 -c 'import time; print(f"{time.time():.3f}")')
  base_app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload-base-$pr.log" | tail -n 1)"
  [[ -n "$base_app" && -d "$base_app" ]] || { echo "inplace: the base build printed no app path" >&2; grep -E "error:|BUILD FAILED" "$out/reload-base-$pr.log" | head -40 >&2; return 3; }
  # The base app's identity, copied aside: the head build replaces the tag's app in place.
  mkdir -p "$out/identity-$pr"
  python3 - "$base_app" "$out/identity-$pr/base.json" <<'PY'
import hashlib, json, plistlib, subprocess, sys
app, path = sys.argv[1:]
info = plistlib.load(open(f"{app}/Contents/Info.plist", "rb"))
exe = f"{app}/Contents/MacOS/{info['CFBundleExecutable']}"
exports = subprocess.run(["nm", "-gU", exe], capture_output=True, text=True).stdout.count("\n")
fixups = subprocess.run(["otool", "-l", exe], capture_output=True, text=True).stdout
json.dump({"bundle_id": info.get("CFBundleIdentifier"), "version": info.get("CFBundleShortVersionString"),
           "build": info.get("CFBundleVersion"), "cmux_commit": info.get("CMUXCommit"),
           "executable_sha256": hashlib.sha256(open(exe, "rb").read()).hexdigest(),
           "exported_symbols": exports, "chained_fixups": "LC_DYLD_CHAINED_FIXUPS" in fixups,
           "in_app_patch_loader": False}, open(path, "w"), indent=2)
PY
  # The lab driver: the launch, seeding, state reads, probes, apply and revert (Python, as
  # nightly-ws-switch.py drives the app through fresh_home_launch_smoke.py's hooks).
  cat >"$scratch/driver.py" <<'DRIVER'
import json, os, socket, subprocess, sys, time
from pathlib import Path
HERE = Path(os.environ["LIVE_APPLY_HERE"])
sys.path.insert(0, str(HERE / "scripts" / "ci"))
import fresh_home_launch_smoke as smoke  # noqa: E402

PHASE, PROBE, PR = os.environ["LIVE_APPLY_PHASE"], os.environ["LIVE_APPLY_PROBE"], os.environ["LIVE_APPLY_PR"]
HEAD_TREE = os.environ["LIVE_APPLY_HEAD_TREE"]
now = time.time


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


def action(sock, name, args=None, target=None, timeout=60.0):
    params = {"action": name, "args": args or {}, "focus": True, "origin": "script"}
    if target:
        params["target"] = target
    return rpc(sock, "action.run", params, timeout)


class Daemon:
    """The tag's headless cmux-tui (JSON lines), found as holder-dogfood.py finds it."""

    def __init__(self, app):
        tui = os.path.join(os.path.realpath(app), "Contents/Resources/bin/cmux-tui")
        self.socket = None
        ps = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
        for line in ps.splitlines():
            _, _, command = line.strip().partition(" ")
            words = command.split()
            if command.startswith(tui + " --headless") and "--socket" in words:
                self.socket = words[words.index("--socket") + 1]

    def call(self, cmd, **params):
        if not self.socket:
            return None
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
                conn.settimeout(30)
                conn.connect(self.socket)
                conn.sendall((json.dumps(dict(params, cmd=cmd, id=1)) + "\n").encode())
                for line in conn.makefile("r"):
                    reply = json.loads(line)
                    if reply.get("id") == 1 and "ok" in reply:
                        return reply.get("data") if reply["ok"] else {"error": reply.get("error")}
        except (OSError, ValueError) as error:
            return {"error": str(error)}
        return None


def tabs_of(topo):
    for w in topo.get("workspaces") or []:
        for screen in w.get("screens") or []:
            for pane in screen.get("panes") or []:
                for tab in pane.get("tabs") or []:
                    yield w.get("id"), pane.get("id"), tab


def topology(sock):
    return (rpc(sock, "snapshot.get") or {}).get("topology") or {}


def state(sock, daemon, seeded):
    ident = rpc(sock, "system.identify") or {}
    topo = topology(sock)
    loops = {}
    for surface in seeded.get("loop_surfaces", []):
        total = (daemon.call("read-scrollback", surface=surface, start=0, count=0) or {}).get("total")
        res = daemon.call("terminal-resources", surfaces=[surface]) or {}
        pids = [t.get("pid") for t in res.get("terminals", []) if t.get("surface") == surface]
        alive = None
        if pids and isinstance(pids[0], int):
            try:
                os.kill(pids[0], 0)
                alive = True
            except OSError:
                alive = False
        loops[str(surface)] = {"scrollback_rows": total, "shell_pid": pids[0] if pids else None, "shell_alive": alive}
    return {"pid": ident.get("pid"), "workspaces": [w.get("id") for w in topo.get("workspaces") or []],
            "windows": [w.get("id") for w in topo.get("windows") or []],
            "chat_tabs": [t.get("id") for _, _, t in tabs_of(topo) if t.get("kind") == "conversation"],
            "loops": loops, "debug_methods": any(str(m).startswith("debug.") for m in ident.get("methods") or [])}


def seed(sock):
    """Two terminal workspaces with a printing loop each (scrollback grows), and an agent chat (mock host)."""
    seeded = {"workspaces": [], "loop_surfaces": [], "chat": None}
    for _ in range(2):
        before = {t.get("id") for _, _, t in tabs_of(topology(sock))}
        action(sock, "workspace.newAtBottom")
        time.sleep(1.0)  # harness: the new workspace's shell starts
        action(sock, "terminal.sendText", {"text": "while :; do date; sleep 0.2; done\r"})
        new = [(w, t) for w, _, t in tabs_of(topology(sock)) if t.get("id") not in before and t.get("kind") == "terminal"]
        if new:
            seeded["workspaces"].append(new[0][0])
            if isinstance(new[0][1].get("surface"), int):
                seeded["loop_surfaces"].append(new[0][1]["surface"])
    target = f"workspace:{seeded['workspaces'][-1]}" if seeded["workspaces"] else None
    seeded["chat"] = action(sock, "palette.newAgentChat", {}, target)
    time.sleep(2.0)  # harness: the chat page loads
    return seeded


def probe(sock, report):
    """PROBE's verdict on this app: ("pass" | "fail" | "error", detail)."""
    if PROBE == "chat_scroll_jumps":
        # #30543: folded runs with agent messages were estimated at other heights than they draw, so
        # the transcript's scroll position jumps as rows measure. Seed a worked turn, observe at rest.
        seeded = rpc(sock, "debug.agent_pane", {"action": "seed_rows", "count": 120, "fixture": "worked-turn"}, 60)
        observed = rpc(sock, "debug.agent_pane", {"action": "layout_watch", "ms": 2500, "tolerance": 1}, 60) or {}
        result = observed.get("result", observed) if isinstance(observed, dict) else {}
        if not isinstance(result, dict) or "error" in result or "scroll_jumps" not in result:
            return "error", {"seed": seeded, "layout": observed}
        jumps = result.get("scroll_jumps") or []
        return ("pass" if not jumps else "fail"), {"scroll_jumps": len(jumps), "shifts": len(result.get("shifts") or [])}
    if PROBE == "post_frame_feeds_mark":
        # #30861: acpmux feeds start after the first window frame (launch.post_frame_feeds after
        # first_window_frame_committed). A launch-order behaviour: only a launch can show it.
        marks = report.get("marks") or {}
        mark, frame = marks.get("launch.post_frame_feeds"), marks.get("first_window_frame_committed")
        if mark is None:
            return "fail", {"post_frame_feeds": None, "first_frame": frame}
        return ("pass" if frame is not None and mark >= frame else "fail"), {"post_frame_feeds": mark, "first_frame": frame}
    if PROBE == "close_key_turn":
        # #31874: Close Window closes in its own turn, without performClose's ~100 ms button flash.
        before = [w.get("id") for w in topology(sock).get("windows") or []]
        action(sock, "newWindow")
        time.sleep(1.5)  # harness: the window opens
        after = [w.get("id") for w in topology(sock).get("windows") or []]
        new = [w for w in after if w not in before]
        if not new:
            return "error", {"why": "newWindow opened no window", "windows": after}
        t0 = time.perf_counter()
        reply = action(sock, "closeWindow", {}, f"window:{new[0]}")
        ms = (time.perf_counter() - t0) * 1000
        gone = new[0] not in [w.get("id") for w in topology(sock).get("windows") or []]
        return ("pass" if gone and ms < 50 else "fail"), {"close_reply_ms": round(ms, 1), "closed": gone, "reply": reply}
    return "error", {"why": f"no probe {PROBE}"}


def overlay(env, verb, timeout):
    e = dict(os.environ, CMUX_NEXT_CONFIG_FILE=env["CMUX_NEXT_CONFIG_FILE"], CMUX_WEB_OVERLAY_DIR=env["CMUX_WEB_OVERLAY_DIR"])
    t0 = now()
    if verb == "build" and not Path(HEAD_TREE, "webviews", "node_modules").is_dir():
        subprocess.run(["bun", "install", "--frozen-lockfile"], cwd=f"{HEAD_TREE}/webviews", env=e,
                       capture_output=True, text=True, timeout=900)
    done = subprocess.run([f"{HEAD_TREE}/scripts/cmux-next/web-overlay.sh", verb], cwd=HEAD_TREE, env=e,
                          capture_output=True, text=True, timeout=timeout)
    Path(os.environ["LIVE_APPLY_OUT"], f"web-overlay-{verb}-{PR}.log").write_text(done.stdout + done.stderr)
    return done.returncode == 0, round(now() - t0, 2)


LAB = {}


def prepare_home(env):
    root = Path(env["HOME"]).parent
    (root / "cfg").mkdir(parents=True, exist_ok=True)
    (root / "cfg" / "cmux-next.json").write_text("{}\n")
    (root / "tunables.json").write_text(json.dumps({"version": 1, "values": {"webDev.override": True}}))
    env.update(CMUX_NEXT_CONFIG_FILE=str(root / "cfg" / "cmux-next.json"),
               CMUX_NEXT_DEBUG_TUNABLES_FILE=str(root / "tunables.json"),
               CMUX_WEB_OVERLAY_DIR=str(root / "overlay"), CMUX_NEXT_AGENT_PANE_MOCK="1")
    LAB["env"] = dict(env)


def after_render(process, socket_path, env, app, out, report):
    rec = {"phase": PHASE, "launched_pid": process.pid}
    t_render = now()
    daemon = Daemon(app)
    seeded = seed(socket_path)
    rec["seeded"] = seeded
    time.sleep(2.0)  # harness: the loops print into scrollback
    rec["state_before"] = before = state(socket_path, daemon, seeded)
    verdict, detail = probe(socket_path, report)
    rec["probe"] = {"base": verdict}
    rec["probe_detail"] = {"base": detail}
    if verdict == "pass":
        rec["probe_green_at"] = now()
    rec["launch_to_probe_s"] = round(now() - t_render, 2)
    if PHASE == "inplace":
        if PROBE == "chat_scroll_jumps":
            ok, secs = overlay(LAB["env"], "build", 1800)
            time.sleep(1.0)  # harness: pages reload on the overlay's manifest.json
            rec["apply"] = {"outcome": "applied" if ok else "failed", "path": "web overlay (the head's bundles, built)",
                            "seconds": secs, "zero_compile": False, "why": None if ok else "web-overlay.sh build failed"}
        else:
            rec["apply"] = {"outcome": "refused", "path": None, "seconds": None, "zero_compile": False,
                            "why": "Swift: the running app has no patch loader and its binary exports no symbols "
                                   "(identity base.json); no in-place path exists: a full build and a relaunch"}
        if rec["apply"]["outcome"] == "applied":
            v2, d2 = probe(socket_path, report)
            rec["probe"]["after_apply"] = v2
            rec["probe_detail"]["after_apply"] = d2
            if v2 == "pass":
                rec["probe_green_at"] = now()
            rec["state_after"] = after = state(socket_path, daemon, seeded)
            rec["same_pid"] = before.get("pid") is not None and before.get("pid") == after.get("pid") == process.pid
            grew = all(((after["loops"].get(k) or {}).get("scrollback_rows") or 0) >= (v.get("scrollback_rows") or 0)
                       for k, v in before["loops"].items())
            rec["state_intact"] = bool(rec["same_pid"] and set(before["workspaces"]) <= set(after["workspaces"])
                                       and before["windows"] == after["windows"]
                                       and set(before["chat_tabs"]) <= set(after["chat_tabs"]) and before["chat_tabs"]
                                       and all((v or {}).get("shell_alive") for v in after["loops"].values()) and grew
                                       and len(before["loops"]) >= 2)
            reverted, _ = overlay(LAB["env"], "off", 120)
            time.sleep(1.0)  # harness: pages reload on the overlay's removal
            v3, d3 = probe(socket_path, report)
            rec["revert"] = {"done": reverted, "probe_after_revert": v3}
            rec["probe"]["after_revert"] = v3
            rec["probe_detail"]["after_revert"] = d3
        else:
            rec["same_pid"] = None
            rec["state_intact"] = None
            rec["revert"] = {"done": None, "why": "nothing was applied"}
    Path(out).mkdir(parents=True, exist_ok=True)
    Path(out, "inplace.json").write_text(json.dumps(rec, indent=2, default=str))
    return []


smoke.PREPARE_HOME = prepare_home
smoke.AFTER_RENDER = after_render
if __name__ == "__main__":
    sys.exit(smoke.main(sys.argv[1:] + ["--seconds", "5", "--startup-timeout", "150"]))
DRIVER
  # The head's tree beside it, for the web bundles (a web change) and the parity build.
  git -C "$here" worktree add --quiet --detach "$scratch/head" "$sha" || return 3
  export LIVE_APPLY_HEAD_TREE="$scratch/head" LIVE_APPLY_BASE_TREE="$srcdir" LIVE_APPLY_PROBE="$probe" \
    LIVE_APPLY_PR="$pr" LIVE_APPLY_OUT="$out" LIVE_APPLY_PHASE=inplace LIVE_APPLY_HERE="$here" \
    LIVE_APPLY_SCRIPT_BLOB="$(git -C "$here" rev-parse HEAD:scripts/measure/live-apply-matrix.sh 2>/dev/null || echo unknown)"
  python3 "$scratch/driver.py" --app "$base_app" --out "$out/lab-$pr" >"$out/lab-$pr.log" 2>&1 || status=$?
  python3 "$here/scripts/cmux-next/tag_teardown.py" "$base_app" >/dev/null 2>&1 || true
  # Parity and fallback: the head built on the same tag (incremental), launched fresh, probed.
  local th0 th1
  th0=$(python3 -c 'import time; print(f"{time.time():.3f}")')
  (cd "$srcdir" && git checkout --quiet --detach "$sha" && CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --no-global-cli-links) >"$out/reload-head-$pr.log" 2>&1 || true
  th1=$(python3 -c 'import time; print(f"{time.time():.3f}")')
  head_app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload-head-$pr.log" | tail -n 1)"
  if [[ -n "$head_app" && -d "$head_app" ]]; then
    LIVE_APPLY_PHASE=parity python3 "$scratch/driver.py" --app "$head_app" --out "$out/parity-$pr" >"$out/parity-$pr.log" 2>&1 || true
    python3 "$here/scripts/cmux-next/tag_teardown.py" "$head_app" >/dev/null 2>&1 || true
  fi
  python3 - "$out" "$pr" "$sha" "$base" "$stratum" "$probe" "$t_select" "$tb0" "$tb1" "$th0" "$th1" "${head_app:-}" <<'PY'
import json, os, sys, time
out, pr, sha, base, stratum, probe, t0, tb0, tb1, th0, th1, head_app = sys.argv[1:]
t0, tb0, tb1, th0, th1 = map(float, (t0, tb0, tb1, th0, th1))
def load(p):
    try:
        return json.load(open(p))
    except (OSError, ValueError):
        return None
lab = load(f"{out}/lab-{pr}/inplace.json") or {}
parity = load(f"{out}/parity-{pr}/inplace.json") or {}
ident = load(f"{out}/identity-{pr}/base.json") or {}
cls = load(f"{out}/classifier-{pr}.json") or {}
nightly_commit = "8a134ee405f83893b3950c45ee60305ffc20859f"
p = lab.get("probe", {})
inplace_ok = (p.get("base") == "fail" and p.get("after_apply") == "pass" and lab.get("same_pid") is True
              and lab.get("state_intact") is True)
parity_ok = (parity.get("probe") or {}).get("base") == "pass"
if lab.get("apply", {}).get("outcome") == "applied" and inplace_ok and parity_ok:
    verdict = "in_place_pass"
elif lab.get("apply", {}).get("outcome") != "applied":
    verdict = "fallback_full_build"
else:
    verdict = "in_place_fail"
probe_discriminates = p.get("base") == "fail" and parity_ok
# Whether a Release app (NIGHTLY, DEV) can read this probe at all. chat_scroll_jumps needs the
# Debug-only debug.agent_pane: the lab build can run it, but its result says nothing about Release,
# so that row is neither covered nor failed for Release.
release_probe = {"chat_scroll_jumps": "unsupported", "post_frame_feeds_mark": "accessible",
                 "close_key_turn": "accessible"}.get(probe, "unsupported")
apply_s = lab.get("apply", {}).get("seconds")
row = {
  "label": "IMPLEMENTED",
  "experience": "2: in-place swap into a running real cmux (lab instance, fresh home)",
  "pr": int(pr), "applied_commit": sha, "base": base, "stratum": stratum, "probe_name": probe,
  "identity": {"base_app": ident, "base_build_s": round(tb1 - tb0, 2),
               "script_blob": os.environ.get("LIVE_APPLY_SCRIPT_BLOB"),
               "published_nightly_commit": nightly_commit,
               "published_nightly_is_base": base == nightly_commit,
               "published_nightly_already_contains_pr": True,
               "host": os.uname().nodename.split(".")[0]},
  "classifier": {"label": "CLASSIFIER-ONLY", "verdict": cls.get("verdict"), "reasons": cls.get("reasons")},
  "seeded_state": lab.get("seeded"), "state_before": lab.get("state_before"), "state_after": lab.get("state_after"),
  "apply": lab.get("apply"), "same_pid": lab.get("same_pid"), "state_intact": lab.get("state_intact"),
  "probe": {"base": p.get("base"), "after_apply": p.get("after_apply"), "after_revert": p.get("after_revert"),
            "full_head_build": (parity.get("probe") or {}).get("base"), "discriminates": probe_discriminates,
            "detail": lab.get("probe_detail"), "parity_detail": parity.get("probe_detail")},
  "revert": lab.get("revert"),
  "fallback": None if verdict == "in_place_pass" else {
      "reason": (lab.get("apply") or {}).get("why") or "in place applied but a check failed",
      "head_build_s": round(th1 - th0, 2), "head_app_built": bool(head_app),
      "launch_to_probe_s": parity.get("launch_to_probe_s"),
      "state_after_fallback": "not preserved: a relaunch from a fresh home (the harness starts each launch fresh)"},
  "compile_checked": "pass" if head_app else "fail",
  "runtime": "pass" if parity_ok else ("fail" if head_app else "not_run"),
  "verdict": verdict,
  "needs_full_build": verdict != "in_place_pass",
  "release_probe": release_probe,
  "counted_for_release": release_probe == "accessible",
  "seconds": {
      "selection_to_probe_green_in_place": lab.get("probe_green_at") - t0 if verdict == "in_place_pass" and lab.get("probe_green_at") else None,
      "apply_only": apply_s,
      "selection_to_probe_green_fallback": (parity.get("probe_green_at") - t0) if parity.get("probe_green_at") else None,
      "total": round(time.time() - t0, 2)},
}
json.dump(row, open(f"{out}/inplace-{pr}.json", "w"), indent=2)
print(json.dumps(row, indent=2))
PY
  tar -czf "$out/inplace-$pr.tgz" -C "$out" . 2>/dev/null || true
  return $status
}
if [[ "${1:-}" == inplace ]]; then
  [[ $# -eq 3 ]] || { echo "usage: live-apply-matrix.sh inplace OUT PR" >&2; exit 64; }
  inplace "$2" "$3"
  exit $?
fi
out="${1:?usage: live-apply-matrix.sh OUT [ROW...]}"; shift
mkdir -p "$out"; out="$(cd "$out" && pwd)"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
package="$root/Prototypes/ViewShell"
src="$package/Sources/ViewShell"
fixture="$src/MatrixFixture.swift"
badge="$src/Badge.swift"
main_swift="$src/main.swift"
if [[ -e "$fixture" || -L "$fixture" ]]; then
  echo "live-apply-matrix: $fixture already exists; this measurement writes and deletes it" >&2; exit 1
fi
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
# Base provenance: the commit every row's prebuilt and full build come from, and a clean view shell
# at that commit (an edited source would make the "base" something other than the commit).
base_sha="$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)"
if [[ "$base_sha" == unknown ]]; then
  echo "live-apply-matrix: $root is not a git checkout; the base commit cannot be checked" >&2; exit 1
fi
if [[ -n "$(git -C "$root" status --porcelain -- Prototypes/ViewShell)" ]]; then
  echo "live-apply-matrix: Prototypes/ViewShell differs from $base_sha; refusing to call that the base" >&2
  git -C "$root" status --porcelain -- Prototypes/ViewShell >&2; exit 1
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/live-apply-matrix.XXXXXX")"
mkdir -p "$work/orig"
cp "$badge" "$main_swift" "$work/orig/"
shell=""
restore_all() {
  [[ -n "$shell" ]] && kill "$shell" 2>/dev/null || true
  cp "$work/orig/Badge.swift" "$badge"; cp "$work/orig/main.swift" "$main_swift"
  rm -f "$fixture"
  rm -rf "$work"
}
trap restore_all EXIT

# The seeded base: one fixture file, one term per mechanism, all 0; the badge's padding adds them.
cat >"$work/MatrixFixture.swift" <<'SWIFT'
import AppKit
import SwiftUI

// Written by scripts/measure/live-apply-matrix.sh and removed when it ends. Each declaration is
// one row's mechanism; a row's change makes its term 16.
func matrixPad() -> CGFloat {
    0 // pad
}

struct MatrixBox {
    var a: CGFloat = 0
    func total() -> CGFloat {
        a // box
    }
}

final class MatrixFinal {
    var a: CGFloat = 0
    func total() -> CGFloat {
        a // final
    }
}

class MatrixBase {
    func extra() -> CGFloat {
        0 // base
    }
}

final class MatrixSub: MatrixBase {
    override func extra() -> CGFloat {
        0 // sub
    }
}

protocol MatrixPadding {
    func extra() -> CGFloat
}

struct MatrixWitness: MatrixPadding {
    func extra() -> CGFloat {
        0 // witness
    }
}

final class MatrixObjC: NSObject {
    @objc dynamic func extra() -> CGFloat {
        0 // objc
    }
}

enum MatrixTone {
    case plain
    case loud
}

func matrixTonePad(_ tone: MatrixTone) -> CGFloat {
    switch tone {
    case .plain: 0
    case .loud: 0
    }
}

enum MatrixStatics {
    static func pad() -> CGFloat {
        0 // statics
    }
}

func matrixGeneric<T>(_ value: T) -> CGFloat {
    0 // generic
}

func matrixDefault(_ x: CGFloat = 0) -> CGFloat {
    x
}

@_transparent func matrixInline() -> CGFloat {
    0 // inline
}

let matrixGlobal: CGFloat = 0
SWIFT
cat >"$work/Badge.extra.swift" <<'SWIFT'

// Seeded by scripts/measure/live-apply-matrix.sh: the caller of every fixture term.
func matrixExtra() -> CGFloat {
    let base: MatrixBase = MatrixSub()
    let witness: any MatrixPadding = MatrixWitness()
    var total: CGFloat = matrixPad()
    total += MatrixBox().total()
    total += MatrixFinal().total()
    total += base.extra()
    total += witness.extra()
    total += MatrixObjC().extra()
    total += matrixTonePad(.plain)
    total += MatrixStatics.pad()
    total += matrixGeneric(1)
    total += matrixDefault()
    total += matrixInline()
    total += matrixGlobal
    return total
}
SWIFT

# FILE OLD NEW: replace one exact occurrence, or fail the row (the seed drifted).
subst() {
  python3 - "$@" <<'PY'
import sys
path, old, new = sys.argv[1:]
text = open(path).read()
if text.count(old) != 1:
    sys.exit(f"subst: {old!r} occurs {text.count(old)} times in {path}")
open(path, "w").write(text.replace(old, new))
PY
}
seed() {
  cp "$work/MatrixFixture.swift" "$fixture"
  cp "$work/orig/Badge.swift" "$badge"; cp "$work/orig/main.swift" "$main_swift"
  subst "$badge" ".padding(.horizontal, 8)" ".padding(.horizontal, 8 + matrixExtra())"
  cat "$work/Badge.extra.swift" >>"$badge"
  # Older than the prebuilt executable, so inject.sh never takes a file as "changed since the build"
  # only because the matrix rewrote it.
  touch -t 202001010000 "$fixture" "$badge" "$main_swift"
}

# Each row: NAME|CATEGORY|FILES TO NAME TO inject.sh|EDIT (a shell function)
edit_control()         { subst "$badge" ".foregroundStyle(.secondary)" ".foregroundStyle(.red).padding(.leading, 16)"; }
edit_callee_body()     { subst "$fixture" "    0 // pad" "    16 // pad"; }
edit_callee_sig()      { subst "$fixture" $'func matrixPad() -> CGFloat {\n    0 // pad' $'func matrixPad(scale: CGFloat = 1) -> CGFloat {\n    16 * scale // pad'; }
edit_struct_stored()   { subst "$fixture" $'    var a: CGFloat = 0\n    func total() -> CGFloat {\n        a // box' $'    var a: CGFloat = 0\n    var b: CGFloat = 16\n    func total() -> CGFloat {\n        a + b // box'; }
edit_class_stored()    { subst "$fixture" $'    var a: CGFloat = 0\n    func total() -> CGFloat {\n        a // final' $'    var a: CGFloat = 0\n    var b: CGFloat = 16\n    func total() -> CGFloat {\n        a + b // final'; }
edit_vtable_body()     { subst "$fixture" "        0 // sub" "        16 // sub"; }
edit_witness_body()    { subst "$fixture" "        0 // witness" "        16 // witness"; }
edit_objc_body()       { subst "$fixture" "        0 // objc" "        16 // objc"; }
edit_enum_case()       { subst "$fixture" $'    case plain\n    case loud\n' $'    case plain\n    case loud\n    case huge\n'
                         subst "$fixture" "    case .loud: 0" $'    case .loud: 0\n    case .huge: 16'
                         subst "$badge" "matrixTonePad(.plain)" "matrixTonePad(.huge)"; }
edit_static_stored()   { subst "$fixture" $'enum MatrixStatics {\n    static func pad() -> CGFloat {\n        0 // statics' $'enum MatrixStatics {\n    static let extra: CGFloat = 16\n    static func pad() -> CGFloat {\n        extra // statics'; }
edit_generic_body()    { subst "$fixture" "    0 // generic" "    16 // generic"; }
edit_default_arg()     { subst "$fixture" "func matrixDefault(_ x: CGFloat = 0) -> CGFloat {" "func matrixDefault(_ x: CGFloat = 16) -> CGFloat {"; }
edit_transparent()     { subst "$fixture" "    0 // inline" "    16 // inline"; }
edit_global_value()    { subst "$fixture" "let matrixGlobal: CGFloat = 0" "let matrixGlobal: CGFloat = 16"; }
edit_view_state()      { subst "$badge" "    let text: String" $'    let text: String\n    @State private var extra: CGFloat = 16'
                         subst "$badge" ".padding(.horizontal, 8 + matrixExtra())" ".padding(.horizontal, 8 + matrixExtra() + extra)"; }
edit_entry_point()     { subst "$main_swift" "    var live: URL?" $'    var live: URL?\n    var matrixUnused = 0'; }
ROWS=(
  "control_view_body|body-only (caller file)|Badge.swift|edit_control"
  "callee_body|caller/linking: callee body, caller unpatched|MatrixFixture.swift|edit_callee_body"
  "callee_signature|caller/linking: callee signature, callee only|MatrixFixture.swift|edit_callee_sig"
  "callee_signature_with_callers|caller/linking: callee signature, callee + callers|MatrixFixture.swift Badge.swift|edit_callee_sig"
  "struct_stored_property|ABI/layout: struct stored property|MatrixFixture.swift|edit_struct_stored"
  "class_stored_property|ABI/layout: final class stored property|MatrixFixture.swift|edit_class_stored"
  "view_state_property|ABI/layout: SwiftUI @State on the view|Badge.swift|edit_view_state"
  "enum_case_added|ABI/layout: enum case (same size) + caller|MatrixFixture.swift Badge.swift|edit_enum_case"
  "vtable_override_body|dispatch: non-final class override body|MatrixFixture.swift|edit_vtable_body"
  "protocol_witness_body|dispatch: protocol witness body via existential|MatrixFixture.swift|edit_witness_body"
  "objc_dynamic_body|dispatch: @objc dynamic method body|MatrixFixture.swift|edit_objc_body"
  "static_stored_added|stored: new static let|MatrixFixture.swift|edit_static_stored"
  "global_let_value|stored: global let initial value|MatrixFixture.swift|edit_global_value"
  "generic_body|generics: unspecialized generic body|MatrixFixture.swift|edit_generic_body"
  "default_argument_value|caller/linking: default argument value|MatrixFixture.swift|edit_default_arg"
  "transparent_body|caller/linking: @_transparent (inlined into caller)|MatrixFixture.swift|edit_transparent"
  "entry_point_file|native shell: main.swift (the loop and its options)|main.swift|edit_entry_point"
)
want=("$@")
# ROW arguments pick rows; none picks every row. Both the diffs-only and the measured runs use it.
wanted() { (( ${#want[@]} == 0 )) || [[ " ${want[*]} " == *" $1 "* ]]; }

# The badge's rendered width for generation N in LOG (empty when it was not drawn).
width_of() { grep "rendered .*generation-$2\.png" "$1" 2>/dev/null | sed -n 's/.*width=\([0-9]*\).*/\1/p' | tail -1; }
wait_log() { # LOG PATTERN SECONDS
  for _ in $(seq 1 $(( $3 * 10 ))); do grep -q "$2" "$1" && return 0; sleep 0.1; done; return 1
}
start_shell() { # BIN LIVE RENDER LOG
  "$1" --headless --live "$2" --live-render "$3" >"$4" 2>&1 &
  shell=$!
}
stop_shell() { [[ -n "$shell" ]] && { kill "$shell" 2>/dev/null || true; wait "$shell" 2>/dev/null || true; }; shell=""; }

diffs_only="${LIVE_APPLY_MATRIX_DIFFS_ONLY:-}"
if [[ -n "$diffs_only" ]]; then
  for spec in "${ROWS[@]}"; do
    IFS='|' read -r name category names edit <<<"$spec"
    wanted "$name" || continue
    dir="$out/$name"; mkdir -p "$dir"; : >"$dir/change.diff"
    seed
    cp "$fixture" "$dir/MatrixFixture.before.swift"; cp "$badge" "$dir/Badge.before.swift"; cp "$main_swift" "$dir/main.before.swift"
    "$edit"
    for f in MatrixFixture Badge main; do
      case $f in MatrixFixture) p="$fixture";; Badge) p="$badge";; main) p="$main_swift";; esac
      diff -u --label "a/Prototypes/ViewShell/Sources/ViewShell/$f.swift" --label "b/Prototypes/ViewShell/Sources/ViewShell/$f.swift" \
        "$dir/$f.before.swift" "$p" >>"$dir/change.diff" || true
    done
    rm -f "$dir"/*.before.swift
  done
  exit 0
fi
swift --version 2>&1 | head -1 >"$out/swift-version.txt"
sw_vers >"$out/sw_vers.txt" 2>&1 || true

# The prebuilt: the seeded base's Debug build, made once.
seed
seeded_digest="$(cat "$fixture" "$badge" "$main_swift" | shasum -a 256 | cut -d' ' -f1)"
b0=$(now)
swift build --package-path "$package" --scratch-path "$work/prebuilt" --product cmux-view-shell >"$out/prebuilt-build.log" 2>&1 \
  || { echo "live-apply-matrix: the seeded base does not build"; tail -40 "$out/prebuilt-build.log"; exit 1; }
b1=$(now)
prebuilt_bin="$(swift build --package-path "$package" --scratch-path "$work/prebuilt" --show-bin-path)/cmux-view-shell"
export CMUX_VIEW_SHELL_BUILD="$work/prebuilt/debug"

: >"$out/rows.jsonl"
for spec in "${ROWS[@]}"; do
  IFS='|' read -r name category names edit <<<"$spec"
  wanted "$name" || continue
  dir="$out/$name"; mkdir -p "$dir"; : >"$dir/change.diff"
  seed
  # Every row starts from the very tree the prebuilt was built from.
  if [[ "$(cat "$fixture" "$badge" "$main_swift" | shasum -a 256 | cut -d' ' -f1)" != "$seeded_digest" ]]; then
    echo "live-apply-matrix: row $name: the seeded base drifted from the prebuilt's" >&2; exit 1
  fi
  cp "$fixture" "$dir/MatrixFixture.before.swift"; cp "$badge" "$dir/Badge.before.swift"; cp "$main_swift" "$dir/main.before.swift"
  edit_ok=yes; "$edit" 2>"$dir/edit.err" || edit_ok=no
  for f in MatrixFixture Badge main; do
    case $f in MatrixFixture) p="$fixture";; Badge) p="$badge";; main) p="$main_swift";; esac
    diff -u --label "a/Prototypes/ViewShell/Sources/ViewShell/$f.swift" --label "b/Prototypes/ViewShell/Sources/ViewShell/$f.swift" \
      "$dir/$f.before.swift" "$p" >>"$dir/change.diff" || true
  done
  rm -f "$dir"/*.before.swift
  # The edited files are newer than the prebuilt, as in a real checkout after a pull.
  touch "$fixture" "$badge" "$main_swift" 2>/dev/null || true
  touch -t 202001010000 "$main_swift"
  [[ "$name" == entry_point_file ]] && touch "$main_swift"
  [[ "$names" == *Badge.swift* || "$name" == view_state_property ]] || touch -t 202001010000 "$badge"
  [[ "$names" == *MatrixFixture.swift* ]] || touch -t 202001010000 "$fixture"

  # 1. prebuilt + patch
  live="$work/live-$name"; mkdir -p "$live"
  start_shell "$prebuilt_bin" "$live" "$dir/patch" "$dir/patch-shell.log"
  patch_outcome="" patch_width="" patch_base_width="" inject_s="" edit_to_pixels_s=""
  if ! wait_log "$dir/patch-shell.log" "redrawn generation=0" 30; then
    patch_outcome="shell_did_not_start"
  else
    patch_base_width="$(width_of "$dir/patch-shell.log" 0)"
    t0=$(now)
    args=(); for n in $names; do args+=("$src/$n"); done
    if [[ "$edit_ok" != yes ]]; then
      patch_outcome="edit_failed"
    elif ! "$package/inject.sh" --live "$live" "${args[@]}" >"$dir/inject.log" 2>&1; then
      patch_outcome="inject_failed"
    else
      t1=$(now); inject_s=$(python3 -c "print(round($t1-$t0,2))")
      for _ in $(seq 1 300); do
        grep -q "redrawn generation=1" "$dir/patch-shell.log" && { patch_outcome="applied"; break; }
        grep -q "refused" "$dir/patch-shell.log" && { patch_outcome="refused"; break; }
        kill -0 "$shell" 2>/dev/null || { patch_outcome="shell_exited"; break; }
        sleep 0.1
      done
      [[ -z "$patch_outcome" ]] && patch_outcome="no_redraw_30s"
      if [[ "$patch_outcome" == applied ]]; then
        sleep 0.5
        patch_width="$(width_of "$dir/patch-shell.log" 1)"
        drawn=$(grep "redrawn generation=1" "$dir/patch-shell.log" | sed 's/.*at=//' | tail -1)
        edit_to_pixels_s=$(python3 -c "print(round($drawn-$t0,2))")
      fi
    fi
  fi
  stale_ptrs="$(grep -o '[0-9]* symbol pointers stayed on the old code' "$dir/patch-shell.log" | head -1 || true)"
  stop_shell

  # 2. full build of the same tree
  # Each row's full build starts from a copy of the prebuilt's folder (warm, like an incremental CI
  # build of the base), so no row's build sees another row's objects.
  rm -rf "$work/full"; cp -R "$work/prebuilt" "$work/full"
  f0=$(now)
  compile_checked=pass
  swift build --package-path "$package" --scratch-path "$work/full" --product cmux-view-shell >"$dir/full-build.log" 2>&1 || compile_checked=fail
  f1=$(now)
  full_width=""; full_runtime=not_run
  if [[ "$compile_checked" == pass ]]; then
    full_bin="$(swift build --package-path "$package" --scratch-path "$work/full" --show-bin-path)/cmux-view-shell"
    mkdir -p "$work/live-full-$name"
    start_shell "$full_bin" "$work/live-full-$name" "$dir/full" "$dir/full-shell.log"
    if wait_log "$dir/full-shell.log" "redrawn generation=0" 30; then
      sleep 0.5; full_width="$(width_of "$dir/full-shell.log" 0)"; full_runtime=pass
    else
      full_runtime=fail
    fi
    stop_shell
  fi

  python3 - "$out/rows.jsonl" "$name" "$category" "$names" "$patch_outcome" "$patch_base_width" "$patch_width" \
    "$full_width" "$compile_checked" "$full_runtime" "$inject_s" "$edit_to_pixels_s" "$(python3 -c "print(round($f1-$f0,2))")" "$stale_ptrs" \
    "$(grep -m1 -E 'refused|error:' "$dir/patch-shell.log" "$dir/inject.log" 2>/dev/null | cut -c1-400 || true)" <<'PY'
import json, sys
(path, name, category, names, outcome, base_w, patch_w, full_w, compile_checked, full_runtime,
 inject_s, e2p, full_s, stale, why) = sys.argv[1:]
num = lambda s: int(s) if s else None
fl = lambda s: float(s) if s else None
base_w, patch_w, full_w = num(base_w), num(patch_w), num(full_w)
row_valid = (full_w is not None and base_w is not None and full_w != base_w) if compile_checked == "pass" else None
if outcome == "applied":
    runtime = "pass"
    if row_valid is False:
        verdict = "invalid_row"  # the change did not move the full build's pixels: proves nothing
    elif patch_w is not None and patch_w == full_w:
        verdict = "match"
    else:
        verdict = "MISMATCH"
elif outcome in ("refused", "inject_failed"):
    verdict = "detected_fallback"; runtime = "not_run"
else:
    verdict = "error"; runtime = "fail"
row = {
  "label": "IMPLEMENTED",
  "evidence": "supporting: Debug view-shell prototype, controlled pixels; not a real-app proof",
  "row": name, "category": category, "files_named_to_inject": names.split(),
  "patch": {"outcome": outcome, "runtime": runtime, "width_before_px": base_w, "width_after_px": patch_w,
            "inject_s": fl(inject_s), "edit_to_pixels_s": fl(e2p), "stale_symbol_pointers": stale or None,
            "detail": why or None},
  "full_build": {"compile_checked": compile_checked, "runtime": full_runtime, "width_px": full_w,
                 "incremental_build_s": fl(full_s)},
  "new_code_ran_in_patch": (patch_w != base_w) if outcome == "applied" and patch_w and base_w else None,
  # The change moved the full build's pixels: otherwise the row cannot tell old code from new.
  "row_valid": row_valid,
  # A mismatch, a detected fallback, an error or an invalid row all mean the PR still needs the
  # full build: only a valid match counts as covered by prebuilt + patch.
  "needs_full_build": verdict != "match",
  "verdict": verdict,
}
open(path, "a").write(json.dumps(row) + "\n")
print(json.dumps(row))
PY
done

base_sha="$base_sha" seeded_digest="$seeded_digest" python3 - "$out" "$(python3 -c "print(round($b1-$b0,2))")" <<'PY'
import json, os, sys
out, prebuilt_s = sys.argv[1:]
base_sha, seeded_digest = os.environ["base_sha"], os.environ["seeded_digest"]
rows = [json.loads(l) for l in open(f"{out}/rows.jsonl")]
summary = {}
for r in rows:
    summary[r["verdict"]] = summary.get(r["verdict"], 0) + 1
covered = sum(1 for r in rows if r["verdict"] == "match")
result = {"label": "IMPLEMENTED", "harness": "Prototypes/ViewShell headless, seeded base",
          "evidence": "supporting: controlled pixels in the Debug view-shell prototype. Not proof of an isolated real cmux instance or an in-place swap into a running real cmux; covered_by_patch is per mechanism, not real-app PR coverage",
          "base_sha": base_sha, "seeded_base_sha256": seeded_digest,
          "covered_by_patch": covered, "needs_full_build": len(rows) - covered,
          "note": "needs_full_build counts MISMATCH, detected_fallback, error and invalid_row: every row stays in the denominator",
          "swift": open(f"{out}/swift-version.txt").read().strip(),
          "prebuilt_debug_build_s": float(prebuilt_s), "rows": len(rows), "verdicts": summary,
          "mismatch_rows": [r["row"] for r in rows if r["verdict"] == "MISMATCH"],
          "fallback_rows": [r["row"] for r in rows if r["verdict"] == "detected_fallback"],
          "error_rows": [r["row"] for r in rows if r["verdict"] == "error"]}
json.dump(result, open(f"{out}/result.json", "w"), indent=2)
print(json.dumps(result))
PY
# One file for the fleet's --artifact: the whole OUT folder.
tar -czf "$out.tgz" -C "$(dirname "$out")" "$(basename "$out")"
