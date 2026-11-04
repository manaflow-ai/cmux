#!/usr/bin/env bash
# Measurement only (cmuxterm-hq#7111 track 4); not landed. A fleet ci-step runs it only from the
# controller's reviewed list (measureScripts), so until then apply-nightly / apply-dev rows are
# CLASSIFIER-ONLY.
#
# Times, on a fleet display Mac, "select a PR" to "the PR's change visible" when the change is
# applied into an already-built NIGHTLY or DEV instead of waiting for a new DEV build. The step's
# checkout is the PR head.
#
#   cmux-ci run --class exclusive --display --script scripts/measure/try-pr-apply.sh --ref HEAD \
#     --arg=--kind=nightly|dev --arg=--mode=installed|lab --arg=--app-zip=URL_OR_PATH \
#     --arg=--base=SHA [--arg=--artifact-ref=SHA --arg=--artifact-sha256=HEX] \
#     --arg=--expect-region=X,Y,W,H --arg=--expect-why=TEXT [--arg=--probe=CMD] \
#     --artifact artifacts/try-pr-apply/result.json
#
# Modes, reported as different paths and never pooled:
#   installed  the app exactly as shipped: no Info.plist edit, no re-sign, launched with `open`.
#              It stands for (a) NIGHTLY or (b) DEV only when all of these hold, each recorded:
#              the shipped bundle id (com.cmuxterm.app.nightly, or the daily DEV's exact
#              com.cmuxterm.app.debug.next), codesign --verify --deep --strict, the hardened runtime
#              flag, and Gatekeeper's assessment (spctl --assess --type execute) accepting it.
#              Anything else is `not-eligible-<kind>`, a fallback row, never (a) or (b).
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
# this zip to that job. Both are recorded. The commit must equal --base, the manifest's exact base; a
# mismatch, a CMUXCommit that disagrees with --artifact-ref, an unverified digest or no commit at all
# is a fallback, never a success.
#
# Proof of change, with controls, so dynamic UI is never counted as the PR's change. Pixels are
# compared after a lossless decode (sips to BMP), never by PNG bytes, inside --expect-region: the area
# the PR's diff changes, chosen by the submitter, whose reason (--expect-why) is recorded.
#   controls  the base overlay, then the base overlay installed again (repeat), then base-only shots
#             once a second for as long as the PR is given to show (CONTROL_SECONDS, default 30).
#             Every control must equal the first base shot inside the region; any diff (a clock, a
#             spinner, an animation, a reload) makes the run inconclusive (runtime=fail).
#   PR        the PR's overlay; its shot must differ from base inside the region and stay the same
#             across two shots a second apart (a stable change, not motion).
#   probe     --probe=CMD (optional, PR-specific behaviour: a DOM, AX or socket read) runs in both
#             states with CMUX_TRY_STATE=base|pr; it must fail on base and pass on the PR.
# runtime=pass needs the controls clean and either the probe passing as described, or the stable
# pixel change (evidence_kind says which; a probe that is given and fails is a fail). A pixel-only pass
# shows that the region changed, not which behaviour did: the region and its reason are the claim.
#
# Not yet run anywhere: syntax-checked only. Unproven before its first fleet run: that `open --env`
# reaches the app on the worker's macOS, that build-web-bundles.sh finds its bun and node in the base
# worktree, and that the menu bar clock stays out of --expect-region.
#
# Phases (result.json "phases", seconds): fetch, prepare (side copy in lab mode; signature check in
# installed mode), verdict, launch, control (base and repeat builds and shots; reported, not counted
# in select_to_change), compile (the PR's web bundles: claim 2, never zero_compile), apply, change.
# select_to_change = fetch + prepare + verdict + launch + compile + apply + change.
# Not web-live (swift-live, daemon, rebuild): a fallback row (no Swift or daemon apply into the app).
set -euo pipefail
kind="" mode="" app_zip="" base="" artifact_ref="" artifact_sha="" region="" why="" probe=""
control_seconds="${CONTROL_SECONDS:-30}"
for a in "$@"; do
  case "$a" in
    --kind=*) kind="${a#*=}" ;; --mode=*) mode="${a#*=}" ;; --app-zip=*) app_zip="${a#*=}" ;;
    --base=*) base="${a#*=}" ;; --artifact-ref=*) artifact_ref="${a#*=}" ;; --artifact-sha256=*) artifact_sha="${a#*=}" ;;
    --expect-region=*) region="${a#*=}" ;; --expect-why=*) why="${a#*=}" ;; --probe=*) probe="${a#*=}" ;;
    *) echo "try-pr-apply: unknown argument $a" >&2; exit 2 ;;
  esac
