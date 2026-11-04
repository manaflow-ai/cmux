#!/usr/bin/env bash
# Measurement only (cmuxterm-hq#7111 track 4); not landed. A fleet ci-step runs a script only when
# its bytes equal feat-cmux-next's or main's (the worker's reviewed-bytes check), so this file runs on
# the fleet only after it lands there, at that commit; running it at a PR head would also take a
# controller measurement-list entry. Until then every row it would write stays CLASSIFIER-ONLY.
#
# Times, in a real cmux app on a fleet display Mac, the seconds from selecting a pull request to the
# PR's behaviour working, for the two experiences, without waiting for a new DEV build:
#   isolated  (E1) a fresh, separate real app instance that starts with the PR's change
#   in-place  (E2) the PR's change hot-swapped into a real app that is already running, same process
# A browser page, a screenshot change or the view shell prototype is not either experience: the proof is
# a PR-specific functional probe run against the real app (below); pixels only support it.
# The step's checkout is the PR head. The script refuses to launch anything outside a fleet step.
#
#   cmux-ci run --class exclusive --display --script scripts/measure/try-pr-apply.sh --ref HEAD \
#     --arg=--experience=isolated|in-place --arg=--kind=nightly|dev --arg=--mode=installed|lab \
#     --arg=--app-zip=URL_OR_PATH --arg=--base=SHA [--arg=--artifact-ref=SHA --arg=--artifact-sha256=HEX] \
#     --arg=--probe=CMD [--arg=--state-probe=CMD] --arg=--expect-region=X,Y,W,H --arg=--expect-why=TEXT \
#     --artifact artifacts/try-pr-apply/result.json
#
# Identity, recorded in every result: base (the manifest's exact base), head (this checkout), the app
# zip's sha256, the app's commit and where it came from (below), its bundle id and signature.
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
#              CMUX_WEB_OVERLAY_DIR); a person turns the overlay on in Debug Settings instead.
#   lab        a side instance (#35544's mechanics): Info.plist edited (bundle id) and re-signed ad
#              hoc. Evidence about the lab path only (`lab-<kind>`), never about an installed app. A lab
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
#                accessibility tree or its page DOM through the app), exit 0 when the PR's behaviour is
#                there. It runs with CMUX_TRY_STATE=base|pr, CMUX_TRY_PID, CMUX_TRY_APP,
#                CMUX_NEXT_CONFIG_FILE and CMUX_WEB_OVERLAY_DIR. It must fail on base and pass on the PR.
#                Without it the run is `not_proven`, whatever the pixels show.
#   integrity    in-place: the same process before and after (pid and start time), no relaunch, and,
#                with --state-probe=CMD (a digest of state the PR does not change: windows,
#                workspaces, tabs), the same digest before and after. isolated: a new process, its own
#                settings and overlay folders, no other instance of the bundle running at launch, and
#                the base instance quit before the PR instance starts.
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
# step's checkout, timed in the step's controller record, not here.
# Swift, daemon and rebuild verdicts: neither experience exists for them in the app today; a fallback
# row says so (the view shell prototype does not count).
set -euo pipefail
experience="" kind="" mode="" app_zip="" base="" artifact_ref="" artifact_sha="" region="" why="" probe="" state_probe=""
control_seconds="${CONTROL_SECONDS:-30}" usable_seconds="${USABLE_SECONDS:-60}"
for a in "$@"; do
  case "$a" in
    --experience=*) experience="${a#*=}" ;; --kind=*) kind="${a#*=}" ;; --mode=*) mode="${a#*=}" ;;
    --app-zip=*) app_zip="${a#*=}" ;; --base=*) base="${a#*=}" ;;
    --artifact-ref=*) artifact_ref="${a#*=}" ;; --artifact-sha256=*) artifact_sha="${a#*=}" ;;
    --probe=*) probe="${a#*=}" ;; --state-probe=*) state_probe="${a#*=}" ;;
    --expect-region=*) region="${a#*=}" ;; --expect-why=*) why="${a#*=}" ;;
    *) echo "try-pr-apply: unknown argument $a" >&2; exit 2 ;;
  esac
done
[[ "$experience" == isolated || "$experience" == in-place ]] && [[ "$kind" == nightly || "$kind" == dev ]] \
  && [[ "$mode" == installed || "$mode" == lab ]] && [[ -n "$app_zip" && "$base" =~ ^[0-9a-f]{40}$ ]] \
  && [[ "$region" =~ ^[0-9]+,[0-9]+,[0-9]+,[0-9]+$ && -n "$why" ]] \
  || { echo "try-pr-apply: needs --experience=isolated|in-place --kind=nightly|dev --mode=installed|lab --app-zip --base=SHA --expect-region=X,Y,W,H --expect-why=TEXT [--probe=CMD]" >&2; exit 2; }
