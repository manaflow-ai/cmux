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
#     --arg=--base=SHA [--arg=--artifact-ref=SHA] --arg=--expect-region=X,Y,W,H \
#     --artifact artifacts/try-pr-apply/result.json
#
# Modes, reported as different paths and never pooled:
#   installed  the app exactly as shipped: no Info.plist edit, no re-sign, launched with `open`.
#              Its signature is checked (codesign --verify --strict) and recorded with its flags; a
#              failed check is a fallback. Only this mode can stand for (a) NIGHTLY or (b) DEV. Its
#              settings file, debug tunables and web overlay are this run's own, passed at launch
#              (`open -n --env`: CMUX_NEXT_CONFIG_FILE, CMUX_NEXT_DEBUG_TUNABLES_FILE,
#              CMUX_WEB_OVERLAY_DIR), the variables the app reads, so the bundle stays as signed.
#   lab        a side instance (#35544's mechanics): Info.plist edited (bundle id, LSEnvironment) and
#              re-signed ad hoc. Evidence about the lab path only, never about an installed app.
#
# Base identity: the app's CMUXCommit (Info.plist), else --artifact-ref (the fleet job's ref, which
# the submitter read from `cmux-ci status`; DEV builds carry no CMUXCommit). It must equal --base, the
# manifest's exact base; a mismatch or an unknown commit is a fallback, never a success.
#
# Proof of change, with controls. The overlay is built three times and each shot is taken after the
# overlay generation lands: base, base again (repeat), then the PR head. Pixels are compared after a
# lossless decode (sips to BMP), not by PNG bytes. runtime=pass only when base vs repeat shows no
# changed pixel inside --expect-region, and base vs PR shows a change inside it. Any control diff
# makes the run inconclusive (runtime=fail, reason recorded).
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
kind="" mode="" app_zip="" base="" artifact_ref="" region=""
for a in "$@"; do
  case "$a" in
    --kind=*) kind="${a#*=}" ;; --mode=*) mode="${a#*=}" ;; --app-zip=*) app_zip="${a#*=}" ;;
    --base=*) base="${a#*=}" ;; --artifact-ref=*) artifact_ref="${a#*=}" ;; --expect-region=*) region="${a#*=}" ;;
    *) echo "try-pr-apply: unknown argument $a" >&2; exit 2 ;;
  esac
done
[[ "$kind" == nightly || "$kind" == dev ]] && [[ "$mode" == installed || "$mode" == lab ]] \
  && [[ -n "$app_zip" && "$base" =~ ^[0-9a-f]{40}$ && "$region" =~ ^[0-9]+,[0-9]+,[0-9]+,[0-9]+$ ]] \
  || { echo "try-pr-apply: needs --kind=nightly|dev --mode=installed|lab --app-zip --base=SHA --expect-region=X,Y,W,H" >&2; exit 2; }
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
path = ("apply-" + kind) if mode == "installed" else "lab-" + kind
doc = {"path": path, "mode": mode, "kind": kind, "base": base, "head": head, "status": status,
       "reason": reason or None, "phases": phases,
       "select_to_change_s": round(sum(phases[n] for n in counted), 2) if runtime == "pass" else None,
       "compile_checked": "pass" if "compiled" in t else "not_run", "runtime": runtime, **info}
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

plist="$app/Contents/Info.plist"; buddy=/usr/libexec/PlistBuddy
app_commit="$($buddy -c 'Print :CMUXCommit' "$plist" 2>/dev/null || true)"
if [[ -n "$app_commit" ]]; then note commit_source info-plist; else app_commit="$artifact_ref"; note commit_source "${artifact_ref:+artifact-ref}"; fi
note app_commit "${app_commit:-unknown}"
note bundle_id "$($buddy -c 'Print :CFBundleIdentifier' "$plist")"
if [[ "$mode" == installed ]]; then
  if codesign --verify --deep --strict "$app" 2>"$work/codesign.err"; then note signature ok; else note signature "invalid: $(head -c 300 "$work/codesign.err")"; fi
  note signature_flags "$(codesign -dv "$app" 2>&1 | sed -n 's/^CodeDirectory.*flags=\([^ ]*\).*/\1/p')"
  note team_id "$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
else
  # lab: a side instance with its own id, re-signed ad hoc; evidence about this path only.
  $buddy -c "Set :CFBundleIdentifier $($buddy -c 'Print :CFBundleIdentifier' "$plist").side-try" "$plist"
  codesign --force --sign - --deep "$app" >/dev/null 2>&1
  note signature "ad hoc (lab)"
fi
mark prepared
[[ "$mode" == installed && "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("signature"))' "$info_json")" != ok ]] \
  && { result fallback not_run "installed app's signature does not verify"; exit 0; }
[[ "$app_commit" == "$base" ]] || { result fallback not_run "base mismatch: app is ${app_commit:-unknown}, manifest base is $base"; exit 0; }

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
a, w, h, n, flip = load(sys.argv[1]); b, w2, h2, _, _ = load(sys.argv[2])
if (w, h) != (w2, h2): print(f"-1 size {w}x{h} vs {w2}x{h2}"); sys.exit()
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

git -C "$root" worktree add --detach -q "$work/base-tree" "$base"
overlay_from "$work/base-tree" base || { result fail fail "base overlay never settled"; exit 1; }
overlay_from "$work/base-tree" repeat || { result fail fail "repeat overlay never settled"; exit 1; }
control="$(diff_in base repeat)"; note control_diff "$control"
mark controlled
[[ "$control" == "0 -" ]] || { result fail fail "control differs inside the region ($control): inconclusive"; exit 0; }

mark compiled_start
rm -rf "$work/web"; "$root/scripts/cmux-next/build-web-bundles.sh" --force --out-root "$work/web" >/dev/null
mark compiled
"$root/scripts/cmux-next/web-overlay.sh" install "$work/web" >/dev/null
mark applied
change="-1"
for _ in $(seq 1 120); do
  shot pr; change="$(diff_in base pr)"; [[ "${change%% *}" -gt 0 ]] && break; sleep 0.5
done
note change_diff "$change"
mark changed
if [[ "${change%% *}" -gt 0 ]]; then result ok pass ""; else result fail fail "no change inside the region after the PR overlay ($change)"; fi
