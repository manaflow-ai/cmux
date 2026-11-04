#!/usr/bin/env bash
# Measurement only (cmuxterm-hq#7111 track 4); not landed. A fleet ci-step runs a script only when
# its bytes equal feat-cmux-next's or main's (the worker's reviewed-bytes check), so this file runs on
# the fleet only after it lands there, at that commit; running it at a PR head would also take a
# controller measurement-list entry. Until then every row it would write stays CLASSIFIER-ONLY.
#
# Times, in a real cmux app on a fleet display Mac, the seconds from selecting a pull request to the
# PR's behaviour working, for the two experiences, without waiting for a new DEV build:
#   isolated   (E1) a fresh, separate real app instance that starts with the PR's change, beside a
#              running instance of the same artifact (this run's base) that keeps running untouched
#   in-place   (E2) the PR's change hot-swapped into a real app that is already running, same process
#   full-build the probe's own check, not an experience: --app-zip is a full build of the head (the
#              probe must pass: parity) or of the base (it must fail), for any verdict, Swift included
# A browser page, a screenshot change or the view shell prototype is not either experience: the proof is
# a PR-specific functional probe run against the real app (below); pixels only support it.
# The step's checkout is the PR head. The script refuses to launch anything outside a fleet step.
#
#   cmux-ci run --class exclusive --display --script scripts/measure/try-pr-apply.sh --ref HEAD \
#     --arg=--experience=isolated|in-place|full-build --arg=--pr=N --arg=--kind=nightly|dev \
#     --arg=--mode=installed|lab --arg=--app-zip=URL_OR_PATH --arg=--base=SHA \
#     [--arg=--artifact-ref=SHA --arg=--artifact-sha256=HEX] \
#     --arg=--probe=CMD [--arg=--seed=CMD --arg=--state-probe=CMD] --arg=--expect-region=X,Y,W,H --arg=--expect-why=TEXT \
#     --artifact artifacts/try-pr-apply/result.json
#
# Identity, recorded in every result (`identity`): the PR, head (this checkout), base (the manifest's
# exact base, which must be the merge base of base and head), the app's build SHA and where it came
# from (below), its version, build and executable sha256, the zip's sha256, the PR diff's sha256 and
# the built overlay's, this script's blob, the host class, and the wall clock start and end.
#
# Modes, reported as different paths and never pooled:
#   installed  the app exactly as shipped: no Info.plist edit, no re-sign, launched with `open`.
#              It stands for NIGHTLY or DEV only when all of these hold, each recorded:
#              the shipped bundle id (com.cmuxterm.app.nightly, or the daily DEV's exact
#              com.cmuxterm.app.debug.next), codesign --verify --deep --strict, the hardened runtime
#              flag, and Gatekeeper's assessment (spctl --assess --type execute) accepting it.
#              Anything else is `not-eligible-<kind>`, a fallback row.
#              Disclosed deviations from a person's install, written into every result: it runs
#              from the step's temp folder (no quarantine, so Gatekeeper's first-launch check is not
#              exercised), and its settings file, debug tunables and web overlay are this run's own,
#              passed at launch (`open -n --env`: CMUX_NEXT_CONFIG_FILE, CMUX_NEXT_DEBUG_TUNABLES_FILE,
#              CMUX_WEB_OVERLAY_DIR), one set per instance; a person turns the overlay on in Debug
#              Settings instead.
#   lab        a tagged side instance (#35544's mechanics): Info.plist edited (bundle id
#              <id>.side-try.t<pid>, unique per run) and re-signed ad hoc. Evidence about the lab path
#              only (`lab-<kind>`), never about an installed app. A lab
#              DEV copy has a changed id, which WebDevOverride.isAvailable refuses in a Release DEV.
#
# Base identity: the app's CMUXCommit (Info.plist). DEV builds carry none, so for them the fleet
# job's provenance stands in: --artifact-ref (the job's ref) counts only when the zip's own sha256
# equals --artifact-sha256 (the job's artifact digest, both read from `cmux-ci status`), which ties
# this zip to that job. The commit must equal --base; a mismatch, a CMUXCommit that disagrees with
# --artifact-ref, an unverified digest or no commit at all is a fallback, never a success.
#
# Proof (runtime=pass needs all of it):
#   probe        --probe=CMD, required: PR-specific behaviour read from the real app (its socket, its
#                accessibility tree or its page DOM through the app). Exit 0: the PR's behaviour is
#                there; 1: the app answered and it is not; anything else: the app is not ready yet, so
#                the script asks again (up to USABLE_SECONDS) and a red is never just a slow start.
#                It runs with CMUX_TRY_STATE=base|pr|full-build, CMUX_TRY_PID, CMUX_TRY_APP,
#                CMUX_TRY_SOCKET (the instance's control socket), CMUX_NEXT_CONFIG_FILE and
#                CMUX_WEB_OVERLAY_DIR. It must fail on base and pass on the PR.
#                Without it the run is `not_proven`, whatever the pixels show.
#   integrity    in-place: the same process before and after (pid and start time), no relaunch, and
#                the seeded state surviving, named, not a digest: --seed=CMD (after the base launch,
#                setup) makes 2+ workspaces, a terminal running a long-lived process with scrollback
#                and an open chat; --state-probe=CMD prints JSON {"workspaces": N, "terminal_pid": PID,
#                "scrollback_sha256": HEX, "chat": ID_AND_MESSAGE_COUNT}. Before and after must be
#                equal, with N >= 2 and the terminal process alive; without both, the run is at most
#                `not_proven` ("state survival not proven").
#                isolated: the PR instance is a new process started while the base instance (same
#                artifact, its own HOME, socket, settings and overlay) keeps running; afterwards the
#                base must still be the same process (pid and start time) on the same socket, and the
#                probe must still fail on it (the PR instance did not change it). Every instance gets
#                its own HOME (HOME and CFFIXED_USER_HOME), control socket (CMUX_NEXT_SOCKET_PATH),
#                settings file and overlay folder, and must create that socket; the state each one
#                wrote under its HOME is listed.
#   coexistence  the script never quits, signals or refuses because of an app it did not launch.
#                `coexistence` is about the run's own base instance (above); `coexistence_preexisting`
#                about other cmux apps that were already running: NOT PROVEN when there were none, and
#                a pass only when the isolation check (below) does. An installed copy under the
#                shipped bundle id next to an already running app with that same id would share its
#                bundle-id state under the account's real home: a fallback (unsupported), and that app
#                is left alone; --mode=lab runs a tagged copy (its own bundle id, re-signed: LAB).
#   isolation    both experiences: other cmux processes (pid, start time), the cmux sockets and the cmux
#                state under the account's real home (Application Support, ~/.cmux, Preferences, four
#                levels deep: path, inode, size, mtime) are listed before the first launch and after
#                the last probe; any change fails the run.
#   pixels       supporting only: decoded pixels (sips to BMP, never PNG bytes) in --expect-region,
#                with a base, a repeat install and a base-only control window (CONTROL_SECONDS,
#                default 30); a control diff marks the pixel evidence inconclusive.
#
# Time (result.json): `setup` phases are not part of the experience and say whether they are
# amortized: fetching and preparing the app (an installed NIGHTLY or DEV is already on the Mac), and
# for in-place the launch and the base overlay (the app is already running). `controls` are the
# measurement's own and never counted. `select_to_usable_s` runs from selecting the PR to the probe
# passing: verdict, compile (the PR's web bundles: claim 2, never zero compilation), apply (for
# isolated also the launch), usable (USABLE_SECONDS cap, default 60). The PR head's fetch is the
# step's checkout, timed in the step's controller record, not here. `total_s` is the whole run,
# setup and controls included; a full-build run reports `launch_to_probe_s` instead.
# Daemon verdicts are their own N/A stratum: no path ships a PR's daemon into an installed app, so they
# are recorded and never counted as covered. Swift and rebuild verdicts: neither experience exists for
# them in the app today; a fallback row says so (the view shell prototype does not count), and its
# time is a full build's: the DEV build job's seconds plus a full-build run of this script.
set -euo pipefail
experience="" pr="" kind="" mode="" app_zip="" base="" artifact_ref="" artifact_sha="" region="" why="" probe="" state_probe="" seed=""
control_seconds="${CONTROL_SECONDS:-30}" usable_seconds="${USABLE_SECONDS:-60}"
for a in "$@"; do
  case "$a" in
    --experience=*) experience="${a#*=}" ;; --pr=*) pr="${a#*=}" ;; --kind=*) kind="${a#*=}" ;; --mode=*) mode="${a#*=}" ;;
    --app-zip=*) app_zip="${a#*=}" ;; --base=*) base="${a#*=}" ;;
    --artifact-ref=*) artifact_ref="${a#*=}" ;; --artifact-sha256=*) artifact_sha="${a#*=}" ;;
    --probe=*) probe="${a#*=}" ;; --state-probe=*) state_probe="${a#*=}" ;; --seed=*) seed="${a#*=}" ;;
    --expect-region=*) region="${a#*=}" ;; --expect-why=*) why="${a#*=}" ;;
    *) echo "try-pr-apply: unknown argument $a" >&2; exit 2 ;;
  esac
