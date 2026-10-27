#!/usr/bin/env python3
"""cef_shim_warnings.py (p10-stability-162, queue Q22): clang's warning lines counted once per (file, line, column, flag),
files made repository-relative, every -Wunsafe-buffer-usage* group in unsafe_buffer_usage, notes and errors ignored.
Runs anywhere (no Xcode, no CEF).
Run: python3 -I scripts/cmux-next/tests/test_cef_shim_warnings.py"""
import importlib.util, io, json, os, sys, tempfile, unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "..", "cef_shim_warnings.py")

spec = importlib.util.spec_from_file_location("cef_shim_warnings", TOOL)
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)

ROOT = Path("/repo")
SRC = "/repo/Packages/macOS/CmuxNext/CEFShim/src"
# clang 18's text for two sources that both include suggestion_rows.h.
LOG = f"""\
In file included from {SRC}/shim_client.mm:4:
{SRC}/../src/suggestion_rows.h:63:48: warning: unsafe pointer arithmetic [-Wunsafe-buffer-usage]
   63 |   return std::string(data + offset, length);
      |                      ^~~~
{SRC}/suggestion_rows.h:63:48: note: pass -fsafe-buffer-usage-suggestions to receive code hardening suggestions
{SRC}/shim_client.mm:120:7: warning: unused parameter 'browser' [-Wunused-parameter]
{SRC}/shim_client.mm:130:9: warning: 'memcpy' is an unsafe libc call [-Wunsafe-buffer-usage-in-libc-call]
{SRC}/shim_client.mm:140:3: warning: comparison of integers of different signs [-Wsign-compare,-Wextra]
{SRC}/shim_client.mm:150:3: warning: a warning with no flag
{SRC}/shim_client.mm:160:3: error: not counted [-Werror,-Wunguarded-availability-new]
In file included from {SRC}/shim_browser.mm:2:
{SRC}/suggestion_rows.h:63:48: warning: unsafe pointer arithmetic [-Wunsafe-buffer-usage]
2 warnings generated.
"""


class CountTests(unittest.TestCase):
    def setUp(self):
        self.result = tool.count(LOG.splitlines(), ROOT, "address")

    def test_header_warning_counts_once(self):
        self.assertEqual(self.result["by_file"]["Packages/macOS/CmuxNext/CEFShim/src/suggestion_rows.h"], 1)

    def test_totals(self):
        self.assertEqual(self.result["total"], 5)
        self.assertEqual(self.result["unsafe_buffer_usage"], 2)
        self.assertEqual(self.result["sanitize"], "address")
        self.assertEqual(self.result["schema"], 1)

    def test_by_flag_takes_the_first_flag(self):
        self.assertEqual(self.result["by_flag"], {
            "-W(none)": 1, "-Wsign-compare": 1, "-Wunsafe-buffer-usage": 1,
            "-Wunsafe-buffer-usage-in-libc-call": 1, "-Wunused-parameter": 1,
        })

    def test_files_outside_the_root_stay_absolute(self):
        result = tool.count(["/sdk/usr/include/x.h:1:2: warning: w [-Wextra-semi]"], ROOT)
        self.assertEqual(list(result["by_file"]), ["/sdk/usr/include/x.h"])

    def test_empty_log(self):
        result = tool.count([], ROOT)
        self.assertEqual((result["total"], result["unsafe_buffer_usage"], result["by_file"]), (0, 0, {}))


class MainTests(unittest.TestCase):
    def test_writes_the_file_and_one_summary_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            log, out = Path(tmp, "warnings.log"), Path(tmp, "warnings.json")
            log.write_text(LOG)
            printed = io.StringIO()
            with redirect_stdout(printed):
                self.assertEqual(tool.main(["--root", "/repo", "--out", str(out), str(log)]), 0)
            data = json.loads(out.read_text())
            self.assertEqual((data["total"], data["unsafe_buffer_usage"], data["sanitize"]), (5, 2, "none"))
            self.assertEqual(printed.getvalue(), f"==> CEF shim warnings: 5 (2 -Wunsafe-buffer-usage); {out}\n")


if __name__ == "__main__":
    unittest.main()