root="$(cd "$(dirname "$0")/../.." && pwd)"
head="$(git -C "$root" rev-parse HEAD)"
out="$root/artifacts/try-pr-apply"; mkdir -p "$out"
work="$(mktemp -d "${TMPDIR:-/tmp}/try-pr-apply.XXXXXX")"; work="$(cd "$work" && pwd -P)"
# The app's settings, tunables and overlay: this run's own (web-overlay.sh reads the same variables).
export CMUX_NEXT_CONFIG_FILE="$work/config/cmux-next.json" CMUX_WEB_OVERLAY_DIR="$work/web-overlay"
export CMUX_NEXT_DEBUG_TUNABLES_FILE="$work/config/debug-tunables.json"
mkdir -p "$work/config" "$CMUX_WEB_OVERLAY_DIR"
printf '{"version": 1, "values": {"webDev.override": true}}\n' > "$CMUX_NEXT_DEBUG_TUNABLES_FILE"
pid=""
cleanup() { [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true; git -C "$root" worktree remove --force "$work/base-tree" 2>/dev/null || true; rm -rf "$work"; }
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
  python3 - "$out/result.json" "$t_json" "$info_json" "$1" "$2" "$3" "$experience" "$kind" "$mode" "$base" "$head" <<'PY'
import json, sys
out, tp, ip, status, runtime, reason, experience, kind, mode, base, head = sys.argv[1:]
t, info = json.load(open(tp)), json.load(open(ip))
def span(a, b): return round(t[b] - t[a], 2) if a in t and b in t else None
setup = {"fetch": {"s": span("start", "fetched"), "amortized": True, "why": "an installed NIGHTLY or DEV is already on the Mac"},
         "prepare": {"s": span("fetched", "prepared"), "amortized": True, "why": "signature checks (installed) or the side copy (lab), once per app"}}
if experience == "in-place":
    setup["launch_and_base"] = {"s": span("prepared", "based"), "amortized": True, "why": "the app is already running before the PR is selected"}
controls = {"s": span("controls_start", "controls_end")}
counted = {"verdict": span("select", "verdicted"), "compile": span("verdicted", "compiled"),
           "apply": span("compiled", "applied"), "usable": span("applied", "usable")}
path = info.pop("path", None) or (("apply-" + kind) if mode == "installed" else "lab-" + kind)
doc = {"experience": experience, "path": path, "mode": mode, "kind": kind, "base": base, "head": head,
       "status": status, "reason": reason or None, "setup": setup, "controls": controls, "counted": counted,
       "select_to_usable_s": span("select", "usable") if runtime == "pass" else None,
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
  bundle_id="$bundle_id.side-try"; $buddy -c "Set :CFBundleIdentifier $bundle_id" "$plist"
  codesign --force --sign - --deep "$app" >/dev/null 2>&1
  note signature "ad hoc (lab)"
fi
mark prepared
if [[ -n "$eligible_why" ]]; then note path "not-eligible-$kind"; result fallback not_run "not production-equivalent: $eligible_why"; exit 0; fi
[[ -z "$provenance_bad" ]] || { result fallback not_run "base identity: $provenance_bad"; exit 0; }
[[ "$app_commit" == "$base" ]] || { result fallback not_run "base mismatch: app is $app_commit, manifest base is $base"; exit 0; }
note expect_region "$region"; note expect_why "$why"

# The classification needs no app, so it runs now to decide; after "select" it runs again, timed.
verdict="$(python3 "$root/scripts/cmux-next/live_apply.py" --repo "$root" --json "$base" "$head" | python3 -c 'import json,sys; print(json.load(sys.stdin)["verdict"])')"
note verdict "$verdict"
case "$verdict" in
  web-live) ;;
  no-app|ios-only) result n/a not_run "no app effect: N/A stratum"; exit 0 ;;
  *) result fallback not_run "$verdict: neither experience exists for it in the app today (needs a new binary; the view shell prototype does not count)"; exit 0 ;;
esac
[[ -n "$probe" ]] || note proof "no --probe: runtime can be at most not_proven"

# From here the script launches a real app: only inside a fleet step of class exclusive, never on a
# person's Mac, and never next to another running instance of the same bundle.
[[ -n "${CMUX_CI_STEP_KEY:-}" && "${CMUX_CI_STEP_CLASS:-}" == exclusive ]] \
  || { result fail not_run "refused: launches an app only inside a fleet step of class exclusive"; exit 2; }
