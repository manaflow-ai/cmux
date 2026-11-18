#!/usr/bin/env bash
# What computer use can still do while a Mac's screen is locked (ask-3cf710da4e; cmuxterm-hq
# docs/design/locked-screen-computer-use.md). Inside a throwaway macOS guest (the cu-driver-bench
# image, SIP off, the one place a step's own executables can hold Screen Recording and Accessibility;
# macos-cu-density.sh says why), with TextEdit open, macos-locked-screen-cu/guest.sh captures the
# window four ways and the displays through ScreenCaptureKit, types into it three ways and through
# Cua Driver 0.38.0 (the driver cmux's helper loads), and reads the document back through
# Accessibility: unlocked, on a CGVirtualDisplay, then after SACLockScreenImmediate, at once and
# late= seconds later. Locking a guest strands no fleet Mac: a locked mini needs a restart or a
# break-glass password to come back (cmuxterm-hq REPAIR.md).
#
#   cmux-ci run --class exclusive --measurement --label measure --label macos-26 \
#     --script scripts/measure/macos-locked-screen-cu.sh --ref SHA \
#     --artifact artifacts/macos-locked-screen-cu.tgz [--arg=late=120] --timeout 3600
#
# app=SHA (40 hex) is instead the end-to-end proof of computerUse.whileLocked: "lock the screen on
# a test Mac, run a computer-use task, and read back a captured window and an input that took
# effect" (Leo). It builds the cmux NEXT DEV app at SHA here (tagged lscproof, Debug: only a DEV
# build embeds "cmux Computer Use (dev).app"; fetched from GitHub when this checkout lacks SHA),
# then runs scripts/cmux-next/cua-helper-v2-live.py in the guest's login session twice, each in a
# fresh guest:
#   locked   --while-locked --lock-with lockprobe: on the locked screen, get_window_state returns
#            a screenshot with content, the test window records the click, the session stays locked;
#   refused  --lock-with lockprobe only: get_window_state answers mac_locked, nothing is clicked.
# The build needs the CMUX_CEF_R2_* read credentials (as tab-switch.sh build=SHA) and a team
# signing identity in CMUX_DEV_SIGN_IDENTITY: the helper verifies the app that starts it
# (CmuxAppCodeCheck: Apple-anchored, team 7WLXT3NR37, a com.cmuxterm.app.debug.* identifier) and
# answers host_unverified to an ad-hoc app, so an ad-hoc build proves nothing. Both are checked
# before the build. The DEV app embeds the pinned helper (cua-helper-dev.pin.json), not one built
# at SHA: build/helper.txt says whether the pin's helper source tree is SHA's.
#   cmux-ci run --class exclusive --measurement --label measure --label macos-26 --label cef-r2 \
#     --script scripts/measure/macos-locked-screen-cu.sh --ref SHA \
#     --artifact artifacts/macos-locked-screen-cu.tgz --arg=app=APPSHA --timeout 7200
#
# app=nightly runs the same two passes on the current cmux NEXT NIGHTLY instead of a build: its
# appcast's newest DMG (as scripts/ci/cua_signed_host_check.py takes it, with that script's
# checks: com.cmuxterm.app.nightly.cmux-next and its embedded com.cmuxterm.cua, both team
# 7WLXT3NR37). NIGHTLY carries no helper v2, so the app runs the legacy helper ("cmux Computer
# Use.app"), which refuses with screen_locked; the live script accepts that or mac_locked. The
# setting goes in through the run's isolated cmux.json (CMUX_NEXT_CONFIG_FILE), as in app=SHA, and
# is read back with settings.get on the app's control socket. build/nightly.txt and summary.txt
# name the NIGHTLY's version, build and CMUXCommit. No build, so no cef-r2 label:
#   cmux-ci run --class exclusive --measurement --label measure --label macos-26 \
#     --script scripts/measure/macos-locked-screen-cu.sh --ref SHA \
#     --artifact artifacts/macos-locked-screen-cu.tgz --arg=app=nightly --timeout 5400
#
# Output: LSC lines, and artifacts/macos-locked-screen-cu.tgz with guest/results.jsonl, the PNGs
# and summary.txt (app=SHA: guest-locked/ and guest-refused/, each with cua-helper-v2-live.json,
# screenshot.png, live.log and the app's log, and summary.txt with every check). Exit 0 when the
# guest's results came back (app=SHA: both passes'; LSC-VERDICT says whether each passed), else 4.
set -uo pipefail
late=120 guest_mem=8 guest_cpu=4 app_sha=""
for arg in "$@"; do
  case "$arg" in
    late=*) late="${arg#late=}" ;;
    guest_mem=*) guest_mem="${arg#guest_mem=}" ;;
    guest_cpu=*) guest_cpu="${arg#guest_cpu=}" ;;
    app=*) app_sha="${arg#app=}" ;;
    *) echo "macos-locked-screen-cu.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$late" =~ ^[0-9]{1,4}$ && "$late" -le 2400 && "$guest_mem" =~ ^[0-9]{1,2}$ && "$guest_cpu" =~ ^[0-9]{1,2}$ ]] ||
  { echo "macos-locked-screen-cu.sh: late= s (at most 2400), guest_mem= GB, guest_cpu= count" >&2; exit 2; }