done
[[ "$experience" =~ ^(isolated|in-place|full-build)$ && "$pr" =~ ^[0-9]+$ ]] && [[ "$kind" == nightly || "$kind" == dev ]] \
  && [[ "$mode" == installed || "$mode" == lab ]] && [[ -n "$app_zip" && "$base" =~ ^[0-9a-f]{40}$ ]] \
  && [[ "$region" =~ ^[0-9]+,[0-9]+,[0-9]+,[0-9]+$ && -n "$why" ]] \
  || { echo "try-pr-apply: needs --experience=isolated|in-place|full-build --pr=N --kind=nightly|dev --mode=installed|lab --app-zip --base=SHA --expect-region=X,Y,W,H --expect-why=TEXT [--probe=CMD] [--state-probe=CMD] [--seed=CMD]" >&2; exit 2; }
root="$(cd "$(dirname "$0")/../.." && pwd)"
head="$(git -C "$root" rev-parse HEAD)"
real_home="$HOME"
out="$root/artifacts/try-pr-apply"; mkdir -p "$out"
work="$(mktemp -d "${TMPDIR:-/tmp}/try-pr-apply.XXXXXX")"; work="$(cd "$work" && pwd -P)"
# An instance's settings, tunables and overlay: its own (web-overlay.sh reads the same variables).
use_instance() { # NAME
  export CMUX_NEXT_CONFIG_FILE="$work/config-$1/cmux-next.json" CMUX_WEB_OVERLAY_DIR="$work/overlay-$1"
  export CMUX_NEXT_DEBUG_TUNABLES_FILE="$work/config-$1/debug-tunables.json"
  mkdir -p "$work/config-$1" "$CMUX_WEB_OVERLAY_DIR"
  printf '{"version": 1, "values": {"webDev.override": true}}\n' > "$CMUX_NEXT_DEBUG_TUNABLES_FILE"
}
pid="" sock="" socks=() mine=() survived="" coexisting=""
cleanup() { local p; for p in "${mine[@]}"; do kill "$p" 2>/dev/null || true; done; rm -f "${socks[@]}"; git -C "$root" worktree remove --force "$work/base-tree" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
t_json="$work/times.json"; echo '{}' > "$t_json"
mark() { python3 - "$t_json" "$1" "$(now)" <<'PY'
import json, sys
p, k, v = sys.argv[1:]; d = json.load(open(p)); d[k] = float(v); json.dump(d, open(p, "w"))
PY
}
info_json="$work/info.json"; echo '{}' > "$info_json"
note() { python3 - "$info_json" "$1" "$2" <<'PY'
import json, sys
p, k, v = sys.argv[1:]; d = json.load(open(p)); d[k] = v; json.dump(d, open(p, "w"))
PY
}
result() { # STATUS RUNTIME REASON
  mark end
  python3 - "$out/result.json" "$t_json" "$info_json" "$1" "$2" "$3" "$experience" "$kind" "$mode" "$base" "$head" "$pr" <<'PY'
import json, sys, time
out, tp, ip, status, runtime, reason, experience, kind, mode, base, head, pr = sys.argv[1:]
t, info = json.load(open(tp)), json.load(open(ip))
iso = lambda k: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t[k])) if k in t else None
identity = {"pr": int(pr), "head": head, "base": base, "merge_base": info.pop("merge_base", None),
            "artifact_build_sha": info.pop("app_commit", None), "artifact_commit_source": info.pop("commit_source", None),
            "artifact_version": info.pop("app_version", None), "artifact_build": info.pop("app_build", None),
            "exe_sha256": info.pop("exe_sha256", None), "zip_sha256": info.pop("zip_sha256", None),
            "patch_diff_sha256": info.pop("patch_diff_sha256", None), "overlay_sha256": info.pop("overlay_sha256", None),
            "script_blob": info.pop("script_blob", None), "host_class": info.pop("host_class", None),
            "wall_clock_start": iso("start"), "wall_clock_end": iso("end")}
