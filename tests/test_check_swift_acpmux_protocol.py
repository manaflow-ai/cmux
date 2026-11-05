#!/usr/bin/env python3
"""scripts/ci/check-swift-acpmux-protocol.py is red on each kind of Swift-to-acpmux drift and green without it."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("check", ROOT / "scripts/ci/check-swift-acpmux-protocol.py")
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)

PROTOCOL = {
    "version": 1,
    "methods": [
        {"kind": "request", "name": "initialize", "params": True, "result": True},
        {"kind": "request", "name": "session/prompt", "params": True, "result": True},
        {"kind": "request", "name": "acp.session.fork", "params": {"$ref": "#/types/ForkParams"}, "result": True},
        {"kind": "request", "name": "_acpmux/attach", "params": {"$ref": "#/types/AttachParams"}, "result": True},
    ],
    "types": {
        # No additionalProperties: an open object, so a key beyond its properties is allowed.
        "ForkParams": {"properties": {"sessionId": {"type": "string"}}},
        "AttachParams": {
            "additionalProperties": False,
            "properties": {"sessionId": {"type": "string"}, "afterSeq": {"type": ["integer", "null"]}},
        }
    },
}

PANE = '''
nonisolated enum AcpmuxPaneMethods {
    public static let initialize = "{initialize}"
    public static let requests: Set<String> = [
        "session/prompt", "_acpmux/attach", {extra_request}
    ]
    public static let notifications: Set<String> = ["session/prompt"]
}
'''

PARAMS = '''
extension AcpmuxPaneMethods {
    static let knownParams: [String: (params: Set<String>, acpmux: Set<String>)] = [
        "_acpmux/attach": (["sessionId", "afterSeq"{extra_param}], ["promptId"]),
        "acp.session.fork": (["sessionId", "cwd"], []),
    ]
    static let other: [String: (params: Set<String>, acpmux: Set<String>)] = [
        "_acpmux/attach": (["notAParam"], []),
    ]
}
'''


class CheckTests(unittest.TestCase):
    def tree(self, *, client: str = "", extra_request: str = "", extra_param: str = "", allow: str = "",
             initialize: str = "initialize") -> Path:
        root = Path(tempfile.mkdtemp())
        (root / check.PROTOCOL).parent.mkdir(parents=True)
        (root / check.PROTOCOL).write_text(json.dumps(PROTOCOL))
        pane = root / check.PANE
        pane.mkdir(parents=True)
        (pane / "AcpmuxPaneMethods.swift").write_text(
            PANE.replace("{extra_request}", extra_request).replace("{initialize}", initialize))
        (pane / "AcpmuxPaneMethods+Params.swift").write_text(PARAMS.replace("{extra_param}", extra_param))
        (root / check.SOURCES / "Client.swift").write_text(client)
        (root / check.ALLOWLIST).parent.mkdir(parents=True)
        (root / check.ALLOWLIST).write_text(allow)
        return root

    def test_green_when_every_name_is_in_the_protocol(self):
        client = 'let a = "_acpmux/attach" // "_acpmux/nope" in a comment\nlet p = "_acpmux/" + op\n'
        self.assertEqual(check.check(self.tree(client=client)), [])

    def test_a_method_literal_the_protocol_lacks(self):
        problems = check.check(self.tree(client='send(method: "_acpmux/attachh")\n'))
        self.assertEqual(len(problems), 1)
        self.assertIn("Client.swift:1: '_acpmux/attachh'", problems[0])

    def test_a_pane_method_the_protocol_lacks(self):
        problems = check.check(self.tree(extra_request='"session/promptt"'))
        # Reported once, at its literal: the policy pass does not name it again.
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("AcpmuxPaneMethods.swift:5: 'session/promptt'", problems[0])

    def test_a_param_key_the_typed_params_lack(self):
        problems = check.check(self.tree(extra_param=', "promptID"'))
        self.assertEqual(problems, [
            "AcpmuxPaneMethods.knownParams[_acpmux/attach]: '_acpmux/attach#promptID' is not in "
            f"{check.PROTOCOL}"
        ])

    def test_the_first_frames_method_is_checked(self):
        problems = check.check(self.tree(initialize="initialise"))
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("'initialise'", problems[0])

    def test_multiline_and_raw_strings(self):
        # `//` inside a multiline string is not a comment; a raw string's method is still seen.
        client = 'let doc = """\n  see https://x // "_acpmux/attachh"\n  """\nlet m = #"_acpmux/rawdrift"#\n'
        problems = check.check(self.tree(client=client))
        self.assertEqual(sorted(p.split("'")[1] for p in problems), ["_acpmux/attachh", "_acpmux/rawdrift"], problems)

    def test_a_listed_name_is_allowed_and_a_stale_one_fails(self):
        allow = "_acpmux/attachh not registered yet (owner: acpmux)\n_acpmux/gone stale\nsession/prompt now defined\n"
        problems = check.check(self.tree(client='"_acpmux/attachh"\n', allow=allow))
        self.assertEqual(len(problems), 2, problems)
        self.assertIn("'_acpmux/gone' is no longer named", problems[0])
        self.assertIn("'session/prompt' is in the protocol now", problems[1])

    def test_the_repository_is_green(self):
        self.assertEqual(check.check(ROOT), [])


if __name__ == "__main__":
    unittest.main()