[[ -z "$app_sha" || "$app_sha" == nightly || "$app_sha" =~ ^[0-9a-f]{40}$ ]] ||
  { echo "macos-locked-screen-cu.sh: app= takes a 40-hex commit or nightly" >&2; exit 2; }
started_at=$(date +%s)
root="$(git rev-parse --show-toplevel)"
cd "$root"
here="$root/scripts/measure/macos-locked-screen-cu"
ev="$root/scripts/measure/cu-driver-eval"
out="$root/artifacts/macos-locked-screen-cu"
rm -rf "$out" "$root/artifacts/macos-locked-screen-cu.tgz"
mkdir -p "$out/build" "$out/guest"
note() { echo "LSC $(date -u +%H:%M:%S) $*"; }
passes=(locked refused)
finish() {
  [[ -n "${1:-}" ]] && { note "blocked: $1"; printf '%s\n' "$1" >"$out/blocked.txt"; }
  if [[ -s "$out/guest/results.jsonl" ]]; then
    # One line per check: phase, what, ok, pixels, text read back.
    python3 -I - "$out/guest/results.jsonl" >"$out/summary.txt" 2>&1 <<'EOF'
import json, sys
for line in open(sys.argv[1]):
    try:
        r = json.loads(line)
    except ValueError:
        continue
    s = r.get("session") or {}
    st = r.get("stats") or {}
    bits = [r.get("phase", ""), r.get("cmd", "") or "note", "locked=%s" % s.get("locked", "")]
    for k in ("ok", "is_error", "error", "note", "after", "text", "set_err", "display_id", "applied"):
        if r.get(k) not in (None, ""):
            bits.append("%s=%s" % (k, str(r[k])[:160].replace("\n", " ")))
    if st:
        bits.append("px=%sx%s lit=%.2f colors=%s" % (st.get("w"), st.get("h"), st.get("lit", 0), st.get("colors")))
    print(" | ".join(str(b) for b in bits))
EOF
    cat "$out/summary.txt"
  fi
  if [[ -n "$app_sha" ]]; then
    # One line per check of each pass, then the pass's verdict.
    python3 -I - "$out" "${passes[@]}" >"$out/summary.txt" 2>&1 <<'EOF'
import json, os, sys
out = sys.argv[1]
for note in ("nightly.txt", "helper.txt"):
    if os.path.exists(os.path.join(out, "build", note)):
        print("LSC-APP " + open(os.path.join(out, "build", note)).read().strip())
for name in sys.argv[2:]:
    path = os.path.join(out, "guest-" + name, "cua-helper-v2-live.json")
    try:
        report = json.load(open(path))
    except (OSError, ValueError):
        print("LSC-VERDICT %s: NO RESULT (%s missing)" % (name, path))
        continue
    print("%s | app %s %s (build %s, CMUXCommit %s), helper %s" % (name, report.get("bundle_id"), report.get("short_version"),
          report.get("version"), report.get("commit"), report.get("driver_runs")))
    for c in report.get("checks", []):
        print("%s | %s | %s | %s" % (name, "ok" if c.get("ok") else "FAIL", c.get("check"), str(c.get("detail", ""))[:160].replace("\n", " ")))
    status = open(os.path.join(out, "guest-" + name, "status")).read().strip() if os.path.exists(os.path.join(out, "guest-" + name, "status")) else "?"
    failures, missing = report.get("failures") or [], report.get("missing_grants") or []
    verdict = "FAIL: " + "; ".join(failures) if failures else "MISSING GRANT " + ", ".join(missing) if missing else "PASS"
    print("LSC-VERDICT %s: %s (live script exit %s)" % (name, verdict, status))
EOF
    cat "$out/summary.txt"
  fi
  tar -czf "$root/artifacts/macos-locked-screen-cu.tgz" -C "$root/artifacts" macos-locked-screen-cu
}
if [[ -n "${CU_DRIVER_BENCH_HOME:-}" ]]; then
  lume_home="$CU_DRIVER_BENCH_HOME"
