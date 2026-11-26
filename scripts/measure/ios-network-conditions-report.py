#!/usr/bin/env python3
"""The network-conditions report: NETCOND lines in, report.json and a markdown table out.

Input lines (ios-network-conditions.sh writes them): `LABEL {json}`, LABEL before or after, the
json one value: {"surface", "profile" (name@version), "phase", "scale", "metric", "value", "run",
"seed"}. A null value is a run that did not get there within the bench's bound: it counts as a
miss (shown as `n/miss`), never as a number.

report.json: {"after": SHA, "before": SHA|null, "rows": [{surface, profile, phase, scale, metric,
"after": {p50, p95, n, miss}, "before": {...}|null}]}. report.md: one table per surface.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from collections import defaultdict

METRIC_ORDER = [
    "r1_ms",
    "first_content_ms",
    "setup_ms",
    "interactive_ms",
    "gap_after_link_back_ms",
    "gap_total_ms",
    "settle_ms",
    "gap_after_settle_ms",
    "redial_after_drop_ms",
    "dial_from_link_back_ms",
    "dial_open_ms",
    "bytes_down",
    "bytes_up",
    "round_trips",
]
# path-change is the app's redial on a blackout (the row targets read); harness-dark-dial is the
# harness's own dial from the dark riding the shaper's SYN backoff, kept for comparison.
PHASE_ORDER = [
    "cold", "warm", "warm-again", "warm-full", "streaming", "reconnect", "path-change", "harness-dark-dial",
    "send", "attach", "fixture", "home", "settled_serial", "settled_batched", "reattach",
]


def first_content_summary(rows: list[dict]) -> list[str]:
    """First content, p50 / p95 ms, profile x history scale x phase; then each phase's p95 at
    the largest scale over the smallest (history size must not move first content). With a
    before, the summary shows after; the change is in the detail tables below."""
    label = "after"
    cells: dict[tuple, dict] = {}
    for row in rows:
        if row["metric"] == "first_content_ms" and row[label] and row[label]["n"]:
            cells[(row["surface"], row["profile"], row["scale"], row["phase"])] = row[label]
    out: list[str] = []
    for surface in sorted({k[0] for k in cells}):
        phases = [p for p in PHASE_ORDER if any(k[0] == surface and k[3] == p for k in cells)]
        profiles = list(dict.fromkeys(k[1] for k in cells if k[0] == surface))
        scales = sorted({k[2] for k in cells if k[0] == surface}, key=scale_order)
        out.append(f"### {surface}: first content ms, p50 / p95 (n per cell in report.json)")
        out.append("")
        out.append("| profile | history | " + " | ".join(phases) + " |")
        out.append("|---|---|" + "---|" * len(phases))
        for profile in profiles:
            for scale in scales:
                vals = []
                for phase in phases:
                    c = cells.get((surface, profile, scale, phase))
                    vals.append(f"{c['p50']:,.0f} / {c['p95']:,.0f}" if c else "-")
                if any(v != "-" for v in vals):
                    out.append(f"| {profile} | {scale} | " + " | ".join(vals) + " |")
            history = [sc for sc in scales if scale_order(sc)[0] == 0]
            if len(history) >= 2:
                lo, hi = history[0], history[-1]
                ratio = []
                for phase in phases:
                    a, b = cells.get((surface, profile, lo, phase)), cells.get((surface, profile, hi, phase))
                    ratio.append(f"{b['p95'] / a['p95']:.2f}" if a and b and a["p95"] else "-")
                if any(r != "-" for r in ratio):
                    out.append(f"| {profile} | p95 {hi}/{lo} | " + " | ".join(ratio) + " |")
        out.append("")
    return out


def scale_order(scale: str) -> tuple:
    # history scales sort by size ("1x" < "10x"), then mode=duress's idle before duress; any
    # other named scale such as "ios" sorts after them
    if re.fullmatch(r"\d+x", scale):
        return (0, int(scale[:-1]), "")
    if scale in DURESS_SCALES:
        return (1, DURESS_SCALES[scale], scale)
    return (2, 0, scale)


READ_FIRST_LEGEND = (
    "R2 time to fresh = first_content_ms (tap to the first frame from the Mac); "
    "R1 time to readable = r1_ms (tap to the first frame from the phone's own store, link cut)"
)
# settled_*: link up to the settled Workspaces list, the setup in 4 serial round trips or 1.
DURESS_PHASES = ("home", "settled_serial", "settled_batched", "reattach")
# mode=duress: the idle fixture and the loaded daemon (mobile_link_conditions.rs open_path_under_duress).
DURESS_SCALES = {"idle": 0, "duress": 1}
DURESS_METRICS = ["round_trips", "bytes_down", "first_content_ms", "setup_ms", "interactive_ms", "workspaces_shown"]


# mode=background (cmux-next-ios/design/background-delta-sync.md): scale `<away>-<load>`, phase
# the phone's form (before: today's; after: the cursor form; after_bounded: + resume_max_bytes).
BACKGROUND_SCALE = re.compile(r"^(\d+)([smh])-(idle|busy)$")
BACKGROUND_PHASES = ("before", "after", "after_bounded")
BACKGROUND_SURFACES = ("workspaces", "chat", "terminal")


def background_scale(scale: str):
    """`1h-busy`: (load, seconds away), or None for another mode's scale."""
    match = BACKGROUND_SCALE.match(scale)
    if not match:
        return None
    number, unit, load = match.groups()
    return load, int(number) * {"s": 1, "m": 60, "h": 3600}[unit]


