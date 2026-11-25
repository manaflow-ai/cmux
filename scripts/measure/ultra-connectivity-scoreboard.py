#!/usr/bin/env python3
"""Rewrite the ultra-connectivity scoreboard's "Today" and "Source" cells from a run's bench lines.

The scoreboard is cmuxterm-hq docs/design/ultra-connectivity-scoreboard.md. This reads the lines the benches
print (any log text; other lines are ignored):

  SCOREROW {"condition":..,"pair":..,"metric":..,"value":..,"unit":..,"run":..,"host_os":..,"rig":..}
  SCOREROW-NA {"condition":..,"pair":..,"metric":..,"reason":"harness missing: ..",...}
  PAIRCELL / PAIRCELL-NA / ROUNDTRIP lines (the pair matrix, DESIGN.md) through the same selectors.

and a MAPPING: a table row, keyed by its first three cells (condition, pair, metric) exactly as the table
reads, to a template and the line selectors that fill it. A selector is {"kind", "match": {field: value},
"stat"}: it keeps the lines of that kind whose fields equal `match` (a null `value` is a failed run and counts
against `n`, not into the stats) and takes `stat` (p50, p95, max, min, mean, n, fails) of their `value`.

Rules (the lane brief):
  * Only rows in MAPPING are rewritten, and only their Today and Source cells. Every other line is kept byte
    for byte, hand-seeded rows included.
  * A row with a mapped number gets it (fresher than a hand number: this run is newer than the seed).
  * A row whose Today is a dash (starts with an em dash or is empty) and has no number gets
    "harness missing: <what>": the SCOREROW-NA reason if a bench printed one, else the MAPPING's default.
  * A hand-seeded Today is never replaced by a "harness missing".

Usage:
  ultra-connectivity-scoreboard.py --scoreboard IN.md --run-url URL [--out OUT.md] LOGFILE...
  ultra-connectivity-scoreboard.py --selftest
"""
import argparse
import json
import re
import sys

LINE = re.compile(r"\b(SCOREROW-NA|SCOREROW|PAIRCELL-NA|PAIRCELL|ROUNDTRIP) (\{.*\})\s*$")
KINDS = ("SCOREROW", "SCOREROW-NA", "PAIRCELL", "PAIRCELL-NA", "ROUNDTRIP")


def read_lines(texts):
    """[(kind, dict)] in order, from any log text."""
    out = []
    for text in texts:
        for raw in text.splitlines():
            m = LINE.search(raw)
            if not m:
                continue
            try:
                out.append((m.group(1), json.loads(m.group(2))))
            except ValueError:
                continue
    return out


def pct(values, fraction):
    values = sorted(values)
    return values[int(round((len(values) - 1) * fraction))]


STATS = {
    "p50": lambda v: pct(v, 0.5),
    "p95": lambda v: pct(v, 0.95),
    "max": max,
    "min": min,
    "mean": lambda v: sum(v) / len(v),
    "n": len,
}


def select(lines, sel):
    """The stat of the selected lines' values, or None when no run produced one."""
    kind = sel.get("kind", "SCOREROW")
    picked = [d for k, d in lines if k == kind and all(d.get(f) == v for f, v in sel["match"].items())]
    values = [d["value"] for d in picked if isinstance(d.get("value"), (int, float))]
    stat = sel.get("stat", "p50")
    if stat == "fails":
        return len(picked) - len(values) if picked else None
    if not values:
        return None
    return STATS[stat](values)


def fmt(value, places=None):
    if value is None:
        return "n/a"
    if places is not None:
        return f"{value:,.{places}f}"
    if abs(value) >= 100 or value == int(value):
        return f"{value:,.0f}"
    return f"{value:.1f}"


def na_reason(lines, condition):
    """The first SCOREROW-NA reason printed for this row's condition."""
    for kind, d in lines:
        if kind == "SCOREROW-NA" and d.get("condition") == condition:
            return d.get("reason", "").strip()
    return None


def sel(metric, stat, condition, kind="SCOREROW", **more):
    return {"kind": kind, "match": {"condition": condition, "metric": metric, **more}, "stat": stat}


