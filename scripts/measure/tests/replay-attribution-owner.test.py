#!/usr/bin/env python3
"""replay-attribution's script_owner names an owner for every React render sample (no bare "React render" row)."""
import importlib.util
import pathlib
import sys

path = pathlib.Path(__file__).resolve().parents[1] / "replay-attribution.py"
spec = importlib.util.spec_from_file_location("replay_attribution", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
own = mod.script_owner

cases = [  # innermost first
    (["useMemo", "AcpmuxPane", "renderWithHooks", "beginWork", "workLoopSync", "performWorkOnRoot"],
     "React render: AcpmuxPane"),
    (["t1", "renderWithHooks", "beginWork", "workLoopSync", "performWorkOnRoot"], "React render: t1"),
    (["", "renderWithHooks", "beginWork", "workLoopSync", "performWorkOnRoot"], "React render: (anon)"),
    (["reconcileChildFibers", "beginWork", "workLoopSync", "performWorkOnRoot"], "React render (React internals)"),
    (["commitMutationEffects", "commitRoot", "performWorkOnRoot"], "React commit (DOM mutation)"),
    (["onMessage", "dispatch"], "script: dispatch"),
]
bad = [(f, want, own(f)) for f, want in cases if own(f) != want]
for f, want, got in bad:
    print(f"FAIL {f}: want {want!r}, got {got!r}")
sys.exit(1 if bad else 0)
