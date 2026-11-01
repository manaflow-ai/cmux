#!/usr/bin/env python3
"""Offer the explicitly activated native signer; never infer capability from OS.

Activation follows a real owned-Mac keychain/notarytool fixture and exclusive
admission on every member of the dedicated label. Every consuming job still
checks the current attempt, exclusive claim and trusted hook before credentials.
No activation, a retry, or any other repository/ref/event retains Linux signing.
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Mapping

LABEL = "glaeda-nightly-only-m4pro"
CAPABILITY = "keychain-v1"


def native_pool(env: Mapping[str, str]) -> str:
    required = {
        "GITHUB_REPOSITORY": "manaflow-ai/cmux",
        "GITHUB_REF": "refs/heads/nightly-next",
        "GITHUB_EVENT_NAME": "push",
        "GITHUB_RUN_ATTEMPT": "1",
        "ENABLED": "1",
        "OWNED_ENABLED": "1",
        "NATIVE_SIGNER_CAPABILITY": CAPABILITY,
        "NIGHTLY_ONLY_LABEL": LABEL,
    }
    return LABEL if all(env.get(key) == value for key, value in required.items()) else ""


def main(env: Mapping[str, str] = os.environ) -> int:
    label = native_pool(env)
    with Path(env["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
        output.write(f"owned_pool={label}\n")
    print("native signing: " + (label or "not activated; retain trusted Linux fallback"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