probe = {"cmd": info.pop("probe_cmd", None), "base": info.pop("probe_base", None), "pr": info.pop("probe_pr", None),
         "full_build": info.pop("probe_full_build", None), "full_build_expected": info.pop("probe_full_build_expected", None)}
def span(a, b): return round(t[b] - t[a], 2) if a in t and b in t else None
setup = {"fetch": {"s": span("start", "fetched"), "amortized": True, "why": "an installed NIGHTLY or DEV is already on the Mac"},
         "prepare": {"s": span("fetched", "prepared"), "amortized": True, "why": "signature checks (installed) or the side copy (lab), once per app"}}
if experience == "in-place":
    setup["launch_and_base"] = {"s": span("prepared", "based"), "amortized": True, "why": "the app is already running before the PR is selected"}
controls = {"s": span("controls_start", "controls_end")}
counted = {"verdict": span("select", "verdicted"), "compile": span("verdicted", "compiled"),
           "apply": span("compiled", "applied"), "usable": span("applied", "usable")}
coexistence = str(info.pop("coexistence", None)); preexisting = info.pop("coexistence_preexisting", None)
path = info.pop("path", None) or (("apply-" + kind) if mode == "installed" else "lab-" + kind)
doc = {"experience": experience, "path": path, "mode": mode, "kind": kind, "identity": identity, "probe": probe,
       "isolation": info.pop("isolation", None), "coexistence": coexistence, "coexistence_preexisting": preexisting,
       "e1_claim": (("side instance beside a running instance of the same artifact" if status == "ok" and coexistence.startswith("pass")
                     else "not proven: no side instance ran beside a running one") if experience == "isolated" else None),
       "total_s": span("start", "end"), "status": status,
       "reason": reason or None, "setup": setup, "controls": controls, "counted": counted,
       "select_to_usable_s": span("select", "usable") if runtime == "pass" and experience != "full-build" else None,
       "launch_to_probe_s": span("compiled", "usable") if experience == "full-build" else None,
       "pr_fetch": "the step's checkout of the PR head, timed in the step's controller record",
       "compile_checked": "pass" if "compiled" in t else "not_run", "runtime": runtime,
       "deviations": ["runs from the step's temp folder, not quarantined (Gatekeeper first launch not exercised)",
                      "settings, debug tunables and web overlay passed as launch env (open --env), not set in Debug Settings"]
                     + (["Info.plist edited and re-signed ad hoc (lab)"] if mode == "lab" else []),
       **info}
