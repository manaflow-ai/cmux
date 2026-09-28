"""scripts/fuzz: seeded UI fuzzing of cmux.

On a Mac with a cmux DEV build and a console session nobody is using (the fleet runs it as an idle gap fill,
glaeda-idle-warm --fuzz; never on a laptop someone is using):

    scripts/fuzz run --app "<path>/cmux DEV.app" --minutes 30 [--seed S] [--focus splits,drag]
    scripts/fuzz replay <finding>/repro.json --app "<path>/cmux DEV.app"
    scripts/fuzz regressions --app "<path>/cmux DEV.app"

Anywhere with gh, on a finding a run recorded (session-NNN/ with finding.json):

    scripts/fuzz issue <finding dir>            # print the issue it would file, and any existing match
    scripts/fuzz issue <finding dir> --file     # upload its frames, then file it or comment on the match
"""

from __future__ import annotations

import argparse
import json
import random
import subprocess
import sys
import time
from pathlib import Path

from . import areas, triage

REPO = Path(__file__).resolve().parents[3]
REGRESSIONS = REPO / "dogfood/fuzz/regressions"


def _weights(args: argparse.Namespace) -> dict[str, float]:
    focus = areas.parse_focus(getattr(args, "focus", None))
    if focus:
        return focus
    paths: list[str] = []
    changed = getattr(args, "changed_files", None)
    if changed and Path(changed).exists():
        paths = [line.strip() for line in Path(changed).read_text().splitlines() if line.strip()]
    elif (REPO / ".git").exists():
        try:
            paths = areas.recent_main_paths(REPO, "HEAD")
        except subprocess.CalledProcessError:
            paths = []
    return areas.weights_from_counts(areas.areas_for_paths(paths))


def cmd_run(args: argparse.Namespace) -> int:
    from .runner import Fuzzer

    seed = args.seed if args.seed is not None else random.randrange(1 << 31)
    out = Path(args.out or f"/tmp/cmux-fuzz/{time.strftime('%Y%m%d-%H%M%S')}-{seed}")
    weights = _weights(args)
    meta = {"seed": seed, "app": str(args.app), "minutes": args.minutes, "weights": weights,
            "ref_label": args.label or "", "sha": args.sha or "", "started": int(time.time())}
    out.mkdir(parents=True, exist_ok=True)
    (out / "run.json").write_text(json.dumps(meta, indent=1))
    print(f"fuzz: seed {seed}, {args.minutes:g} min, out {out}", flush=True)
    print(f"fuzz: weights {json.dumps({k: round(v, 2) for k, v in weights.items()})}", flush=True)
    fz = Fuzzer(app=Path(args.app), out=out, seed=seed, area_weights=weights, use_pointer=not args.no_pointer,
                log=lambda m: print(f"fuzz: {m}", flush=True), sha=args.sha or "", label=args.label or "")
    summary = fz.fuzz(args.minutes, steps_per_session=args.steps, max_findings=args.max_findings,
                      minimize_minutes=args.minimize_minutes)
    print(json.dumps({"fuzz": "done", **{k: v for k, v in summary.items()}}), flush=True)
    return 2 if "launch_failed" in summary else 0  # the build never started: not a clean run


def cmd_replay(args: argparse.Namespace) -> int:
    from .runner import replay

    repro = json.loads(Path(args.repro).read_text())
    out = Path(args.out or f"/tmp/cmux-fuzz-replay-{int(time.time())}")
    out.mkdir(parents=True, exist_ok=True)
    (out / "frames").mkdir(exist_ok=True)
    result = replay(Path(args.app), repro, out, use_pointer=not args.no_pointer)
    if result.failure:
        print(f"reproduced: {result.failure.signature.title} at step {result.failed_step} "
              f"[{result.failure.signature.digest}]")
        return 1
    print(f"passed: {len(result.steps)} steps, no failure")
    return 0


def cmd_regressions(args: argparse.Namespace) -> int:
    from .runner import replay

    failed = []
    repros = sorted(REGRESSIONS.glob("*.json"))
    if not repros:
        print(f"no repros in {REGRESSIONS}")
    for path in repros:
        repro = json.loads(path.read_text())
        out = Path(args.out or "/tmp/cmux-fuzz-regressions") / path.stem
        out.mkdir(parents=True, exist_ok=True)
        (out / "frames").mkdir(exist_ok=True)
        result = replay(Path(args.app), repro, out, use_pointer=not args.no_pointer)
        status = "FAIL" if result.failure else "ok"
        print(f"{status} {path.name}" + (f": {result.failure.signature.title}" if result.failure else ""))
        if result.failure:
            failed.append(path.name)
    return 1 if failed else 0


def cmd_issue(args: argparse.Namespace) -> int:
    result = triage.file_or_comment(Path(args.finding), file=args.file, repo=args.repo, redact=args.redact)
    print(json.dumps(result, indent=1) if not args.file else json.dumps({k: v for k, v in result.items()
                                                                          if k != "body"}))
    return 0


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = argparse.ArgumentParser(prog="scripts/fuzz", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    def common_local(p: argparse.ArgumentParser) -> None:
        p.add_argument("--app", required=True, help="path to a cmux DEV .app")
        p.add_argument("--out")
        p.add_argument("--no-pointer", action="store_true", help="socket actions only (no cua-driver)")

    run = sub.add_parser("run", help="fuzz a local app")
    common_local(run)
    run.add_argument("--minutes", type=float, default=30)
    run.add_argument("--seed", type=int)
    run.add_argument("--focus", help=f"areas to lean on: {','.join(areas.AREAS)}")
    run.add_argument("--changed-files", help="file listing changed paths (weights toward their areas)")
    run.add_argument("--steps", type=int, default=400, help="steps per app session")
    run.add_argument("--max-findings", type=int, default=5)
    run.add_argument("--minimize-minutes", type=float, default=20)
    run.add_argument("--label", help="what is fuzzed, for the report (main, PR #N)")
    run.add_argument("--sha")
    run.set_defaults(fn=cmd_run)

    rep = sub.add_parser("replay", help="replay one repro")
    rep.add_argument("repro")
    common_local(rep)
    rep.set_defaults(fn=cmd_replay)

    reg = sub.add_parser("regressions", help="replay every checked-in repro; fails if any reproduces")
    common_local(reg)
    reg.set_defaults(fn=cmd_regressions)

    iss = sub.add_parser("issue", help="dedupe one finding against cmux issues and file it")
    iss.add_argument("finding", help="a session directory holding finding.json")
    iss.add_argument("--file", action="store_true", help="upload frames and file or comment (default: dry run)")
    iss.add_argument("--repo", default=triage.REPO)
    iss.add_argument("--redact", action="append", default=[], metavar="NAME",
                     help="a name to keep out of the issue (the host the finding came from); repeatable")
    iss.set_defaults(fn=cmd_issue)

    args = parser.parse_args(argv)
    return args.fn(args)
