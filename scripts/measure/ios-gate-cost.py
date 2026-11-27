#!/usr/bin/env python3
"""Measure the always-present iOS gate's unrelated-path routing, including imports.

    cmux-ci run -- python3 scripts/measure/ios-gate-cost.py

No simulator, network call, source compile or Cargo graph walk. Runner queue/checkout are excluded; measure those from the Actions job receipt after publication.
"""
from __future__ import annotations

import json
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'ci'))
wall, cpu = time.perf_counter(), time.process_time()
import ios_gate  # noqa: E402

plan = ios_gate.plan(['docs/example.md'])
state, description = ios_gate.verdict(**plan)
print(json.dumps({'case': 'unrelated-path-with-imports', 'plan': plan, 'state': state,
                  'wall_seconds': time.perf_counter() - wall,
                  'cpu_seconds': time.process_time() - cpu,
                  'excludes': ['runner queue', 'checkout']}))
raise SystemExit(0 if state == 'success' else 1)
