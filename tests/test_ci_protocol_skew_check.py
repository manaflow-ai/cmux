#!/usr/bin/env python3
"""protocol_skew_check.py over a scratch repository: each skew it must fail, and what it must let through.

python3 -m unittest tests/test_ci_protocol_skew_check.py
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ci/protocol_skew_check.py"
sys.path.insert(0, str(SCRIPT.parent))
import protocol_skew_check as skew  # noqa: E402

BASE_POLICY = {
    "initialize": "initialize",
    "requests": ["_acpmux/attach", "_acpmux/old_thing", "session/new"],
    "notifications": ["session/cancel"],
    "known_params": {
        "initialize": {"params": ["protocolVersion"], "acpmux": ["clientName"]},
        "_acpmux/attach": {"params": ["sessionId"], "acpmux": []},
    },
}
PAGE = "webviews/src/agent-session/acpmux/client.ts"
STRIP = "pub fn stripping_unknown_params() {}\n"


class Repo:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True,
                              text=True).stdout.strip()

    def write(self, path: str, text: str) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self, files: dict[str, str]) -> str:
        for path, text in files.items():
            self.write(path, text)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "c", "--allow-empty")
        return self.git("rev-parse", "HEAD")


def policy(**changes) -> str:
    p = json.loads(json.dumps(BASE_POLICY))
    p.update(changes)
    return json.dumps(p)


class SkewTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(Path(self.tmp.name))
        self.cwd = os.getcwd()
        os.chdir(self.tmp.name)

    def tearDown(self) -> None:
        os.chdir(self.cwd)
        self.tmp.cleanup()

    def base(self, strips: bool, page: str = 'send("_acpmux/attach")') -> str:
        return self.repo.commit({skew.POLICY: policy(), skew.PARAMS_RS: STRIP if strips else "\n", PAGE: page})

    def run_gate(self, base: str) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = skew.main(["--base", base, "--nightly-feed", ""])
        return code, out.getvalue()

    def test_a_new_initialize_key_fails_against_a_relay_that_refuses_unknown_keys(self) -> None:
        # cmux#46563: the page sent initialize _meta.acpmux.peerRowBatches; the NIGHTLY's relay refused it.
        base = self.base(strips=False)
        known = dict(BASE_POLICY["known_params"])
        known["initialize"] = {"params": ["protocolVersion"], "acpmux": ["clientName", "peerRowBatches"]}
        self.repo.commit({skew.POLICY: policy(known_params=known)})
        code, out = self.run_gate(base)
        self.assertEqual(code, 1, out)
        self.assertIn("initialize gains _meta.acpmux.peerRowBatches", out)

    def test_the_same_key_passes_once_the_old_relay_drops_unknown_keys(self) -> None:
        base = self.base(strips=True)
        known = dict(BASE_POLICY["known_params"])
        known["initialize"] = {"params": ["protocolVersion"], "acpmux": ["clientName", "peerRowBatches"]}
        self.repo.commit({skew.POLICY: policy(known_params=known)})
        code, out = self.run_gate(base)
        self.assertEqual(code, 0, out)

    def test_a_new_key_off_the_open_path_only_warns(self) -> None:
        base = self.base(strips=False)
        known = dict(BASE_POLICY["known_params"])
        known["_acpmux/old_thing"] = {"params": ["fresh"], "acpmux": []}
        self.repo.commit({skew.POLICY: policy(known_params=known)})
        code, out = self.run_gate(base)
        self.assertEqual(code, 0, out)
        self.assertIn("::warning::", out)

    def test_a_new_open_path_method_the_page_sends_fails(self) -> None:
        base = self.base(strips=True)
        self.repo.commit({skew.POLICY: policy(requests=BASE_POLICY["requests"] + ["session/resume"]),
                          PAGE: 'send("_acpmux/attach"); send("session/resume")'})
        code, out = self.run_gate(base)
        self.assertEqual(code, 1, out)
        self.assertIn("session/resume", out)

    def test_a_new_method_off_the_open_path_only_warns(self) -> None:
        base = self.base(strips=True)
        self.repo.commit({skew.POLICY: policy(requests=BASE_POLICY["requests"] + ["_acpmux/turn_shots"]),
                          PAGE: 'send("_acpmux/attach"); send("_acpmux/turn_shots")'})
        code, out = self.run_gate(base)
        self.assertEqual(code, 0, out)
        self.assertIn("_acpmux/turn_shots", out)

    def test_dropping_a_method_the_old_page_sends_fails(self) -> None:
        base = self.base(strips=True, page='send("_acpmux/attach"); send("_acpmux/old_thing")')
        self.repo.commit({skew.POLICY: policy(requests=["_acpmux/attach", "session/new"]),
                          PAGE: 'send("_acpmux/attach")'})
        code, out = self.run_gate(base)
        self.assertEqual(code, 1, out)
        self.assertIn("_acpmux/old_thing, which this relay no longer allows", out)

    def test_a_new_strict_decoder_fails_unless_it_says_why(self) -> None:
        base = self.base(strips=True)
        self.repo.commit({"cmux-tui/crates/x/src/wire.rs": "#[serde(deny_unknown_fields)]\nstruct A;\n"})
        code, out = self.run_gate(base)
        self.assertEqual(code, 1, out)
        self.assertIn("cmux-tui/crates/x/src/wire.rs:1", out)

        base = self.repo.git("rev-parse", "HEAD")
        self.repo.commit({"cmux-tui/crates/x/src/token.rs":
                          "// skew: strict a signed token: an unknown field is a forgery\n"
                          "#[serde(deny_unknown_fields)]\nstruct T;\n"})
        code, out = self.run_gate(base)
        self.assertEqual(code, 0, out)

    def test_a_resource_operation_newly_refusing_extra_params_fails(self) -> None:
        self.repo.commit({skew.RESOURCE_SPEC: '{"a": {"params": {"extra": true}}}'})
        base = self.base(strips=True)
        self.repo.commit({skew.RESOURCE_SPEC: '{"a": {"params": {"extra": false}}}'})
        code, out = self.run_gate(base)
        self.assertEqual(code, 1, out)
        self.assertIn('"extra": false', out)

    def test_a_skew_the_base_already_has_against_an_old_build_only_warns(self) -> None:
        old = self.base(strips=False)
        known = json.loads(policy())["known_params"]
        known["_acpmux/attach"]["params"].append("attending")
        base = self.repo.commit({skew.POLICY: policy(known_params=known)})
        self.repo.commit({"README.md": "x"})
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = skew.main(["--base", base, "--old", old, "--nightly-feed", ""])
        self.assertEqual(code, 0, out.getvalue())
        self.assertIn("gains attending, and that relay refuses keys it does not know (already on the base)",
                      out.getvalue())

    def test_an_unchanged_tree_passes(self) -> None:
        base = self.base(strips=False)
        self.repo.commit({"README.md": "x"})
        code, out = self.run_gate(base)
        self.assertEqual(code, 0, out)


class FeedTests(unittest.TestCase):
    def test_the_highest_build_names_the_nightly(self) -> None:
        feed = ("<item><sparkle:version>5</sparkle:version><cmux:sourceCommit xmlns:cmux=\"x\">" + "a" * 40 +
                "</cmux:sourceCommit></item><item><sparkle:version>9</sparkle:version>"
                "<cmux:sourceCommit xmlns:cmux=\"x\">" + "b" * 40 + "</cmux:sourceCommit></item>")
        with tempfile.NamedTemporaryFile("w", suffix=".xml", delete=False) as f:
            f.write(feed)
        try:
            self.assertEqual(skew.nightly_commit(Path(f.name).as_uri()), "b" * 40)
        finally:
            os.unlink(f.name)


if __name__ == "__main__":
    unittest.main()