done
[[ "$kind" == nightly || "$kind" == dev ]] && [[ "$mode" == installed || "$mode" == lab ]] \
  && [[ -n "$app_zip" && "$base" =~ ^[0-9a-f]{40}$ && "$region" =~ ^[0-9]+,[0-9]+,[0-9]+,[0-9]+$ && -n "$why" ]] \
  || { echo "try-pr-apply: needs --kind=nightly|dev --mode=installed|lab --app-zip --base=SHA --expect-region=X,Y,W,H --expect-why=TEXT" >&2; exit 2; }
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
  python3 - "$out/result.json" "$t_json" "$info_json" "$1" "$2" "$3" "$kind" "$mode" "$base" "$head" <<'PY'
import json, sys
out, tp, ip, status, runtime, reason, kind, mode, base, head = sys.argv[1:]
t, info = json.load(open(tp)), json.load(open(ip))
spans = [("fetch", "select", "fetched"), ("prepare", "fetched", "prepared"), ("verdict", "prepared", "verdicted"),
         ("launch", "verdicted", "launched"), ("control", "launched", "controlled"),
         ("compile", "controlled", "compiled"), ("apply", "compiled", "applied"), ("change", "applied", "changed")]
phases = {n: round(t[b] - t[a], 2) for n, a, b in spans if a in t and b in t}
counted = ["fetch", "prepare", "verdict", "launch", "compile", "apply", "change"]
path = info.pop("path", None) or (("apply-" + kind) if mode == "installed" else "lab-" + kind)
doc = {"path": path, "mode": mode, "kind": kind, "base": base, "head": head, "status": status,
       "reason": reason or None, "phases": phases,
       "select_to_change_s": round(sum(phases[n] for n in counted), 2) if runtime == "pass" else None,
       "compile_checked": "pass" if "compiled" in t else "not_run", "runtime": runtime,
       "deviations": ["runs from the step's temp folder, not quarantined (Gatekeeper first launch not exercised)",
                      "settings, debug tunables and web overlay passed as launch env (open --env), not set in Debug Settings"]
                     + (["Info.plist edited and re-signed ad hoc (lab)"] if mode == "lab" else []),
       **info}
json.dump(doc, open(out, "w"), indent=1, sort_keys=True)
print(json.dumps(doc, indent=1, sort_keys=True))
PY
}

mark select
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
  $buddy -c "Set :CFBundleIdentifier $($buddy -c 'Print :CFBundleIdentifier' "$plist").side-try" "$plist"
  codesign --force --sign - --deep "$app" >/dev/null 2>&1
  note signature "ad hoc (lab)"
fi
mark prepared
if [[ -n "$eligible_why" ]]; then note path "not-eligible-$kind"; result fallback not_run "not production-equivalent: $eligible_why"; exit 0; fi
[[ -z "$provenance_bad" ]] || { result fallback not_run "base identity: $provenance_bad"; exit 0; }
[[ "$app_commit" == "$base" ]] || { result fallback not_run "base mismatch: app is $app_commit, manifest base is $base"; exit 0; }
note expect_region "$region"; note expect_why "$why"

verdict="$(python3 "$root/scripts/cmux-next/live_apply.py" --repo "$root" --json "$base" "$head" | python3 -c 'import json,sys; print(json.load(sys.stdin)["verdict"])')"
note verdict "$verdict"
mark verdicted
case "$verdict" in
  web-live) ;;
  no-app|ios-only) result n/a not_run "no app effect: N/A stratum"; exit 0 ;;
  *) result fallback not_run "$verdict needs a new binary (no Swift or daemon apply into the app)"; exit 0 ;;
esac

