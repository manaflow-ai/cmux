"""Every registered bench: the modules in scripts/bench/benches/ that define BENCH."""
from __future__ import annotations

import importlib
import pkgutil
import sys
from pathlib import Path

from .bench import Bench

BENCHES_DIR = Path(__file__).resolve().parent.parent / "benches"


def load_all() -> dict[str, Bench]:
    parent = str(BENCHES_DIR.parent)
    if parent not in sys.path:
        sys.path.insert(0, parent)
    found: dict[str, Bench] = {}
    for info in sorted(pkgutil.iter_modules([str(BENCHES_DIR)]), key=lambda i: i.name):
        if info.name.startswith("_"):
            continue
        module = importlib.import_module(f"benches.{info.name}")
        bench = getattr(module, "BENCH", None)
        if not isinstance(bench, Bench):
            raise TypeError(f"benches/{info.name}.py defines no BENCH")
        for attr in ("name", "summary", "units", "owner", "harness"):
            if not getattr(bench, attr):
                raise TypeError(f"benches/{info.name}.py: BENCH.{attr} is empty")
        if bench.name in found:
            raise TypeError(f"two benches are named {bench.name}")
        found[bench.name] = bench
    return found