json.dump(doc, open(out, "w"), indent=1, sort_keys=True)
print(json.dumps(doc, indent=1, sort_keys=True))
PY
}

mark start
if [[ "$app_zip" =~ ^https:// ]]; then curl -fsSL -o "$work/app.zip" "$app_zip"; else cp "$app_zip" "$work/app.zip"; fi
ditto -x -k "$work/app.zip" "$work/unzipped"
app="$(find "$work/unzipped" -maxdepth 2 -name '*.app' -type d | head -1)"
[[ -n "$app" ]] || { result fail not_run "no .app in the zip"; exit 1; }
mark fetched

plist="$app/Contents/Info.plist"; buddy="${TRY_PR_APPLY_PLISTBUDDY:-/usr/libexec/PlistBuddy}"  # the override is for its tests
zip_sha="$(shasum -a 256 "$work/app.zip" | cut -d' ' -f1)"; note zip_sha256 "$zip_sha"
note script_blob "$(git hash-object "$0")"
note host_class "step class ${CMUX_CI_STEP_CLASS:-none}; $(sysctl -n hw.model 2>/dev/null || uname -m); $(sw_vers -productVersion 2>/dev/null | sed 's/^/macOS /' || true)"
note app_version "$($buddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || echo none)"
note app_build "$($buddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || echo none)"
exe="$($buddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)"
if [[ -n "$exe" && -f "$app/Contents/MacOS/$exe" ]]; then note exe_sha256 "$(shasum -a 256 "$app/Contents/MacOS/$exe" | cut -d' ' -f1)"; else note exe_sha256 missing; fi
merge_base="$(git -C "$root" merge-base "$base" "$head" 2>/dev/null || echo none)"; note merge_base "$merge_base"
note patch_diff_sha256 "$(git -C "$root" diff --binary "$base" "$head" | shasum -a 256 | cut -d' ' -f1)"
note probe_cmd "${probe:-none}"
note artifact_ref "${artifact_ref:-none}"; note artifact_sha256 "${artifact_sha:-none}"
embedded="$($buddy -c 'Print :CMUXCommit' "$plist" 2>/dev/null || true)"; note embedded_commit "${embedded:-none}"
digest_ok=""; [[ -n "$artifact_sha" && "${artifact_sha#sha256:}" == "$zip_sha" ]] && digest_ok=1
app_commit="" provenance_bad=""
if [[ -n "$embedded" ]]; then
  app_commit="$embedded"; note commit_source info-plist
  [[ -n "$artifact_ref" && "$artifact_ref" != "$embedded" ]] && provenance_bad="CMUXCommit $embedded disagrees with the job's ref $artifact_ref"
elif [[ -n "$artifact_ref" && -n "$digest_ok" ]]; then
  app_commit="$artifact_ref"; note commit_source "fleet job ref, zip sha256 verified"
else
  note commit_source none
  provenance_bad="no CMUXCommit and no verified job provenance (--artifact-ref with a matching --artifact-sha256)"
fi
note app_commit "${app_commit:-unknown}"
bundle_id="$($buddy -c 'Print :CFBundleIdentifier' "$plist")"; note bundle_id "$bundle_id"
eligible_why=""
if [[ "$mode" == installed ]]; then
  if codesign --verify --deep --strict "$app" 2>"$work/codesign.err"; then note signature ok; else note signature "invalid: $(head -c 300 "$work/codesign.err")"; eligible_why="signature does not verify"; fi
  flags="$(codesign -dv "$app" 2>&1 | sed -n 's/^CodeDirectory.*flags=\([^ ]*\).*/\1/p')"; note signature_flags "$flags"
  note team_id "$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [[ "$flags" == *runtime* ]] || eligible_why="${eligible_why:-no hardened runtime flag}"
  if spctl --assess --type execute -vv "$app" >"$work/spctl.out" 2>&1; then note gatekeeper "accepted: $(tr '\n' ' ' <"$work/spctl.out" | head -c 300)"
  else note gatekeeper "rejected: $(tr '\n' ' ' <"$work/spctl.out" | head -c 300)"; eligible_why="${eligible_why:-Gatekeeper rejects it}"; fi
  shipped="com.cmuxterm.app.nightly"; [[ "$kind" == dev ]] && shipped="com.cmuxterm.app.debug.next"
  [[ "$bundle_id" == "$shipped" ]] || eligible_why="${eligible_why:-bundle id $bundle_id is not the shipped $shipped}"
else
  # lab: a side instance with its own id, re-signed ad hoc; evidence about this path only.
  note shipped_bundle_id "$bundle_id"; bundle_id="$bundle_id.side-try.t$$"; $buddy -c "Set :CFBundleIdentifier $bundle_id" "$plist"
  note bundle_id "$bundle_id"
  codesign --force --sign - --deep "$app" >/dev/null 2>&1
  note signature "ad hoc (lab)"
fi
mark prepared
if [[ -n "$eligible_why" ]]; then note path "not-eligible-$kind"; result fallback not_run "not production-equivalent: $eligible_why"; exit 0; fi
[[ -z "$provenance_bad" ]] || { result fallback not_run "base identity: $provenance_bad"; exit 0; }
[[ "$merge_base" == "$base" ]] || { result fallback not_run "base $base is not the merge base of base and head ($merge_base)"; exit 0; }
if [[ "$experience" == full-build ]]; then
  [[ "$app_commit" == "$head" || "$app_commit" == "$base" ]] || { result fallback not_run "full-build: app is $app_commit, neither head $head nor base $base"; exit 0; }
  [[ -n "$probe" ]] || { result fail not_run "full-build needs --probe"; exit 2; }
else
  [[ "$app_commit" == "$base" ]] || { result fallback not_run "base mismatch: app is $app_commit, manifest base is $base"; exit 0; }
fi
note expect_region "$region"; note expect_why "$why"

# The classification needs no app, so it runs now to decide; after "select" it runs again, timed.
verdict="$(python3 "$root/scripts/cmux-next/live_apply.py" --repo "$root" --json "$base" "$head" | python3 -c 'import json,sys; print(json.load(sys.stdin)["verdict"])')"
note verdict "$verdict"
[[ "$experience" == full-build ]] || case "$verdict" in
  web-live) ;;
  no-app|ios-only) note stratum no-app-effect; result n/a not_run "no app effect: N/A stratum"; exit 0 ;;
  daemon) note stratum daemon
     result n/a not_run "daemon: its own N/A stratum (no path ships a PR's daemon into an installed app); recorded, never counted as covered"; exit 0 ;;
  *) note fallback_time "a full build: the DEV build job's seconds plus a full-build run of this script"
     result fallback not_run "$verdict: neither experience exists for it in the app today (needs a new binary; the view shell prototype does not count)"; exit 0 ;;
