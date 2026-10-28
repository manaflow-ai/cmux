#!/usr/bin/env python3
"""The app-daemon connection's OS-behavior tests inside macOS VMs (chrome-parity p05-ipc task 117).

The connection leans on behavior that can differ by macOS release: a read-only shared mapping and the refusal
of a writable one (the output ring), descriptors over SCM_RIGHTS, QoS classes and their overrides, and
os_unfair_lock's priority inheritance. No fleet Mac runs macOS 14 or 15, so vm.sh (`--suite unit`;
os-matrix.sh `--suite unit[:ROWS]`) runs these rows' tests in each guest. Behavior only: a VM's timing is
not comparable.

Rows (ROWS below):
  output_ring         cmux-ipc output_ring and shm (lib, tests/output_ring.rs); cmux-tui-core output_ring_attach
  fds                 cmux-ipc cmux_ipc_fds (tests/fds.rs, tests/fds_leak.rs)
  qos                 qos in cmux-tui-platform, cmux-threads and cmux-tui-core (and its request_threads)
  pi_mutex            cmux-tui-platform pi_mutex
  shared_output_ring  CmuxNext SharedOutputRingTests (Swift Testing)

The tests come from the runner ref's checkout (vm.sh's tree), not from BUILD: run os-matrix.sh with a --ref
that has them.

  build  on the Tart host, inside a fleet step: the Rust test binaries (cargo test --no-run, macOS 14
         deployment target) and the CmuxNext test bundle (package-test-lane.sh suite, which also runs the
         suite on the host), with the host Xcode's Swift Testing runtime; writes BIN/manifest.json. A part
         that does not build is its row's NO-VERDICT, with its log in BIN/../logs.
  run    for one guest: copy BIN in, run each part there as the guest user with a bound, write
         OUT/result.json and one line per row, then "UNIT VERDICT PASS|FAIL|NO-VERDICT".
The guest has no Xcode: a Swift part runs swiftpm-testing-helper with the host Xcode's testing frameworks in
DYLD_FRAMEWORK_PATH and DYLD_LIBRARY_PATH, as `swift test` runs it (scripts/ci/run_swift_test_bundle.py).

A part PASSes when its process exits 0 and ran at least one test; it FAILs on a failed test or a crash in a
test; anything else (no build, no test matched, a timeout, an SSH failure, a runtime that did not load) is
NO-VERDICT. A row is the worst of its parts, a major the worst of its rows (FAIL, then NO-VERDICT).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Cargo:
    """`cargo test -p PACKAGE TARGETS --no-run`, each test binary then run with FILTERS."""

    package: str
    targets: tuple[str, ...]
    filters: tuple[str, ...]


@dataclass(frozen=True)
class Swift:
    """The test bundle of PACKAGE (a repo-relative SwiftPM package), run with --filter FILTER."""

    package: str
    target: str
    filter: str


ROWS: dict[str, tuple[Cargo | Swift, ...]] = {
    "output_ring": (Cargo("cmux-ipc", ("--lib", "--test", "output_ring"), ("output_ring", "shm")),
                    Cargo("cmux-tui-core", ("--lib",), ("output_ring_attach",))),
    "fds": (Cargo("cmux-ipc", ("--test", "fds", "--test", "fds_leak"), ("cmux_ipc_fds",)),),
    "qos": (Cargo("cmux-tui-platform", ("--lib",), ("qos",)),
            Cargo("cmux-threads", ("--lib",), ("qos",)),
            Cargo("cmux-tui-core", ("--lib",), ("qos", "request_threads"))),
    "pi_mutex": (Cargo("cmux-tui-platform", ("--lib",), ("pi_mutex",)),),
    "shared_output_ring": (Swift("Packages/macOS/CmuxNext", "CmuxNextIPCTests", "SharedOutputRingTests"),),
}

CARGO_SECONDS = 2400  # one cargo test --no-run; the first one builds cmux-tui-core and libghostty-vt
SWIFT_SECONDS = 3600  # package-test-lane.sh suite: the CmuxNext test build and the host's suite run
PART_SECONDS = 600  # one test process in the guest
GUEST_DIR = "unit"  # under the guest user's home
VERDICTS = ("PASS", "NO-VERDICT", "FAIL")  # worst last

# Runs ARGV in its own process group and kills the group past SECONDS (exit 124); a signal is 128 + N.
# The guest has no coreutils timeout (vm.sh's exec suite bounds its probe the same way).
GUEST_BOUND = ('my $s = shift; my $pid = fork; if (!$pid) { setpgrp(0, 0); exec @ARGV; exit 127 } '
               'my $ok = eval { local $SIG{ALRM} = sub { die "t\\n" }; alarm $s; waitpid($pid, 0); alarm 0; 1 }; '
               'if (!$ok) { kill 9, -$pid; waitpid($pid, 0); exit 124 } exit($? & 127 ? 128 + ($? & 127) : $? >> 8)')


def parse_rows(text: str) -> list[str]:
    """The rows a --rows value names, in table order; "" or "all" is every row. Raises ValueError."""
    if text in ("", "all"):
        return list(ROWS)
    names = text.split(",")
    unknown = [n for n in names if n not in ROWS]
    if unknown or len(set(names)) != len(names):
        raise ValueError("--rows takes distinct names from %s (got %s)" % (",".join(ROWS), text))
    return [n for n in ROWS if n in names]


def worst(verdicts: list[str]) -> str:
    """FAIL over NO-VERDICT over PASS; nothing at all is NO-VERDICT."""
    return max(verdicts, key=VERDICTS.index) if verdicts else "NO-VERDICT"


# --- build (Tart host) ---------------------------------------------------------------------------------------

def bounded(cmd: list[str], seconds: int, log: Path, stdout: Path | None = None, **kw) -> int:
    """Runs CMD with stderr (and stdout, unless STDOUT names its own file) in LOG; kills its whole process
    group past SECONDS (124). A command that cannot start is 127."""
    with open(log, "ab") as err, open(stdout or os.devnull, "wb") as own:
        try:
            proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=own if stdout else err,
                                    stderr=err if stdout else subprocess.STDOUT, start_new_session=True, **kw)
        except OSError as error:
            err.write(b"unit.py: %s did not start: %s\n" % (cmd[0].encode(), str(error).encode()))
            return 127
        try:
            return proc.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            err.write(b"\nunit.py: killed after %d s\n" % seconds)
            return 124


def test_executables(cargo_json: str) -> list[str]:
    """The test binaries of `cargo test --no-run --message-format=json` output, in build order."""
    found = []
    for line in cargo_json.splitlines():
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if (isinstance(msg, dict) and msg.get("reason") == "compiler-artifact"
                and (msg.get("profile") or {}).get("test") and msg.get("executable")
                and msg["executable"] not in found):
            found.append(msg["executable"])
    return found


class Builder:
    def __init__(self, root: Path, out: Path):
        self.root, self.bin, self.logs = root, out / "bin", out / "logs"
        self.target_dir = out / "cargo-target"
        self.bin.mkdir(parents=True)
        self.logs.mkdir()
        self.cargo_env: dict[str, str] | None = None
        self.copied: dict[str, str] = {}  # host executable -> its name in bin/rust
        self.developer = ""  # the selected Xcode, once its Swift Testing runtime is in bin

    def rust(self) -> dict[str, str]:
        """cargo's environment: rust-toolchain.toml's toolchain, ghostty-next for libghostty-vt. Raises OSError."""
        if self.cargo_env is not None:
            return self.cargo_env
        log = self.logs / "rust-setup.log"
        # The step's checkout has empty submodules (scripts/ci/cmux-tui-rust-check.sh does the same).
        if not (self.root / "ghostty-next" / "build.zig").is_file():
            if bounded(["git", "-C", str(self.root), "submodule", "update", "--init", "--depth", "1", "ghostty-next"],
                       600, log) != 0:
                raise OSError("git submodule update --init ghostty-next failed (logs/rust-setup.log)")
        rustup = shutil.which("rustup") or str(Path.home() / ".cargo/bin/rustup")
        # Installs rust-toolchain.toml's toolchain when the host lacks it; `which` below says if that failed.
        bounded([rustup, "toolchain", "install"], 900, log, cwd=self.root / "cmux-tui")
        try:
            cargo = subprocess.run([rustup, "which", "cargo"], cwd=self.root / "cmux-tui", capture_output=True,
                                   text=True, timeout=900, stdin=subprocess.DEVNULL, check=True).stdout.strip()
        except (OSError, subprocess.SubprocessError) as error:
            raise OSError("no Rust toolchain: rustup which cargo failed (%s)" % error) from error
        env = dict(os.environ, CARGO_TARGET_DIR=str(self.target_dir), MACOSX_DEPLOYMENT_TARGET="14.0")
        env["PATH"] = os.path.dirname(cargo) + os.pathsep + env.get("PATH", "")
        self.cargo_env = env
        return env

    def cargo(self, row: str, index: int, part: Cargo) -> list[dict]:
        label = "%s %s" % (part.package, " ".join(part.targets))
        log = self.logs / ("%s-%d-cargo.log" % (row, index))
        try:
            env = self.rust()
        except OSError as error:
            return [{"kind": "rust", "label": label, "error": str(error)}]
        cmd = ["cargo", "test", "--locked", "--no-run", "--message-format=json-render-diagnostics",
               "-p", part.package, *part.targets]
        json_path = self.logs / ("%s-%d-cargo.json" % (row, index))
        rc = bounded(cmd, CARGO_SECONDS, log, stdout=json_path, cwd=self.root / "cmux-tui", env=env)
        executables = test_executables(json_path.read_text(errors="replace"))
        if rc != 0 or not executables:
            why = "cargo test --no-run exit %d, %d test binaries (logs/%s)" % (rc, len(executables), log.name)
            return [{"kind": "rust", "label": label, "error": why}]
        parts = []
        for exe in executables:
            name = self.copied.get(exe)
            if name is None:
                name = "rust/%s" % os.path.basename(exe)
                (self.bin / "rust").mkdir(exist_ok=True)
                shutil.copy2(exe, self.bin / name)
                self.copied[exe] = name
            parts.append({"kind": "rust", "label": "%s %s" % (part.package, os.path.basename(exe)),
                          "path": name, "args": list(part.filters)})
        return parts

    def swift(self, row: str, index: int, part: Swift) -> list[dict]:
        label = "%s %s" % (part.target, part.filter)
        log = self.logs / ("%s-%d-swift.log" % (row, index))
        env = dict(os.environ)
        try:
            developer = self.xcode(env)
        except OSError as error:
            return [{"kind": "swift", "label": label, "error": str(error)}]
        env["DEVELOPER_DIR"] = developer
        # The lane's focused gate: its Xcode, GhosttyKit and web bundles, one test build, then the suite on the host.
        started = time.time()
        host_rc = bounded(["bash", "scripts/ci/package-test-lane.sh", "suite", part.package, part.filter],
                          SWIFT_SECONDS, log, cwd=self.root, env=env)
        built = self.root / part.package / ".build" / "debug"
        # SwiftPM 6.4 builds a bundle per test target; 6.3 one <Package>PackageTests bundle.
        bundles = [built / ("%s.xctest" % part.target)] + sorted(built.glob("*PackageTests.xctest"))
        # Only a bundle this build linked: a warm checkout can hold an older one.
        bundle = next((b for b in bundles if (b / "Contents" / "MacOS" / b.stem).is_file()
                       and (b / "Contents" / "MacOS" / b.stem).stat().st_mtime >= started), None)
        if bundle is None:
            return [{"kind": "swift", "label": label, "error": "no test bundle built in %s, package-test-lane.sh "
                     "exit %d (logs/%s)" % (built, host_rc, log.name)}]
        dest = self.bin / "swift" / "debug"
        dest.mkdir(parents=True, exist_ok=True)
        if not (dest / bundle.name).exists():
            shutil.copytree(bundle, dest / bundle.name, symlinks=True)
            # The bundle's @rpath next to it: the package's dynamic frameworks and libraries (no resources).
            for item in sorted(built.iterdir()):
                if item.suffix in (".framework", ".dylib") and not (dest / item.name).exists():
                    (shutil.copytree(item, dest / item.name, symlinks=True) if item.is_dir() and not item.is_symlink()
                     else shutil.copy2(item, dest / item.name, follow_symlinks=True))
        binary = "swift/debug/%s/Contents/MacOS/%s" % (bundle.name, bundle.stem)
        return [{"kind": "swift", "label": label, "path": binary, "filter": part.filter, "host_exit": host_rc}]

    def xcode(self, env: dict[str, str]) -> str:
        """Selects the CI Xcode (scripts/select-ci-xcode.sh) and copies its Swift Testing runtime into bin, once."""
        if self.developer:
            return self.developer
        log = self.logs / "xcode.log"
        env_file = self.logs / "xcode.env"
        env_file.write_text("")
        if bounded(["bash", "scripts/select-ci-xcode.sh"], 120, log, cwd=self.root,
                   env=dict(env, GITHUB_ENV=str(env_file), CMUX_CI_SKIP_XCODE_SELECT="1")) != 0:
            raise OSError("scripts/select-ci-xcode.sh failed (logs/xcode.log)")
        found = re.findall(r"^DEVELOPER_DIR=(.+)$", env_file.read_text(), re.M)
        if not found:
            raise OSError("scripts/select-ci-xcode.sh named no DEVELOPER_DIR (logs/xcode.log)")
        xenv = dict(env, DEVELOPER_DIR=found[-1])
        xenv.pop("SDKROOT", None)
        try:
            platform = Path(subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-platform-path"], env=xenv,
                                           capture_output=True, text=True, check=True, timeout=60).stdout.strip())
            swift_test = subprocess.run(["xcrun", "--find", "swift-test"], env=xenv, capture_output=True, text=True,
                                        check=True, timeout=60).stdout.strip()
        except (OSError, subprocess.SubprocessError) as error:
            raise OSError("xcrun could not find the macOS platform or swift-test: %s" % error) from error
        helper = Path(swift_test).parent.parent / "libexec" / "swift" / "pm" / "swiftpm-testing-helper"
        developer = platform / "Developer"
        sources = {"Frameworks": developer / "Library" / "Frameworks",
                   "PrivateFrameworks": developer / "Library" / "PrivateFrameworks", "lib": developer / "usr" / "lib"}
        if not helper.is_file() or not sources["Frameworks"].is_dir():
            raise OSError("no swiftpm-testing-helper or Swift Testing frameworks in %s" % found[-1])
        runtime = self.bin / "swift" / "runtime"
        runtime.mkdir(parents=True)
        for name, source in sources.items():
            if source.is_dir():
                shutil.copytree(source, runtime / name, symlinks=True)
        shutil.copy2(helper, runtime / helper.name)
        self.developer = found[-1]
        return self.developer

    def build(self, rows: list[str]) -> dict:
        manifest = {"runner_ref": os.environ.get("CMUX_CI_SOURCE_DIGEST", "unknown"), "rows": {}}
        for row in rows:
            parts = []
            for index, part in enumerate(ROWS[row]):
                parts += self.cargo(row, index, part) if isinstance(part, Cargo) else self.swift(row, index, part)
            manifest["rows"][row] = parts
        (self.bin / "manifest.json").write_text(json.dumps(manifest, indent=1))
        return manifest


# --- run (one guest) -----------------------------------------------------------------------------------------

def guest_command(part: dict) -> str:
    """The shell command that runs PART in the guest, from the copied folder, under the bound."""
    if part["kind"] == "rust":
        argv, env = ["./" + part["path"], *part["args"]], []
    else:
        runtime = "$HOME/%s/swift/runtime" % GUEST_DIR
        env = ['DYLD_FRAMEWORK_PATH="%s/Frameworks:%s/PrivateFrameworks"' % (runtime, runtime),
               'DYLD_LIBRARY_PATH="%s/lib"' % runtime]
        binary = "./" + part["path"]
        argv = ["./swift/runtime/swiftpm-testing-helper", "--test-bundle-path", binary, "--filter", part["filter"],
                binary, "--testing-library", "swift-testing"]
    run = " ".join(shlex.quote(a) for a in ["/usr/bin/perl", "-e", GUEST_BOUND, str(PART_SECONDS), *argv])
    return 'cd "$HOME/%s" || exit 3; %s%s' % (GUEST_DIR, "".join(e + " " for e in env), run)


RUST_RESULT = re.compile(r"^test result: (?:ok|FAILED)\. (\d+) passed; (\d+) failed", re.M)
SWIFT_RESULT = re.compile(r"Test run with (\d+) tests?\b.* (passed|failed)")


def judge(kind: str, rc: int, output: str) -> tuple[str, int, int, str]:
    """(verdict, passed, failed, why) of one part's exit status and output."""
    if rc == 124:
        return "NO-VERDICT", 0, 0, "timed out after %d s (VM)" % PART_SECONDS
    if rc == 255:
        return "NO-VERDICT", 0, 0, "ssh failed"
    if kind == "rust":
        counts = [(int(p), int(f)) for p, f in RUST_RESULT.findall(output)]
        passed, failed = sum(p for p, _ in counts), sum(f for _, f in counts)
        started = bool(counts) or "\nrunning " in "\n" + output
    else:
        if "dyld[" in output and "Test run started" not in output:
            return "NO-VERDICT", 0, 0, "the Swift Testing runtime did not load in the guest"
        runs = SWIFT_RESULT.findall(output)
        passed = sum(int(n) for n, word in runs if word == "passed")
        failed = sum(int(n) for n, word in runs if word == "failed")
        started = bool(runs) or "Test run started" in output
    if failed or (rc == 101 and kind == "rust") or (rc == 1 and kind == "swift" and started):
        return "FAIL", passed, failed, "a test failed"
    if rc > 128 and started:
        return "FAIL", passed, failed, "crashed with signal %d" % (rc - 128)
    if rc == 0 and passed:
        return "PASS", passed, failed, ""
    if rc == 0:
        return "NO-VERDICT", 0, 0, "no test matched"
    return "NO-VERDICT", passed, failed, "exit %d before a test ran" % rc


