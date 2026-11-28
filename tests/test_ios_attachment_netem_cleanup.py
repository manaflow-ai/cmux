#!/usr/bin/env python3
"""Exercise benchmark cleanup without creating privileged network resources."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "cmux-next-ios/scripts/upload-netem-bench.sh"


class NetemCleanupTests(unittest.TestCase):
    def run_bench(self, root, name, fail=""):
        run = root / name
        run.mkdir()
        commands = run / "commands.jsonl"
        env = dict(os.environ, PATH=str(root / "bin") + os.pathsep + os.environ["PATH"],
                   NETEM_OUT=str(run / "out"), TMPDIR=str(root), COMMAND_LOG=str(commands),
                   FAKE_EXE=str(root / "bin" / "cell"), FAIL_CREATE=fail)
        result = subprocess.run(
            ["bash", str(SCRIPT), "--lanes", "1", "--sizes", "1", "--profiles", "none",
             "--loads", "idle", "--runs", "1"], env=env, capture_output=True, text=True, timeout=30)
        calls = [json.loads(line) for line in commands.read_text().splitlines()]
        return result, calls

    def fixtures(self, root):
        binaries = root / "bin"
        binaries.mkdir()
        scripts = {
            "cargo": '#!/bin/sh\nprintf "Executable test (%s)\\n" "$FAKE_EXE"\n',
            "cell": '#!/bin/sh\necho NETEM-ROW\n',
            "sudo": '''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["COMMAND_LOG"], "a") as output:
    output.write(json.dumps(args) + "\\n")
kind = os.environ.get("FAIL_CREATE")
if (kind == "namespace" and args[1:4] == ["ip", "netns", "add"]) or (kind == "link" and args[1:4] == ["ip", "link", "add"]):
    sys.exit(1)
''',
        }
        for name, source in scripts.items():
            path = binaries / name
            path.write_text(source)
            path.chmod(0o755)

    def test_success_cleans_only_created_names_and_each_run_is_unique(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.fixtures(root)
            namespaces = []
            for name in ("first", "second"):
                result, calls = self.run_bench(root, name)
                self.assertEqual(result.returncode, 0, result.stderr)
                for resource in ("netns", "link"):
                    added = [call[4] for call in calls if call[1:4] == ["ip", resource, "add"]]
                    deleted = [call[4] for call in calls if call[1:4] == ["ip", resource, "del"]]
                    self.assertEqual(added, deleted)
                    self.assertEqual(len(added), 1)
                    self.assertGreater(calls.index(next(c for c in calls if c[1:4] == ["ip", resource, "del"])),
                                       calls.index(next(c for c in calls if c[1:4] == ["ip", resource, "add"])))
                namespaces.append(next(c[4] for c in calls if c[1:4] == ["ip", "netns", "add"]))
            self.assertNotEqual(*namespaces)
            self.assertFalse(list(root.glob("cmux-netem.*")))

    def test_creation_failure_does_not_delete_an_unowned_resource(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.fixtures(root)
            for failure in ("namespace", "link"):
                result, calls = self.run_bench(root, failure, failure)
                self.assertNotEqual(result.returncode, 0)
                deleted = [call for call in calls if call[1:3] in (["ip", "netns"], ["ip", "link"]) and call[3] == "del"]
                self.assertEqual(len(deleted), 0 if failure == "namespace" else 1)
                if deleted:
                    self.assertEqual(deleted[0][1:4], ["ip", "netns", "del"])
            self.assertFalse(list(root.glob("cmux-netem.*")))


if __name__ == "__main__":
    unittest.main()