esac
[[ -n "$probe" ]] || note proof "no --probe: runtime can be at most not_proven"

# From here the script launches a real app: only inside a fleet step of class exclusive, never on a
# person's Mac. It signals only the processes it launched.
[[ -n "${CMUX_CI_STEP_KEY:-}" && "${CMUX_CI_STEP_CLASS:-}" == exclusive ]] \
  || { result fail not_run "refused: launches an app only inside a fleet step of class exclusive"; exit 2; }
ours_running() { ps -axo pid=,comm= | while read -r p c; do [[ "$c" == "$app/Contents/MacOS/"* ]] && echo "$p"; done; }
# Other running apps with cmux in their path: "PID BUNDLE_ID" (unknown when the Info.plist is unreadable).
other_apps() { python3 - "$work" <<'PY'
import plistlib, subprocess, sys
ours = sys.argv[1]
for l in subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout.splitlines():
    pid, _, comm = l.strip().partition(" ")
    if "/Contents/MacOS/" not in comm or "cmux" not in comm.lower() or ours in comm: continue
    try: bid = plistlib.load(open(comm.split("/Contents/MacOS/")[0] + "/Contents/Info.plist", "rb")).get("CFBundleIdentifier", "unknown")
    except Exception: bid = "unknown"
    print(pid, bid)
PY
}