# (condition, pair, metric) -> {"today": template, "sel": {name: selector}, "need": [names that must exist],
#                              "na_condition": SCOREROW condition of the NA line, "missing": default text}
# Template fields are {name} or {name:places}. Rows not here are never touched.
MAPPING = {
    ("satellite 600 ms", "iOS→Mac, Mac→Linux", "link up; keystroke echo (predicted)"): {
        "today": (
            "link up p50 / p95 {up50} / {up95} ms; remote echo p50 {rem} ms; predicted echo {pred} ms "
            "(satellite-600@1, signaling on loopback; Mac→Linux: harness missing: no Mac→Linux satellite bench)"
        ),
        "sel": {
            "up50": sel("link_up_ms", "p50", "satellite 600 ms"),
            "up95": sel("link_up_ms", "p95", "satellite 600 ms"),
            "rem": sel("keystroke_echo_remote_ms", "p50", "satellite 600 ms"),
            "pred": sel("keystroke_echo_predicted_ms", "p95", "satellite 600 ms"),
        },
        "need": ["up50"],
        "missing": "harness missing: satellite-600 bench did not report a link up",
    },
    ("airplane Wi-Fi", "iOS→Mac", "link up"): {
        "today": "{up50} / {up95} ms p50 / p95 (airplane-wifi@1, signaling on loopback; 443-only and captive parts: harness missing)",
        "sel": {
            "up50": sel("link_up_ms", "p50", "airplane Wi-Fi"),
            "up95": sel("link_up_ms", "p95", "airplane Wi-Fi"),
        },
        "need": ["up50"],
        "missing": "harness missing: airplane-wifi bench did not report a link up",
    },
    ("keystroke during 8 MB tool output", "iOS→Mac", "keystroke echo p95"): {
        "today": "{during} ms during the flood (idle {idle} ms; lte@1, n={n} keys, 8 MB on the bulk lane)",
        "sel": {
            "during": sel("keystroke_echo_during_flood_ms", "p95", "keystroke during 8 MB tool output"),
            "idle": sel("keystroke_echo_idle_ms", "p95", "keystroke during 8 MB tool output"),
            "n": sel("keystroke_echo_during_flood_ms", "n", "keystroke during 8 MB tool output"),
        },
        "need": ["during"],
        "missing": "harness missing: no key was echoed during the flood",
    },
    ("idle link, foreground", "iOS→Mac", "bytes per hour"): {
        "today": (
            "{h} B/h ({kb} KB/h; foreground probe on; probe off {off} B/h; 120 s window x 30, IP+UDP headers, lte@1)"
        ),
        "sel": {
            "h": sel("idle_bytes_per_hour", "p50", "idle link, foreground"),
            "kb": sel("idle_bytes_per_hour", "p50", "idle link, foreground"),
            "off": sel("idle_bytes_per_hour_probe_off", "p50", "idle link, foreground"),
        },
        "need": ["h"],
        "scale": {"kb": 1 / 1000.0},
        "places": {"kb": 1},
        "missing": "harness missing: the idle bench did not finish a window",
    },
    ("metered cell", "iOS→Mac", "bulk bytes sent without consent"): {
        "today": (
            "{sent} of {tried} B sent with the cellular flag set and no consent asked: not gated "
            "(the flag only caps repair data)"
        ),
        "sel": {
            "sent": sel("bulk_bytes_sent_on_cellular", "p50", "metered cell"),
            "tried": {"kind": "SCOREROW", "match": {"condition": "metered cell", "metric": "bulk_bytes_sent_on_cellular"},
                      "stat": "p50", "field": "attempted"},
        },
        "need": ["sent"],
        "missing": "harness missing: the metered bench did not send",
    },
    # Dash rows no bench in this process covers: the NA line names what is missing.
    ("captive portal", "all", 'time to "sign in" notice; cell stays live'): {"sel": {}, "need": []},
    ("explicit proxy, 443 only", "iOS→Mac, Mac→Cloud", "link up"): {"sel": {}, "need": []},
    ("TLS-inspecting proxy", "iOS→Mac, Mac→Cloud", "link up"): {"sel": {}, "need": []},
    ("IPv6-only, NAT64", "iOS→Mac", "link up"): {"sel": {}, "need": []},
    ("peer nearby, no internet", "iOS→Mac, Mac→Mac", "link up"): {"sel": {}, "need": [], "keep_hand_seed": True},
    ("idle link, background", "iOS→Mac", "energy per hour (Instruments)"): {"sel": {}, "need": []},
    ("1 MB attachment", "iOS→Mac", "CPU ms per MB"): {
        "sel": {}, "need": [], "missing": "harness missing: no bench maps to this row (no attachment CPU bench)"},
    ("re-sent attachment (already on far end)", "iOS→Mac", "time"): {
        "sel": {}, "need": [], "missing": "harness missing: no bench maps to this row", "only_dash": True},
    ("warm path", "agent VM→agent VM", "channel open to first byte"): {
        "sel": {}, "need": [], "missing": "harness missing: no bench maps to this row (needs two agent VMs)"},
    ("Mac sleeps mid-turn", "iOS viewing Mac + VM", "visible stream gap"): {
        "sel": {}, "need": [], "missing": "harness missing: no bench maps to this row (needs a Mac, a VM and a phone)"},
    ("any", "all", "RTTs added by security"): {
        "sel": {}, "need": [], "missing": "harness missing: no bench maps to this row"},
    ("chat turn bytes, metered", "iOS→Mac", "bytes per turn"): {
        "sel": {}, "need": [], "missing": "harness missing: no bench maps to this row (no dictionary yet)"},
}

