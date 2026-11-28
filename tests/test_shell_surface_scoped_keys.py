#!/usr/bin/env python3
"""The three shell integrations must agree on which env keys are surface-scoped.

A key in `_CMUX_TMUX_SYNC_KEYS` is pushed to tmux's *global* session
environment, so every pane in the session inherits the first pane's value. A
key in `_CMUX_TMUX_SURFACE_SCOPED_KEYS` is unset there instead, leaving each
pane its own inherited value.

A per-surface key that is in neither list gets the sync path's default
behaviour: tmux hoists the server's inherited copy into the global
environment and every later pane reads the *first* surface's value. That is
silent and per-user -- surface B reads and writes surface A's shell history
-- and no existing test catches it, because the tmux-driven history tests run
only on the `macos-shell` lane.

These checks are pure text, so they run on every pull request.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INTEGRATION = ROOT / "Resources/shell-integration"

BASH = INTEGRATION / "cmux-bash-integration.bash"
ZSH = INTEGRATION / "cmux-zsh-integration.zsh"
FISH = INTEGRATION / "fish/config.fish"

# Keys whose value identifies one surface. Inheriting another surface's value
# is a correctness bug, not a cosmetic one.
REQUIRED_SURFACE_SCOPED = {
    "CMUX_HISTORY_FILE",
    "CMUX_PANEL_ID",
    "CMUX_SURFACE_ID",
}


def _array_keys(text: str, name: str) -> set[str]:
    """Keys from a `name=( ... )` array declaration (bash/zsh)."""
    match = re.search(rf"{re.escape(name)}=\(\s*(.*?)\)", text, re.S)
    assert match, f"{name} declaration not found"
    return set(match.group(1).split())


def _fish_keys(text: str, name: str) -> set[str]:
    """Keys from fish's `set -g name a b c` (optionally continued with \\)."""
    match = re.search(rf"set -g {re.escape(name)}\s+((?:[^\n\\]|\\\n)*)", text)
    assert match, f"{name} declaration not found"
    return set(match.group(1).replace("\\\n", " ").split())


class SurfaceScopedKeyParityTests(unittest.TestCase):
    def scoped(self) -> dict[str, set[str]]:
        return {
            "bash": _array_keys(BASH.read_text(), "_CMUX_TMUX_SURFACE_SCOPED_KEYS"),
            "zsh": _array_keys(ZSH.read_text(), "typeset -ga _CMUX_TMUX_SURFACE_SCOPED_KEYS"),
            "fish": _fish_keys(FISH.read_text(), "_CMUX_TMUX_SURFACE_SCOPED_KEYS"),
        }

    def synced(self) -> dict[str, set[str]]:
        return {
            "bash": _array_keys(BASH.read_text(), "_CMUX_TMUX_SYNC_KEYS"),
            "zsh": _array_keys(ZSH.read_text(), "typeset -ga _CMUX_TMUX_SYNC_KEYS"),
            "fish": _fish_keys(FISH.read_text(), "_CMUX_TMUX_SYNC_KEYS"),
        }

    def test_every_shell_scopes_the_required_keys(self):
        for shell, keys in self.scoped().items():
            with self.subTest(shell=shell):
                self.assertEqual(
                    sorted(REQUIRED_SURFACE_SCOPED - keys),
                    [],
                    f"{shell} does not scope these per-surface keys, so tmux "
                    "hoists the first surface's value to every pane",
                )

    def test_the_three_shells_agree(self):
        scoped = self.scoped()
        self.assertEqual(
            scoped["bash"],
            scoped["zsh"],
            "bash and zsh disagree on the surface-scoped key set",
        )
        self.assertEqual(
            scoped["bash"],
            scoped["fish"],
            "bash and fish disagree on the surface-scoped key set",
        )

    def test_no_key_is_both_synced_and_scoped(self):
        scoped, synced = self.scoped(), self.synced()
        for shell in scoped:
            with self.subTest(shell=shell):
                both = sorted(scoped[shell] & synced[shell])
                self.assertEqual(
                    both,
                    [],
                    f"{shell} both publishes and unsets these keys; the push "
                    "order then decides what a pane sees",
                )


if __name__ == "__main__":
    unittest.main()