shot() { screencapture -x -D 1 "$out/$1.png" && sips -s format bmp "$out/$1.png" --out "$work/$1.bmp" >/dev/null; }
# Changed pixels of B against A inside the region, as "count x,y,w,h" (the box of the changes).
diff_in() { python3 - "$work/$1.bmp" "$work/$2.bmp" "$region" <<'PY'
import struct, sys
def load(p):
    b = open(p, "rb").read(); off, w, h, bpp = struct.unpack_from("<I", b, 10)[0], *struct.unpack_from("<iiH", b, 18)[:2], struct.unpack_from("<H", b, 28)[0]
    return b[off:], w, abs(h), bpp // 8, h > 0
a, w, h, n, flip = load(sys.argv[1]); b, w2, h2, n2, flip2 = load(sys.argv[2])
if (w, h, n, flip) != (w2, h2, n2, flip2): print(f"-1 format {w}x{h}x{n * 8} vs {w2}x{h2}x{n2 * 8}"); sys.exit()
x0, y0, rw, rh = map(int, sys.argv[3].split(",")); row = (w * n + 3) & ~3; hits = []
for y in range(max(0, y0), min(h, y0 + rh)):
    r = (h - 1 - y) if flip else y
    for x in range(max(0, x0), min(w, x0 + rw)):
        i = r * row + x * n
        if a[i:i + n] != b[i:i + n]: hits.append((x, y))
if not hits: print("0 -"); sys.exit()
xs, ys = [p[0] for p in hits], [p[1] for p in hits]
print(f"{len(hits)} {min(xs)},{min(ys)},{max(xs) - min(xs) + 1},{max(ys) - min(ys) + 1}")
PY
}
# Waits for the screen to settle: two shots in a row the same inside the region (60 s cap), kept as NAME.
settle() { shot "$1-prev"; for _ in $(seq 1 120); do sleep 0.5; shot "$1"; [[ "$(diff_in "$1-prev" "$1")" == "0 -" ]] && return 0; mv "$work/$1.bmp" "$work/$1-prev.bmp"; done; return 1; }
build_web() { rm -rf "$work/web"; "$1/scripts/cmux-next/build-web-bundles.sh" --force --out-root "$work/web" >/dev/null; }
# COMMIT: the exact commit the bundles in $work/web were built from, recorded in the overlay's
# manifest (web-overlay.sh install --commit; an older web-overlay.sh ignores it).
install_web() { "$root/scripts/cmux-next/web-overlay.sh" install "$work/web" --commit "$1" >/dev/null; }
launch() { # NAME: the instance's own HOME and control socket (in /tmp: a socket path has a 104-byte limit)
  local before; before=" $(ours_running | tr '\n' ' ') "
  local home="$work/home-$1"; mkdir -p "$home"; sock="/tmp/tpa-$$-$1.sock"; socks+=("$sock")
  open -n --env CMUX_NEXT_CONFIG_FILE="$CMUX_NEXT_CONFIG_FILE" --env CMUX_WEB_OVERLAY_DIR="$CMUX_WEB_OVERLAY_DIR" \
    --env CMUX_NEXT_DEBUG_TUNABLES_FILE="$CMUX_NEXT_DEBUG_TUNABLES_FILE" --env CMUX_NEXT_SOCKET_PATH="$sock" \
    --env HOME="$home" --env CFFIXED_USER_HOME="$home" "$app"
  pid=""; for _ in $(seq 1 300); do
    pid="$(ours_running | while read -r p; do [[ "$before" == *" $p "* ]] || echo "$p"; done | tail -1)"; [[ -n "$pid" ]] && break; sleep 0.1
  done
  [[ -n "$pid" ]] || { result fail not_run "the app did not start"; exit 1; }
  mine+=("$pid")
  for _ in $(seq 1 300); do [[ -S "$sock" ]] && break; sleep 0.1; done
  [[ -S "$sock" ]] || { result fail fail "the $1 instance did not create its own socket $sock"; exit 1; }
  note "home_$1" "$home"; note "socket_$1" "$sock"
}
# Other cmux processes (not this run's), and cmux sockets and state under the account's real home.
others() { python3 - "$real_home" "$work" <<'PY'
import os, subprocess, sys
home, ours = sys.argv[1:]  # ours: this run's folder (its app, its instances' homes and helpers)
for l in subprocess.run(["ps", "-axo", "pid=,lstart=,comm="], capture_output=True, text=True).stdout.splitlines():
    if "/Contents/MacOS/" in l and "cmux" in l.lower() and ours not in l: print("proc", " ".join(l.split()))
sup = os.path.join(home, "Library/Application Support")
roots = [os.path.join(home, ".cmux"), os.path.join(home, "Library/Preferences")]
roots += [os.path.join(sup, d) for d in (os.listdir(sup) if os.path.isdir(sup) else []) if "cmux" in d.lower()]
roots += ["/tmp/" + f for f in os.listdir("/tmp") if f.startswith("cmux")]
def line(p):
    try: st = os.lstat(p)
    except OSError: return
    print("file", p, st.st_ino, st.st_size, st.st_mtime_ns)
for r in sorted(roots):
    if not os.path.isdir(r) or os.path.islink(r): line(r); continue
    for d, dirs, files in os.walk(r):
        dirs[:] = [x for x in dirs if d.count(os.sep) - r.count(os.sep) < 3]
        for f in sorted(files):
            if r.endswith("Preferences") and "cmux" not in f.lower(): continue
            line(os.path.join(d, f))
PY
}
isolation_check() {
  local h; for h in "$work"/home-*; do [[ -d "$h" ]] && note "own_state_${h##*/home-}" "$(cd "$h" && find . -maxdepth 4 -type f | wc -l | tr -d ' ') files under its own HOME: $(cd "$h" && find . -maxdepth 3 -type d | LC_ALL=C sort | head -12 | tr '\n' ' ')"; done
  others >"$work/others-after.txt"
  local changed; changed="$(diff "$work/others-before.txt" "$work/others-after.txt" | sed -n 's/^[<>] //p' | head -20 | tr '\n' ';' || true)"
  note isolation "$(wc -l <"$work/others-before.txt" | tr -d ' ') other cmux processes and files before; ${changed:+changed: $changed}${changed:-unchanged after}"
  [[ -z "$changed" ]] || { result fail fail "isolation: another instance's process, socket or state changed"; exit 0; }
  if [[ -n "$coexisting" ]]; then note coexistence_preexisting "pass: ran alongside $coexisting, whose processes, sockets and state stayed unchanged"; fi
}
quit_app() { kill "$pid" 2>/dev/null || true; for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done; pid=""; }
started() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' '; }
probe_in() { # STATE: 0 the PR's behaviour is there, 1 it is not, other: the app is not ready
  CMUX_TRY_STATE="$1" CMUX_TRY_PID="$pid" CMUX_TRY_APP="$app" CMUX_TRY_SOCKET="$sock" bash -c "$probe" >"$out/probe-$1.log" 2>&1
}
probe_answer() { # STATE UNTIL: pass, fail or timeout; UNTIL=pass keeps asking through a 1 as well
  local rc
  for _ in $(seq 1 $(( usable_seconds * 4 ))); do
    rc=0; probe_in "$1" || rc=$?
    [[ "$rc" == 0 ]] && { echo pass; return; }
    [[ "$rc" == 1 && "$2" != pass ]] && { echo fail; return; }
    sleep 0.25
  done
  echo timeout
}
state_json() { [[ -n "$state_probe" ]] || { echo '{}'; return; }
  CMUX_TRY_PID="$pid" CMUX_TRY_APP="$app" CMUX_TRY_SOCKET="$sock" bash -c "$state_probe" 2>/dev/null || echo '{}'; }