elif [[ -d /Volumes/ephemeral0/cmux-agent-work && -w /Volumes/ephemeral0/cmux-agent-work ]]; then
  lume_home=/Volumes/ephemeral0/cmux-agent-work/cu-driver-bench
else
  lume_home=/Users/Shared/cu-driver-bench
fi
mkdir -p "$lume_home/bin" "$lume_home/tmp" "$lume_home/.config"
pin() { python3 -I -c 'import functools, json, sys; print(functools.reduce(lambda d, k: d[k], sys.argv[2:], json.load(open(sys.argv[1]))))' "$ev/pins.json" "$@"; }

vm="" run_pid="" cloned="" keydir="" ip="" build_tmp=""
guest_down() {
  [[ -n "$run_pid" ]] && { kill "$run_pid" 2>/dev/null; wait "$run_pid" 2>/dev/null; }
  if [[ -n "$cloned" ]]; then
    lume stop "$vm" >/dev/null 2>&1 || true
    lume delete "$vm" --force >/dev/null 2>&1 || true
  fi
  [[ -n "$keydir" ]] && rm -rf "$keydir"
  vm="" run_pid="" cloned="" keydir="" ip=""
}
cleanup() {
  guest_down
  # The app build's worktree and scratch folder (13 to 18 GB), by their own paths.
  if [[ -n "$build_tmp" ]]; then
    git -C "$root" worktree remove --force "$build_tmp/src" >/dev/null 2>&1 || true
    rm -rf -- "$build_tmp"
  fi
}
trap cleanup EXIT

app="" app_tag=lscproof
if [[ "$app_sha" == nightly ]]; then
  app_tag=nightly # names the run only: a NIGHTLY is not a tagged build
  note "STAGE app nightly"
  build_tmp="$(mktemp -d)"
  # The NEXT NIGHTLY as cua_signed_host_check.py takes it: the appcast's newest enclosure, its
  # length, the DMG's one app, then the app's and its embedded helper's identity and team signature.
  python3 -I - "$root/scripts/ci" "$build_tmp" "$out/build/nightly.json" >"$out/build/nightly.log" 2>&1 <<'EOF'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import cua_signed_host_check as c  # noqa: E402

root, record = Path(sys.argv[2]), sys.argv[3]
feed = "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml"
try:
    url, length, version = c.feed_url(feed)
    dmg = root / "next.dmg"
    c.download(url, length, dmg)
    mount = root / "mount"
    mount.mkdir()
    c.run(["/usr/bin/hdiutil", "attach", str(dmg), "-nobrowse", "-readonly", "-mountpoint", str(mount)], timeout=300)
    try:
        apps = sorted(mount.glob("*.app"))
        if len(apps) != 1:
            raise c.Failure(f"{dmg}: expected one app, found {apps}")
        app = root / "app" / apps[0].name
        app.parent.mkdir()
        c.run(["/usr/bin/ditto", str(apps[0]), str(app)], timeout=300)
    finally:
        c.run(["/usr/bin/hdiutil", "detach", str(mount)], timeout=120, check=False)
    dmg.unlink()
    c.verify_signature(app, "com.cmuxterm.app.nightly.cmux-next")
    helper = c.nested_helper(app)
    c.verify_signature(helper, c.HELPER_ID)
    info = c.plist(app)
    json.dump({"feed": feed, "url": url, "sparkle_version": version, "bundle_id": info.get("CFBundleIdentifier"),
               "short_version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion"),
               "commit": info.get("CMUXCommit"), "helper": str(helper.relative_to(app)), "app": str(app)}, open(record, "w"), indent=1)
    print(f"nightly: {app}")
