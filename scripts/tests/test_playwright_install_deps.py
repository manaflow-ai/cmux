"""playwright-install-deps.sh repairs a runner's broken apt state once, and leaves any other red alone."""

import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci/playwright-install-deps.sh"


def stub(dir_: pathlib.Path, name: str, body: str) -> None:
    path = dir_ / name
    path.write_text("#!/usr/bin/env bash\n" + body + "\n")
    path.chmod(0o755)


class PlaywrightInstallDepsTest(unittest.TestCase):
    def run_with(self, failures: list[str]) -> tuple[subprocess.CompletedProcess, list[str]]:
        tmp = pathlib.Path(tempfile.mkdtemp())
        calls = tmp / "calls"
        state = tmp / "n"
        state.write_text("0")
        # Each install call prints the next scripted failure, or succeeds once the script runs out.
        outs = tmp / "outs"
        outs.write_text("\n".join(failures))
        stub(tmp, "playwright", f"""echo "playwright $*" >> {calls}
n=$(cat {state}); echo $((n+1)) > {state}
line=$(sed -n "$((n+1))p" {outs})
if [ -n "$line" ]; then echo "$line"; exit 1; fi
exit 0""")
        for tool in ("dpkg", "apt-get", "fuser"):
            stub(tmp, tool, f'echo "{tool} $*" >> {calls}; [ {tool} = fuser ] && exit 1; exit 0')
        stub(tmp, "sudo", 'if [ "$1" = -n ]; then shift; fi; [ "$1" = true ] && exit 0; "$@"')
        env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}", PLAYWRIGHT_CLI=str(tmp / "playwright"))
        proc = subprocess.run([str(SCRIPT), "webkit"], env=env, capture_output=True, text=True)
        return proc, calls.read_text().splitlines() if calls.exists() else []

    def test_pass_first_time_touches_nothing(self):
        proc, calls = self.run_with([])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(calls, ["playwright install --with-deps webkit"])

    def test_broken_apt_is_repaired_and_retried(self):
        proc, calls = self.run_with(["E: Unmet dependencies. Try 'apt --fix-broken install'"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("dpkg --configure -a", calls)
        self.assertIn("apt-get -f install -y", calls)
        self.assertIn("apt-get update", calls)
        self.assertEqual(calls.count("playwright install --with-deps webkit"), 2)
        self.assertIn("broken", proc.stderr)

    def test_other_failure_is_not_retried(self):
        proc, calls = self.run_with(["Error: browserType.launch: something else"])
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(calls, ["playwright install --with-deps webkit"])

    def test_second_apt_failure_stays_red(self):
        proc, calls = self.run_with(["E: Unmet dependencies.", "E: Unmet dependencies."])
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(calls.count("playwright install --with-deps webkit"), 2)


if __name__ == "__main__":
    unittest.main()
