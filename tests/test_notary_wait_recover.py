#!/usr/bin/env python3
"""notary_wait_recover finishes a notarytool wait that lost its connection after submitting.

Run 41801811362 failed the NEXT nightly on "A TLS error caused the secure connection to fail" while notarytool
polled a submission Apple already had (.../notary/v2/submissions/<id>). scripts/ci/lib/notary-wait-recover.sh
waits on that id instead; these drive it with a fake xcrun.
"""

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "scripts/ci/lib/notary-wait-recover.sh"
SUBMISSION = "03950565-9cb1-4246-9188-5475d18f0208"
TLS_DROP = (
    "Error: HTTPError(statusCode: nil, error: Error Domain=NSURLErrorDomain Code=-1200 \"A TLS error caused the "
    "secure connection to fail.\" UserInfo={NSErrorFailingURLStringKey=https://appstoreconnect.apple.com/notary/v2/"
    f"submissions/{SUBMISSION}?}})\n"
)


def run(output: str, waits: list[tuple[int, str]]) -> tuple[subprocess.CompletedProcess[str], str, list[str]]:
    temp = Path(tempfile.mkdtemp())
    out = temp / "submit-output"
    out.write_text(output)
    calls = temp / "calls"
    # The fake xcrun answers each `notarytool wait` with the next scripted (exit, text).
    script = ["#!/usr/bin/env bash", f'echo "$*" >> "{calls}"', f'n=$(wc -l < "{calls}" | tr -d " ")']
    for index, (code, text) in enumerate(waits, start=1):
        script.append(f'if [ "$n" = {index} ]; then printf %s {subprocess.list2cmdline([text])}; exit {code}; fi')
    script.append("exit 9")
    xcrun = temp / "xcrun"
    xcrun.write_text("\n".join(script) + "\n")
    xcrun.chmod(0o755)
    body = textwrap.dedent(f"""
        set -euo pipefail
        XCRUN_TOOL={xcrun}
        NOTARY_AUTH_ARGS=(--key k --key-id i --issuer s)
        NOTARY_RECOVER_SLEEP_SECONDS=0
        source {LIB}
        rc=0
        notary_wait_recover {out} 25m || rc=$?
        echo "rc=$rc"
    """)
    result = subprocess.run(["bash", "-c", body], capture_output=True, text=True, env=dict(os.environ))
    return result, out.read_text(), calls.read_text().splitlines() if calls.exists() else []


class NotaryWaitRecoverTests(unittest.TestCase):
    def test_tls_drop_after_submit_waits_on_the_named_submission(self):
        accepted = f'{{"id":"{SUBMISSION}","status":"Accepted","message":"Processing complete"}}'
        result, out, calls = run(TLS_DROP, [(0, accepted)])
        self.assertIn("rc=0", result.stdout, result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0].startswith(f"notarytool wait {SUBMISSION} --key k"), calls[0])
        self.assertIn("--output-format json --timeout 25m", calls[0])
        self.assertTrue(out.endswith(accepted))

    def test_a_second_drop_is_waited_through(self):
        accepted = f'{{"id":"{SUBMISSION}","status":"Accepted"}}'
        result, _, calls = run(TLS_DROP, [(1, TLS_DROP), (0, accepted)])
        self.assertIn("rc=0", result.stdout, result.stderr)
        self.assertEqual(len(calls), 2)

    def test_gives_up_after_three_tries(self):
        result, _, calls = run(TLS_DROP, [(1, TLS_DROP)] * 4)
        self.assertIn("rc=1", result.stdout, result.stderr)
        self.assertEqual(len(calls), 3)

    def test_a_timeout_is_left_to_the_caller(self):
        result, out, calls = run(TLS_DROP, [(1, "Error: timed out waiting for the submission\n")] * 3)
        self.assertIn("rc=1", result.stdout, result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertIn("timed out", out)

    def test_no_submission_named_is_not_retried(self):
        result, _, calls = run("Error: Unable to upload your app for notarization\n", [])
        self.assertIn("rc=1", result.stdout, result.stderr)
        self.assertEqual(calls, [])

    def test_an_answered_submission_is_not_retried(self):
        invalid = f'{{"id":"{SUBMISSION}","status":"Invalid","message":"Processing complete"}}'
        result, _, calls = run(invalid, [])
        self.assertIn("rc=1", result.stdout, result.stderr)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