open -n --env CMUX_NEXT_CONFIG_FILE="$CMUX_NEXT_CONFIG_FILE" --env CMUX_WEB_OVERLAY_DIR="$CMUX_WEB_OVERLAY_DIR" \
  --env CMUX_NEXT_DEBUG_TUNABLES_FILE="$CMUX_NEXT_DEBUG_TUNABLES_FILE" "$app"
for _ in $(seq 1 300); do pid="$(pgrep -nf "$app/Contents/MacOS/" || true)"; [[ -n "$pid" ]] && break; sleep 0.1; done
[[ -n "$pid" ]] || { result fail not_run "the app did not start"; exit 1; }
# A shot of the main display, decoded losslessly so equal pixels compare equal.
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
# Builds the web bundles of TREE, installs them as a new overlay generation and waits for the app to
# draw it: shots until two in a row agree after the install (60 s cap), the last one kept as NAME.
overlay_from() { # TREE NAME
  rm -rf "$work/web"; "$1/scripts/cmux-next/build-web-bundles.sh" --force --out-root "$work/web" >/dev/null
  "$root/scripts/cmux-next/web-overlay.sh" install "$work/web" >/dev/null
  shot "$2-prev"; for _ in $(seq 1 120); do sleep 0.5; shot "$2"; [[ "$(diff_in "$2-prev" "$2")" == "0 -" ]] && return 0; mv "$work/$2.bmp" "$work/$2-prev.bmp"; done
  return 1
}
mark launched

# PR-specific behaviour, when given: exit 0 means the PR's behaviour is there.
probe_in() { [[ -z "$probe" ]] && return 2; CMUX_TRY_STATE="$1" bash -c "$probe" >"$out/probe-$1.log" 2>&1; }
git -C "$root" worktree add --detach -q "$work/base-tree" "$base"
overlay_from "$work/base-tree" base || { result fail fail "base overlay never settled"; exit 1; }
overlay_from "$work/base-tree" repeat || { result fail fail "repeat overlay never settled"; exit 1; }
control="$(diff_in base repeat)"
# The dynamic-UI window: base-only shots for as long as the PR gets to show.
for i in $(seq 1 "$control_seconds"); do
  [[ "$control" == "0 -" ]] || break
  sleep 1; shot "control"; control="$(diff_in base control)"; [[ "$control" == "0 -" ]] || control="$control (control shot $i)"
done
note control_diff "$control"; note control_seconds "$control_seconds"
probe_base=""; if [[ -n "$probe" ]]; then probe_in base && probe_base=pass || probe_base=fail; note probe_base "$probe_base"; fi
mark controlled
[[ "$control" == "0 -" ]] || { result fail fail "a base-only control differs inside the region ($control): dynamic UI there, inconclusive"; exit 0; }
[[ "$probe_base" != pass ]] || { result fail fail "the probe already passes on base: it does not test the PR's behaviour"; exit 0; }

mark compiled_start
rm -rf "$work/web"; "$root/scripts/cmux-next/build-web-bundles.sh" --force --out-root "$work/web" >/dev/null
mark compiled
"$root/scripts/cmux-next/web-overlay.sh" install "$work/web" >/dev/null
mark applied
change="-1" stable=""
for _ in $(seq 1 "$control_seconds"); do
  shot pr; change="$(diff_in base pr)"
  if [[ "${change%% *}" -gt 0 ]]; then
    sleep 1; shot pr2; [[ "$(diff_in pr pr2)" == "0 -" ]] && { stable=1; break; }
  else sleep 1; fi
done
note change_diff "$change"; note change_stable "${stable:+yes}"
probe_pr=""; if [[ -n "$probe" ]]; then probe_in pr && probe_pr=pass || probe_pr=fail; note probe_pr "$probe_pr"; fi
mark changed
if [[ -n "$probe" ]]; then
  note evidence_kind probe
  if [[ "$probe_pr" == pass ]]; then result ok pass ""; else result fail fail "the probe fails on the PR"; fi
elif [[ -n "$stable" ]]; then
  note evidence_kind "pixels with controls"; result ok pass ""
else
  note evidence_kind "pixels with controls"; result fail fail "no stable change inside the region after the PR overlay ($change)"
fi
