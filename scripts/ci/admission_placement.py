#!/usr/bin/env python3
"""Pin compile admission to an idle root runner on a mini running no root job.

pr_runner_pool.py places a run's jobs in `changes`, before admission
queues. A std mini has two root runners and a compile takes either free
root, so two compiles can share a mini while another mini's root runners sit
idle. ci-macos.yml's admission-placement job runs this just before
admission, on attempt 1 with `vars.CI_OWNED_SPREAD == '1'`, when the picker
put admission on a pool with a root count. It lists the runners through the
org route App (as late_placement.py does) and picks, in order:

- spread: an idle root runner on a mini none of whose root runners is busy
  (pr_runner_pool.spread_admission_runner()), a warm one when there is one;
- warm: an idle root runner warm for the run's merge base (ADMISSION_WARM,
  the picker's `admission_warm`), when every mini runs a root job;
- root: the root label alone.

Output `runner` is admission's runs-on as a JSON array (`["<root label>",
"glaeda-runner-<name>"]`, or `["<root label>"]`), and `placement` says which
(spread, spread-warm, warm, root). When the runners cannot be read both are
empty, and admission keeps the picker's `admission_runner`.
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence


def _picker():
    path = Path(__file__).with_name("pr_runner_pool.py")
    spec = importlib.util.spec_from_file_location("pr_runner_pool", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("pr_runner_pool", module)
    spec.loader.exec_module(module)
    return module


pool = _picker()


def warm_names(raw: str | None) -> set[str]:
    """ADMISSION_WARM: a JSON array of runner names; anything else names none."""
    try:
        data = json.loads((raw or "").strip() or "[]")
    except ValueError:
        return set()
    return {name for name in data if isinstance(name, str)} if isinstance(data, list) else set()


def decide(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None) -> tuple[str, str, str]:
    """(runs-on JSON, placement, why); ("", "", why) keeps the picker's choice."""
    root = (env.get("ROOT_RUNNER") or "").strip()
    if not pool.persistent(root) or not root.startswith(pool.ROOT_PREFIX):
        return "", "", f"admission has no root label ({root or 'none'})"
    if runners is None:
        return "", "", "owned runners could not be read live"
    hot = warm_names(env.get("ADMISSION_WARM"))
    labels, hit = pool.spread_admission_runner(runners, root, hot, seed=(env.get("GITHUB_RUN_ID") or "").strip())
    if labels:
        name = json.loads(labels)[1]
        return labels, "spread-warm" if hit else "spread", (
            f"`{name}` is idle on a mini with no root job running" + (", and warm for the merge base" if hit else ""))
    name = pool.idle_warm_runner(runners, root, hot)
    if name:
        return (pool.pinned_admission(root, name), "warm",
                f"every mini runs a root job; `{name}` is idle and warm for the merge base")
    return json.dumps([root]), "root", f"every mini runs a root job; admission takes `{root}`"


def main(env: Mapping[str, str] = os.environ) -> int:
    runners = None
    token, repo = env.get("ROUTE_TOKEN", ""), env.get("GITHUB_REPOSITORY", "")
    if token and repo:
        try:
            runners = pool.GitHub(token, repo).runners()
        except Exception as error:  # noqa: BLE001 - fail open: keep the picker's choice
            print(f"::warning title=admission placement::could not list runners ({error})")
    labels, placement, why = decide(env, runners)
    print(f"admission placement: {why}")
    output = env.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"runner={labels}\nplacement={placement}\n")
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"### Admission placement\n\n{placement or 'unchanged'}: {why}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
