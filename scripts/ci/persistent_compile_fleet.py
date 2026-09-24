#!/usr/bin/env python3
"""Operate the persistent macOS compile fleet from one command.

    scripts/persistent-compile                 doctor: what is set up, and the next command
    scripts/persistent-compile group [--apply]         org admin: create or repair the runner group
    scripts/persistent-compile register [--apply]      on the mini: install the runner as a service
    scripts/persistent-compile drain [--now]           stop taking jobs (Glaeda state and GitHub)
    scripts/persistent-compile resume                  take jobs again
    scripts/persistent-compile unregister [--apply]    remove the runner from this mini
    scripts/persistent-compile pilot <pr-or-branch>... route only these PRs to the fleet
    scripts/persistent-compile all | off               route every trusted PR, or none

Enrollment itself stays with Glaeda (docs/fleet-enrollment.md); this command
reads its result and refuses to register a runner on a mini that is not
`eligible`. Everything that talks to GitHub goes through `gh`, so it acts as
whoever `gh auth status` says, and prints what it would do unless --apply is
given. Registration tokens are passed to the runner through its environment and
never printed. See docs/ci/mac-fleet.md for the design this operates.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import time
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

ORG = "manaflow-ai"
REPO = "manaflow-ai/cmux"
GROUP = "cmux-persistent-compile"
CUSTOM_LABEL = "cmux-persistent-macos-compile"
# config.sh adds the first three itself on an Apple silicon Mac. The producer's
# `runs-on` compares all four literally (docs/ci/mac-fleet.md 3.2).
LABELS = ("self-hosted", "macOS", "ARM64", CUSTOM_LABEL)
WORKFLOW_REF = f"{REPO}/.github/workflows/persistent-macos-compile.yml@refs/heads/main"
SELECTOR_VARIABLE = "CI_PERSISTENT_MAC_COMPILE"
COHORT_VARIABLE = "CI_PERSISTENT_MAC_COMPILE_COHORT"
XCODE_APP = "/Applications/Xcode_26.3.app"
ROLE = "cmux_macos_native_build"

RUNNER_VERSION = "2.336.0"
RUNNER_SHA256 = "8e8839c49b7060b6b2154f4931f815df330c27f167d53ef2239ee3dfce28b079"
RUNNER_URL = (
    f"https://github.com/actions/runner/releases/download/v{RUNNER_VERSION}/"
    f"actions-runner-osx-arm64-{RUNNER_VERSION}.tar.gz"
)
# The producer's timeout is 35 minutes, so a drain that waits this long has
# outlived any job the runner could be holding.
DRAIN_WAIT_SECONDS = 40 * 60


class Failure(Exception):
    pass


# ---------------------------------------------------------------- paths


def fleet_root() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(Path.home(), ".config")
    return Path(base) / "glaeda" / "cmux-fleet"


def enrollment_path() -> Path:
    return fleet_root() / "enrollment.json"


def acceptance_path() -> Path:
    return fleet_root() / "acceptance" / f"{ROLE}.json"


def runner_dir() -> Path:
    return Path(os.environ.get("CMUX_PERSISTENT_RUNNER_DIR") or Path.home() / "actions-runner-cmux-persistent-compile")


def glaeda_root(explicit: str | None) -> Path | None:
    candidates = [explicit, os.environ.get("GLAEDA_ROOT")]
    candidates += [os.fspath(Path.home() / sub) for sub in ("glaeda", "Projects/glaeda", "src/glaeda", "code/glaeda")]
    for candidate in candidates:
        if candidate and (Path(candidate) / "scripts" / "cmux_fleet.py").is_file():
            return Path(candidate)
    return None


# ---------------------------------------------------------------- GitHub


def gh(*args: str, stdin: str | None = None) -> tuple[bool, Any]:
    """Run `gh`; returns (ok, parsed JSON or the error text)."""
    if not shutil.which("gh"):
        return False, "gh is not installed"
    result = subprocess.run(
        ["gh", *args], input=stdin, text=True, capture_output=True, check=False
    )
    if result.returncode:
        lines = (result.stderr or result.stdout).strip().splitlines()
        return False, lines[-1] if lines else f"gh exited {result.returncode}"
    text = result.stdout.strip()
    if not text:
        return True, None
    try:
        return True, json.loads(text)
    except ValueError:
        return True, text


def gh_api(path: str, method: str = "GET", body: dict[str, Any] | None = None) -> Any:
    args = ["api", "-X", method, path, "-H", "Accept: application/vnd.github+json"]
    if body is not None:
        args += ["--input", "-"]
    ok, data = gh(*args, stdin=json.dumps(body) if body is not None else None)
    if not ok:
        raise Failure(f"gh api {method} {path}: {data}")
    return data


def find_group(groups: list[dict[str, Any]]) -> dict[str, Any] | None:
    return next((g for g in groups if g.get("name") == GROUP), None)


def group_changes(group: dict[str, Any] | None, repo_id: int, repo_ids: list[int]) -> list[str]:
    """What must change for the group to be the security boundary mac-fleet.md 3.2 describes."""
    if group is None:
        return ["create the group"]
    changes = []
    if group.get("visibility") != "selected":
        changes.append(f"visibility is {group.get('visibility')!r}, must be 'selected'")
    if not group.get("allows_public_repositories"):
        changes.append("allow public repositories (manaflow-ai/cmux is public)")
    if not group.get("restricted_to_workflows"):
        changes.append("restrict the group to the producer workflow")
    if list(group.get("selected_workflows") or []) != [WORKFLOW_REF]:
        changes.append(f"selected workflows must be exactly [{WORKFLOW_REF}]")
    if repo_id not in repo_ids:
        changes.append(f"grant {REPO} access")
    return changes


def group_warnings(repo_id: int, repo_ids: list[int]) -> list[str]:
    extra = [r for r in repo_ids if r != repo_id]
    return [f"{len(extra)} other repositories can also use the group"] if extra else []


def runner_problems(runner: dict[str, Any]) -> list[str]:
    labels = sorted(label.get("name", "") for label in runner.get("labels", []))
    problems = []
    if labels != sorted(LABELS):
        problems.append(f"labels are {labels}, must be exactly {sorted(LABELS)}")
    if runner.get("status") != "online":
        problems.append(f"status is {runner.get('status')}")
    return problems


@dataclass
class GitHubState:
    auth: str | None = None
    error: str | None = None
    group: dict[str, Any] | None = None
    group_changes: list[str] = field(default_factory=list)
    group_warnings: list[str] = field(default_factory=list)
    runners: list[dict[str, Any]] = field(default_factory=list)
    runners_error: str | None = None
    variables: dict[str, str] = field(default_factory=dict)
    variables_error: str | None = None


def read_github() -> GitHubState:
    state = GitHubState()
    ok, me = gh("api", "user", "--jq", ".login")
    if not ok:
        state.error = "gh is not signed in (run: gh auth login)"
        return state
    state.auth = me if isinstance(me, str) else str(me)
    try:
        repo_id = int(gh_api(f"repos/{REPO}")["id"])
        groups = gh_api(f"orgs/{ORG}/actions/runner-groups?per_page=100").get("runner_groups", [])
        state.group = find_group(groups)
        repo_ids: list[int] = []
        if state.group is not None:
            gid = state.group["id"]
            if state.group.get("visibility") == "selected":
                repos = gh_api(f"orgs/{ORG}/actions/runner-groups/{gid}/repositories?per_page=100")
                repo_ids = [int(r["id"]) for r in repos.get("repositories", [])]
            else:
                repo_ids = [repo_id]
        state.group_changes = group_changes(state.group, repo_id, repo_ids)
        state.group_warnings = group_warnings(repo_id, repo_ids)
    except Failure as error:
        state.error = f"{error} (reading runner groups needs an org admin: gh auth refresh -s admin:org)"
        return state
    if state.group is not None:
        try:
            data = gh_api(f"orgs/{ORG}/actions/runner-groups/{state.group['id']}/runners?per_page=100")
            state.runners = data.get("runners", [])
        except Failure as error:
            state.runners_error = str(error)
    try:
        data = gh_api(f"repos/{REPO}/actions/variables?per_page=100")
        state.variables = {v["name"]: v["value"] for v in data.get("variables", [])}
    except Failure as error:
        state.variables_error = str(error)
    return state


# ---------------------------------------------------------------- this machine


@dataclass
class LocalState:
    is_mac: bool
    xcode: bool
    enrollment: dict[str, Any] | None
    enrollment_error: str | None
    acceptance: bool
    runner_configured: bool
    runner_name: str | None
    service_loaded: bool | None
    glaeda: Path | None


def read_json(path: Path) -> tuple[dict[str, Any] | None, str | None]:
    try:
        return json.loads(path.read_text()), None
    except FileNotFoundError:
        return None, None
    except (OSError, ValueError) as error:
        return None, f"{path}: {error}"


def service_label(directory: Path) -> str | None:
    service = directory / ".service"
    try:
        text = service.read_text().strip()
    except OSError:
        return None
    return Path(text).stem or None


def service_loaded(directory: Path) -> bool | None:
    label = service_label(directory)
    if label is None:
        return None
    result = subprocess.run(
        ["launchctl", "print", f"gui/{os.getuid()}/{label}"], capture_output=True, text=True, check=False
    )
    return result.returncode == 0 and "state = running" in result.stdout


def read_local(glaeda_arg: str | None) -> LocalState:
    enrollment, enrollment_error = read_json(enrollment_path())
    directory = runner_dir()
    runner_config, _ = read_json(directory / ".runner")
    is_mac = platform.system() == "Darwin"
    return LocalState(
        is_mac=is_mac,
        xcode=Path(XCODE_APP).is_dir(),
        enrollment=enrollment,
        enrollment_error=enrollment_error,
        acceptance=acceptance_path().is_file(),
        runner_configured=runner_config is not None,
        runner_name=(runner_config or {}).get("agentName"),
        service_loaded=service_loaded(directory) if is_mac and runner_config is not None else None,
        glaeda=glaeda_root(glaeda_arg),
    )


# ---------------------------------------------------------------- doctor


@dataclass
class Line:
    ok: bool | None  # None: not applicable here
    text: str


def doctor_lines(github: GitHubState, local: LocalState | None) -> tuple[list[tuple[str, list[Line]]], str | None]:
    """Checklist sections plus the one command to run next (None when done)."""
    nxt: list[str] = []
    sections: list[tuple[str, list[Line]]] = []

    if local is not None:
        lines = []
        lines.append(Line(local.xcode, f"Xcode at {XCODE_APP}"))
        if not local.xcode:
            nxt.append(f"install Xcode 26.3 at {XCODE_APP}, then: sudo xcode-select -s {XCODE_APP}")
        state = (local.enrollment or {}).get("state")
        if local.enrollment_error:
            lines.append(Line(False, f"Glaeda enrollment unreadable: {local.enrollment_error}"))
        elif local.enrollment is None:
            lines.append(Line(False, f"Glaeda enrollment ({enrollment_path()})"))
            nxt.append("in the Glaeda checkout: scripts/glaeda-mini-enroll --cmux-root <this cmux checkout>"
                       " --node-id cmux-mac-NNN --apply")
        else:
            node = local.enrollment.get("nodeId", "?")
            lines.append(Line(state in {"eligible", "draining"}, f"Glaeda node {node} is {state}"))
            if state == "enrolling":
                nxt.append("in the Glaeda checkout: scripts/glaeda-mini-enroll --cmux-root <this cmux checkout> --apply")
            elif state == "quarantined":
                nxt.append(f"node is quarantined ({local.enrollment.get('quarantineReason')}); re-enroll through Glaeda")
        lines.append(Line(local.acceptance, "acceptance receipt"))
        lines.append(Line(local.glaeda is not None, "Glaeda checkout found" if local.glaeda
                          else "Glaeda checkout (set GLAEDA_ROOT or pass --glaeda-root)"))
        lines.append(Line(local.runner_configured, f"runner configured in {runner_dir()}"
                          + (f" as {local.runner_name}" if local.runner_name else "")))
        if local.runner_configured:
            lines.append(Line(bool(local.service_loaded), "runner service running"))
            if not local.service_loaded and state == "eligible":
                nxt.append("scripts/persistent-compile resume")
        elif state == "eligible":
            nxt.append("scripts/persistent-compile register --apply")
        sections.append(("This mini", lines))

    lines = []
    if github.error:
        lines.append(Line(False, github.error))
        nxt.append("gh auth login && gh auth refresh -s admin:org")
        sections.append(("GitHub", lines))
        return sections, nxt[0] if nxt else None
    lines.append(Line(True, f"signed in as {github.auth}"))
    if github.group_changes:
        for change in github.group_changes:
            lines.append(Line(False, f"runner group {GROUP}: {change}"))
        nxt.insert(0, "scripts/persistent-compile group --apply   (org admin)")
    else:
        lines.append(Line(True, f"runner group {GROUP} restricted to the producer workflow"))
    for warning in github.group_warnings:
        lines.append(Line(None, f"runner group {GROUP}: {warning}"))
    if github.runners_error:
        lines.append(Line(False, f"runners: {github.runners_error}"))
    elif github.group is not None:
        if not github.runners:
            lines.append(Line(False, "no runner registered in the group"))
            if local is None:
                nxt.append("on the mini: scripts/persistent-compile register --apply")
        healthy = 0
        for runner in github.runners:
            problems = runner_problems(runner)
            busy = " (busy)" if runner.get("busy") else ""
            lines.append(Line(not problems, f"runner {runner.get('name')}{busy}"
                              + (": " + "; ".join(problems) if problems else "")))
            healthy += not problems
    if github.variables_error:
        lines.append(Line(False, f"variables: {github.variables_error}"))
    else:
        selector = github.variables.get(SELECTOR_VARIABLE, "")
        cohort = github.variables.get(COHORT_VARIABLE, "")
        routing = selector.strip().lower()
        if routing == "pilot":
            lines.append(Line(True, f"routing: pilot for {cohort or '(empty cohort: nothing routes)'}"))
        elif routing in {"1", "on", "true", "all"}:
            lines.append(Line(True, "routing: every trusted PR"))
        else:
            lines.append(Line(None, f"routing: off ({SELECTOR_VARIABLE}={selector or 'unset'})"))
            ready = not github.group_changes and any(not runner_problems(r) for r in github.runners)
            if ready:
                nxt.append("scripts/persistent-compile pilot <your PR number>")
    sections.append(("GitHub", lines))
    return sections, nxt[0] if nxt else None


def render_doctor(sections: list[tuple[str, list[Line]]], nxt: str | None) -> str:
    out = []
    for title, lines in sections:
        out.append(title)
        for line in lines:
            mark = {True: "ok ", False: "-- ", None: "   "}[line.ok]
            out.append(f"  {mark} {line.text}")
        out.append("")
    out.append(f"Next: {nxt}" if nxt else "Next: nothing; the fleet is routing. Watch: scripts/persistent-compile")
    return "\n".join(out)


def cmd_doctor(args: argparse.Namespace) -> int:
    local = read_local(args.glaeda_root) if (platform.system() == "Darwin" or args.local) else None
    sections, nxt = doctor_lines(read_github(), local)
    print(render_doctor(sections, nxt))
    return 0


# ---------------------------------------------------------------- group


def cmd_group(args: argparse.Namespace) -> int:
    github = read_github()
    if github.error:
        raise Failure(github.error)
    if not github.group_changes:
        print(f"{GROUP} is already restricted to {WORKFLOW_REF}")
        for warning in github.group_warnings:
            print(f"note: {warning}")
        return 0
    print(f"{GROUP} needs:")
    for change in github.group_changes:
        print(f"  - {change}")
    if not args.apply:
        print("\nRe-run with --apply to make these changes (needs org admin).")
        return 0
    repo_id = int(gh_api(f"repos/{REPO}")["id"])
    policy = {
        "visibility": "selected",
        "allows_public_repositories": True,
        "restricted_to_workflows": True,
        "selected_workflows": [WORKFLOW_REF],
    }
    if github.group is None:
        created = gh_api(f"orgs/{ORG}/actions/runner-groups", "POST",
                         {"name": GROUP, "selected_repository_ids": [repo_id], **policy})
        gid = created["id"]
    else:
        gid = github.group["id"]
        gh_api(f"orgs/{ORG}/actions/runner-groups/{gid}", "PATCH", {"name": GROUP, **policy})
        gh_api(f"orgs/{ORG}/actions/runner-groups/{gid}/repositories/{repo_id}", "PUT")
    after = read_github()
    if after.group_changes:
        raise Failure(f"group {gid} still needs: " + "; ".join(after.group_changes))
    print(f"{GROUP} (id {gid}) now admits only {WORKFLOW_REF}")
    return 0


# ---------------------------------------------------------------- runner on this mini


def require_mac() -> None:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise Failure("this step runs on the Apple silicon mini itself")


def run_checked(argv: list[str], cwd: Path, env: dict[str, str] | None = None) -> None:
    result = subprocess.run(argv, cwd=cwd, env=env, check=False)
    if result.returncode:
        raise Failure(f"{' '.join(argv[:2])} exited {result.returncode}")


def install_runner(directory: Path) -> None:
    if (directory / "config.sh").is_file():
        return
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / f"actions-runner-osx-arm64-{RUNNER_VERSION}.tar.gz"
    print(f"downloading actions runner {RUNNER_VERSION}")
    with urllib.request.urlopen(RUNNER_URL) as response, archive.open("wb") as out:
        shutil.copyfileobj(response, out)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != RUNNER_SHA256:
        archive.unlink()
        raise Failure(f"runner archive sha256 {digest} does not match the pinned {RUNNER_SHA256}")
    run_checked(["tar", "-xzf", archive.name], directory)
    archive.unlink()


def runner_token(kind: str) -> str:
    data = gh_api(f"orgs/{ORG}/actions/runners/{kind}-token", "POST")
    token = (data or {}).get("token")
    if not token:
        raise Failure(f"GitHub returned no {kind} token")
    return token


def default_runner_name(local: LocalState) -> str:
    node = (local.enrollment or {}).get("nodeId")
    return f"{node}-persistent-compile" if node else f"{platform.node().split('.')[0]}-persistent-compile"


def cmd_register(args: argparse.Namespace) -> int:
    require_mac()
    local = read_local(args.glaeda_root)
    state = (local.enrollment or {}).get("state")
    if state != "eligible" and not args.without_enrollment:
        raise Failure(f"Glaeda enrollment is {state or 'missing'}, not eligible. Enroll and accept this mini "
                      "first (docs/fleet-enrollment.md), or pass --without-enrollment for a rehearsal.")
    if not local.xcode:
        raise Failure(f"{XCODE_APP} is missing; the producer selects exactly that Xcode")
    directory = runner_dir()
    name = args.name or local.runner_name or default_runner_name(local)
    steps = [
        f"install actions runner {RUNNER_VERSION} (sha256 pinned) in {directory}" if not (directory / "config.sh").is_file()
        else f"reuse the runner in {directory}",
        f"register {name} in group {GROUP} with labels {', '.join(LABELS)} (org registration token via gh)",
        "install and start it as a launchd agent (./svc.sh), so it survives logout and reboot with auto-login",
    ]
    print("register:\n" + "\n".join(f"  - {s}" for s in steps))
    if not args.apply:
        print("\nRe-run with --apply to do it.")
        return 0
    install_runner(directory)
    env = dict(os.environ, ACTIONS_RUNNER_INPUT_TOKEN=runner_token("registration"))
    run_checked(["./config.sh", "--unattended", "--replace", "--url", f"https://github.com/{ORG}",
                 "--runnergroup", GROUP, "--labels", CUSTOM_LABEL, "--name", name, "--work", "_work"],
                directory, env)
    if service_label(directory) is None:
        run_checked(["./svc.sh", "install"], directory)
    run_checked(["./svc.sh", "start"], directory)
    print(f"\n{name} is registered and running. Next: scripts/persistent-compile pilot <your PR number>")
    return 0


def glaeda_transition(local: LocalState, target: str) -> None:
    if local.enrollment is None:
        print("no Glaeda enrollment on this mini; skipping the Glaeda state change")
        return
    if local.enrollment.get("state") == target:
        return
    if local.glaeda is None:
        raise Failure("cannot find the Glaeda checkout; set GLAEDA_ROOT or pass --glaeda-root")
    argv = [sys.executable, os.fspath(local.glaeda / "scripts" / "cmux_fleet.py"), "transition-apply",
            os.fspath(enrollment_path()), "--to", target]
    if target == "eligible":
        argv += ["--acceptance", os.fspath(acceptance_path())]
    run_checked(argv, local.glaeda)
    print(f"Glaeda: {local.enrollment.get('nodeId')} is {target}")


def this_runner(local: LocalState) -> dict[str, Any] | None:
    github = read_github()
    return next((r for r in github.runners if r.get("name") == local.runner_name), None)


def cmd_drain(args: argparse.Namespace) -> int:
    require_mac()
    local = read_local(args.glaeda_root)
    if not local.runner_configured:
        raise Failure(f"no runner is configured in {runner_dir()}")
    # Two control planes: Glaeda's state is what routing reads, the runner
    # service is what GitHub assigns to. Draining one without the other leaves
    # the mini taking work (docs/ci/mac-fleet.md 3.5).
    # The runner service is the half that stops GitHub assigning jobs, so a
    # Glaeda failure must not prevent it.
    glaeda_error = None
    try:
        glaeda_transition(local, "draining")
    except Failure as error:
        glaeda_error = error
    deadline = time.monotonic() + (0 if args.now else DRAIN_WAIT_SECONDS)
    while True:
        runner = this_runner(local)
        if not runner or not runner.get("busy") or time.monotonic() >= deadline:
            break
        print(f"{local.runner_name} is running a job; waiting for it to finish (--now to stop immediately)")
        time.sleep(30)
    run_checked(["./svc.sh", "stop"], runner_dir())
    print(f"{local.runner_name} is stopped: GitHub will not assign it jobs. Undo: scripts/persistent-compile resume")
    if glaeda_error is not None:
        raise Failure(f"the runner is stopped, but Glaeda was not moved to draining: {glaeda_error}")
    return 0


def cmd_resume(args: argparse.Namespace) -> int:
    require_mac()
    local = read_local(args.glaeda_root)
    if not local.runner_configured:
        raise Failure("no runner is configured here; run: scripts/persistent-compile register --apply")
    glaeda_transition(local, "eligible")
    run_checked(["./svc.sh", "start"], runner_dir())
    print(f"{local.runner_name} is taking jobs again")
    return 0


def cmd_unregister(args: argparse.Namespace) -> int:
    require_mac()
    local = read_local(args.glaeda_root)
    directory = runner_dir()
    if not local.runner_configured:
        print(f"no runner is configured in {directory}")
        return 0
    print(f"unregister {local.runner_name}: stop and uninstall its service, remove it from {GROUP}")
    if not args.apply:
        print("\nRe-run with --apply to do it.")
        return 0
    if service_label(directory) is not None:
        run_checked(["./svc.sh", "stop"], directory)
        run_checked(["./svc.sh", "uninstall"], directory)
    env = dict(os.environ, ACTIONS_RUNNER_INPUT_TOKEN=runner_token("remove"))
    run_checked(["./config.sh", "remove"], directory, env)
    print(f"{local.runner_name} is removed")
    return 0


# ---------------------------------------------------------------- routing switch


def set_variable(name: str, value: str) -> None:
    ok, error = gh("variable", "set", name, "--repo", REPO, "--body", value)
    if not ok:
        raise Failure(f"gh variable set {name}: {error}")


def cmd_pilot(args: argparse.Namespace) -> int:
    cohort = ",".join(v.strip().lstrip("#") for v in args.targets if v.strip())
    set_variable(COHORT_VARIABLE, cohort)
    set_variable(SELECTOR_VARIABLE, "pilot")
    print(f"routing pilot: {cohort}. The next CI run on those PRs tries the fleet; everything else stays hosted.")
    return 0


def cmd_all(_: argparse.Namespace) -> int:
    set_variable(SELECTOR_VARIABLE, "all")
    print("routing every trusted same-repository PR to the fleet, with hosted fallback")
    return 0


def cmd_off(_: argparse.Namespace) -> int:
    set_variable(SELECTOR_VARIABLE, "off")
    print("routing off; every PR compiles hosted from its next run")
    return 0


# ---------------------------------------------------------------- entry


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="scripts/persistent-compile", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--glaeda-root", help="Glaeda checkout (default: $GLAEDA_ROOT or ~/glaeda)")
    sub = p.add_subparsers(dest="command")
    d = sub.add_parser("doctor", help="show what is set up and the next command (default)")
    d.add_argument("--local", action="store_true", help="also inspect this machine when it is not a Mac")
    g = sub.add_parser("group", help="create or repair the org runner group (org admin)")
    g.add_argument("--apply", action="store_true")
    r = sub.add_parser("register", help="install this mini's runner as a service")
    r.add_argument("--apply", action="store_true")
    r.add_argument("--name", help="runner name (default: <Glaeda node id>-persistent-compile)")
    r.add_argument("--without-enrollment", action="store_true", help="skip the Glaeda eligibility check")
    dr = sub.add_parser("drain", help="stop taking jobs, after the current one finishes")
    dr.add_argument("--now", action="store_true", help="do not wait for a running job")
    sub.add_parser("resume", help="take jobs again")
    u = sub.add_parser("unregister", help="remove this mini's runner")
    u.add_argument("--apply", action="store_true")
    pi = sub.add_parser("pilot", help="route only these PR numbers or branch names")
    pi.add_argument("targets", nargs="+")
    sub.add_parser("all", help="route every trusted PR")
    sub.add_parser("off", help="route nothing")
    return p


COMMANDS = {
    None: cmd_doctor, "doctor": cmd_doctor, "group": cmd_group, "register": cmd_register,
    "drain": cmd_drain, "resume": cmd_resume, "unregister": cmd_unregister,
    "pilot": cmd_pilot, "all": cmd_all, "off": cmd_off,
}


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.command is None:
        args.local = False
    try:
        return COMMANDS[args.command](args)
    except Failure as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