def run(target: str, ssh_opts: list[str], bin_dir: Path, out: Path) -> int:
    base = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=6", *ssh_opts, target]

    def sh(cmd: str, timeout: float, **kw) -> subprocess.CompletedProcess:
        try:
            return subprocess.run(base + [cmd], capture_output=True, timeout=timeout, **kw)
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess(base, 124, b"", b"host-side timeout")

    manifest = json.loads((bin_dir / "manifest.json").read_text())
    out.mkdir(parents=True, exist_ok=True)
    # Streamed through tar, which keeps the frameworks' symlinks (scp -r would copy them as files).
    tar = subprocess.Popen(["tar", "-C", str(bin_dir), "-cf", "-", "."], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE)
    copied = sh('rm -rf "$HOME/%s" && mkdir "$HOME/%s" && tar -C "$HOME/%s" -xf -' % ((GUEST_DIR,) * 3), 1800,
                stdin=tar.stdout)
    tar.stdout.close()
    if tar.wait() != 0 and copied.returncode == 0:
        copied = subprocess.CompletedProcess(base, 1, b"", b"tar of the build's bin folder failed")
    osv = sh("sw_vers -productVersion", 30, stdin=subprocess.DEVNULL).stdout.decode(errors="replace").strip()
    build = sh("sw_vers -buildVersion", 30, stdin=subprocess.DEVNULL).stdout.decode(errors="replace").strip()
    rows = []
    for row, parts in manifest["rows"].items():
        judged = []
        for index, part in enumerate(parts):
            entry = {"label": part["label"], "kind": part["kind"]}
            if "host_exit" in part:  # the suite's own run on the Tart host (package-test-lane.sh)
                entry["host_exit"] = part["host_exit"]
            if "error" in part:
                entry.update(verdict="NO-VERDICT", detail="not built: " + part["error"])
            elif copied.returncode != 0:
                entry.update(verdict="NO-VERDICT", detail="copy into the guest failed: %s"
                             % copied.stderr.decode(errors="replace").strip()[-300:])
            else:
                proc = sh(guest_command(part), PART_SECONDS + 120, stdin=subprocess.DEVNULL)
                text = proc.stdout.decode(errors="replace") + proc.stderr.decode(errors="replace")
                log = "%s-%d.log" % (row, index)
                (out / log).write_text(text)
                verdict, passed, failed, why = judge(part["kind"], proc.returncode, text)
                entry.update(verdict=verdict, exit_code=proc.returncode, passed=passed, failed=failed, detail=why,
                             log=log)
            judged.append(entry)
        verdict = worst([p["verdict"] for p in judged])
        rows.append({"row": row, "verdict": verdict, "parts": judged})
        details = "; ".join("%s %s%s" % (p["label"], p["verdict"], " (%s)" % p["detail"] if p.get("detail") else "")
                            for p in judged if p["verdict"] != "PASS")
        print("%-20s %-10s passed=%d %s" % (row, verdict, sum(p.get("passed", 0) for p in judged), details)[:400])
    verdict = worst([r["verdict"] for r in rows])
    result = {"suite": "unit", "os": osv, "build": build, "runner_ref": manifest.get("runner_ref"),
              "verdict": verdict, "ok": verdict == "PASS", "rows": rows,
              "failed_steps": [r["row"] for r in rows if r["verdict"] != "PASS"]}
    (out / "result.json").write_text(json.dumps(result, indent=1))
    print("UNIT VERDICT %s os=%s" % (verdict, osv))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    sub = parser.add_subparsers(dest="phase", required=True)
    check = sub.add_parser("check-rows", help="exit 0 when ROWS names rows of the table")
    check.add_argument("rows")
    b = sub.add_parser("build", help="build the rows' tests on the Tart host")
    b.add_argument("--repo", required=True, type=Path, help="the runner ref's checkout")
    b.add_argument("--rows", default="all")
    b.add_argument("--out", required=True, type=Path, help="a new folder")
    r = sub.add_parser("run", help="run the built rows in one guest")
    r.add_argument("--ssh", required=True, help="USER@IP of the guest")
    r.add_argument("--ssh-opt", action="append", default=[])
    r.add_argument("--bin", required=True, type=Path, help="the build's bin folder")
    r.add_argument("--out", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        rows = parse_rows(args.rows) if args.phase in ("check-rows", "build") else []
    except ValueError as error:
        print(error, file=sys.stderr)
        return 2
    if args.phase == "check-rows":
        return 0
    if args.phase == "build":
        # cargo and swift build run on the fleet only (CLAUDE.md: never on a person's Mac).
        if not os.environ.get("CMUX_CI_STEP_KEY"):
            print("unit.py build compiles and runs only in a fleet step (os-matrix.sh --suite unit)", file=sys.stderr)
            return 2
        if args.out.exists():
            print("--out %s exists" % args.out, file=sys.stderr)
            return 2
        manifest = Builder(args.repo.resolve(), args.out).build(rows)
        for row, parts in manifest["rows"].items():
            for part in parts:
                print("%-20s %-6s %s %s" % (row, part["kind"], part["label"], part.get("error", "built")))
        return 0
    return run(args.ssh, args.ssh_opt, args.bin, args.out)


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    raise SystemExit(main())