ROW = re.compile(r"^\|(.*)\|\s*$")


def is_dash(cell):
    cell = cell.strip()
    return cell == "" or cell.startswith("—") or cell.startswith("-")


def render(entry, lines):
    """The Today text of an entry, or None if its needed selectors have no number."""
    if "today" not in entry:
        return None
    values = {}
    for name, s in entry["sel"].items():
        if "field" in s:  # a field of the selected lines rather than their value
            picked = [d for k, d in lines if k == s.get("kind", "SCOREROW") and all(d.get(f) == v for f, v in s["match"].items())]
            v = next((d[s["field"]] for d in picked if s["field"] in d), None)
        else:
            v = select(lines, s)
        if v is not None:
            v *= entry.get("scale", {}).get(name, 1)
        values[name] = v
    if any(values.get(n) is None for n in entry["need"]):
        return None
    out = entry["today"]
    for name, v in values.items():
        out = out.replace("{" + name + "}", fmt(v, entry.get("places", {}).get(name)))
    return out


def rewrite(text, lines, run_url, mapping=None):
    """(new text, [(key, what)]) for every row touched."""
    mapping = MAPPING if mapping is None else mapping
    out, changes = [], []
    for raw in text.split("\n"):
        m = ROW.match(raw)
        cells = [c.strip() for c in m.group(1).split("|")] if m else None
        key = tuple(cells[:3]) if cells and len(cells) == 6 else None
        entry = mapping.get(key) if key else None
        if not entry:
            out.append(raw)
            continue
        today = render(entry, lines)
        source = None
        if today is not None:
            source = f"[run]({run_url}) ({entry_rig(lines, entry)})" if run_url else "this run"
            what = "number"
        elif is_dash(cells[3]) and not entry.get("keep_hand_seed"):
            reason = na_reason(lines, entry.get("na_condition", key[0])) or entry.get("missing")
            if not reason:
                out.append(raw)
                continue
            if not reason.startswith("harness missing"):
                reason = "harness missing: " + reason
            today = reason
            source = f"[run]({run_url})" if run_url else "this run"
            what = "harness missing"
        else:
            out.append(raw)
            continue
        cells[3], cells[5] = today, source
        out.append("| " + " | ".join(cells) + " |")
        changes.append((key, what))
    return "\n".join(out), changes


def entry_rig(lines, entry):
    for s in entry["sel"].values():
        for k, d in lines:
            if k == s.get("kind", "SCOREROW") and all(d.get(f) == v for f, v in s["match"].items()) and d.get("rig"):
                return f"{d['rig']}, {d.get('host_os', '?')}"
    return "bench"


