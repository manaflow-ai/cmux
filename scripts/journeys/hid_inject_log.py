"""Reads hid_inject's script and log (handoff resize-videos/KIT.md). Python only checks files; it makes no timestamp.

  validate_script(script) -> list of problems (empty: the compiled tool will accept it)
  verdict(log) -> ("ran" | "not run", reason): a drag below the floor of its target rate is NOT RUN, as is a log
                 that did not post (plan mode) or posted no event
"""

KINDS = {"move", "key", "click", "drag", "wait"}


def _point(v):
    return isinstance(v, list) and len(v) == 2 and all(isinstance(x, (int, float)) for x in v)


def validate_script(script):
    problems = []
    steps = script.get("steps") if isinstance(script, dict) else None
    if not isinstance(steps, list) or not steps:
        return ["no steps"]
    for i, step in enumerate(steps):
        kind = step.get("do") if isinstance(step, dict) else None
        if kind not in KINDS:
            problems.append(f"step {i}: unknown do {kind!r}")
        elif kind == "key" and (isinstance(step.get("key_code"), bool) or not isinstance(step.get("key_code"), int)):
            problems.append(f"step {i}: key needs an integer key_code")
        elif kind in ("move", "click") and not all(isinstance(step.get(k), (int, float)) and not isinstance(step.get(k), bool)
                                                   for k in ("x", "y")):
            problems.append(f"step {i}: {kind} needs numbers x and y")
        elif kind == "drag":
            if not (_point(step.get("from")) and _point(step.get("to"))):
                problems.append(f"step {i}: drag needs from and to as [x, y]")
            hz = step.get("hz", 120)
            if not isinstance(hz, (int, float)) or not 1 <= hz <= 1000:
                problems.append(f"step {i}: hz must be 1..1000")
            if not isinstance(step.get("duration_ms", 0), (int, float)) or step.get("duration_ms", 0) < 0:
                problems.append(f"step {i}: duration_ms must be >= 0")
    floor = script.get("rate_floor", 0.95)
    if not isinstance(floor, (int, float)) or not 0 < floor <= 1:
        problems.append("rate_floor must be in (0, 1]")
    return problems


def verdict(log):
    if not log.get("posted"):
        return "not run", "plan mode: no event was posted"
    if not log.get("events"):
        return "not run", "no event was posted"
    floor = float(log.get("rate_floor", 0.95))
    for i, step in enumerate(log.get("steps") or []):
        target, got = step.get("target_hz"), step.get("achieved_hz")
        if target and (got is None or got < floor * target):
            return "not run", f"step {i} ({step.get('do')}): {got if got is not None else 0:.1f} Hz achieved, target {target} Hz, floor {floor:.0%}"
    return "ran", ""