except c.Failure as error:
    print(f"nightly: {error}", file=sys.stderr)
    sys.exit(1)
EOF
  app=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("app") or "")' "$out/build/nightly.json" 2>/dev/null)
  [[ -n "$app" && -d "$app" ]] || { cat "$out/build/nightly.log"; finish "could not download and verify the NEXT NIGHTLY (build/nightly.log)"; exit 4; }
  # CMUXCommit is the short SHA the nightly stamps; the full one when this checkout has it.
  short=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("commit") or "")' "$out/build/nightly.json")
  full=""
  [[ "$short" =~ ^[0-9a-f]{7,40}$ ]] && full=$(git rev-parse --verify --quiet "$short^{commit}" 2>/dev/null)
  printf 'nightly %s, CMUXCommit %s%s\n' "$(python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d["short_version"], "build", d["build"], "(appcast", d["sparkle_version"] + ")")' "$out/build/nightly.json")" \
    "${short:-none}" "${full:+ ($full)}" >"$out/build/nightly.txt"
  { codesign -dvv "$app" 2>&1; } >"$out/build/signing.txt"
  note "$(cat "$out/build/nightly.txt"): $app"
elif [[ -n "$app_sha" ]]; then
  note "STAGE app $app_sha"
  # prepare_build, require_submodule_refs and cef_read_file_ok, as tab-switch.sh build=SHA uses them.
  # shellcheck source=scripts/measure/tab-switch.sh
  source "$root/scripts/measure/tab-switch.sh"
  set +e # tab-switch.sh sets -e; this script checks each step itself
  # shellcheck source=scripts/ci/lib/signing-runtime-guard.sh
  source "$root/scripts/ci/lib/signing-runtime-guard.sh"
  # shellcheck source=scripts/lib/dev-sign-identity.sh
  source "$root/scripts/lib/dev-sign-identity.sh"
  # Refuse before the build what would fail after it: the read credentials for the pinned assets
  # (the helper among them, in the private cmux-cef R2 bucket), and a team signature.
  cef_ok=0
  if [[ -n "${CMUX_CEF_R2_ACCESS_KEY_ID:-}" && -n "${CMUX_CEF_R2_SECRET_ACCESS_KEY:-}" &&
    -n "${CMUX_CEF_R2_ACCOUNT_ID:-}${CMUX_CEF_R2_ENDPOINT:-}" ]]; then
    cef_ok=1
  else
    account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    for file in "${CMUX_CEF_R2_ENV_FILE:-}" "$HOME/.secrets/cmux-cef.env" "${account_home:+$account_home/.secrets/cmux-cef.env}"; do
      cef_read_file_ok "$file" && { export CMUX_CEF_R2_ENV_FILE="$file"; cef_ok=1; break; }
    done
  fi
  [[ $cef_ok == 1 ]] || { finish "no CMUX_CEF_R2_* read credentials on this Mac (none in the environment, $HOME/.secrets/cmux-cef.env${account_home:+ or $account_home/.secrets/cmux-cef.env}): the build would fail after minutes fetching its pinned assets, the Computer Use helper among them. Not building. Run on a worker labeled cef-r2 (cmuxterm-hq build-fleet/mini-ops/cef-r2-key.sh HOST installs the read key)."; exit 4; }
  [[ -n "${CMUX_DEV_SIGN_IDENTITY:-}" && "$CMUX_DEV_SIGN_IDENTITY" != - ]] ||
    { finish "CMUX_DEV_SIGN_IDENTITY is not set on this worker, so reload.sh signs the app ad hoc, and the helper's CmuxAppCodeCheck refuses an ad-hoc app (host_unverified: not Apple-signed): every call would be refused before the lock is read. Not building. Run where CMUX_DEV_SIGN_IDENTITY names a cmux team (7WLXT3NR37) Apple Development identity."; exit 4; }
  cmux_dev_sign_identity_ready >"$out/build/sign-identity.log" 2>&1 ||
    { cat "$out/build/sign-identity.log"; finish "CMUX_DEV_SIGN_IDENTITY names no identity this worker has (build/sign-identity.log)"; exit 4; }
  cmux_signing_runtime_guard >"$out/build/signing-guard.log" 2>&1 ||
    { cat "$out/build/signing-guard.log"; finish "a CI signing keychain is still present (build/signing-guard.log)"; exit 4; }
  build_tmp="$(mktemp -d)"
  src="$root"
  if [[ "$app_sha" != "$(git rev-parse HEAD)" ]]; then
    # As tab-switch.sh: the commit from the explicit URL, never into submodules.
    git cat-file -e "$app_sha^{commit}" 2>/dev/null ||
      git -c submodule.recurse=false fetch --quiet --no-recurse-submodules https://github.com/manaflow-ai/cmux.git "$app_sha" ||
      { finish "cannot fetch $app_sha"; exit 4; }
    src="$build_tmp/src"
    git -c submodule.recurse=false worktree add --quiet --detach "$src" "$app_sha" || { finish "git worktree add $app_sha failed"; exit 4; }
  fi
  require_submodule_refs "$src" "$build_tmp" LSC || { finish "a submodule commit of $app_sha cannot be fetched (see the LSC line above)"; exit 4; }
  # Debug (no --release): the embed phase skips the helper in Release. A missing helper fails the
  # build (CMUX_NEXT_REQUIRE_CUA_HELPER=1) instead of building an app with nothing to measure.
  (cd "$src" && prepare_build "$build_tmp" && CMUX_DEV_BACKEND_MODE=local CMUX_NEXT_REQUIRE_CUA_HELPER=1 \
    ./scripts/reload.sh --tag "$app_tag" --no-global-cli-links) >"$out/build/app-build.log" 2>&1
  note "reload.sh exit $?"
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/build/app-build.log" | tail -n 1)"
  if [[ -z "$app" || ! -d "$app" ]]; then
    grep -E "error:|BUILD FAILED" "$out/build/app-build.log" | head -n 60
    tail -n 30 "$out/build/app-build.log"
    finish "the app build at $app_sha printed no app path (build/app-build.log)"; exit 4
  fi
  helper_app="$app/Contents/Library/cmux Computer Use (dev).app"
  [[ -d "$helper_app" ]] || { finish "the app has no cmux Computer Use (dev).app"; exit 4; }
  { codesign -dvv "$app" 2>&1; echo; codesign -dvv "$helper_app" 2>&1; } >"$out/build/signing.txt"
  team=$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [[ "$team" == 7WLXT3NR37 ]] || { finish "the built app is signed by team '${team:-none}', not 7WLXT3NR37: the helper would answer host_unverified (build/signing.txt)"; exit 4; }
  # The helper is the pinned bytes (cua-helper-dev.pin.json); its source tree hash, as
  # build-cua-helper-dev.sh computes it, against SHA's helper package.
  pinned_tree=$(/usr/libexec/PlistBuddy -c 'Print :CmuxHelperSourceTree' "$helper_app/Contents/Info.plist" 2>/dev/null)
  sha_tree=$(cd "$src/Packages/macOS/CmuxComputerUseHelper" && find . -type f -not -path './.build/*' -not -path './.swiftpm/*' | LC_ALL=C sort |
    while IFS= read -r f; do printf '%s\n' "$f"; shasum -a 256 "$f" | awk '{print $1}'; done | shasum -a 256 | awk '{print $1}')
  if [[ -n "$pinned_tree" && "$pinned_tree" == "$sha_tree" ]]; then
    helper_note="the embedded helper is built from $app_sha's helper sources ($sha_tree)"
  else
    helper_note="WARNING: the embedded helper (pinned, source tree ${pinned_tree:-unknown}) is not built from $app_sha's helper sources ($sha_tree): it runs the pin's ConsentGate, so a whileLocked change at $app_sha that is not in the pin cannot pass"
  fi
  printf '%s\n' "$helper_note" >"$out/build/helper.txt"
  note "built $app (team $team); $helper_note"