def selftest():
    sb = "\n".join([
        "| Condition | Pair | Metric | Today | Target | Source |",
        "|---|---|---|---|---|---|",
        "| airplane Wi-Fi | iOS→Mac | link up | — | ≤ 3 RTT | — |",
        "| captive portal | all | time to \"sign in\" notice; cell stays live | — | ≤ 1 s; yes | — |",
        "| peer nearby, no internet | iOS→Mac, Mac→Mac | link up | fails (no local path) | ≤ 200 ms | — |",
        "| LAN rig | iOS→Mac (real) | link up p50 / p95 | 1160 / 1270 ms | ≤ 100 ms | hand |",
        "| metered cell | iOS→Mac | bulk bytes sent without consent | not gated | 0 | — |",
        "| idle link, foreground | iOS→Mac | bytes per hour | — | — | — |",
        "",
    ])

    def sr(cond, metric, value, **more):
        d = {"condition": cond, "pair": "iOS→Mac", "metric": metric, "value": value, "unit": "ms", "run": 0,
             "host_os": "linux", "rig": "t.rs::x", **more}
        return "SCOREROW " + json.dumps(d)

    log = "\n".join([
        "noise SCOREROW {not json",
        sr("airplane Wi-Fi", "link_up_ms", 2000.0), sr("airplane Wi-Fi", "link_up_ms", 3000.0),
        sr("airplane Wi-Fi", "link_up_ms", None, error="x"),
        "SCOREROW-NA " + json.dumps({"condition": "captive portal", "reason": "harness missing: portal node"}),
        "SCOREROW-NA " + json.dumps({"condition": "peer nearby, no internet", "reason": "harness missing: offline LAN"}),
        sr("metered cell", "bulk_bytes_sent_on_cellular", 4194304, attempted=4194304),
    ])
    lines = read_lines([log])
    new, changes = rewrite(sb, lines, "https://example/run/1")
    rows = {tuple(c.strip() for c in r.split("|")[1:4]): r for r in new.split("\n") if r.startswith("| ")}
    air = rows[("airplane Wi-Fi", "iOS→Mac", "link up")]
    assert "3,000 ms" in air or "2,000 / 3,000" in air or "2,000" in air, air
    assert "[run](https://example/run/1)" in air and "t.rs::x, linux" in air, air
    assert "harness missing: portal node" in new, new
    assert "fails (no local path)" in new, "hand-seeded row replaced"
    assert "| LAN rig | iOS→Mac (real) | link up p50 / p95 | 1160 / 1270 ms | ≤ 100 ms | hand |" in new
    assert "4,194,304 of 4,194,304 B" in new, new
    idle = rows[("idle link, foreground", "iOS→Mac", "bytes per hour")]
    assert "harness missing: the idle bench did not finish a window" in idle, idle
    assert len(changes) == 4, changes
    # Idempotent: a second pass over the output changes the same rows to the same text.
    again, _ = rewrite(new, lines, "https://example/run/1")
    assert again == new
    # Stats
    assert select(lines, sel("link_up_ms", "fails", "airplane Wi-Fi")) == 1
    assert select(lines, sel("link_up_ms", "p50", "airplane Wi-Fi")) in (2000.0, 3000.0)
    print("selftest ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("logs", nargs="*")
    ap.add_argument("--scoreboard")
    ap.add_argument("--out")
    ap.add_argument("--run-url", default="")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        selftest()
        return 0
    if not args.scoreboard or not args.logs:
        ap.error("give --scoreboard FILE and one or more bench log files (or --selftest)")
    texts = []
    for path in args.logs:
        with open(path, encoding="utf-8", errors="replace") as f:
            texts.append(f.read())
    with open(args.scoreboard, encoding="utf-8") as f:
        text = f.read()
    new, changes = rewrite(text, read_lines(texts), args.run_url)
    with open(args.out or args.scoreboard, "w", encoding="utf-8") as f:
        f.write(new)
    for key, what in changes:
        print(f"{what}: {' | '.join(key)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
