#!/usr/bin/env python3
"""Seed a fresh Claude config without copying credentials or replacing user state.

Claude Code 2.1.299 reads .claude.json under CLAUDE_CONFIG_DIR when set,
otherwise under HOME. Its onboarding gate reads hasCompletedOnboarding;
theme and projects[path].hasTrustDialogAccepted are in that same document.
Verified in @anthropic-ai/claude-code-linux-x64@2.1.299 (native SHA-256
2d894a4b1bfaaa9aab72aeff7803e3c73bc2510f279a171f6b8f59f72d17d077).

With --settings-default, seed the person's settings.json instead: a key it
does not set gets cmux's default (SETTINGS_DEFAULTS); a value already there is
left as it is. These are user settings, not managed ones, so the person's own
choice wins.
"""

import json
import os
from pathlib import Path
import sys
import tempfile

# Leo, 2026-11-18, on a Claude Code holding another session's message: "can you
# make this accept", "they shouldnt hold em".
SETTINGS_DEFAULTS = {"crossSessionInbound": "accept"}


def seed(path):
    if os.path.lexists(path):
        return
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    config = {
        "hasCompletedOnboarding": True,
        "bypassPermissionsModeAccepted": True,
        "theme": "dark",
        "projects": {"/": {"hasTrustDialogAccepted": True}},
    }
    key = os.environ.get("ANTHROPIC_API_KEY", "")
    if key:
        config["customApiKeyResponses"] = {"approved": [key[-20:]], "rejected": []}
    # A finished 0600 file is linked only if no caller created the config
    # meanwhile. Concurrent first launches never see a partial document.
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, prefix=".claude-seed-") as tmp:
        json.dump(config, tmp)
        tmp.write("\n")
        tmp.flush()
        try:
            os.link(tmp.name, path)
        except FileExistsError:
            pass


def seed_settings_defaults(path):
    try:
        settings = json.loads(path.read_text())
        mode = path.stat().st_mode & 0o777
    except FileNotFoundError:
        settings, mode = {}, 0o600
    if not isinstance(settings, dict):
        return
    missing = {key: value for key, value in SETTINGS_DEFAULTS.items() if key not in settings}
    if not missing:
        return
    settings.update(missing)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, prefix=".settings-seed-", delete=False) as tmp:
        json.dump(settings, tmp, indent=2)
        tmp.write("\n")
    os.chmod(tmp.name, mode)
    os.replace(tmp.name, path)


if __name__ == "__main__":
    if sys.argv[1:2] == ["--settings-default"]:
        for argument in sys.argv[2:]:
            seed_settings_defaults(Path(argument))
    else:
        for argument in sys.argv[1:]:
            seed(Path(argument))