fi

note "STAGE build"
b="$out/build"
xcrun clang -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=14.0 -Wno-deprecated-declarations -o "$b/lockprobe" \
  "$here/lockprobe.m" -framework Foundation -framework AppKit -framework ApplicationServices -framework ScreenCaptureKit -framework CoreGraphics \
  -framework IOKit >"$b/lockprobe.log" 2>&1 || { cat "$b/lockprobe.log"; finish "lockprobe.m did not compile (build/lockprobe.log)"; exit 4; }
codesign -s - -f "$b/lockprobe" >/dev/null 2>&1 || { finish "ad-hoc signing failed"; exit 4; }
cp "$here/guest.sh" "$here/guest-app.sh" "$b/"
printf '%s\n' "$late" >"$b/late"
printf '%s\n' "$app_tag" >"$b/tag"
drv_sum=$(pin drivers cua-driver-0.38.0 sha256)
drv_tgz="$lume_home/bin/$drv_sum.tar.gz"
[[ -s "$drv_tgz" ]] || { curl -fsSL --retry 3 -o "$drv_tgz.part" "$(pin drivers cua-driver-0.38.0 url)" && mv "$drv_tgz.part" "$drv_tgz"; }
[[ "$(shasum -a 256 "$drv_tgz" 2>/dev/null | awk '{print $1}')" == "$drv_sum" ]] || { rm -f "$drv_tgz"; finish "could not fetch the pinned Cua Driver"; exit 4; }
mkdir -p "$b/drv" && tar -xzf "$drv_tgz" -C "$b/drv" && cp "$b/drv/$(pin drivers cua-driver-0.38.0 binary)" "$b/cua-driver" ||
  { finish "could not unpack the pinned Cua Driver"; exit 4; }
