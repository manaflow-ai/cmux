#!/usr/bin/env python3
"""scripts/cmux-vmd/autocloud-template.sh keeps up with what cmux-host's first bind needs.

The template's machines failed bind twice in a row on dev: no `wg` (wireguard-tools) and no recorded
/etc/cmux/daemon.json. A third would have followed: the running daemon's per-machine files in the snapshot. The regular Cloud image bake (web/scripts/cmux-vm-image/bake.ts) has both; this
test holds the cmux-vmd template script to the same sources, so the two cannot drift apart again.
"""

from __future__ import annotations

import json
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-vmd/autocloud-template.sh"
LOCK = ROOT / "images/cmux-vm/inputs.lock.json"
BAKE = ROOT / "web/scripts/cmux-vm-image/bake.ts"
WIRE = ROOT / "cmux-tui/crates/cmux-host/src/cloud/wire.rs"
CONFIG = ROOT / "cmux-tui/crates/cmux-host/src/config.rs"


def script() -> str:
    return SCRIPT.read_text()


def shell_var(name: str) -> str:
    match = re.search(rf'^{name}="([^"]*)"', script(), re.M)
    assert match, f"{name} not set in {SCRIPT.name}"
    return match.group(1)


class AutocloudTemplateTest(unittest.TestCase):
    def test_syntax(self) -> None:
        subprocess.run(["bash", "-n", str(SCRIPT)], check=True)

    def test_wireguard_tools_matches_the_image_lock(self) -> None:
        lock = json.loads(LOCK.read_text())
        pinned = lock_value(lock, "wireguard-tools")
        self.assertEqual(shell_var("WG_TOOLS_VERSION"), pinned)
        self.assertIn("wireguard-tools=$WG_TOOLS_VERSION", script())

    def test_per_machine_files_match_bake_ts(self) -> None:
        block = re.search(r"PER_MACHINE_FILES = \[(.*?)\]", BAKE.read_text(), re.S)
        assert block, "bake.ts PER_MACHINE_FILES not found"
        expected = re.findall(r'"([^"]+)"', block.group(1))
        self.assertEqual(shell_var("PER_MACHINE_FILES").split(), expected)

    def test_records_the_daemon_files_cmux_host_reads(self) -> None:
        wire = WIRE.read_text()
        for const in ("DAEMON_INFO_FILE", "DAEMON_SOCKET_FILE"):
            match = re.search(rf'{const}: &str = "([^"]+)"', wire)
            assert match, f"wire.rs {const} not found"
            self.assertIn(f"> {match.group(1)}", script().replace(".tmp", ""), const)
        self.assertIn("cloud daemon-info", script())
        self.assertIn("vm-agent-v1", script())
        self.assertIn("loopback-forward-v1", script())

    def test_checks_every_bind_step_before_the_snapshot(self) -> None:
        text = script()
        layout = re.search(r'LAYOUT_MARKER_FILE: &str = "([^"]+)"', CONFIG.read_text())
        assert layout
        self.assertIn(layout.group(1), text)
        for step in ("install-key", "wg-key", "daemon-socket", "daemon-json", "json-poster", "noise-key", "updater"):
            self.assertRegex(text, rf"step {step} ", step)
        self.assertLess(text.index("step updater"), text.index("/snapshot"))

    def test_parks_the_daemon_like_bake_ts(self) -> None:
        park = re.search(r"function parkCommand\(\).*?'rm -rf ([^']+)'", BAKE.read_text(), re.S)
        assert park, "bake.ts parkCommand rm list not found"
        self.assertEqual(shell_var_single("PARK_PATHS"), park.group(1))
        self.assertIn("rm -rf $PARK_PATHS $PER_MACHINE_FILES", script())
        self.assertLess(script().index("rm -rf $PARK_PATHS"), script().index("step noise-key"))

    def test_a_fork_is_checked_before_the_templates_move(self) -> None:
        text = script()
        for step in ("fork-clock", "fork-cmux-host", "fork-wg-key", "fork-daemon-info"):
            self.assertRegex(text, rf"step {step} ", step)
        self.assertLess(text.index("/fork"), text.index("/v1/templates/"))
        self.assertIn('api -X DELETE "$VMD/v1/snapshots/$sid"', text)


def shell_var_single(name: str) -> str:
    match = re.search(rf"^{name}='([^']*)'", script(), re.M)
    assert match, f"{name} not set in {SCRIPT.name}"
    return match.group(1)


def lock_value(node: object, key: str) -> str:
    if isinstance(node, dict):
        if isinstance(node.get(key), str):
            return node[key]
        for value in node.values():
            found = lock_value(value, key)
            if found:
                return found
    return ""


if __name__ == "__main__":
    unittest.main()
