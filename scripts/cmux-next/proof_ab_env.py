"""SCRATCH MEASUREMENT REF ONLY (cp/proof-ab-measure, never lands): the prove-or-remove A/B arm of one bench launch.

proof-ab.py sets PROOF_AB_ENABLE / PROOF_AB_DISABLE (comma lists of feature names) for each arm run; every bench
launch path (bench_launch.BenchApp, bench-startup.py, bench_memory.py) calls ``apply`` on the app's environment, so the
app resolves the arm through its own CMUX_ENABLE_FEATURES / CMUX_DISABLE_FEATURES (FeatureList step 2, over the
chrome-parity- tag's build defaults). ``record`` appends the launch's features.list snapshot to PROOF_AB_FEATURES_OUT,
so the driver checks that the arm really took effect."""
import json
import os

ENABLE, DISABLE, OUT = "PROOF_AB_ENABLE", "PROOF_AB_DISABLE", "PROOF_AB_FEATURES_OUT"


def _names(value):
    return [name for name in (value or "").split(",") if name]


def apply(env):
    """Adds the arm's feature lists to `env` (a launch environment dict) and returns it."""
    on, off = _names(os.environ.get(ENABLE)), _names(os.environ.get(DISABLE))
    if on:
        env["CMUX_ENABLE_FEATURES"] = ",".join(dict.fromkeys(_names(env.get("CMUX_ENABLE_FEATURES")) + on))
    if off:
        env["CMUX_DISABLE_FEATURES"] = ",".join(dict.fromkeys(_names(env.get("CMUX_DISABLE_FEATURES")) + off))
    return env


def record(snapshot, where):
    """Appends one launch's features.list snapshot ({name: {state, source}}) for the driver's arm check."""
    path = os.environ.get(OUT)
    if not path:
        return
    watched = set(_names(os.environ.get(ENABLE)) + _names(os.environ.get(DISABLE)))
    features = snapshot[0] if isinstance(snapshot, tuple) and snapshot else None
    row = {"where": where, "features": {n: v for n, v in (features or {}).items() if n in watched} if features is not None else None}
    with open(path, "a") as handle:
        handle.write(json.dumps(row) + "\n")
