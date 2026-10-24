#!/usr/bin/env bash
# One cmux-next build on each supported macOS major, in disposable Tart VMs: a launch smoke,
# the seeded UI fuzz, or the replay of a saved repro. Run it ON a Tart host, never on a laptop.
# Agents start it on the fleet with os-matrix.sh (a cmux-ci step of class vm).
#
# Usage: vm.sh [--majors 14,15,26,27] [--suite smoke|fuzz|repro|exec] [--seed N] [--steps N] [--minutes N]
#              [--repro NAME | --replay STEPS.jsonl | --probe NAME] [--work DIR] [--results FILE] [--keep-vm] BUILD
#   BUILD      a cmux-next .app, a .zip with one, or a .dmg (a shipped nightly).
#   --suite    smoke: smoke.py (launch, window, terminal echo, split, Chromium and WebKit tabs,
#              Settings, quit; needs a DEV build). fuzz (default): fuzz.py, a feature tour and
#              --steps seeded random steps. repro: fuzz.py --replay repros/NAME.jsonl.
#              exec: compile probes/NAME.swift (beside this script) on the host with the host's
#              Xcode (arm64, macOS 14 target, ad hoc signed), copy only the binary into each guest
#              and run it there as the guest user, bounded to 5 min. result.json has its exit
#              code, stdout and stderr. Exit 0 is PASS, 1 is FAIL, anything else is no verdict.
#              The probe never runs on the host. It tests the OS, not the build (BUILD is still
#              copied into the guest, so a probe may use it).
#   --minutes  fuzz: stop each major's walk after N minutes (the run's time bound); --steps
#              stays the upper bound of the walk.
#   --results  write the run (logs, screenshots, reports, matrix.json) to FILE as a .tgz and
#              exit 0 when every major gave a verdict, also a FAIL one: the verdict is the data
#              (matrix.json and the last line, MATRIX VERDICT PASS|FAIL). Without it the exit
#              code is the verdict.
# Images, Tart, TART_HOME, the fleet host lock and the keychain rules are defined
# by this script's images.json and the host environment. Env: FUZZ_HOST_LOCK (none: no lock),
# FUZZ_ALLOW_PULL=1 (pull an image the Tart cache lacks; off by default, each is about 25 GB),
# FUZZ_KEYCHAIN_PASSWORD_FILE (0600 file with the login password, read on stdin: run without a
# tty, e.g. nohup ... </dev/null; unlocks a locked login keychain for each VM, relocks after;
# Virtualization.framework keeps its host key there. A fleet step gets the keychain unlocked
# by the worker instead).
# For each major: clone the pinned image, boot headless with Virtualization.framework's
# VNC server, copy the build in, run the suite (input over VNC, CLI over SSH), copy the
# findings out, stop and delete the clone. Majors run one at a time under the host lock.
# Output: <work>/fuzz/<UTC>-<pid>/<major>/{result.json|summary.json,*.png,*.ips,...}
# and <run>/matrix.json. Without --results: exit 1 when any major failed.
# Replay a finding: --replay <run>/<major>/steps.jsonl (same build, same major).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGES="$HERE/images.json"
MAJORS=14,15,26; SEED=1; STEPS=600; KEEP_VM=0; REPLAY=""; SUITE=fuzz; REPRO=""; RESULTS=""; MINUTES=0; PROBE=""
WORK=${FUZZ_WORK:-/Volumes/ephemeral0/cmux-agent-work/mfloor}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --majors) MAJORS=$2; shift 2 ;;
    --seed) SEED=$2; shift 2 ;;
    --steps) STEPS=$2; shift 2 ;;
    --minutes) MINUTES=$2; shift 2 ;;
    --work) WORK=$2; shift 2 ;;
    --replay) REPLAY=$2; shift 2 ;;
    --suite) SUITE=$2; shift 2 ;;
    --repro) REPRO=$2; shift 2 ;;
    --probe) PROBE=$2; shift 2 ;;
    --results) RESULTS=$2; shift 2 ;;
    --keep-vm) KEEP_VM=1; shift ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) BUILD=$1; shift ;;
  esac
