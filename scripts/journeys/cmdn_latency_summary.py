#!/usr/bin/env python3
"""CMD-N LATENCY: summary of cmdn-latency journey results (cmux-ad m6 2c).

  cmdn_latency_summary.py RESULT_JSON_OR_RUN_DIR [...] [--json]

Per result and per session (light, stress), p50/p95/p99/max over the counted presses of:
  visible_ms    Cmd-N key -> the first display frame that shows the new workspace (debug.new_tab bench_create)
  confirmed_ms  Cmd-N key -> the first frame with the daemon's workspace in place of the provisional one
  key_ms        the Cmd-N key's synchronous main-thread time
  commit_ms     debug.action_budget: the newTab run (entrypoint key) to its Core Animation commit
  prompt_ms     debug.new_terminal_trace: newSurface -> prompt_contents (the new shell's first visible prompt)
Warm-up presses are not counted. A missed run (no value) is counted apart, never dropped silently."""
import json, os, sys


def pct(values, q):
    if not values:
        return None
    v = sorted(values)
    k = (len(v) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(v) - 1)
    return round(v[lo] + (v[hi] - v[lo]) * (k - lo), 2)


def next_tick_after(reply):
    frames, visible = reply.get("frames") or {}, reply.get("visible_ms")
    first = frames.get("first_tick_ms")
    if not isinstance(visible, (int, float)) or not isinstance(first, (int, float)):
        return None
    ticks, t = [first], first
    for interval in frames.get("intervals_ms") or []:
        t += max(0.0, interval)
        ticks.append(t)
    later = [x for x in ticks if x > visible + 1.0]
    return round(later[0], 2) if later else None


def stats(values):
    vals = [x for x in values if isinstance(x, (int, float))]
    return {"n": len(vals), "missed": len(values) - len(vals), "p50": pct(vals, .5), "p95": pct(vals, .95),
            "p99": pct(vals, .99), "max": round(max(vals), 2) if vals else None}


def load(path):
    if os.path.isdir(path):
        inner = [os.path.join(path, j, "result.json") for j in ("cmdn-latency", "cmdn-profile") if os.path.isdir(os.path.join(path, j))]
        path = inner[0] if inner else os.path.join(path, "result.json")
    return path, json.load(open(path))


def summarize(result):
    out = {"status": result.get("status"), "reason": result.get("reason", "")[:200], "sessions": {}}
    budgets, kinds = [], {}
    for step in result.get("steps") or []:
        res = step.get("result") or {}
        if step.get("do") == "rpc" and isinstance(res.get("reply"), dict) and "recent" in res["reply"]:
            budgets.append(res["reply"]["recent"])
        if step.get("do") != "latency_runs" or not res.get("label") or "warmup" in res["label"]:
            continue
        s = out["sessions"].setdefault(res["label"], {})
        rows = res.get("rows") or []
        if res.get("bench") == "prompt":
            s["prompt_ms"] = stats([((r.get("reply") or {}).get("marks_ms") or {}).get("prompt_contents") for r in rows])
            s["prompt_timed_out"] = sum(1 for r in rows if (r.get("reply") or {}).get("timed_out"))
        else:
            for key in ("visible_ms", "confirmed_ms", "key_ms"):
                s[key] = stats([(r.get("reply") or {}).get(key) for r in rows])
            # The frame that shows the workspace is on screen only once its commit ends; the next display-link tick
            # after the visible one comes after that commit (the link fires on the main thread), so it bounds key-to-pixels.
            s["shown_after_commit_ms"] = stats([next_tick_after((r.get("reply") or {})) for r in rows])
            kinds[res["label"]] = sorted({str(r.get("kind_after")) for r in rows})
            s["kind_after"] = kinds[res["label"]]
    # action budget: the newTab key runs of each session (the first reply: light; the new sequences of the second: stress),
    # the first 3 of each session (the warm-up presses) not counted
    seen = set()
    for label, recent in zip(("light", "stress"), budgets):
        runs = sorted((r for r in recent if r.get("id") == "newTab" and r.get("entrypoint") == "key" and r.get("sequence") not in seen),
                      key=lambda r: r.get("sequence", 0))
        seen |= {r.get("sequence") for r in recent}
        if label in out["sessions"]:
            out["sessions"][label]["commit_ms"] = stats([r.get("commit_ms") for r in runs[3:]])
    return out


def main(argv):
    as_json = "--json" in argv
    rows = []
    for arg in [a for a in argv if a != "--json"]:
        try:
            path, result = load(arg)
        except (OSError, ValueError) as error:
            rows.append({"path": arg, "error": str(error)})
            continue
        rows.append(dict(path=path, **summarize(result)))
    if as_json:
        print(json.dumps(rows, indent=1))
        return
    for row in rows:
        print(f"== {row['path']}  status={row.get('status')} {row.get('reason') or row.get('error', '')}")
        for label, s in (row.get("sessions") or {}).items():
            for key in ("visible_ms", "shown_after_commit_ms", "confirmed_ms", "key_ms", "commit_ms", "prompt_ms"):
                v = s.get(key)
                if v:
                    print(f"  {label:7s} {key:13s} n={v['n']:3d} missed={v['missed']} p50={v['p50']} p95={v['p95']} p99={v['p99']} max={v['max']}")
            if s.get("kind_after"):
                print(f"  {label:7s} Cmd-N shows: {', '.join(s['kind_after'])}")


if __name__ == "__main__":
    main(sys.argv[1:])
