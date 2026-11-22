"""`cloud-dev-stack.sh url --tag T` prints a running stack's origin and nothing else (review.sh --backend tag-stack reads it)."""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/cmux-next/cloud-dev-stack.sh"


class UrlTests(unittest.TestCase):
    def run_url(self, stacks: list[dict], *args: str) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as tmp:
            ssh = Path(tmp) / "ssh"
            # The fake VM: `vm status --tag T` answers with this registry; nothing else is expected.
            ssh.write_text("#!/bin/sh\ncase \"$*\" in *'vm_stack.py status'*) cat <<'J'\n"
                           + json.dumps({"capacity": {}, "stacks": stacks}) + "\nJ\n;; *) echo \"unexpected: $*\" >&2; exit 9;; esac\n")
            ssh.chmod(0o755)
            env = dict(os.environ, PATH=f"{tmp}{os.pathsep}{os.environ['PATH']}")
            return subprocess.run(["bash", str(SCRIPT), "url", *args], capture_output=True, text=True, env=env)

    def test_a_running_stack_prints_only_its_origin(self) -> None:
        r = self.run_url([{"tag": "t1", "state": "running", "url": "https://cmux-dev-backend-1.tail137216.ts.net:3850"}], "--tag", "t1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, "https://cmux-dev-backend-1.tail137216.ts.net:3850\n")

    def test_a_reaped_or_missing_stack_exits_3_with_no_url(self) -> None:
        for stacks in ([{"tag": "t1", "state": "reaped", "url": "https://old.tail137216.ts.net:3850"}], []):
            r = self.run_url(stacks, "--tag", "t1")
            self.assertEqual(r.returncode, 3, r.stderr)
            self.assertEqual(r.stdout, "")
            self.assertIn("up --tag t1", r.stderr)

    def test_url_needs_a_tag(self) -> None:
        r = self.run_url([], )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("--tag", r.stderr)


if __name__ == "__main__":
    unittest.main()
