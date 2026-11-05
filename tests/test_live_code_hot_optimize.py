#!/usr/bin/env python3
"""patch.py --optimize --all: the live code build you edited, optimized in place (hot optimize).

The "build" is a reload log naming a stand-in swift-frontend and swiftc; nm and codesign are
stand-ins too. So this checks the patch's path (every file compiled at -O in parallel runs, a file
with state of its own left out, one dylib in the live folder), not a real compile.
"""

import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / "scripts/live-code/patch.py"

# Records each run's optimization flag and primaries, and writes each object it was asked for: an
# object whose source says `static var` gets a storage symbol, as a real compile would.
FRONTEND = '''#!/usr/bin/env python3
import sys
args = sys.argv[1:]
prim = open(args[args.index("-primary-filelist") + 1]).read().split()
level = "-O" if "-O" in args else "-Onone" if "-Onone" in args else "?"
with open(sys.argv[0] + ".record", "a") as rec:
    rec.write(level + " " + " ".join(prim) + "\\n")
outs = [args[i + 1] for i, a in enumerate(args) if a == "-o"]
for source, out in zip(prim, outs):
    state = "static var" in open(source).read()
    open(out, "w").write("STATE\\n" if state else "CODE\\n")
'''
# Lists a storage symbol for a STATE object, a function for any other.
NM = '''#!/bin/sh
if grep -q STATE "$2"; then echo "0000000000000010 b _\\$s11CmuxNextApp5CacheV5shared0D0vpZ"; fi
echo "0000000000000000 T _\\$s11CmuxNextApp4workyyF"
'''
SWIFTC = '''#!/usr/bin/env python3
import sys
args = sys.argv[1:]
open(sys.argv[0] + ".record", "w").write(" ".join(a for a in args if a.endswith(".o")))
open(args[args.index("-o") + 1], "w").write("dylib")
'''


class HotOptimizeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="hot-optimize-test."))
        module = self.tmp / "checkout/Packages/macOS/CmuxNext/Sources/CmuxNextApp"
        (module / "Home").mkdir(parents=True)
        self.sources = {
            module / "View.swift": "struct View { func draw() {} }\n",
            module / "Home/View.swift": "struct HomeView { func draw() {} }\n",
            module / "Cache.swift": "enum Cache { static var shared = 0 }\n",
            module / "Keys.swift": "struct Keys { func route() {} }\n",
        }
        for path, text in self.sources.items():
            path.write_text(text)
        toolchain = self.tmp / "toolchain"
        toolchain.mkdir()
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        for path, body in {toolchain / "swift-frontend": FRONTEND, toolchain / "swiftc": SWIFTC,
                           self.bin / "nm": NM, self.bin / "codesign": "#!/bin/sh\nexit 0\n"}.items():
            path.write_text(body)
            path.chmod(0o755)
        filelist = self.tmp / "CmuxNextApp.SwiftFileList"
        filelist.write_text("".join(f"{path}\n" for path in self.sources))
        frontend = [str(toolchain / "swift-frontend"), "-frontend", "-c", "-filelist", str(filelist),
                    "-primary-file", str(next(iter(self.sources))), "-target", "arm64-apple-macos14.0",
                    "-Onone", "-enable-testing", "-module-name", "CmuxNextApp", "-o", "/build/View.o"]
        self.log = self.tmp / "xcodebuild.log"
        self.log.write_text(shlex.join(frontend) + "\n")
        self.frontend_record = toolchain / "swift-frontend.record"
        self.link_record = toolchain / "swiftc.record"
        self.live = self.tmp / "live"

    def run_patch(self, *args):
        env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}"}
        return subprocess.run(["python3", str(PATCH), "--log", str(self.log), "--live", str(self.live), *args],
                              capture_output=True, text=True, env=env)

    def test_hot_optimize_compiles_every_file_at_O_and_leaves_out_a_file_with_state(self):
        run = self.run_patch("--optimize", "--all", "--jobs", "2")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("files=3 kept_for_state=1 optimized=1", run.stdout)
        runs = self.frontend_record.read_text().splitlines()
        # Two parallel runs, both at -O, together compiling every file once.
        self.assertEqual(len(runs), 2)
        self.assertTrue(all(line.startswith("-O ") for line in runs), runs)
        compiled = sorted(path for line in runs for path in line.split()[1:])
        self.assertEqual(compiled, sorted(str(path) for path in self.sources))
        linked = self.link_record.read_text().split()
        self.assertEqual(len(linked), 3)
        self.assertFalse(any(path.endswith("-Cache.o") for path in linked), linked)
        # Two files named View.swift get two objects, not one overwriting the other.
        self.assertEqual(len({os.path.basename(path) for path in linked}), 3)
        self.assertEqual(len([name for name in os.listdir(self.live) if name.endswith(".dylib")]), 1)

    def test_an_edited_file_patch_stays_unoptimized_and_keeps_its_state_file(self):
        cache = next(path for path in self.sources if path.name == "Cache.swift")
        run = self.run_patch(str(cache))
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("files=1 kept_for_state=0 optimized=0", run.stdout)
        self.assertEqual(self.frontend_record.read_text().split(), ["-Onone", str(cache)])

    def test_no_file_and_no_all_is_a_usage_error(self):
        run = self.run_patch()
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("name the edited FILEs, or --all", run.stderr)


if __name__ == "__main__":
    unittest.main()