def background_table(rows: list[dict]) -> list[str]:
    """mode=background: one table, a row per surface x load x time away x profile; per phone
    form the catch-up p50 / p95, bytes down and round trips (p50), and whether the host answered
    from the cursor (cursor_hit: the runs that did / n)."""
    bg = [row for row in rows if background_scale(row["scale"]) and row["phase"] in BACKGROUND_PHASES]
    if not bg:
        return []
    by_key = {(row["surface"], row["scale"], row["profile"], row["phase"], row["metric"]): row["after"] for row in bg}
    phases = [phase for phase in BACKGROUND_PHASES if any(row["phase"] == phase for row in bg)]
    keys = sorted(
        {(row["surface"], row["scale"], row["profile"]) for row in bg},
        key=lambda k: (
            BACKGROUND_SURFACES.index(k[0]) if k[0] in BACKGROUND_SURFACES else 9,
            background_scale(k[1])[0] != "idle",
            background_scale(k[1])[1],
            k[2],
        ),
    )

    def p50(summary):
        return summary.get("p50") if summary and "p50" in summary else None

    def num(value, unit=""):
        if value is None:
            return "-"
        if unit == " B":
            for size, name in ((1 << 20, " MiB"), (1 << 10, " KiB")):
                if value >= size:
                    return f"{value / size:,.1f}{name}"
        return f"{value:,.0f}{unit}"

    def latency(summary):
        if not summary:
            return "-"
        if "p50" not in summary:
            return f"miss {summary['miss']}"
        text = f"{num(summary['p50'])} / {num(summary['p95'])}"
        return text + (f" ({summary['miss']} miss)" if summary["miss"] else "")

    def hit(summary):
        if not summary or "p50" not in summary:
            return ""
        # cursor_hit is 0 or 1 per run: p50 1 is most runs.
        return " [cursor]" if summary["p50"] >= 1 else " [full]" if summary["p95"] < 1 else " [cursor some runs]"

    head = ["surface", "load", "away", "profile", "events behind"]
    for phase in phases:
        head += [f"catch-up ms {phase} p50 / p95", f"bytes down {phase}", f"round trips {phase}"]
    out = [
        "### background: catch-up after time away (p50 / p95 ms; bytes and round trips p50; "
        "`[cursor]`: the host answered from the phone's cursor, `[full]`: it sent the whole surface)",
        "",
        "| " + " | ".join(head) + " |",
        "|" + "---|" * len(head),
    ]
    for surface, scale, profile in keys:
        load, secs = background_scale(scale)
        away = scale.rsplit("-", 1)[0]
        behind = p50(by_key.get((surface, scale, profile, "before", "events_behind")))
        held = p50(by_key.get((surface, scale, profile, "after", "held_behind")))
        unit = " B" if surface == "terminal" else ""
        behind_text = num(behind, unit)
        if held is not None and behind is not None and held < behind:
            behind_text += f" (host held {num(held, unit)})"
        cells = [surface, load, away, profile, behind_text]
        for phase in phases:
            get = lambda metric: by_key.get((surface, scale, profile, phase, metric))
            cells += [
                latency(get("catch_up_ms")) + ("" if phase == "before" else hit(get("cursor_hit"))),
                num(p50(get("bytes_down")), " B"),
                num(p50(get("round_trips"))),
            ]
        out.append("| " + " | ".join(cells) + " |")
    out.append("")
    return out