# BEFORE AFTER (state_json output): "ok" or why the seeded state is not proven to survive.
state_verdict() { python3 - "$1" "$2" <<'PY'
import json, os, sys
try: a, b = (json.loads(x or "{}") for x in sys.argv[1:])
except ValueError: print("the state probe printed no JSON"); sys.exit()
keys = ["workspaces", "terminal_pid", "scrollback_sha256", "chat"]
missing = [k for k in keys if k not in a or k not in b]
if missing: print("not proven: the state probe gives no " + ", ".join(missing)); sys.exit()
if not isinstance(a["workspaces"], int) or a["workspaces"] < 2: print(f"not proven: {a['workspaces']} workspaces seeded, needs 2+"); sys.exit()
changed = [k for k in keys if a[k] != b[k]]
if changed: print("changed: " + ", ".join(f"{k} {a[k]} -> {b[k]}" for k in changed)); sys.exit()
try: os.kill(int(b["terminal_pid"]), 0)
except (OSError, ValueError): print(f"changed: terminal process {b['terminal_pid']} is gone"); sys.exit()
print("ok")
PY
}

others >"$work/others-before.txt"
coexisting="$(other_apps | tr '\n' ',' | sed 's/,$//; s/,/, /g')"; note other_instances "${coexisting:-none}"
if [[ "$mode" == installed && -n "$coexisting" ]] && other_apps | awk -v id="$bundle_id" '$2 == id || $2 == "unknown" {f=1} END {exit !f}'; then
  note coexistence_preexisting "unsupported: a running app has the shipped bundle id $bundle_id (or an unreadable one)"
  result fallback not_run "coexistence: a second instance under the shipped bundle id $bundle_id would share the running one's bundle-id state, so an installed side instance next to it is unsupported; the running app was left alone (--mode=lab runs a tagged copy)"
  exit 0
fi
[[ -n "$coexisting" ]] || note coexistence_preexisting "NOT PROVEN: no other cmux app was already running"
if [[ "$experience" == full-build ]]; then
  # The probe against a full build, no overlay: green on the head (parity), red on the base.
  want=fail; [[ "$app_commit" == "$head" ]] && want=pass; note probe_full_build_expected "$want"
  mark select; mark verdicted; mark compiled
  use_instance full; launch full; mark applied
  got="$(probe_answer full-build "$want")"
  mark usable; note probe_full_build "$got"; quit_app; isolation_check
  if [[ "$got" == "$want" ]]; then result ok pass ""; else result fail fail "full build of $app_commit: the probe gave $got, expected $want"; fi
  exit 0
fi
# Base state and controls: the base overlay in a running app, a repeat install, a base-only window.
git -C "$root" worktree add --detach -q "$work/base-tree" "$base"
use_instance base; build_web "$work/base-tree"; install_web "$base"
launch base; base_pid="$pid" base_sock="$sock"; note base_pid "$base_pid"
settle base || { result fail fail "the base app never settled"; exit 1; }
if [[ "$experience" == in-place && -n "$seed" ]]; then
  CMUX_TRY_PID="$pid" CMUX_TRY_APP="$app" CMUX_TRY_SOCKET="$sock" bash -c "$seed" >"$out/seed.log" 2>&1 \
    || { result fail fail "the --seed command failed (seed.log)"; exit 0; }
  settle seeded || { result fail fail "the seeded app never settled"; exit 1; }; mv "$work/seeded.bmp" "$work/base.bmp"
