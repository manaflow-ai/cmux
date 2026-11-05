#!/usr/bin/env python3
"""side-instance.sh make over an existing NAME clears the state of the identity it replaces.

Remaking NAME from a different app (a nightly's copy, then a DEV's) gives the copy a new bundle id
and build key, and remove deletes only the identity the marker names: the first identity's
~/.acpmux, ~/.cmux/chief and preferences were left behind for good (#35544 review, F1).
PlistBuddy, codesign, xattr and defaults are stand-ins, so this runs anywhere with bash and python3.
"""

import os
import plistlib
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/side-instance.sh"

# Print, Set, Add and Delete on :a:b:0 paths, the subset side-instance.sh uses.
BUDDY = textwrap.dedent('''\
    #!/usr/bin/env python3
    import plistlib, sys
    args = sys.argv[1:]; path = args[-1]; cmds = [args[i + 1] for i in range(0, len(args) - 1, 2)]
    data = plistlib.load(open(path, "rb"))
    def walk(keys):
        node = data
        for k in keys[:-1]: node = node[int(k)] if isinstance(node, list) else node[k]
        last = keys[-1]
        return node, int(last) if isinstance(node, list) else last
    for cmd in cmds:
        verb, rest = cmd.split(" ", 1)
        key, _, value = rest.partition(" ")
        node, last = walk(key.lstrip(":").split(":"))
        if verb == "Print":
            try: v = node[last]
            except (KeyError, IndexError): sys.exit(1)
            print(v if not isinstance(v, (dict, list)) else "Dict {"); continue
        if verb == "Delete":
            try: del node[last]
            except (KeyError, IndexError): sys.exit(1)
            continue
        if verb == "Set":
            if isinstance(node, dict) and last not in node: sys.exit(1)
            node[last] = value; continue
        kind, _, v = value.partition(" ")
        if isinstance(node, dict) and last in node: sys.exit(1)
        v = {"string": v, "dict": {}, "array": []}[kind]
        if isinstance(node, list): node.insert(last, v)
        else: node[last] = v
    plistlib.dump(data, open(path, "wb"))
''')


class SideInstanceRemakeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="side-instance-remake-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.home = self.tmp / "home"
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for tool, body in {"PlistBuddy": BUDDY, "codesign": "#!/bin/sh\nexit 0\n", "xattr": "#!/bin/sh\nexit 0\n",
                           "defaults": f"#!/bin/sh\necho \"$*\" >>'{self.tmp}/defaults.log'\n"}.items():
            (bin_dir / tool).write_text(body)
            (bin_dir / tool).chmod(0o755)
        self.env = {**os.environ, "HOME": str(self.home), "CMUX_SIDE_ROOT": str(self.tmp / "side"),
                    "SIDE_INSTANCE_PLISTBUDDY": str(bin_dir / "PlistBuddy"),
                    "PATH": f"{bin_dir}:{os.environ['PATH']}"}

    def app(self, name: str, bundle_id: str, tag: str) -> Path:
        app = self.tmp / f"{name}.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        with open(app / "Contents/Info.plist", "wb") as f:
            plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "cmux", "CFBundleVersion": "1",
                           "LSEnvironment": {"CMUX_TAG": tag}}, f)
        return app

    def make(self, app: Path) -> dict:
        subprocess.run(["bash", str(SCRIPT), "make", "pr-1", "--from", str(app)], env=self.env, check=True,
                       capture_output=True, text=True)
        marker = self.tmp / "side/pr-1/.side-instance"
        return dict(line.split("=", 1) for line in marker.read_text().splitlines())

    def state_of(self, ident: dict) -> list[Path]:
        paths = [self.home / ".acpmux/builds" / ident["key"], self.home / ".cmux/chief" / ident["key"],
                 self.home / ".cmux/chief" / f"{ident['key']}@acct",
                 self.home / "Library/Application Support/cmux/builds" / ident["key"],
                 self.home / "Library/Caches" / ident["bundle"]]
        for p in paths:
            p.mkdir(parents=True, exist_ok=True)
        return paths

    def test_remake_from_another_app_clears_the_replaced_identity(self):
        first = self.make(self.app("nightly", "com.cmuxterm.app.nightly", "cmux-next"))
        old_state = self.state_of(first)
        second = self.make(self.app("dev", "com.cmuxterm.app.debug.next", "next"))
        self.assertNotEqual(first["bundle"], second["bundle"])
        self.assertEqual([p for p in old_state if p.exists()], [])
        self.assertIn(f"delete {first['bundle']}", (self.tmp / "defaults.log").read_text())

    def test_remake_from_the_same_app_keeps_its_state(self):
        nightly = self.app("nightly", "com.cmuxterm.app.nightly", "cmux-next")
        first = self.make(nightly)
        state = self.state_of(first)
        self.assertEqual(self.make(nightly), first)
        self.assertEqual([p for p in state if not p.exists()], [])

    def test_remove_clears_the_current_identity(self):
        ident = self.make(self.app("nightly", "com.cmuxterm.app.nightly", "cmux-next"))
        state = self.state_of(ident)
        subprocess.run(["bash", str(SCRIPT), "remove", "pr-1"], env=self.env, check=True, capture_output=True, text=True)
        self.assertEqual([p for p in state if p.exists()], [])
        self.assertFalse((self.tmp / "side/pr-1").exists())


if __name__ == "__main__":
    unittest.main()