note "built lockprobe; Cua Driver 0.38.0 ($drv_sum)"

note "STAGE lume"
lume_sum=$(pin lume sha256)
lume_tgz="$lume_home/bin/$lume_sum.tar.gz"
[[ -s "$lume_tgz" ]] || { curl -fsSL --retry 3 -o "$lume_tgz.part" "$(pin lume url)" && mv "$lume_tgz.part" "$lume_tgz"; }
[[ "$(shasum -a 256 "$lume_tgz" 2>/dev/null | awk '{print $1}')" == "$lume_sum" ]] || { rm -f "$lume_tgz"; finish "could not fetch the pinned Lume"; exit 4; }
lume_dir="$lume_home/bin/$lume_sum"
[[ -x "$lume_dir/lume" ]] || { mkdir -p "$lume_dir" && tar -xzf "$lume_tgz" -C "$lume_dir"; }
[[ -x "$lume_dir/lume" ]] || { finish "could not unpack the pinned Lume"; exit 4; }
lume_env=(env HOME="$lume_home" CFFIXED_USER_HOME="$lume_home" XDG_CONFIG_HOME="$lume_home/.config" TMPDIR="$lume_home/tmp/"
  LUME_TELEMETRY_ENABLED=0 LUME_LOG_LEVEL=error "$lume_dir/lume")
lume() { "${lume_env[@]}" "$@"; }

