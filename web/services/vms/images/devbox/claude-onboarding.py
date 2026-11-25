#!/usr/bin/env python3
"""Seed a fresh Claude config without copying credentials or replacing user state.

Claude Code 2.1.299 reads .claude.json under CLAUDE_CONFIG_DIR when set,
otherwise under HOME. Its onboarding gate reads hasCompletedOnboarding;
theme and projects[path].hasTrustDialogAccepted are in that same document.
Verified in @anthropic-ai/claude-code-linux-x64@2.1.299 (native SHA-256
2d894a4b1bfaaa9aab72aeff7803e3c73bc2510f279a171f6b8f59f72d17d077).
"""

import json
import os
from pathlib import Path
import sys
import tempfile


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


if __name__ == "__main__":
    for argument in sys.argv[1:]:
        seed(Path(argument))
