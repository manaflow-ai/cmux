#!/usr/bin/env python3
"""perf100: the shared measurement runner (plans/cmux-next/perf100/README.md).

Never run it on a laptop: GUI scenarios run on cmux-lawrence-2 (nx-remote --needs gui) or the
bench worker; headless ones on rbx or an AWS Mac (scripts/measure/perf100.sh).

  perf100.py app      --app BUNDLE [--scenarios S0,S1,S2,S3,S4] [--seed 1] --out DIR
  perf100.py tui      --tui BIN    [--scenarios S0,S1,S3,S4]     [--seed 1] --out DIR
  perf100.py acpmux   --acpmux BIN [--sessions 10,100]           [--seed 1] --out DIR
  perf100.py report   DIR|FILE... [--md OUT.md]
  perf100.py compare  --before DIR|FILE... --after DIR|FILE... [--only SUBSTRING]
  perf100.py budget   --results DIR|FILE... [--budgets scripts/perf100/budgets.json]
  perf100.py extract  LOG|BUNDLE.json --out DIR   # run JSONs from an rbx log or a fleet results.json

Each run writes one JSON per scenario (schema perf100.run.v1: host, build tag, commit, scenario,
seed, every phase's per-group and per-kind counters, flat `metrics`) and `report` writes the
Markdown table. `--quick` shrinks every scenario (sizes and windows) for a harness smoke run.
"""
from __future__ import annotations

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import report  # noqa: E402
import runlib  # noqa: E402

ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))


def _paths(items: list[str]) -> list[str]:
    out = []
    for item in items:
        out.extend(report.index(item) if os.path.isdir(item) else [item])
    return out


def _build(args) -> dict:
    # A synced tree (rbx) has no .git of its own: a parent repository's HEAD would be wrong.
    own = runlib.git_sha(ROOT) if os.path.exists(os.path.join(ROOT, ".git")) else None
    return {"tag": args.tag or os.environ.get("NX_APP_TAG"), "sha": args.sha or own,
            "app": getattr(args, "app", None), "harness_sha": own}


