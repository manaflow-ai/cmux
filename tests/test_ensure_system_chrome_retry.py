#!/usr/bin/env python3
"""ensure-system-chrome.sh tries the Chrome install again when the download is cut off mid-transfer.

Playwright fetches the Chrome .deb with one plain `curl -L -O`. A stream cut mid-transfer (job
131599730461: "curl: (92) HTTP/2 stream 1 was not closed cleanly") failed a webview shard's engine
gate and cost its PR a 27 min rerun. A cut transfer is tried again; a 404 is not.

Runs the script against a fake `playwright` and a fake system Chrome; no network, no install.
"""

import os
import pathlib
import platform
import stat
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "ensure-system-chrome.sh"

FAKE_PLAYWRIGHT = """#!/usr/bin/env bash
# Each call takes the next scripted outcome: `ok` installs Chrome 157, anything else is printed and fails.
state="$FAKE_STATE"
n=$(( $(cat "$state/calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$state/calls"
outcome="$(sed -n "${n}p" "$state/outcomes")"
if [ "$outcome" = ok ]; then
  echo 157.0.8103.78 > "$state/chrome-version"
  exit 0
fi
echo "$outcome"
echo "Failed to install browsers"
echo "Error: Failed to install chrome"
exit 1
"""

FAKE_CHROME = """#!/usr/bin/env bash
echo "Google Chrome $(cat "$FAKE_STATE/chrome-version")"
"""


def write_exec(path: pathlib.Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


@unittest.skipUnless(platform.system() == "Linux" and platform.machine() == "x86_64", "the script's Linux path")
class ChromeInstallRetryTests(unittest.TestCase):
    def run_script(self, outcomes: list[str]) -> tuple[subprocess.CompletedProcess, int]:
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            state = tmp / "state"
            state.mkdir()
            (state / "outcomes").write_text("\n".join(outcomes) + "\n")
            (state / "chrome-version").write_text("151.0.7922.169\n")
            work = tmp / "webviews"
            write_exec(work / "node_modules" / ".bin" / "playwright", FAKE_PLAYWRIGHT)
            write_exec(tmp / "bin" / "google-chrome-stable", FAKE_CHROME)
            # A cached headless shell new enough, so the script asks no network for it.
            cache = tmp / "cache"
            write_exec(cache / "chrome-headless-shell-157.0.8103.78" / "chrome-headless-shell-linux64"
                       / "chrome-headless-shell", "#!/usr/bin/env bash\necho 157.0.8103.78\n")
            env = {k: v for k, v in os.environ.items() if k not in ("GITHUB_ENV", "GITHUB_ACTIONS")}
            env.update(PATH=f"{tmp / 'bin'}:{env.get('PATH', '/usr/bin:/bin')}", FAKE_STATE=str(state),
                       CMUX_CI_CACHE_DIR=str(cache), CMUX_CHROME_INSTALL_RETRY_SECONDS="0")
            done = subprocess.run(["bash", str(SCRIPT)], cwd=work, env=env, capture_output=True, text=True,
                                  timeout=60)
            calls = int((state / "calls").read_text().strip() or 0) if (state / "calls").exists() else 0
            return done, calls

    def test_a_download_cut_mid_transfer_is_tried_again(self):
        done, calls = self.run_script(["curl: (92) HTTP/2 stream 1 was not closed cleanly: INTERNAL_ERROR (err 2)",
                                       "ok"])
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(calls, 2)
        self.assertIn("system Chrome 157.0.8103.78", done.stdout)

    def test_every_cut_off_transfer_kind_is_retried(self):
        for code in (18, 28, 35, 52, 56, 92):
            with self.subTest(code=code):
                done, calls = self.run_script([f"curl: ({code}) transfer cut", "ok"])
                self.assertEqual((done.returncode, calls), (0, 2), done.stdout + done.stderr)

    def test_three_cut_offs_end_the_tries(self):
        cut = "curl: (56) Recv failure: Connection reset by peer"
        done, calls = self.run_script([cut, cut, cut, "ok"])
        self.assertEqual(calls, 3)
        self.assertEqual(done.returncode, 1)
        self.assertIn("need 156.0.8078.73 or later", done.stderr)

    def test_a_missing_file_is_not_retried(self):
        done, calls = self.run_script(["curl: (22) The requested URL returned error: 404", "ok"])
        self.assertEqual(calls, 1)
        self.assertEqual(done.returncode, 1)

    def test_an_apt_hash_mismatch_is_still_tried_once_more(self):
        done, calls = self.run_script(["E: Hashes of received file sha256 do not match", "ok"])
        self.assertEqual((done.returncode, calls), (0, 2), done.stdout + done.stderr)


if __name__ == "__main__":
    unittest.main()