def percentile(values: list[float], q: float) -> float:
    ordered = sorted(values)
    # Nearest rank: a p95 of 5 runs is the slowest run, never an interpolation below it.
    rank = max(1, math.ceil(q * len(ordered)))
    return ordered[rank - 1]


def summarize(values: list[float | None]) -> dict:
    present = [v for v in values if v is not None]
    out = {"n": len(present), "miss": len(values) - len(present)}
    if present:
        out["p50"] = round(percentile(present, 0.5), 1)
        out["p95"] = round(percentile(present, 0.95), 1)
    return out


def fmt(summary: dict | None, metric: str) -> str:
    if not summary:
        return "-"
    if "p50" not in summary:
        return f"miss {summary['miss']}/{summary['miss']}"
    unit = "" if metric in ("round_trips", "workspaces_shown") else (" B" if metric.startswith("bytes") else " ms")
    p50, p95 = summary["p50"], summary["p95"]
    num = lambda v: f"{v:,.0f}" if abs(v) >= 10 else f"{v:g}"
    text = f"{num(p50)}{unit}" if p50 == p95 else f"{num(p50)} / {num(p95)}{unit}"
    if summary["miss"]:
        text += f" ({summary['miss']} miss)"
    return text


def change(before: dict | None, after: dict | None) -> str:
    if not before or not after or "p50" not in before or "p50" not in after or before["p50"] == 0:
        return ""
    return f"{(after['p50'] - before['p50']) / before['p50'] * 100:+.0f}%"


def duress_table(rows: list[dict], before: str | None) -> list[str]:
    """mode=duress: phase x metric, a column per link (the idle fixture first), before -> after
    p50, and FLAG where a duress after-p50 is more than 2x the idle fixture's after-p50."""
    duress = [row for row in rows if row["scale"] in DURESS_SCALES and row["phase"] in DURESS_PHASES]
    if not duress:
        return []
    by_key = {(row["phase"], row["metric"], row["profile"], row["scale"]): row for row in duress}
    links = sorted({row["profile"] for row in duress if row["scale"] == "duress"}, key=lambda p: (p != "none", p))
    columns = []
    for link in links:
        name = "no shaper" if link == "none" else link
        columns += [(link, "idle", f"{name}, idle fixture"), (link, "duress", f"{name} + duress")]
    fixture = {row["scale"]: row for row in rows if row["phase"] == "fixture" and row["metric"] == "stream_bytes_per_s"}

    def p50(summary: dict | None):
        return summary.get("p50") if summary else None

    def cell(row: dict | None, idle: dict | None) -> str:
        if not row:
            return "-"
        after = row["after"]
        text = fmt(after, row["metric"])
        if before:
            text = f"{fmt(row['before'], row['metric'])} -> {text}"
        value, idle_after = p50(after), p50(idle["after"]) if idle else None
        if row["scale"] == "duress" and row["metric"] != "workspaces_shown" and value is not None and idle_after:
            if value > 2 * idle_after:
                text += f" **FLAG {value / idle_after:.1f}x idle**"
        return text

    out = ["### duress: p50 (/ p95)" + (" before -> after" if before else "") + "; FLAG: a duress after > 2x the idle fixture's after on the same link", ""]
    stream = fixture.get("duress")
    if stream and stream.get("after"):
        out.append(f"duress stream rate at the daemon: {fmt(stream['after'], 'bytes_down')}/s")
        out.append("")
    out.append("| phase | metric | " + " | ".join(label for _, _, label in columns) + " |")
    out.append("|---|---|" + "---|" * len(columns))
    for phase in DURESS_PHASES:
        for metric in DURESS_METRICS:
            cells = [by_key.get((phase, metric, link, scale)) for link, scale, _ in columns]
            if not any(cells):
                continue
            idle = {link: by_key.get((phase, metric, link, "idle")) for link in links}
            out.append(f"| {phase} | {metric} | " + " | ".join(
                cell(row, idle[link]) for row, (link, _, _) in zip(cells, columns)) + " |")
    out.append("")
    return out


SEND_ROWS = ["idle", "lte", "lossy-3", "link-down", "duress"]