running_of_bundle() { pgrep -f "/Contents/MacOS/" | while read -r p; do
  [[ "$(ps -o comm= -p "$p" 2>/dev/null)" == *"/$(basename "$app")/Contents/MacOS/"* ]] && echo "$p"; done; }

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
install_web() { "$root/scripts/cmux-next/web-overlay.sh" install "$work/web" >/dev/null; }
launch() {
  [[ -z "$(running_of_bundle)" ]] || { result fail not_run "another instance of $(basename "$app") already runs: no isolation"; exit 1; }
  open -n --env CMUX_NEXT_CONFIG_FILE="$CMUX_NEXT_CONFIG_FILE" --env CMUX_WEB_OVERLAY_DIR="$CMUX_WEB_OVERLAY_DIR" \
    --env CMUX_NEXT_DEBUG_TUNABLES_FILE="$CMUX_NEXT_DEBUG_TUNABLES_FILE" "$app"
  pid=""; for _ in $(seq 1 300); do pid="$(running_of_bundle | tail -1)"; [[ -n "$pid" ]] && break; sleep 0.1; done
  [[ -n "$pid" ]] || { result fail not_run "the app did not start"; exit 1; }
}
quit_app() { kill "$pid" 2>/dev/null || true; for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done; pid=""; }
started() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' '; }
probe_in() { # STATE: 0 when the PR's behaviour is there
  [[ -n "$probe" ]] || return 2
  CMUX_TRY_STATE="$1" CMUX_TRY_PID="$pid" CMUX_TRY_APP="$app" bash -c "$probe" >"$out/probe-$1.log" 2>&1
}
state_digest() { [[ -n "$state_probe" ]] || { echo none; return; }
  CMUX_TRY_PID="$pid" CMUX_TRY_APP="$app" bash -c "$state_probe" 2>/dev/null | shasum -a 256 | cut -d' ' -f1; }

# Base state and controls: the base overlay in a running app, a repeat install, a base-only window.
git -C "$root" worktree add --detach -q "$work/base-tree" "$base"
build_web "$work/base-tree"; install_web
launch; base_pid="$pid"; note base_pid "$base_pid"
settle base || { result fail fail "the base app never settled"; exit 1; }
mark based
mark controls_start
install_web; settle repeat || { result fail fail "the repeat install never settled"; exit 1; }
control="$(diff_in base repeat)"
for i in $(seq 1 "$control_seconds"); do
  [[ "$control" == "0 -" ]] || break
  sleep 1; shot control; control="$(diff_in base control)"; [[ "$control" == "0 -" ]] || control="$control (control shot $i)"
done
note pixel_control "$control"
probe_base=""; if [[ -n "$probe" ]]; then probe_in base && probe_base=pass || probe_base=fail; note probe_base "$probe_base"; fi
[[ "$probe_base" != pass ]] || { mark controls_end; result fail fail "the probe already passes on base: it does not test the PR's behaviour"; exit 0; }
state_before="$(state_digest)"; start_before="$(started "$pid")"
if [[ "$experience" == isolated ]]; then quit_app; fi
mark controls_end

# Selected.
mark select
python3 "$root/scripts/cmux-next/live_apply.py" --repo "$root" --json "$base" "$head" >/dev/null
mark verdicted
build_web "$root"
mark compiled
install_web
if [[ "$experience" == isolated ]]; then
  launch; note pr_pid "$pid"
  [[ "$pid" != "$base_pid" ]] || { result fail fail "isolated: the PR instance is the base process"; exit 1; }
  note integrity "new process $pid (base was $base_pid, quit first), own settings and overlay folders"
fi
mark applied
usable="" probe_pr=""
for _ in $(seq 1 $(( usable_seconds * 4 ))); do
  if [[ -n "$probe" ]]; then probe_in pr && { usable=1; probe_pr=pass; break; }
  else shot pr; [[ "$(diff_in base pr)" =~ ^[1-9] ]] && { usable=1; break; }; fi
  sleep 0.25
done
mark usable
[[ -z "$probe" ]] || note probe_pr "${probe_pr:-fail}"
# Supporting pixels: the PR shot against base, and stable across a second.
shot pr; sleep 1; shot pr2
note pixel_change "$(diff_in base pr)"; note pixel_stable "$([[ "$(diff_in pr pr2)" == "0 -" ]] && echo yes || echo no)"
if [[ "$experience" == in-place ]]; then
  same_pid="no"; kill -0 "$base_pid" 2>/dev/null && [[ "$pid" == "$base_pid" && "$(started "$pid")" == "$start_before" ]] && same_pid=yes
  state_after="$(state_digest)"
  note integrity "same process: $same_pid; state digest before $state_before, after $state_after"
  [[ "$same_pid" == yes ]] || { result fail fail "in-place: the app relaunched or exited"; exit 0; }
  [[ "$state_before" == "$state_after" ]] || { result fail fail "in-place: state changed across the swap"; exit 0; }
fi
if [[ -z "$probe" ]]; then
  result not_proven not_proven "no PR-specific probe: pixels alone do not prove the behaviour"
elif [[ -n "$usable" ]]; then
  result ok pass ""
else
  result fail fail "the probe did not pass within ${usable_seconds} s of the apply"
fi
