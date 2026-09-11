#!/usr/bin/env python3
"""CLI wrapper for the target-scale resource benchmark."""

from __future__ import annotations

import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from perf_target_scale import main  # noqa: E402


if __name__ == "__main__":
    raise SystemExit(main())