done
[[ -n "${BUILD:-}" && -e "$BUILD" ]] || { echo "usage: vm.sh [--majors 14,15,26] [--suite smoke|fuzz|repro] BUILD" >&2; exit 2; }
[[ -z "$PROBE" || "$SUITE" == exec ]] || { echo "--probe needs --suite exec" >&2; exit 2; }
case "$SUITE" in
  smoke|fuzz) [[ -z "$REPRO" ]] || { echo "--repro needs --suite repro" >&2; exit 2; } ;;
  exec)
    # NAME is a plain name (no separator, no ..), probes/ is a real folder of this runner and
    # probes/NAME.swift a regular file in it, not a link: the source is the reviewed one.
    [[ -z "$REPRO" && "$PROBE" =~ ^[a-z0-9][a-z0-9-]{0,63}$ && -d "$HERE/probes" && ! -L "$HERE/probes" &&
       -f "$HERE/probes/$PROBE.swift" && ! -L "$HERE/probes/$PROBE.swift" ]] || {
      echo "--suite exec needs --probe NAME of a regular file $HERE/probes/NAME.swift (NAME: a-z, 0-9, -; no links)" >&2; exit 2; } ;;
  repro)
    [[ "$REPRO" =~ ^[a-z0-9][a-z0-9-]{0,63}$ && -f "$HERE/repros/$REPRO.jsonl" ]] || {
      echo "--suite repro needs --repro NAME of a file in $HERE/repros (without .jsonl)" >&2; exit 2; }
    REPLAY="$HERE/repros/$REPRO.jsonl" ;;
  *) echo "--suite must be smoke, fuzz, repro or exec" >&2; exit 2 ;;
esac
# The results file is created new at the end (O_EXCL): refuse an existing one before the run.
[[ -z "$RESULTS" || ! -e "$RESULTS" && ! -L "$RESULTS" ]] || { echo "--results $RESULTS exists" >&2; exit 2; }
export TART_HOME=${TART_HOME:-$WORK/tart-home}
TART_BIN=${TART_BIN:-$(command -v tart || ls -d "$WORK"/tools/tart-*/tart.app/Contents/MacOS/tart 2>/dev/null | tail -1 || true)}
[[ -x "$TART_BIN" ]] || { echo "no tart binary (see images.json)" >&2; exit 2; }
LOCK=${FUZZ_HOST_LOCK:-/Users/Shared/cmux-build-fleet/host.lock}
[[ "$LOCK" == none || -e "$LOCK" ]] || LOCK=none
CURRENT_VM=""
# A failing command under set -e skips the RETURN trap: stop and delete the clone at exit too.
trap '[[ -n "$CURRENT_VM" ]] && { "$TART_BIN" stop "$CURRENT_VM" --timeout 30 >/dev/null 2>&1; [[ "$KEEP_VM" == 1 ]] || "$TART_BIN" delete "$CURRENT_VM" >/dev/null 2>&1; }; relock_keychain; true' EXIT
RUN="$WORK/fuzz/$(date -u +%Y%m%dT%H%M%SZ)-$$"; mkdir -p "$RUN"
printf '#!/bin/sh\necho admin\n' >"$RUN/askpass.sh"; chmod 700 "$RUN/askpass.sh"
export SSH_ASKPASS="$RUN/askpass.sh" SSH_ASKPASS_REQUIRE=force DISPLAY=none
SSH_OPTS=(-o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive -o NumberOfPasswordPrompts=1)
SSHB=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 "${SSH_OPTS[@]}")

