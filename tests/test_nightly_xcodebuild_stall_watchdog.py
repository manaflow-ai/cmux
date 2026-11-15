#!/usr/bin/env python3
"""The nightly Release build's stall watchdog keeps the build service's stacks and ends only its own processes.

Nightly run 43673773157 (2026-11-15, the signer Mac): Xcode 26.6's build service deadlocked in libSwiftDriver while
planning an explicit-module build (every llbuild lane in LibSwiftDriver.createAndPlan, in dispatch_sync ->
__ulock_wait), SWBBuildService's CPU time frozen at 2:40.45, xcodebuild.log silent from ~1 minute into the step,
for 2.5 hours. run-xcodebuild-with-diagnostics.sh now ends a build like that with status 124 (#43568). This test
pins what the step needs on top of that, with a fake xcodebuild that writes a few lines, starts a fake
SWBBuildService whose CPU time never moves, and hangs:

  - before ending the build, the wrapper runs `sample <SWBBuildService pid> 5 -file F` into the stall
    directory, and its error names F, so a deadlock leaves the stacks that diagnose it;
  - it ends only the processes this build started: an SWBBuildService outside the build's tree (another
    job's, or Xcode's own) lives on;
  - app-build-release.sh retries a stalled build once with a new build service; a second stall fails the
    step with an error that names the sample files.

The stall window is shrunk with CMUX_XCODEBUILD_STALL_SECONDS so the test takes seconds. Run it by hand
after changing the wrapper or the Release step: python3 tests/test_nightly_xcodebuild_stall_watchdog.py
"""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "scripts/ci/run-xcodebuild-with-diagnostics.sh"
STEP = ROOT / "scripts/ci/nightly-steps/app-build-release.sh"

# A build service that never uses CPU: an idle sleep, under the name the wrapper looks for in its own tree.
FAKE_BUILD_SERVICE = "#!/usr/bin/env python3\nimport time\ntime.sleep(600)\n"

# A stand-in for macOS `sample PID SECONDS -file FILE`: records what it was asked to sample.
FAKE_SAMPLE = """#!/usr/bin/env bash
pid="$1"; seconds="$2"; shift 2
[[ "$1" == -file ]] || { echo "fake sample: expected -file, got $*" >&2; exit 2; }
{
  echo "Analysis of sampling pid $pid every 1 millisecond for $seconds seconds"
  echo "Command: $(ps -o args= -p "$pid")"
  echo "Sort by top of stack, same collapsed (when >= 5):"
  echo "        __ulock_wait  (in libsystem_kernel.dylib)        3900"
} >"$2"
"""

# The fake xcodebuild: a few log lines as run 43673773157's last ones, then the build service, then nothing.
# A build in a directory holding "succeed-on" finishes on that attempt instead.
FAKE_XCODEBUILD = """#!/usr/bin/env bash
dir="$(cd "$(dirname "$0")" && pwd)"
attempt=0; [[ -f "$dir/attempts" ]] && attempt="$(cat "$dir/attempts")"; attempt=$((attempt + 1))
echo "$attempt" >"$dir/attempts"
echo "SwiftDriverJobDiscovery normal arm64 Emitting module for CmuxHomeRender (in target 'CmuxHomeRender')"
echo "SwiftDriver MessagesLabHome normal arm64 com.apple.xcode.tools.swift.compiler (in target 'MessagesLabHome')"
echo "    builtin-SwiftDriver -- swiftc -module-name MessagesLabHome -Osize -explicit-module-build -cache-compile-job"
if [[ -f "$dir/succeed-on" && "$(cat "$dir/succeed-on")" == "$attempt" ]]; then
  echo "** BUILD SUCCEEDED **"
  exit 0
fi
"$dir/service/SWBBuildService" &
echo "$!" >>"$dir/service-pids"
wait
"""


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # A zombie still answers kill 0; it has ended all the same.
    state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], text=True, capture_output=True).stdout.strip()
    return bool(state) and not state.startswith("Z")


class StallWatchdogTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory(prefix="stall-watchdog-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.bin = self.root / "bin"
        (self.bin / "service").mkdir(parents=True)
        for path, text in ((self.bin / "service/SWBBuildService", FAKE_BUILD_SERVICE),
                           (self.bin / "sample", FAKE_SAMPLE),
                           (self.bin / "xcodebuild", FAKE_XCODEBUILD)):
            path.write_text(text)
            path.chmod(0o755)
        self.stall_dir = self.root / "stall"
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "CMUX_XCODEBUILD_HEARTBEAT_SECONDS": "0.2",
            "CMUX_XCODEBUILD_STALL_SECONDS": "2",
            "CMUX_XCODEBUILD_STALL_DIR": str(self.stall_dir),
            "RUNNER_TEMP": str(self.root),
            "TMPDIR": str(self.root),
        }
        # Another SWBBuildService on the host, not started by this build: the watchdog must leave it alone.
        self.decoy = subprocess.Popen([str(self.bin / "service/SWBBuildService")], start_new_session=True)
        self.addCleanup(self._end_decoy)
        self.addCleanup(self._end_build_services)

    def _end_decoy(self) -> None:
        if self.decoy.poll() is None:
            self.decoy.kill()
        self.decoy.wait()

    def _end_build_services(self) -> None:
        # Only the fake services this test's builds started, by the pids they recorded.
        for pid in self._service_pids():
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def _service_pids(self) -> list[int]:
        path = self.bin / "service-pids"
        return [int(line) for line in path.read_text().split()] if path.exists() else []

    def _samples(self) -> list[Path]:
        return sorted(self.stall_dir.glob("*.sample.txt")) if self.stall_dir.exists() else []

    def test_a_stalled_build_is_sampled_then_only_its_own_processes_end(self) -> None:
        result = subprocess.run(
            [str(WRAPPER), "--", "env", "CMUX_NEXT_TUI_MODE=deferred", str(self.bin / "xcodebuild"), "build"],
            env=self.env, text=True, capture_output=True, timeout=120,
        )
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 124, output)
        services = self._service_pids()
        self.assertEqual(len(services), 1, output)
        samples = self._samples()
        self.assertEqual(len(samples), 1, f"one sample of the stalled build service is kept:\n{output}")
        sample = samples[0].read_text()
        self.assertIn(f"sampling pid {services[0]} every 1 millisecond for 5 seconds", sample)
        self.assertIn("SWBBuildService", sample)
        error = next((line for line in output.splitlines() if line.startswith("::error::xcodebuild stalled")), "")
        self.assertIn(str(samples[0]), error, f"the stall's error names the sample file:\n{output}")
        self.assertIn("__ulock_wait", output, "the sample's top of stack reaches the step log")
        self.assertFalse(alive(services[0]), "the stalled build's own SWBBuildService is ended")
        self.assertTrue(alive(self.decoy.pid), "an SWBBuildService this build did not start is left running")

    def _release_step_root(self) -> Path:
        """A tree with the Release step's scripts (the real wrapper among them) and nothing to resolve."""
        work = self.root / "work"
        for rel in ("scripts/ci/nightly-steps/app-build-release.sh",
                    "scripts/ci/nightly-steps/app-host-build-root.sh",
                    "scripts/ci/nightly-steps/release-build-summary.sh",
                    "scripts/ci/run-xcodebuild-with-diagnostics.sh",
                    "scripts/ci/timeout.sh",
                    "scripts/ci/fleet-compilation-cache.sh",
                    "scripts/ci/spm_artifact_preflight.py",
                    "scripts/cmux-next/lib/compilation-cache.sh"):
            (work / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / rel, work / rel)
        (work / "scripts/ci/run-with-helper-prebuild.py").write_text(
            "import os,sys\na=sys.argv[sys.argv.index('--')+1:]\nos.execvp(a[0],a)\n")
        return work

    def _run_release_step(self) -> subprocess.CompletedProcess[str]:
        work = self._release_step_root()
        env = {**self.env, "IMPORT_VARIANT": "default", "SWIFT_IMPORT_FLAGS": "", "EMPTY_BROWSER_SOURCES": "false",
               "BUILD_TRACK": "", "NIGHTLY_COMPILE_ARCHS": "arm64", "DECIDE_COLD_CACHE_DISABLE": "1",
               "CHANNEL_ICON_NAME": "AppIcon-Nightly", "CMUX_CI_DISABLE_COMPILATION_CACHE": "1"}
        env.pop("RUNNER_TRACKING_ID", None)
        return subprocess.run(["bash", str(work / STEP.relative_to(ROOT))], cwd=work, env=env, text=True,
                              capture_output=True, timeout=240)

    def test_the_release_step_retries_a_stall_once_with_a_new_build_service(self) -> None:
        (self.bin / "succeed-on").write_text("2")
        result = self._run_release_step()
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertEqual((self.bin / "attempts").read_text().strip(), "2", output)
        self.assertIn("the Release build stalled", output)
        self.assertEqual(len(self._samples()), 1, output)
        self.assertTrue(all(not alive(pid) for pid in self._service_pids()))
        self.assertTrue(alive(self.decoy.pid))

    def test_a_second_stall_fails_the_step_naming_the_sample_files(self) -> None:
        result = self._run_release_step()
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 124, output)
        self.assertEqual((self.bin / "attempts").read_text().strip(), "2", "a stall is retried once, never twice")
        samples = self._samples()
        self.assertEqual(len(samples), 2, output)
        final = [line for line in output.splitlines() if line.startswith("::error::the Release build stalled again")]
        self.assertTrue(final, f"the step's own error says the retry stalled too:\n{output}")
        for sample in samples:
            self.assertIn(str(sample), final[-1])
        self.assertTrue(all(not alive(pid) for pid in self._service_pids()))
        self.assertTrue(alive(self.decoy.pid))


if __name__ == "__main__":
    unittest.main()
