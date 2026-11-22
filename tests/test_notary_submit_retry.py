#!/usr/bin/env python3
"""notary_submit_retry submits again when notarytool never reached Apple.

Run 42289209031 failed the NEXT nightly 11 s into its DMG submit on "Error: HTTPClientError.connectTimeout":
notarytool never connected, so Apple had no submission and there was nothing to wait on, and the 50-minute
build was lost. scripts/ci/lib/notary-wait-recover.sh's notary_submit_retry reruns the submit when the output
names no submission and shows a connect-phase failure; these drive it with a fake xcrun.
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
CONNECT_TIMEOUT = "Error: HTTPClientError.connectTimeout\n"
ACCEPTED = f'{{"id":"{SUBMISSION}","status":"Accepted","message":"Processing complete"}}'


def run(first: tuple[int, str], submits: list[tuple[int, str]]) -> tuple[subprocess.CompletedProcess[str], str, list[str]]:
    temp = Path(tempfile.mkdtemp())
    out = temp / "submit-output"
    calls = temp / "calls"
    # The fake xcrun answers the first submit with `first`, then each retry with the next scripted (exit, text).
    script = ["#!/usr/bin/env bash", f'echo "$*" >> "{calls}"', f'n=$(wc -l < "{calls}" | tr -d " ")']
    for index, (code, text) in enumerate([first, *submits], start=1):
        script.append(f'if [ "$n" = {index} ]; then printf %s {subprocess.list2cmdline([text])}; exit {code}; fi')
    script.append("exit 9")
    xcrun = temp / "xcrun"
    xcrun.write_text("\n".join(script) + "\n")
    xcrun.chmod(0o755)
    body = textwrap.dedent(f"""
        set -euo pipefail
        XCRUN_TOOL={xcrun}
        NOTARY_AUTH_ARGS=(--key k --key-id i --issuer s)
        NOTARY_SUBMIT_RETRY_SLEEP_SECONDS=0
        source {LIB}
        set +e
        "$XCRUN_TOOL" notarytool submit app.dmg "${{NOTARY_AUTH_ARGS[@]}}" --output-format json --wait --timeout 25m >{out} 2>&1
        rc=$?
        set -e
        if [ "$rc" -ne 0 ]; then
          rc=0
          notary_submit_retry {out} "$XCRUN_TOOL" notarytool submit app.dmg "${{NOTARY_AUTH_ARGS[@]}}" \\
            --output-format json --wait --timeout 25m || rc=$?
        fi
        echo "rc=$rc"
    """)
    result = subprocess.run(["bash", "-c", body], capture_output=True, text=True, env=dict(os.environ))
    return result, out.read_text(), calls.read_text().splitlines()


class NotarySubmitRetryTests(unittest.TestCase):
    def test_a_connect_timeout_submits_again(self):
        result, out, calls = run((1, CONNECT_TIMEOUT), [(0, ACCEPTED)])
        self.assertIn("rc=0", result.stdout, result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0], calls[1])
        self.assertTrue(out.endswith(ACCEPTED))

    def test_other_connect_failures_submit_again(self):
        for error in ("Error Domain=NSURLErrorDomain Code=-1004 \"Could not connect to the server.\"\n",
                      "Error Domain=NSURLErrorDomain Code=-1005 \"The network connection was lost.\"\n",
                      "Error Domain=NSURLErrorDomain Code=-1001 \"The request timed out.\"\n"):
            with self.subTest(error=error):
                result, _, calls = run((1, error), [(0, ACCEPTED)])
                self.assertIn("rc=0", result.stdout, result.stderr)
                self.assertEqual(len(calls), 2)

    def test_gives_up_after_two_more_submits(self):
        result, _, calls = run((1, CONNECT_TIMEOUT), [(1, CONNECT_TIMEOUT)] * 3)
        self.assertIn("rc=1", result.stdout, result.stderr)
        self.assertEqual(len(calls), 3)

    def test_a_retry_that_reaches_apple_and_fails_is_not_submitted_again(self):
        # Only the newest attempt decides: an earlier connectTimeout must not trigger a third submit, and the
        # output the caller reads (timeout classifiers, notary_wait_recover) holds only the newest attempt.
        refused = "Error: Unable to upload your app for notarization\n"
        result, out, calls = run((1, CONNECT_TIMEOUT), [(1, refused), (0, ACCEPTED)])
        self.assertIn("rc=1", result.stdout, result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertEqual(out, refused)
        self.assertIn("connectTimeout", result.stderr)

    def test_a_named_submission_is_left_to_the_wait_recovery(self):
        tls = ("Error: HTTPError(statusCode: nil, error: Error Domain=NSURLErrorDomain Code=-1005 \"The network "
               f"connection was lost.\" UserInfo={{NSErrorFailingURLStringKey=https://appstoreconnect.apple.com/notary/v2/submissions/{SUBMISSION}}})\n")
        result, _, calls = run((1, tls), [])
        self.assertIn("rc=1", result.stdout, result.stderr)
        self.assertEqual(len(calls), 1)

    def test_an_answered_submission_is_not_submitted_again(self):
        invalid = f'{{"id":"{SUBMISSION}","status":"Invalid","message":"Processing complete"}}'
        result, _, calls = run((1, invalid), [])
        self.assertIn("rc=1", result.stdout, result.stderr)
        self.assertEqual(len(calls), 1)

    def test_a_refused_upload_is_not_submitted_again(self):
        result, _, calls = run((1, "Error: Unable to upload your app for notarization\n"), [])
        self.assertIn("rc=1", result.stdout, result.stderr)
        self.assertEqual(len(calls), 1)


if __name__ == "__main__":
    unittest.main()
