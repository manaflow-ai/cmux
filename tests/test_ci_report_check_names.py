"""Every `cmux-ci run --report-check NAME` in a workflow is a name the client accepts (2026-11-27, cmux#62960).

The client refuses a name outside REPORT_CHECK_NAME with exit 2 before it submits anything: "split table (bench Mac,
report-only)" (a comma) failed on the Mac gateway in run 46066365682. This test holds every workflow's REPORT_CHECK
env value and every literal --report-check argument to the client's pattern, so the error fails here instead.
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
# A copy of cmuxterm-hq build-fleet/ci-client.py REPORT_CHECK_NAME (report_check.go reportCheckName). Keep in step.
REPORT_CHECK_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._()/:+-]{0,99}$")
ENV_RE = re.compile(r"^\s*(?:[A-Z0-9_]*REPORT_CHECK[A-Z0-9_]*):\s*(.+?)\s*$", re.M)
ARG_RE = re.compile(r"--report-check[ =](\"[^\"$]*\"|'[^']*')")
# A ${{ expression }} becomes a value like the ones it takes (a matrix arch, a variable): letters and digits.
EXPR_RE = re.compile(r"\$\{\{[^}]*\}\}")


def names(text):
    for m in ENV_RE.finditer(text):
        value = m.group(1)
        if value[:1] in "\"'" and value[-1:] == value[:1]:
            value = value[1:-1]
        yield EXPR_RE.sub("arm64", value)
    for m in ARG_RE.finditer(text):
        yield EXPR_RE.sub("arm64", m.group(1)[1:-1])


class ReportCheckNames(unittest.TestCase):
    def test_every_report_check_name_is_one_the_client_accepts(self):
        seen, bad = 0, []
        for path in sorted((ROOT / ".github" / "workflows").glob("*.y*ml")):
            for name in names(path.read_text()):
                seen += 1
                if not REPORT_CHECK_NAME.fullmatch(name):
                    bad.append(f"{path.name}: {name!r}")
        self.assertGreater(seen, 0, "no REPORT_CHECK name found: the scan no longer matches the workflows")
        self.assertEqual(bad, [], "names cmux-ci run --report-check refuses (1-100 letters, digits, spaces or ._()/:+-)")

    def test_the_scan_catches_the_comma(self):
        self.assertFalse(REPORT_CHECK_NAME.fullmatch(next(names("      REPORT_CHECK: split table (bench Mac, report-only)\n"))))


if __name__ == "__main__":
    unittest.main()
