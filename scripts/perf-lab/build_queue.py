#!/usr/bin/env python3
"""`lab.py queue typecheck`: MQ15, the slow type-check functions of the builder story incremental-build.

    python3 -I scripts/perf-lab/lab.py queue typecheck [--dir RUN_OUT | --log COMPILER_LOG] [--json]

One task per repository file, files ordered by their slowest function body over 100 ms, then by path. The story
(scripts/perf-lab/stories/incremental_build.py) writes the queue as typecheck-queue.json next to its result; this
module only gives lab.py the command.
"""
from __future__ import annotations

import argparse
import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB_COMMANDS = {"queue": "MQ15: slow type-check functions (> 100 ms) from incremental-build, one task per file"}


def _story():
    name = "perf_lab_incremental_build_story"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, HERE / "stories" / "incremental_build.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    _story().add_queue_arguments(parser)


def run(command: str, args: argparse.Namespace) -> int:
    return _story().queue_command(args)
