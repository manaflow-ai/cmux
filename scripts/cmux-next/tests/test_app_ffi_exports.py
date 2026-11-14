"""Every function in a shipped header survives the app library's prelink."""
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
BUILD = ROOT / "scripts/cmux-next/build-app-ffi.sh"


def declarations(header):
    # Read C prototypes independently of the build's allowed symbol prefixes.
    text = re.sub(r"/\*.*?\*/|//[^\n]*", "", header, flags=re.S)
    return set(re.findall(
        r"^[ \t]*(?:[A-Za-z_]\w*[\s*]+)+([A-Za-z_]\w*)\s*\([^;{}]*\)\s*;",
        text, re.M,
    ))


class AppExports(unittest.TestCase):
    def test_shipped_header_functions_are_exported(self):
        entries = re.search(r"headers_in=\((.*?)\)\n", BUILD.read_text(), re.S)
        self.assertIsNotNone(entries)
        headers = re.findall(r'"\$crates/([^":]+):[^"\n]+"', entries[1])
        self.assertTrue(headers)
        exports = set(subprocess.check_output(
            ["bash", str(BUILD), "--list-exports"], text=True,
        ).splitlines())
        for relative in headers:
            with self.subTest(header=relative):
                names = declarations((ROOT / "cmux-tui/crates" / relative).read_text())
                self.assertTrue(names, "header contains no detected function declarations")
                self.assertFalse({"_" + n for n in names} - exports,
                                 "header declares a function absent from the exported-symbol list")

    def test_declarations_do_not_depend_on_prefix_or_line_wrapping(self):
        self.assertEqual(declarations('''
/* fake_call(); */
typedef void (*Callback)(void *);
void *another_api_create(void);
const uint8_t *another_api_bytes(
    size_t *len);
void other_api_callback(void (*callback)(void *));
'''), {"another_api_create", "another_api_bytes", "other_api_callback"})


if __name__ == "__main__":
    unittest.main()