image_ref() {  # FUZZ_IMAGE_<major> (e.g. ghcr.io/cirruslabs/macos-sonoma-vanilla:14.8.7) overrides the pin
  local override; override=$(eval "echo \${FUZZ_IMAGE_$1:-}")
  [[ -n "$override" ]] && { echo "$override"; return; }
  python3 -I -c 'import json,sys
for i in json.load(open(sys.argv[1]))["images"]:
    if i["major"] == sys.argv[2]: print(i["ref"] + "@" + i["digest"]); break
else: sys.exit("major %s is not in images.json" % sys.argv[2])' "$IMAGES" "$1"; }

cycle() {  # cycle MAJOR OUT
  local major=$1 out=$2 vm="fuzz-$1-$$" tart_pid="" ip=""
  local ref; ref=$(image_ref "$major")
  # A macOS guest needs a host of at least its major (Virtualization.framework): 27 needs a 27 host.
  local host_min; host_min=$(python3 -I -c 'import json,sys
print(next((i.get("host_os_min", "") for i in json.load(open(sys.argv[1]))["images"] if i["major"] == sys.argv[2]), ""))' "$IMAGES" "$major")
  if [[ -n "$host_min" ]] && (( $(sw_vers -productVersion | cut -d. -f1) < host_min )); then
    echo "macOS $major needs a macOS $host_min host; this host runs $(sw_vers -productVersion)" >"$out/failure"; return 1
  fi
  # Each image is about 25 GB: pull only on request (FUZZ_ALLOW_PULL=1), never as a side effect.
  if ! "$TART_BIN" list --source oci --quiet 2>/dev/null | grep -qF "${ref##*[@]}"; then
    [[ "${FUZZ_ALLOW_PULL:-0}" == 1 ]] || { echo "image $ref is not in $TART_HOME's cache; set FUZZ_ALLOW_PULL=1 to pull it" >"$out/failure"; return 1; }
    "$TART_BIN" pull "$ref" >"$out/pull.log" 2>&1
  fi
  cleanup_vm() {
    "$TART_BIN" stop "$vm" --timeout 30 >/dev/null 2>&1 || true
    [[ -n "$tart_pid" ]] && wait "$tart_pid" 2>/dev/null || true
    [[ "$KEEP_VM" == 1 ]] || "$TART_BIN" delete "$vm" >/dev/null 2>&1 || true
    CURRENT_VM=""
    relock_keychain
  }
  trap cleanup_vm RETURN
  trap 'cleanup_vm; exit 130' INT TERM
  unlock_keychain "$out" || return 1
  CURRENT_VM=$vm
  "$TART_BIN" clone "$ref" "$vm"
  "$TART_BIN" set "$vm" --display 1440x900 >/dev/null 2>&1 || true
  "$TART_BIN" run --no-graphics --vnc-experimental "$vm" >"$out/tart-run.log" 2>&1 &
  tart_pid=$!
  ip=$("$TART_BIN" ip "$vm" --wait 300)
  local deadline=$(( $(date +%s) + 300 ))
  until ssh "${SSHB[@]}" "admin@$ip" true </dev/null 2>/dev/null; do
    kill -0 "$tart_pid" 2>/dev/null || { echo "tart exited during boot" >"$out/failure"; return 1; }
    (( $(date +%s) < deadline )) || { echo "no guest SSH" >"$out/failure"; return 1; }
    sleep 2
  done
  local vnc; vnc=$(grep -Eo 'vnc://[^ ]+' "$out/tart-run.log" | head -1)
  local vncarg; vncarg=$(python3 -I -c 'import sys,urllib.parse as u;p=u.urlparse(sys.argv[1]);print("%s:%s:%s"%(p.hostname,p.port,u.unquote(p.password or "")))' "$vnc")
  scp "${SSHB[@]}" -q "$BUILD_ZIP" "admin@$ip:/Users/admin/build.zip" </dev/null
  local app; app=$(ssh "${SSHB[@]}" "admin@$ip" 'set -e; pkill -x "System Settings" || true; pkill -x Terminal || true; rm -rf ~/fuzzapp; mkdir ~/fuzzapp;
    ditto -x -k ~/build.zip ~/fuzzapp; ls -d ~/fuzzapp/*.app | head -1' </dev/null)
  local common=(--ssh "admin@$ip" --vnc "$vncarg" --app "$app" --out "$out" --ssh-opt=-oPubkeyAuthentication=no
    --ssh-opt=-oPreferredAuthentications=password,keyboard-interactive --ssh-opt=-oNumberOfPasswordPrompts=1)
  if [[ "$SUITE" == exec ]]; then
    exec_probe "$ip" "$out" "$app"
    return 0
  fi
  if [[ "$SUITE" == smoke ]]; then
    python3 -I "$HERE/smoke.py" "${common[@]}" >"$out/smoke.log" 2>&1 || echo "smoke exit $?" >"$out/failure"
    grep -E '^(SMOKE|[a-z_]+ +(ok|FAIL)) ' "$out/smoke.log" | cut -c1-400 >&2 || true
    return 0
  fi
  local rargs=(); if [[ -n "$REPLAY" ]]; then rargs=(--replay "$REPLAY"); fi
  if [[ -n "${FUZZ_DYLIB:-}" ]]; then
    # Diagnostics only: a dylib loaded with DYLD_INSERT_LIBRARIES, which the hardened runtime
    # refuses, so the guest copy of the app is re-signed ad hoc without it.
    scp "${SSHB[@]}" -q "$FUZZ_DYLIB" "admin@$ip:/Users/admin/fuzz-diag.dylib" </dev/null
    ssh "${SSHB[@]}" "admin@$ip" "codesign --force --deep --sign - $(printf %q "$app") >/dev/null 2>&1" </dev/null
    rargs+=(--insert-dylib /Users/admin/fuzz-diag.dylib)
  fi
  python3 -I "$HERE/fuzz.py" "${common[@]}" --seed "$SEED" --steps "$STEPS" --minutes "$MINUTES" ${rargs[@]+"${rargs[@]}"} ${FUZZ_ARGS:-} \
    >"$out/fuzz.log" 2>&1 || echo "fuzz exit $?" >"$out/failure"
}

# exec suite: compile the probe once on the host (compile_probe), copy the binary into each guest and run
# it there as the guest user with a time bound (perl alarm: the guest has no coreutils timeout).
EXEC_SECONDS=300
PROBE_BIN=""
PROBE_COMPILE_SECONDS=300
PROBE_SOURCE_SHA256="" PROBE_RUNNER_REF=""
bounded() {  # bounded SECONDS CMD...: run CMD, kill it past SECONDS (exit 124); no coreutils timeout on macOS
  /usr/bin/perl -e 'my $s = shift; my $pid = fork; if (!$pid) { exec @ARGV; exit 127 }
    my $ok = eval { local $SIG{ALRM} = sub { die "t\n" }; alarm $s; waitpid($pid, 0); alarm 0; 1 };
    if (!$ok) { kill 9, $pid; waitpid($pid, 0); exit 124 } exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$@"
}
compile_probe() {  # compile_probe OUTDIR: sets PROBE_BIN, or returns 1 with OUTDIR/probe-compile.log
  mkdir -p "$1"
  PROBE_BIN="$1/$PROBE"
  # Traceability: the probe's source and the runner commit it came from (the step's checkout).
  PROBE_SOURCE_SHA256=$(shasum -a 256 "$HERE/probes/$PROBE.swift" | cut -d' ' -f1)
  PROBE_RUNNER_REF=$(git -C "$HERE" rev-parse HEAD 2>/dev/null || echo unknown)
  # Compiled on the host, run only in the guests. Bounded: a compile that hangs is no verdict.
  bounded "$PROBE_COMPILE_SECONDS" xcrun swiftc -O -target arm64-apple-macos14.0 -o "$PROBE_BIN" "$HERE/probes/$PROBE.swift" \
    >"$1/probe-compile.log" 2>&1 &&
    bounded 60 /usr/bin/codesign --force --sign - "$PROBE_BIN" >>"$1/probe-compile.log" 2>&1 || { PROBE_BIN=""; return 1; }
}
exec_probe() {  # exec_probe IP OUT APP
  local ip=$1 out=$2 rc=0
  scp "${SSHB[@]}" -q "$PROBE_BIN" "admin@$ip:/Users/admin/os-probe" </dev/null || { echo "probe copy failed" >"$out/failure"; return 0; }
  # CMUX_MATRIX_APP: the build's app in the guest, for a later probe that drives or inspects it.
  ssh "${SSHB[@]}" "admin@$ip" "set -e; p=\$HOME/os-probe; chmod 755 \"\$p\"; export CMUX_MATRIX_APP=$(printf %q "$3");
    cd \$(mktemp -d); /usr/bin/perl -e 'my \$pid = fork; if (!\$pid) { exec @ARGV; exit 127 }
      my \$ok = eval { local \$SIG{ALRM} = sub { die qq(t\\n) }; alarm $EXEC_SECONDS; waitpid(\$pid, 0); alarm 0; 1 };
      if (!\$ok) { kill 9, \$pid; waitpid(\$pid, 0); exit 124 } exit(\$? & 127 ? 128 + (\$? & 127) : \$? >> 8)' \"\$p\"" \
    </dev/null >"$out/probe.stdout" 2>"$out/probe.stderr" || rc=$?
  local os build; os=$(ssh "${SSHB[@]}" "admin@$ip" 'sw_vers -productVersion' </dev/null || true)
  build=$(ssh "${SSHB[@]}" "admin@$ip" 'sw_vers -buildVersion' </dev/null || true)
  python3 -I - "$out" "$PROBE" "$rc" "$os" "$build" "$EXEC_SECONDS" "$PROBE_RUNNER_REF" "$PROBE_SOURCE_SHA256" <<'PY'
import json, os, sys
out, probe, rc, osv, build, bound, runner_ref, source_sha = sys.argv[1:9]
read = lambda n: open(os.path.join(out, n), errors="replace").read()[-20000:]
rc = int(rc)
verdict = {0: "PASS", 1: "FAIL"}.get(rc, "NO-VERDICT")
last = (read("probe.stdout").strip().splitlines() or [""])[-1][:300]
result = {"suite": "exec", "probe": probe, "os": osv, "build": build, "exit_code": rc, "ok": rc == 0, "verdict": verdict,
          "timed_out": rc == 124, "bound_s": int(bound), "runner_ref": runner_ref, "probe_source_sha256": source_sha, "stdout": read("probe.stdout"), "stderr": read("probe.stderr"),
          "failed_steps": [] if rc == 0 else ["exec exit %d" % rc]}
json.dump(result, open(os.path.join(out, "result.json"), "w"), indent=1)
print("EXEC %s probe=%s os=%s exit=%d: %s" % (verdict, probe, osv, rc, last), file=sys.stderr)
PY
}

# Virtualization.framework keeps a host key in the login keychain: Tart fails with "Failed to get
# current host key" when the session has no keychain search list (Tailscale SSH) or the keychain is
# locked (OpenSSH without a GUI login, as a fleet worker step). Unlock it for one VM, relock after.
KEYCHAIN=$HOME/Library/Keychains/login.keychain-db
RELOCK=0
unlock_keychain() {  # unlock_keychain OUT
  [[ -n "$(security default-keychain 2>/dev/null)" ]] || {
    echo "no default keychain in this session (Tailscale SSH?); run from an OpenSSH or GUI session" >"$1/failure"; return 1; }
  security show-keychain-info "$KEYCHAIN" >/dev/null 2>&1 && return 0
  [[ -r "${FUZZ_KEYCHAIN_PASSWORD_FILE:-}" ]] || { echo "login keychain locked; set FUZZ_KEYCHAIN_PASSWORD_FILE" >"$1/failure"; return 1; }
  security unlock-keychain "$KEYCHAIN" <"$FUZZ_KEYCHAIN_PASSWORD_FILE" >/dev/null 2>&1 || {
    echo "login keychain unlock failed" >"$1/failure"; return 1; }
  RELOCK=1
}
relock_keychain() { if [[ "$RELOCK" == 1 ]]; then security lock-keychain "$KEYCHAIN" || true; RELOCK=0; fi; }

case "$BUILD" in
  *.zip) BUILD_ZIP=$(cd "$(dirname "$BUILD")" && pwd)/$(basename "$BUILD") ;;
  *.app|*.app/) BUILD_ZIP="$RUN/build.zip"; ditto -c -k --keepParent "$BUILD" "$BUILD_ZIP" ;;
  *.dmg) mnt=$(mktemp -d); hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$BUILD" >/dev/null
         BUILD_ZIP="$RUN/build.zip"; ditto -c -k --keepParent "$(ls -d "$mnt"/*.app | head -1)" "$BUILD_ZIP"; hdiutil detach -quiet "$mnt" ;;
  *) echo "BUILD must be .app, .zip or .dmg" >&2; exit 2 ;;
esac
export BUILD_ZIP

IFS=, read -r -a majors <<<"$MAJORS"
if [[ "$SUITE" == exec ]] && ! compile_probe "$RUN/probe-bin"; then
  # No probe, no verdict: every major records the compile failure (and boots no VM).
  for major in "${majors[@]}"; do mkdir -p "$RUN/$major"; echo "probe $PROBE did not compile (probe-bin/probe-compile.log)" >"$RUN/$major/failure"; done
  majors=()
fi
for major in ${majors[@]+"${majors[@]}"}; do
  out="$RUN/$major"; mkdir -p "$out"
  echo "== macOS $major (suite $SUITE${REPRO:+ $REPRO}, seed $SEED, steps $STEPS, minutes $MINUTES): waiting for the host lock" >&2
  if [[ "$LOCK" == none ]]; then cycle "$major" "$out" || true
  else
    # Hold the fleet lock only for clone..delete.
    exec 9>>"$LOCK"
    perl -MFcntl=:flock -e 'open(my $f, ">&=", 9) or die; flock($f, LOCK_EX) or die "flock: $!"'
    cycle "$major" "$out" || true
    exec 9>&-
  fi
done

python3 -I - "$RUN" "$MAJORS" "$SUITE" "$RESULTS" <<'PY'
import json, os, sys, tarfile
run, majors, suite, results = sys.argv[1], sys.argv[2].split(","), sys.argv[3], sys.argv[4]
rows, bad, missing = {}, False, []
for m in majors:
    d = os.path.join(run, m)
    load = lambda name: json.load(open(os.path.join(d, name))) if os.path.exists(os.path.join(d, name)) else {}
    fail = open(os.path.join(d, "failure")).read().strip() if os.path.exists(os.path.join(d, "failure")) else ""
    if suite == "exec":
        r = load("result.json")
        # Exit 1 is a FAIL verdict; a probe that could not run (exit 2, timeout, a signal) gives none.
        s = r if r.get("verdict") in ("PASS", "FAIL") else {}
        verdict = bool(s) and bool(s.get("ok")) and not fail
        line = "%-4s %-8s exec  %-10s probe=%s exit=%s %s" % (
            m, r.get("os", "?"), "PASS" if verdict else ("FAIL" if s else "NO-VERDICT"), r.get("probe", "-"),
            r.get("exit_code", "-"), fail)
    elif suite == "smoke":
        s = load("result.json")
        verdict = bool(s) and bool(s.get("ok")) and not fail
        line = "%-4s %-8s smoke %-4s failed=%s crashes=%s hang_reports=%s faults=%s %s" % (
            m, s.get("os", "?"), "PASS" if verdict else "FAIL", ",".join(s.get("failed_steps", [])) or "-",
            s.get("crashes", "-"), s.get("hang_reports", "-"), s.get("faults", "-"), fail)
    else:
        s = load("summary.json")
        verdict = bool(s) and not fail and not (s.get("crashes", 0) or s.get("hangs", 0) or s.get("relaunches", 0)
                                                or s.get("guest_lost_at") is not None)
        line = "%-4s %-8s %-5s %-4s steps=%-5s crashes=%-3s hangs=%-3s dead=%-3s faults=%-4s %s" % (
            m, s.get("os", "?"), suite, "PASS" if verdict else "FAIL", s.get("steps", 0), s.get("crashes", 0),
            s.get("hangs", 0), s.get("relaunches", 0), s.get("faults", 0), fail)
    if not s:
        missing.append(m)
    rows[m] = {**s, "suite": suite, "verdict": "PASS" if verdict else "FAIL", "failure": fail}
    bad |= not verdict
    print(line)
json.dump(rows, open(os.path.join(run, "matrix.json"), "w"), indent=2)
print("artifacts:", run)
print("MATRIX VERDICT", "FAIL" if bad else "PASS")
if results:
    # A new file only, never through a link: the run has the account HOME.
    fd = os.open(results, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as out, tarfile.open(fileobj=out, mode="w:gz") as tar:
        for name in sorted(os.listdir(run)):
            if name not in ("build.zip", "askpass.sh"):
                tar.add(os.path.join(run, name), arcname=name)
    print("results:", results)
    # With --results the verdict is data: exit 0 when every major gave one (PASS or FAIL).
    sys.exit(2 if missing else 0)
sys.exit(1 if bad else 0)
PY