fi
mark based
mark controls_start
install_web "$base"; settle repeat || { result fail fail "the repeat install never settled"; exit 1; }
control="$(diff_in base repeat)"
for i in $(seq 1 "$control_seconds"); do
  [[ "$control" == "0 -" ]] || break
  sleep 1; shot control; control="$(diff_in base control)"; [[ "$control" == "0 -" ]] || control="$control (control shot $i)"
done
note pixel_control "$control"
probe_base=""; if [[ -n "$probe" ]]; then probe_base="$(probe_answer base answer)"; note probe_base "$probe_base"; fi
[[ "$probe_base" != pass ]] || { mark controls_end; result fail fail "the probe already passes on base: it does not test the PR's behaviour"; exit 0; }
[[ "$probe_base" != timeout ]] || { mark controls_end; result fail fail "the probe never answered on base within ${usable_seconds} s"; exit 0; }
state_before="$(state_json)"; start_before="$(started "$pid")"; base_inode="$(ls -i "$base_sock" | awk '{print $1}')"
mark controls_end

# Selected.
mark select
python3 "$root/scripts/cmux-next/live_apply.py" --repo "$root" --json "$base" "$head" >/dev/null
mark verdicted
build_web "$root"
mark compiled
note overlay_sha256 "$(cd "$work/web" && find . -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1)"
[[ "$experience" == isolated ]] && use_instance pr
install_web "$head"
if [[ "$experience" == isolated ]]; then
  launch pr; note pr_pid "$pid"
  [[ "$pid" != "$base_pid" ]] || { result fail fail "isolated: the PR instance is the base process"; exit 1; }
fi
mark applied
usable="" probe_pr=""
for _ in $(seq 1 $(( usable_seconds * 4 ))); do
  if [[ -n "$probe" ]]; then rc=0; probe_in pr || rc=$?; [[ "$rc" == 0 ]] && { usable=1; probe_pr=pass; break; }
  else shot pr; [[ "$(diff_in base pr)" =~ ^[1-9] ]] && { usable=1; break; }; fi
  sleep 0.25
done
mark usable
[[ -z "$probe" ]] || note probe_pr "${probe_pr:-fail (last exit $rc)}"
# Supporting pixels: the PR shot against base, and stable across a second.
shot pr; sleep 1; shot pr2
note pixel_change "$(diff_in base pr)"; note pixel_stable "$([[ "$(diff_in pr pr2)" == "0 -" ]] && echo yes || echo no)"
if [[ "$experience" == isolated ]]; then
  # The base instance ran beside the PR instance the whole time: same process, same socket, and
  # still without the PR's behaviour.
  base_same="no"; kill -0 "$base_pid" 2>/dev/null && [[ "$(started "$base_pid")" == "$start_before" && -S "$base_sock" \
    && "$(ls -i "$base_sock" | awk '{print $1}')" == "$base_inode" ]] && base_same=yes
  base_after=""; if [[ -n "$probe" ]]; then pr_pid="$pid" pr_sock="$sock"; pid="$base_pid" sock="$base_sock"
    base_after="$(probe_answer base answer)"; pid="$pr_pid" sock="$pr_sock"; note probe_base_after "$base_after"; fi
  note integrity "PR instance $pid started beside base instance $base_pid; base same process and socket: $base_same; base probe after: ${base_after:-not run}"
  [[ "$base_same" == yes ]] || { result fail fail "isolated: the base instance exited, restarted or lost its socket while the PR instance ran"; exit 0; }
  [[ "$base_after" != pass ]] || { result fail fail "isolated: the base instance took the PR's behaviour (no isolation)"; exit 0; }
  [[ -z "$probe" ]] || note coexistence "pass: base instance $base_pid (same artifact, own HOME, socket and overlay) kept running unchanged beside the PR instance"
fi
if [[ "$experience" == in-place ]]; then
  same_pid="no"; kill -0 "$base_pid" 2>/dev/null && [[ "$pid" == "$base_pid" && "$(started "$pid")" == "$start_before" ]] && same_pid=yes
  state_after="$(state_json)"; survived="$(state_verdict "$state_before" "$state_after")"
  # Both are needed: a state probe without a seed could report state nobody made.
  [[ -n "$seed" || "$survived" == changed* ]] || survived="not proven: no --seed, so the state was never seeded"
  note state_before "$state_before"; note state_after "$state_after"
  note integrity "same process: $same_pid; seeded state: $survived"
  [[ "$same_pid" == yes ]] || { result fail fail "in-place: the app relaunched or exited"; exit 0; }
  [[ "$survived" != changed* ]] || { result fail fail "in-place: $survived"; exit 0; }
fi
isolation_check
if [[ -z "$probe" ]]; then
  result not_proven not_proven "no PR-specific probe: pixels alone do not prove the behaviour"
elif [[ -n "$usable" && "$experience" == in-place && "$survived" != ok ]]; then
  result not_proven not_proven "the probe passed, but state survival is $survived"
elif [[ -n "$usable" ]]; then
  result ok pass ""
else
  result fail fail "the probe did not pass within ${usable_seconds} s of the apply"
fi
