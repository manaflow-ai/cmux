"""Exercise the build entry point's opt-in in both bundle-report paths."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/cmux-next/build-agent-pane-web.sh"


class CompileHintsOptIn(unittest.TestCase):
    def test_build_arguments(self):
        for report in (False, True):
            for value in (None, "", "0", "1", "true"):
                with self.subTest(report=report, value=value), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    target = root / "scripts/cmux-next/build-agent-pane-web.sh"
                    target.parent.mkdir(parents=True)
                    shutil.copyfile(SCRIPT, target)
                    (root / "webviews/node_modules").mkdir(parents=True)
                    check = root / "scripts/check-webviews-bun-version.sh"
                    check.write_text("#!/bin/sh\nexit 0\n")
                    check.chmod(0o755)
                    bindir = root / "bin"
                    bindir.mkdir()
                    bun = bindir / "bun"
                    # Stop at the real entry point's first bundler invocation, before any build.
                    bun.write_text(
                        '#!/bin/sh\n'
                        'if [ "$1" = scripts/agent-pane/bundle.mjs ]; then\n'
                        '  printf "%s\\n" "$@" > "$CAPTURE"\n'
                        '  exit 42\n'
                        'fi\n'
                    )
                    bun.chmod(0o755)
                    capture = root / "arguments"
                    env = dict(os.environ, PATH=f"{bindir}:/usr/bin:/bin", CAPTURE=str(capture))
                    env.pop("CMUX_AGENT_PANE_COMPILE_HINTS", None)
                    env.pop("CMUX_BUNDLE_REPORT_DIR", None)
                    if value is not None:
                        env["CMUX_AGENT_PANE_COMPILE_HINTS"] = value
                    if report:
                        env["CMUX_BUNDLE_REPORT_DIR"] = str(root / "bundle report")
                    result = subprocess.run(
                        ["sh", str(target), "--check", "--out", str(root / "output space")],
                        env=env, capture_output=True, text=True, timeout=10,
                    )
                    if value == "true":
                        self.assertEqual(result.returncode, 2, result.stderr)
                        self.assertIn("must be 0 or 1", result.stderr)
                        self.assertFalse(capture.exists())
                    else:
                        self.assertEqual(result.returncode, 42, result.stderr)
                        args = capture.read_text().splitlines()
                        self.assertEqual(args.count("--compile-hints"), int(value == "1"))
                        self.assertEqual("--metafile" in args, report)
                        self.assertNotIn("", args)


if __name__ == "__main__":
    unittest.main()
