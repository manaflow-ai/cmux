"""Refuse a test suite on a fleet host that runs no tests (a person's own Mac, a session host).

The fleet registry (leo-workspace machines/fleet-registry.json, deployed to every enrolled host as
~/.ssh/config.d/fleet-registry.json; $FLEET_REGISTRY names another copy) marks such a host with a
`no_local_tests` reason on its machine entry. On that host, importing this module's `refuse_here()`
caller (tests/git_fixture_env.py, tests/real_git.py, scripts/ci/run_python_test_lane.py) prints the
reason and how to run the same command on the fleet, and exits 2.

Why: on 2026-11-10 cosmic-gray, Leo's own Mac, ran at load ~265 with no idle CPU. Four orphaned
`tests/test_pr_checks_base_only.py` runs an agent had started there (PPID 1, 3 to 15 hours old) each
held a fake `git` that exec'd the host's git wrapper, which exec'd the fake again, forever, in one
process. Leo: "im still at 100% cpu for some ungodly reason". Tests and builds go to the fleet.

Nothing here names a host. No registry, an unreadable one, or no entry for this host allows the run,
so CI runners and every machine outside the fleet are unaffected.
"""

from __future__ import annotations

import json
import os
import shlex
import sys
from pathlib import Path


def _registry_paths(environ) -> list[Path]:
    named = environ.get("FLEET_REGISTRY")
    if named:
        return [Path(named)]
    home = environ.get("HOME") or os.path.expanduser("~")
    return [Path(home) / ".ssh" / "config.d" / "fleet-registry.json"]


def this_host(nodename: str | None = None) -> str:
    return (nodename or os.uname().nodename).split(".")[0].lower()


def refusal(environ=None, nodename: str | None = None) -> str | None:
    """This host's `no_local_tests` reason from the fleet registry, or None. Never raises."""
    environ = os.environ if environ is None else environ
    name = this_host(nodename)
    for path in _registry_paths(environ):
        try:
            machines = json.loads(path.read_text()).get("machines") or {}
        except (OSError, ValueError, AttributeError):
            continue
        if not isinstance(machines, dict):
            continue
        for key, machine in machines.items():
            if not isinstance(machine, dict):
                continue
            names = {str(key).lower()}
            names.update(str(n).lower() for n in (machine.get("hostnames") or []) if isinstance(n, str))
            names.update(str(n).lower() for n in (machine.get("aliases") or []) if isinstance(n, str))
            if name in names:
                reason = machine.get("no_local_tests")
                if reason:
                    return reason if isinstance(reason, str) else f"{key} runs no tests (fleet registry)"
                return None
    return None


def message(reason: str, argv: list[str] | None = None) -> str:
    argv = list(sys.argv if argv is None else argv)
    command = shlex.join([os.path.basename(sys.executable) or "python3", *argv]) if argv else "CMD"
    return (f"refused: this host runs no test suites or builds: {reason}\n"
            f"run it on the fleet: cmux-ci test -- {command}")


def refuse_here(environ=None, nodename: str | None = None) -> None:
    """Exit 2 with the reason on a host the fleet registry marks `no_local_tests`; return otherwise."""
    reason = refusal(environ, nodename)
    if reason:
        print(message(reason), file=sys.stderr)
        raise SystemExit(2)
