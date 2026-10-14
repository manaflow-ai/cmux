#!/usr/bin/env bash
# check-no-process-scan.py (NO-PROCESS-SCAN, plans/cmux-next/pty-holder.md):
# a new process-scanning call fails, calls on this process or a held child
# pass, the baseline admits listed sites only and ratchets down.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-no-process-scan.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-no-process-scan.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Runs the guard on a repo root whose only source is $2 at path $1 and whose
# baseline is $3 (may be empty).
check() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/$(dirname "$1")" "$tmp/repo/scripts/cmux-next"
  printf '%s\n' "$2" > "$tmp/repo/$1"
  printf '%b' "${3:-}" > "$tmp/repo/scripts/cmux-next/process-scan-baseline.tsv"
  local code=0
  python3 -I "$CHECK" "$tmp/repo" >/dev/null 2>"$tmp/err" || code=$?
  # 0 = clean; 1 = a finding that names the file; anything else is a crash.
  if [[ $code -eq 1 ]] && ! grep -q "${4:-$1}" "$tmp/err"; then code=3; fi
  return "$code"
}
RS=cmux-tui/crates/fixture/src/lib.rs
SW=Packages/macOS/CmuxNext/Sources/Fixture/Fixture.swift
pass() { check "$1" "$3" "${4:-}" || { echo "FAIL: must pass: $2" >&2; exit 1; }; }
fail() {
  local code=0
  check "$1" "$3" "${4:-}" || code=$?
  [[ $code -eq 1 ]] || { echo "FAIL: must fail with a finding (got $code): $2" >&2; cat "$tmp/err" >&2; exit 1; }
}

fail "$RS" "spawning ps" '    let out = std::process::Command::new("ps").args(["-A"]).output();'
fail "$RS" "spawning /bin/ps" '    let out = Command::new("/bin/ps").output();'
fail "$RS" "spawning lsof" '    Command::new("lsof").arg("-p")'
fail "$RS" "spawning pgrep" '    Command::new("pgrep").arg("claude")'
fail "$RS" "listing every pid" '    unsafe { libc::proc_listpids(PROC_ALL_PIDS, 0, ptr, 0) };'
fail "$RS" "listing children" '    unsafe { libc::proc_listchildpids(pid, ptr, 0) };'
fail "$RS" "reading a foreign argv" '    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];'
fail "$RS" "a foreign executable path" '    libc::proc_pidpath(pid, buf, len)'
fail "$RS" "a foreign cmdline" '    std::fs::read(format!("/proc/{pid}/cmdline"))'
fail "$RS" "walking /proc" '    let entries = fs::read_dir("/proc")?;'
fail "$RS" "a Toolhelp process snapshot" '    CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)'
fail "$RS" "the sysinfo crate" '    let sys = sysinfo::System::new_all();'
fail "$SW" "Swift proc_listpids" '        let n = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)'
fail "$SW" "running applications" '        let apps = NSWorkspace.shared.runningApplications'
fail "$RS" "ps through env" '    Command::new("/usr/bin/env").arg("ps")'
fail "$RS" "ps through sh" '    Command::new("sh").args(["-c", "ps -ax"])'
fail "$RS" "ps by any path" '    Command::new("/opt/homebrew/bin/pgrep")'
fail "$RS" "ps as a const" '    const PS: &str = "ps";'
fail "$RS" "walking /proc/" '    let entries = fs::read_dir("/proc/")?;'
fail "$RS" "walking Path /proc" '    let entries = fs::read_dir(Path::new("/proc"))?;'
fail "$RS" "K32EnumProcesses" '    K32EnumProcesses(ptr, size, &mut needed)'
fail "$RS" "WTS process list" '    WTSEnumerateProcessesW(server, 0, 1, &mut list, &mut count)'
fail "$RS" "the libproc crate" '    let pids = libproc::processes::pids_by_type(filter);'
fail "$RS" "a parent walk" '    let parent = info.pbi_ppid;'
fail "$SW" "Swift ps arguments" '        task.arguments = ["ps", "-ax"]'
fail "$SW" "Swift ps executable" '        task.executableURL = URL(fileURLWithPath: "/bin/ps")'
fail "$SW" "a sysctl parent walk" '        return info.kp_eproc.e_ppid'
fail "$RS" "a code line that starts with a star" '    *out = libc::proc_pidpath(pid, buf, len);'
fail cmux-tui/crates/fixture/Cargo.toml "a process-listing crate" 'sysinfo = "0.30"'
pass "$RS" "this process's fds" '    for d in ["/proc/self/fd", "/dev/fd"] {}'
pass "$RS" "waiting on a held child" '    libc::waitpid(child, &mut status, libc::WNOHANG)'
pass "$RS" "the foreground group of a held PTY" '    libc::tcgetpgrp(master_fd)'
pass "$RS" "a comment" '    // never call proc_listpids here'
pass "$RS" "a block comment line" '     * proc_listpids is banned here'
pass cmux-tui/crates/fixture/Cargo.toml "an ordinary crate" 'serde = "1"'
pass "$SW" "start time of this process" '        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]'
pass "$RS" "a baselined site" '    Command::new("ps").output()' "$RS\t1\tremove\tcx-test\n"
fail "$RS" "a second site past the baseline" '    Command::new("ps").output(); Command::new("lsof").output()
    Command::new("pgrep").output()' "$RS\t1\tremove\tcx-test\n"
fail "$RS" "a removed site with a stale baseline" '    let x = 1;' "$RS\t1\tremove\tcx-test\n"
code=0; check "$RS" '    Command::new("ps").output()' "$RS\t1\tmaybe\tcx-test\n" || code=$?
[[ $code -eq 2 ]] || { echo "FAIL: a bad baseline class must exit 2 (got $code)" >&2; exit 1; }
# Test files are not product code.
check cmux-tui/crates/fixture/tests/it.rs '    Command::new("ps").output()' "" \
  || { echo "FAIL: must pass: an integration test" >&2; exit 1; }
echo "check-no-process-scan.test: ok"