note "STAGE image"
image_name=$(pin image name) image_tag=$(pin image tag) image_digest=$(pin image digest)
base="cu-bench-base-${image_tag//./-}"
base_ok() { [[ "$(lume get "$base" -f json 2>/dev/null | python3 -I -c 'import json, sys
d = json.load(sys.stdin); r = d[0] if isinstance(d, list) and d else d
print(r.get("status", "") if isinstance(r, dict) else "")' 2>/dev/null)" == stopped && "$(cat "$lume_home/$base.digest" 2>/dev/null)" == "$image_digest" ]]; }
if ! base_ok; then
  note "no checked base $base here: cu-driver-bench.sh suite=probe pulls it"
  bash "$root/scripts/measure/cu-driver-bench.sh" suite=probe >"$out/bench-probe.log" 2>&1
  note "cu-driver-bench.sh suite=probe exit $?"
fi
base_ok || { tail -20 "$out/bench-probe.log" 2>/dev/null; finish "no checked base image $base on this worker"; exit 4; }
note "base $base ($image_name:$image_tag $image_digest)"

ssh_opts=()
guest() { ssh "${ssh_opts[@]}" "lume@$ip" "$@"; }
guest_n() { ssh -n "${ssh_opts[@]}" "lume@$ip" "$@"; }
# A fresh clone of the base, booted, with this run's key and passwordless sudo. LOG names its logs.
guest_up() {
  local log="$1" booted=0 pubkey setup
  vm="lsc-$(date +%s)-$$"
  lume clone "$base" "$vm" >"$out/$log-clone.log" 2>&1 || { finish "lume clone failed ($log-clone.log)"; exit 4; }
  cloned=1
  lume set "$vm" --cpu "$guest_cpu" --memory "${guest_mem}GB" --display 1920x1080 >"$out/$log-set.log" 2>&1 ||
    { finish "lume set failed ($log-set.log)"; exit 4; }
  ( exec "${lume_env[@]}" run "$vm" --no-display ) >"$out/$log-run.log" 2>&1 &
  run_pid=$!
  for _ in $(seq 1 90); do
    kill -0 "$run_pid" 2>/dev/null || break
    lume ssh "$vm" -t 10 true >/dev/null 2>&1 && { booted=1; break; }
    sleep 5
  done
  [[ $booted == 1 ]] || { tail -20 "$out/$log-run.log"; finish "the guest's SSH never answered ($log-run.log)"; exit 4; }
  keydir="$lume_home/tmp/key-$vm"
  mkdir -p "$keydir" && chmod 700 "$keydir"
  ssh-keygen -q -t ed25519 -N "" -C "$vm" -f "$keydir/id" || { finish "ssh-keygen failed"; exit 4; }
  ip=$(lume get "$vm" -f json 2>/dev/null | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
r = d[0] if isinstance(d, list) else d
print(r.get("ipAddress") or "")' 2>/dev/null)
  [[ "$ip" =~ ^[0-9.]+$ ]] || { finish "lume reported no guest IP"; exit 4; }
  pubkey=$(cat "$keydir/id.pub")
  setup="mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pubkey' >>~/.ssh/authorized_keys"
  setup+=" && echo lume | sudo -S sh -c 'echo \"lume ALL=(ALL) NOPASSWD: ALL\" >/etc/sudoers.d/lsc && chmod 440 /etc/sudoers.d/lsc'"
  lume ssh "$vm" -t 60 "$setup" >"$out/$log-key.log" 2>&1 || { finish "could not install the run's key in the guest ($log-key.log)"; exit 4; }
  ssh_opts=(-i "$keydir/id" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=error
    -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2)
  guest_n true || { finish "ssh with the run's key failed"; exit 4; }
}
# The LaunchAgent that runs ARGS... in the guest's login session (bootstrapped once the Dock runs).
agent_start() {
  local started=0 a
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      '<plist version="1.0"><dict>' '<key>Label</key><string>ai.manaflow.lsc</string>' '<key>ProgramArguments</key><array>'
    for a in "$@"; do printf '<string>%s</string>\n' "$a"; done
    printf '%s\n' '</array>' '<key>RunAtLoad</key><true/>' '<key>ProcessType</key><string>Interactive</string>' '</dict></plist>'
  } | guest 'cat >~/lsc/agent.plist' || return 1
  for _ in $(seq 1 30); do
    guest_n 'uid=$(id -u); pgrep -u $uid -x Dock >/dev/null && { sudo -n launchctl bootstrap gui/$uid ~/lsc/agent.plist 2>/dev/null ||
      sudo -n launchctl asuser $uid launchctl bootstrap gui/$uid ~/lsc/agent.plist 2>/dev/null ||
      sudo -n launchctl print gui/$uid/ai.manaflow.lsc >/dev/null 2>&1; }' && { started=1; break; }
    sleep 5
  done
  [[ $started == 1 ]]
}
facts() { guest_n 'sw_vers; csrutil status; xcode-select -p; ls -l /opt/homebrew/bin/python3; pmset -g | grep -E "displaysleep|sleep"; defaults read com.apple.screensaver 2>&1 | head -5' >"$1" 2>&1; }

if [[ -z "$app_sha" ]]; then
  note "STAGE guest"
  guest_up guest
  tar -c -C "$b" lockprobe cua-driver guest.sh late -C "$ev" tcc-grant.sh | guest 'rm -rf ~/lsc && mkdir -p ~/lsc && tar -x -C ~/lsc' ||
    { finish "could not copy the probe into the guest"; exit 4; }
  # bash (the LaunchAgent's process, which TCC asks about), the probe and the driver get Screen
  # Recording, Accessibility and event posting, in this throwaway SIP-off clone only.
  guest_n 'bash ~/lsc/tcc-grant.sh /bin/bash ~/lsc/lockprobe ~/lsc/cua-driver' >"$out/grant.log" 2>&1 ||
    { cat "$out/grant.log"; finish "tcc-grant.sh failed in the guest (grant.log)"; exit 4; }
  facts "$out/guest/facts.txt"
  agent_start /bin/bash /Users/lume/lsc/guest.sh || { finish "could not start guest.sh in the guest's login session"; exit 4; }
  note "guest.sh is running in the guest's session (late=$late)"
  deadline=$(( started_at + 3300 ))
  finished=0
  while (( $(date +%s) < deadline )); do
    guest_n 'test -f ~/lsc/status' 2>/dev/null && { finished=1; break; }
    sleep 10
  done
  guest_n 'cd ~/lsc/out && tar -c .' | tar -x -C "$out/guest" 2>/dev/null
  guest_n 'ioreg -n Root -d1 | grep -E "IOConsoleLocked|CGSSessionScreenIsLocked"' >"$out/guest/ioreg-after.txt" 2>&1
  [[ $finished == 1 ]] || { finish "guest.sh did not finish in the time left"; exit 4; }
  finish
  [[ -s "$out/guest/results.jsonl" ]] || exit 4
  exit 0
fi

# app=SHA: one fresh guest per pass. The refused pass needs a session that is not locked yet, and
# getting one back means typing the password into the lock screen (through the global input queue,
# the path this measures as unsafe) or rebooting the guest (a guest restart stops a Virtualization
# VM, so Lume would have to start it again). A second clone of the same base costs about a boot,
# and each pass then starts from the same state: unlocked, no helper or tag state left behind.
# The locked pass runs first, so a run cut short still has the proof itself.
rmdir "$out/guest" 2>/dev/null
pass_wait=1500
for pass in "${passes[@]}"; do
  note "STAGE guest $pass"
  mkdir -p "$out/guest-$pass"
  guest_up "guest-$pass"
  tar -c -C "$b" lockprobe guest-app.sh tag -C "$ev" tcc-grant.sh -C "$root/scripts" cmux-next/cua-helper-v2-live.py \
    cmux-next/cua_v2_probe_agent.py cmux-next/cua_v2_probe_window.py cmux-next/tag_teardown.py |
    guest 'rm -rf ~/lsc && mkdir -p ~/lsc/app && tar -x -C ~/lsc' || { finish "could not copy the probe into the guest"; exit 4; }
  tar -c -C "$(dirname "$app")" "$(basename "$app")" | guest 'tar -x -C ~/lsc/app' || { finish "could not copy the app into the guest"; exit 4; }
  # The helper (by path and by its bundle id), the app, bash (the LaunchAgent's process) and the
  # python get Screen Recording, Accessibility and event posting, in this throwaway SIP-off clone only.
  guest_n 'bash ~/lsc/guest-app.sh grant' >"$out/guest-$pass/grant.log" 2>&1 ||
    { cat "$out/guest-$pass/grant.log"; finish "the grants failed in the guest (guest-$pass/grant.log)"; exit 4; }
  note "guest python: $(head -1 "$out/guest-$pass/grant.log")"
  facts "$out/guest-$pass/facts.txt"
  agent_start /bin/bash /Users/lume/lsc/guest-app.sh run "$pass" ||
    { finish "could not start guest-app.sh in the guest's login session"; exit 4; }
  note "cua-helper-v2-live.py ($pass) is running in the guest's session"
  deadline=$(( $(date +%s) + pass_wait ))
  finished=0
  while (( $(date +%s) < deadline )); do
    guest_n "test -f ~/lsc/status-$pass" 2>/dev/null && { finished=1; break; }
    sleep 10
  done
  guest_n "cat ~/lsc/status-$pass" >"$out/guest-$pass/status" 2>/dev/null
  # The run's output, without its empty work folder.
  guest_n "cd ~/lsc/out/$pass && tar -c --exclude ./work ." | tar -x -C "$out/guest-$pass" 2>/dev/null
  guest_n 'ioreg -n Root -d1 | grep -E "IOConsoleLocked|CGSSessionScreenIsLocked"' >"$out/guest-$pass/ioreg-after.txt" 2>&1
  note "$pass: $(grep -E '^(PASS|FAIL|MISSING GRANT)' "$out/guest-$pass/live.log" 2>/dev/null | tail -1)"
  guest_down
  [[ $finished == 1 ]] || note "$pass: the live script did not finish in $pass_wait s"
done
finish
for pass in "${passes[@]}"; do [[ -s "$out/guest-$pass/cua-helper-v2-live.json" ]] || exit 4; done
exit 0