def send_table(values: dict, surface: str, label: str) -> list[str]:
    """mode=send: one line per row: tap to visible as sent (p50 / p95, n sends, misses) and, from
    what the host applied, double and lost sends per 100 sends (phase `send`, scale = the row)."""
    rows = {}
    for (surf, profile, phase, scale, metric), by_label in values.items():
        if surf == surface and phase == "send" and label in by_label:
            rows.setdefault(scale, {"profile": profile})[metric] = by_label[label]
    if not rows:
        return []
    out = [
        "| row | link | sends | visible as sent p50 / p95 | not visible (miss) | double / 100 | lost / 100 | retries |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for scale in sorted(rows, key=lambda r: SEND_ROWS.index(r) if r in SEND_ROWS else 99):
        row = rows[scale]
        visible = summarize(row.get("send_visible_ms", []))
        sends = int(sum(v for v in row.get("sends", []) if v is not None))

        def per100(metric: str) -> str:
            if not sends or metric not in row:
                return "-"
            count = sum(v for v in row[metric] if v is not None)
            return f"{count / sends * 100:.1f} ({count:g}/{sends})"

        retries = sum(v for v in row.get("retries", []) if v is not None)
        total = visible["n"] + visible["miss"]
        out.append(
            f"| {scale} | {row['profile']} | {sends or total} | {fmt(visible, 'send_visible_ms').split(' (')[0]} "
            f"| {visible['miss']} | {per100('double_sends')} | {per100('lost_sends')} | {retries:g} |"
        )
    out.append("")
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("lines")
    parser.add_argument("--json", required=True)
    parser.add_argument("--markdown", required=True)
    parser.add_argument("--before")
    parser.add_argument("--after", required=True)
    args = parser.parse_args()

    values: dict[tuple, dict[str, list]] = defaultdict(lambda: defaultdict(list))
    with open(args.lines) as handle:
        for line in handle:
            label, _, payload = line.strip().partition(" ")
            if not payload:
                continue
            try:
                row = json.loads(payload)
            except json.JSONDecodeError:
                print(f"ios-network-conditions-report: skipped a line that is not json: {line.strip()[:120]}", file=sys.stderr)
                continue
            key = (row["surface"], row["profile"], row["phase"], row["scale"], row["metric"])
            values[key][label].append(row["value"])

    def order(key: tuple):
        surface, profile, phase, scale, metric = key
        return (
            surface,
            profile,
            PHASE_ORDER.index(phase) if phase in PHASE_ORDER else 9,
            scale_order(scale),
            METRIC_ORDER.index(metric) if metric in METRIC_ORDER else 99,
        )

    rows = []
    for key in sorted(values, key=order):
        surface, profile, phase, scale, metric = key
        by_label = values[key]
        rows.append(
            {
                "surface": surface,
                "profile": profile,
                "phase": phase,
                "scale": scale,
                "metric": metric,
                "after": summarize(by_label["after"]) if "after" in by_label else None,
                "before": summarize(by_label["before"]) if "before" in by_label else None,
            }
        )
    with open(args.json, "w") as handle:
        json.dump({"after": args.after, "before": args.before, "rows": rows}, handle, indent=1)

    # The read-first track's two headline numbers (goals/mobile-speed-ios-bench.md in cmuxterm-hq):
    # R1 time to readable (tap to the first frame drawn from the phone's own store, link cut) and
    # R2 time to fresh (tap to the frame that matches the Mac). This headless leg has no phone
    # store, so its first_content_ms (first content from the real daemon) is R2; R1 comes from the
    # simulator leg's r1_ms rows when present.
    out = [READ_FIRST_LEGEND, "", *first_content_summary(rows)]
    for surface in sorted({row["surface"] for row in rows if not background_scale(row["scale"])}):
        out.append(f"### {surface} (p50 / p95; after {args.after[:12]}" + (f", before {args.before[:12]})" if args.before else ")"))
        out.append("")
        if args.before:
            out.append("| profile | phase | scale | metric | before | after | change |")
            out.append("|---|---|---|---|---|---|---|")
        else:
            out.append("| profile | phase | scale | metric | value |")
            out.append("|---|---|---|---|---|")
        for row in rows:
            if row["surface"] != surface or row["phase"] == "send" or background_scale(row["scale"]):
                continue
            cells = [row["profile"], row["phase"], row["scale"], row["metric"]]
            if args.before:
                cells += [fmt(row["before"], row["metric"]), fmt(row["after"], row["metric"]), change(row["before"], row["after"])]
            else:
                cells += [fmt(row["after"], row["metric"])]
            out.append("| " + " | ".join(cells) + " |")
        out.append("")
        sends = send_table(values, surface, "after")
        if sends:
            out += [f"### {surface} send: tap to visible as sent, double and lost sends per 100", ""] + sends
    out += duress_table(rows, args.before)
    out += background_table(rows)
    with open(args.markdown, "w") as handle:
        handle.write("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