def _common(p: argparse.ArgumentParser):
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--out", required=True)
    p.add_argument("--tag", help="build tag (default $NX_APP_TAG)")
    p.add_argument("--sha", help="commit SHA of the measured build (default: this checkout's HEAD)")
    p.add_argument("--host-class", help="budget host class (default $PERF100_HOST_CLASS or the host name)")
    p.add_argument("--idle", type=float, default=60, help="idle window seconds")
    p.add_argument("--settle", type=float, default=20, help="seconds before an idle window")
    p.add_argument("--latency-samples", type=int, default=30)
    p.add_argument("--quick", action="store_true", help="small sizes and short windows (harness smoke run)")
    p.add_argument("--md", help="also write the Markdown report here")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("app", help="GUI scenarios against a tagged bundle")
    _common(p)
    p.add_argument("--app", required=True)
    p.add_argument("--scenarios", default="S0,S1,S2,S3,S4")
    p.add_argument("--terminals", type=int, default=10)
    p.add_argument("--agent-tuis", type=int, default=3)
    p.add_argument("--tabs", type=int, default=5)
    p.add_argument("--flood-mb", type=float, default=200)
    p.add_argument("--flood-terminals", type=int, default=10)
    p.add_argument("--flood-timeout", type=float, default=900)
    p.add_argument("--agents", type=int, default=10)
    p.add_argument("--stream", default="seeded", help="fixture name, or seeded (each session draws one)")
    p.add_argument("--speed", type=float, default=2.0, help="replay speed of the recorded cadence")
    p.add_argument("--marks", type=int, default=20)
    p.add_argument("--stream-timeout", type=float, default=600)
    p.add_argument("--workspaces", type=int, default=200)
    p.add_argument("--per-workspace", type=int, default=5)
    p.add_argument("--pty-budget", type=int, default=300, help="most PTYs S3 may take on a shared host")
    p.add_argument("--pty-reserve", type=int, default=150, help="PTYs left free for other jobs")
    p.add_argument("--keep-scratch", action="store_true")

    p = sub.add_parser("tui", help="headless cmux-tui scenarios")
    _common(p)
    p.add_argument("--tui", required=True)
    p.add_argument("--scenarios", default="S0,S1,S3,S4")
    p.add_argument("--terminals", type=int, default=10)
    p.add_argument("--agent-tuis", type=int, default=3)
    p.add_argument("--flood-mb", type=float, default=200)
    p.add_argument("--flood-terminals", type=int, default=10)
    p.add_argument("--flood-timeout", type=float, default=900)
    p.add_argument("--workspaces", type=int, default=200)
    p.add_argument("--per-workspace", type=int, default=5)
    p.add_argument("--root-dir", default=None, help="scratch parent (default the temp dir; keep it short on macOS)")
    p.add_argument("--pty-budget", type=int, default=2000, help="most PTYs S3 may take (macOS)")
    p.add_argument("--pty-reserve", type=int, default=64, help="PTYs left free for others (macOS)")

    p = sub.add_parser("acpmux", help="headless acpmux S2 (agent streaming)")
    _common(p)
    p.add_argument("--acpmux", required=True)
    p.add_argument("--sessions", default="10,100")
    p.add_argument("--stream", default="seeded")
    p.add_argument("--speed", type=float, default=2.0)
    p.add_argument("--marks", type=int, default=20)
    p.add_argument("--stream-timeout", type=float, default=900)
    p.add_argument("--root-dir", default=None)

    p = sub.add_parser("report")
    p.add_argument("paths", nargs="+")
    p.add_argument("--md")

    p = sub.add_parser("compare")
    p.add_argument("--before", nargs="+", required=True)
    p.add_argument("--after", nargs="+", required=True)
    p.add_argument("--only")

    p = sub.add_parser("extract")
    p.add_argument("source")
    p.add_argument("--out", required=True)

    p = sub.add_parser("budget")
    p.add_argument("--results", nargs="+", required=True)
    p.add_argument("--budgets", default=os.path.join(HERE, "budgets.json"))
    p.add_argument("--host-class", help="this host's class: its budgets must have a matching run")

    args = parser.parse_args(argv)
    if args.command == "report":
        text = report.markdown_many(_paths(args.paths))
        if args.md:
            with open(args.md, "w") as handle:
                handle.write(text)
        print(text)
        return 0
    if args.command == "compare":
        print(report.compare(_paths(args.before), _paths(args.after), args.only))
        return 0
    if args.command == "extract":
        for path in extract(args.source, args.out):
            print(path)
        return 0
    if args.command == "budget":
        code, text = report.check_budgets(args.budgets, _paths(args.results), args.host_class)
        print(text)
        return code

    sys.path.insert(0, os.path.join(HERE, "fixtures"))
    import streams
    fixtures = streams.verify()
    if args.quick:
        _quick(args)
    build = _build(args)
    build["fixtures_sha256"] = fixtures
    if args.command == "app":
        import app_scenarios
        paths = app_scenarios.run_app(args, build, args.out)
    elif args.command == "tui":
        import headless
        paths = headless.run_tui(args, build, args.out)
    else:
        import headless
        paths = headless.run_acpmux(args, build, args.out)
    text = report.markdown_many(paths)
    md = args.md or os.path.join(args.out, f"perf100-{args.command}.md")
    with open(md, "w") as handle:
        handle.write(text)
    print(text)
    errors = [p for p in paths if report.load(p).get("error")]
    for path in errors:
        print(f"perf100: {os.path.basename(path)}: {report.load(path)['error']}", file=sys.stderr)
    return 1 if errors else 0


def extract(source: str, out_dir: str) -> list[str]:
    """Writes each run of a `PERF100-JSON <name> <json>` log or a perf100.bundle.v1 file to out_dir."""
    import json
    os.makedirs(out_dir, exist_ok=True)
    with open(source, errors="replace") as handle:
        text = handle.read()
    runs = []
    try:
        data = json.loads(text)
        runs = [(None, r) for r in data.get("runs", [])]
    except ValueError:
        for line in text.splitlines():
            i = line.find("PERF100-JSON ")
            if i >= 0:
                name, _, body = line[i + len("PERF100-JSON "):].partition(" ")
                runs.append((name, json.loads(body)))
    paths = []
    for name, run in runs:
        name = name or f"{run['scenario']}-{run['variant']}-{run['build'].get('tag') or 'untagged'}-seed{run['seed']}.json"
        path = os.path.join(out_dir, os.path.basename(name))
        with open(path, "w") as handle:
            json.dump(run, handle, indent=1)
        paths.append(path)
    return paths


def _quick(args):
    for name, value in (("idle", 10), ("settle", 3), ("latency_samples", 5), ("flood_mb", 20), ("flood_terminals", 3),
                        ("workspaces", 10), ("per_workspace", 2), ("agents", 3), ("speed", 8.0), ("marks", 5),
                        ("terminals", 4), ("agent_tuis", 1), ("tabs", 2)):
        if hasattr(args, name):
            setattr(args, name, value)
    if hasattr(args, "sessions"):
        args.sessions = "3"


if __name__ == "__main__":
    sys.exit(main())
