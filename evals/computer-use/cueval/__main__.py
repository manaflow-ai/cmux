# SPDX-License-Identifier: MIT
"""python3 -m cueval <command>; run from evals/computer-use. See README.md."""

from __future__ import annotations

import argparse
import json
import sys

from . import report, runner, selftest, tooltier
from .tasks import load_tasks


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="cueval")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("selftest", help="prove the harness against the fake MCP server (no display, no model)")
    s.add_argument("--out")

    t = sub.add_parser("tools", help="the deterministic tool tier against one arm (needs a display: Xvfb on Linux)")
    t.add_argument("--arm", required=True)
    t.add_argument("--out", default="out")
    t.add_argument("--settle", type=float, default=0.5, help="seconds to wait before reading a state that must not change")

    ls = sub.add_parser("list", help="list tasks")
    ls.add_argument("--split", default="all")

    for name in ("run", "prereg"):
        r = sub.add_parser(name, help="run agent task evals" if name == "run" else "write a pre-registration file")
        r.add_argument("--arms", default="cmux-cu,cua-driver-0.38.0")
        r.add_argument("--agent", choices=["claude", "codex"], default="claude")
        r.add_argument("--model", required=True)
        r.add_argument("--trials", type=int, default=5)
        r.add_argument("--tasks", help="comma list of task ids (default: every task of the split on this platform)")
        r.add_argument("--split", default="dev", choices=["dev", "heldout", "all"])
        r.add_argument("--max-turns-cap", type=int)
        r.add_argument("--seed", type=int, default=1)
        if name == "run":
            r.add_argument("--out", default="out")
            r.add_argument("--prereg")
        else:
            r.add_argument("--out", default="prereg.json")
            r.add_argument("--primary", default="success rate, cmux-cu minus cua-driver-0.38.0, Newcombe 95% CI")
            r.add_argument("--hypothesis", default="")

    rp = sub.add_parser("report", help="render out/report.html")
    rp.add_argument("--out", default="out")

    a = p.parse_args(argv)
    if a.cmd == "selftest":
        return selftest.main(a.out)
    if a.cmd == "tools":
        rs = tooltier.run(a.arm, a.out, settle=a.settle)
        for r in rs:
            print(f"{'PASS' if r['ok'] else 'FAIL'} {r['case']:24} {r['detail'][:140]}")
        print(f"{sum(r['ok'] for r in rs)}/{len(rs)} passed; report: {report.render(a.out)}")
        return 0 if all(r["ok"] for r in rs) else 1
    if a.cmd == "list":
        for t in load_tasks(split=a.split):
            print(f"{t['id']:28} {t['split']:8} {','.join(t['platforms']):20} {t['title']}")
        return 0
    arms = a.arms.split(",")
    ids = a.tasks.split(",") if a.tasks else None
    if a.cmd == "prereg":
        from . import platform_env
        tasks = load_tasks(ids, a.split, platform_env.platform_name())
        reg = runner.digest(tasks, arms, a.agent, a.model, a.trials, a.max_turns_cap)
        reg.update(primary_metric=a.primary, hypothesis=a.hypothesis, task_ids=[t["id"] for t in tasks], arms_list=arms)
        with open(a.out, "w") as f:
            json.dump(reg, f, indent=2)
        print(f"wrote {a.out} (digest {reg['digest'][:12]}); commit it before the run")
        return 0
    runner.run(arms, a.agent, a.model, a.trials, a.out, ids, a.split, a.seed, a.prereg, a.max_turns_cap)
    print(f"report: {report.render(a.out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
