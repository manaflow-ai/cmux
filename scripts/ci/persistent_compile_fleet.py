#!/usr/bin/env python3
"""Bring up and operate the persistent macOS compile fleet.

    scripts/persistent-compile              where things stand, and the one command to run next
    scripts/persistent-compile up           on a mini: set up, enroll, register, start. Re-run any time.
    scripts/persistent-compile group        org admin: create or repair the runner group
    scripts/persistent-compile token        org admin: a one-hour token for someone else's `up`
    scripts/persistent-compile pilot <PR>   route only these PRs (numbers or branch names)
    scripts/persistent-compile all | off    route every trusted PR, or none
    scripts/persistent-compile drain        on a mini: stop taking jobs once the current one ends
    scripts/persistent-compile resume       on a mini: take jobs again
    scripts/persistent-compile unregister   on a mini: remove its runner

`up`, `group` and `unregister` show what they will do and ask first; -y skips
the question. GitHub calls go through `gh` as whoever is signed in. `up` does
not need an org admin at the mini: an admin runs `token` and the operator runs
`CMUX_RUNNER_TOKEN=<token> scripts/persistent-compile up`. See
docs/ci/mac-fleet.md for the design this operates.
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

ROOT = Path(__file__).resolve().parents[2]
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
GLAEDA_URL = "https://github.com/teamleaderleo/glaeda.git"
# The reviewed Glaeda candidate a mini runs (#13491, docs/FLEET_DISTRIBUTION.md in
# Glaeda). The node installs these exact bytes and builds no Rust. Actions keeps the
# artifact for 30 days; replace all four values together from the new run's receipt.
CANDIDATE_RUN = "35879163562"
CANDIDATE_ARTIFACT = "glaeda-candidate-aarch64-apple-darwin"
CANDIDATE_SOURCE = "36e07e36ea7b9bc9e04c366547a5312dd348024d"
CANDIDATE_SHA256 = "c2ceaa2df44d82d8a972fbe2ae6c33a8ceb11247f010cd837fa403313ec8f66e"
TOKEN_ENV = "CMUX_RUNNER_TOKEN"

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


def confirm(args: argparse.Namespace, steps: list[str]) -> bool:
    """Show the plan and ask once. -y answers yes; a non-interactive run without -y only plans."""
    for step in steps:
        print(f"  - {step}")
    if getattr(args, "yes", False):
        return True
    if not sys.stdin.isatty():
        print("\nNot a terminal: nothing changed. Re-run with -y to do it.")
        return False
    try:
        answer = input("\nGo ahead? [y/N] ").strip().lower()
    except EOFError:
        answer = ""
    return answer in {"y", "yes"}


# ---------------------------------------------------------------- paths


def fleet_root() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(Path.home(), ".config")
    return Path(base) / "glaeda" / "cmux-fleet"


def enrollment_path() -> Path:
    return fleet_root() / "enrollment.json"


def acceptance_path() -> Path:
    return fleet_root() / "acceptance" / f"{ROLE}.json"


def candidate_dir() -> Path:
    return Path.home() / "Library/Caches/cmux-fleet" / f"glaeda-candidate-{CANDIDATE_SOURCE[:12]}"


def candidate_archive() -> Path:
    return candidate_dir() / f"glaeda-{CANDIDATE_SOURCE}-aarch64-apple-darwin.tar.gz"


def generation_dir() -> Path:
    # Same generation directory glaeda-mini-enroll stages the candidate into.
    return Path.home() / "Projects/glaeda-generations" / CANDIDATE_SOURCE[:12]


def candidate_staged() -> bool:
    return (generation_dir() / "stage-receipt.json").is_file()


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
        # The runner writes .runner as UTF-8 with a byte-order mark.
        return json.loads(path.read_text(encoding="utf-8-sig")), None
    except FileNotFoundError:
        return None, None
    except (OSError, ValueError) as error:
        return None, f"{path}: {error}"


def service_plist(directory: Path) -> Path | None:
    """The LaunchAgent plist svc.sh install wrote; its path is recorded in .service."""
    try:
        text = (directory / ".service").read_text().strip()
    except OSError:
        return None
    return Path(text) if text else None


def service_label(directory: Path) -> str | None:
    plist = service_plist(directory)
    return plist.stem if plist else None


def launchctl(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["launchctl", *args], capture_output=True, text=True, check=False)


def service_loaded(directory: Path) -> bool | None:
    label = service_label(directory)
    if label is None:
        return None
    return launchctl("print", f"gui/{os.getuid()}/{label}").returncode == 0


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
            nxt.append("scripts/persistent-compile up --node-id cmux-mac-NNN")
        else:
            node = local.enrollment.get("nodeId", "?")
            lines.append(Line(state in {"eligible", "draining"}, f"Glaeda node {node} is {state}"))
            if state == "enrolling":
                nxt.append("scripts/persistent-compile up")
            elif state == "quarantined":
                nxt.append(f"node is quarantined ({local.enrollment.get('quarantineReason')}); "
                           "fix the cause, move it to enrolling in Glaeda, then: scripts/persistent-compile up")
        lines.append(Line(local.acceptance, "acceptance receipt"))
        lines.append(Line(local.glaeda is not None, "Glaeda checkout found" if local.glaeda
                          else "Glaeda checkout (set GLAEDA_ROOT or pass --glaeda-root)"))
        lines.append(Line(local.runner_configured, f"runner configured in {runner_dir()}"
                          + (f" as {local.runner_name}" if local.runner_name else "")))
        if local.runner_configured:
            lines.append(Line(bool(local.service_loaded), "runner service loaded"))
            if state == "draining":
                nxt.append("scripts/persistent-compile resume   (this mini is drained)")
            elif not local.service_loaded and state == "eligible":
                nxt.append("scripts/persistent-compile resume")
        elif state == "eligible":
            nxt.append("scripts/persistent-compile up")
        sections.append(("This mini", lines))

    lines = []
    if github.error:
        lines.append(Line(False, github.error))
        nxt.append("gh auth login   (org admins also: gh auth refresh -s admin:org)")
        sections.append(("GitHub", lines))
        return sections, nxt[0] if nxt else None
    lines.append(Line(True, f"signed in as {github.auth}"))
    if github.group_changes:
        for change in github.group_changes:
            lines.append(Line(False, f"runner group {GROUP}: {change}"))
        nxt.insert(0, "scripts/persistent-compile group   (org admin)")
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
                nxt.append("on the mini: scripts/persistent-compile up --node-id cmux-mac-NNN")
        for runner in github.runners:
            problems = runner_problems(runner)
            busy = " (busy)" if runner.get("busy") else ""
            lines.append(Line(not problems, f"runner {runner.get('name')}{busy}"
                              + (": " + "; ".join(problems) if problems else "")))
    if github.variables_error:
        lines.append(Line(False, f"variables: {github.variables_error}"))
    else:
        selector = github.variables.get(SELECTOR_VARIABLE, "")
        cohort = github.variables.get(COHORT_VARIABLE, "")
        # The router compares the value exactly, so do not normalise case here.
        routing = selector.strip()
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
    print(f"runner group {GROUP}:")
    if not confirm(args, github.group_changes):
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


def worker_running(directory: Path) -> bool:
    """A Runner.Worker process exists only while this runner holds a job."""
    result = subprocess.run(["pgrep", "-f", os.fspath(directory / "bin" / "Runner.Worker")],
                            capture_output=True, check=False)
    return result.returncode == 0


def register_runner(name: str, token: str | None) -> None:
    directory = runner_dir()
    install_runner(directory)
    env = dict(os.environ, ACTIONS_RUNNER_INPUT_TOKEN=token or runner_token("registration"))
    run_checked(["./config.sh", "--unattended", "--replace", "--url", f"https://github.com/{ORG}",
                 "--runnergroup", GROUP, "--labels", CUSTOM_LABEL, "--name", name, "--work", "_work"],
                directory, env)


# svc.sh start/stop use legacy `launchctl load`/`unload`, which fail when the job is
# already in that state and act on the SSH session's domain rather than the GUI
# login's. These act on gui/<uid> directly and are safe to repeat.


def start_service(directory: Path) -> None:
    if service_plist(directory) is None:
        run_checked(["./svc.sh", "install"], directory)
    plist, label, domain = service_plist(directory), service_label(directory), f"gui/{os.getuid()}"
    launchctl("enable", f"{domain}/{label}")
    if not service_loaded(directory):
        result = launchctl("bootstrap", domain, os.fspath(plist))
        if result.returncode and not service_loaded(directory):
            raise Failure(f"launchctl bootstrap {domain} failed ({(result.stderr or result.stdout).strip()}). "
                          "The runner runs in the logged-in GUI session: log in on the mini (or enable auto-login) "
                          "and run this again.")


def stop_service(directory: Path) -> None:
    """Stop the runner and keep it stopped across logins and reboots."""
    label = service_label(directory)
    if label is None:
        return
    domain = f"gui/{os.getuid()}"
    # disable persists: a RunAtLoad agent stays unloaded at the next login.
    launchctl("disable", f"{domain}/{label}")
    if service_loaded(directory):
        launchctl("bootout", f"{domain}/{label}")
    if service_loaded(directory):
        raise Failure(f"could not stop {label}")


# ---------------------------------------------------------------- up


@dataclass
class UpStep:
    key: str
    text: str


def up_plan(local: LocalState, setup_pending: bool, node_id: str | None, has_token: bool,
            glaeda_current: bool = True, have_candidate: bool = True) -> list[UpStep]:
    """What `up` still has to do on this mini, in order. Pure, so it is tested without a Mac."""
    steps: list[UpStep] = []
    if local.glaeda is None:
        steps.append(UpStep("clone", f"clone Glaeda into {Path.home() / 'glaeda'}"))
    elif not glaeda_current:
        steps.append(UpStep("update", f"fast-forward the Glaeda checkout at {local.glaeda} (it predates glaeda-mini-enroll)"))
    if setup_pending:
        steps.append(UpStep("setup", "glaeda-mini-setup: build-host tools, LaunchAgents and cache directories"))
    state = (local.enrollment or {}).get("state")
    enroll_needed = local.enrollment is None or state not in {"eligible", "quarantined", "retired"} or not local.acceptance
    if enroll_needed and not have_candidate:
        steps.append(UpStep("download", f"download the reviewed Glaeda candidate {CANDIDATE_SOURCE[:12]} "
                                        f"(run {CANDIDATE_RUN}) with gh"))
    if local.enrollment is None:
        if not node_id:
            raise Failure("this mini is not enrolled yet: pass --node-id, an opaque id such as cmux-mac-002 "
                          "(not a hostname or serial)")
        steps.append(UpStep("enroll", f"stage the candidate, enroll as {node_id} and run local acceptance "
                                      "(a cold cmux build, about 13 minutes)"))
    elif state in {"quarantined", "retired"}:
        raise Failure(f"Glaeda node {local.enrollment.get('nodeId')} is {state}; "
                      "resolve that in Glaeda before bringing it up")
    elif state != "eligible" or not local.acceptance:
        steps.append(UpStep("enroll", "finish Glaeda enrollment (resumes where it stopped)"))
    if not local.runner_configured:
        source = f"the token in ${TOKEN_ENV}" if has_token else "an org registration token from your gh login"
        steps.append(UpStep("register", f"install actions-runner {RUNNER_VERSION} and register it in {GROUP} "
                                        f"using {source}"))
    if not local.service_loaded:
        steps.append(UpStep("start", "start the runner as a launchd agent"))
    return steps


def glaeda_python(glaeda: Path, script: str, *args: str, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, os.fspath(glaeda / "scripts" / script), *args], cwd=glaeda,
                          text=True, stdout=subprocess.PIPE if capture else None, check=False)


def mini_setup_receipt(glaeda: Path, apply: bool) -> dict[str, Any]:
    # No --cmux-root: glaeda-mini-enroll runs the fleet bootstrap itself, and here it
    # would only add minutes to every `up`.
    args = ["--output", "json"] + (["--apply"] if apply else [])
    result = glaeda_python(glaeda, "glaeda-mini-setup", *args, capture=True)
    try:
        return json.loads(result.stdout)
    except ValueError:
        raise Failure("glaeda-mini-setup did not produce a receipt; run it directly to see why") from None


def setup_pending(receipt: dict[str, Any]) -> bool:
    return any(a.get("state") not in {"unchanged", "kept"} for a in receipt.get("actions", []))


def human_steps(receipt: dict[str, Any]) -> list[str]:
    """Operator steps `up` cannot do itself; the enrollment and registration ones it does."""
    skip = ("glaeda-mini-enroll", "persistent-compile", "rerun with --cmux-root")
    return [f"[{s['needs']}] {s['command']}   ({s['why']})" for s in receipt.get("operatorSteps", [])
            if not any(marker in s["command"] for marker in skip)]


def cmd_up(args: argparse.Namespace) -> int:
    require_mac()
    # Take the token out of the environment before any child runs: setup builds
    # third-party code, and the token can register a runner into the fleet's group.
    token = os.environ.pop(TOKEN_ENV, None)
    local = read_local(args.glaeda_root)
    if local.enrollment_error:
        raise Failure(f"the Glaeda enrollment exists but cannot be read: {local.enrollment_error}. "
                      "Inspect it; up will not replace it.")
    if not local.xcode:
        raise Failure(f"install Xcode 26.3 at {XCODE_APP} and run: sudo xcode-select -s {XCODE_APP}")
    current = local.glaeda is not None and (local.glaeda / "scripts" / "glaeda-mini-enroll").is_file()
    receipt = mini_setup_receipt(local.glaeda, apply=False) if current else {}
    steps = up_plan(local, not current or setup_pending(receipt), args.node_id,
                    bool(token), glaeda_current=current,
                    have_candidate=candidate_staged() or candidate_archive().is_file())
    if not steps:
        print(f"{local.runner_name} is enrolled, registered and running. Nothing to do.")
        return 0
    print("up:")
    if not confirm(args, [step.text for step in steps]):
        return 0
    for step in steps:
        print(f"\n== {step.text}", flush=True)
        if step.key == "clone":
            target = Path.home() / "glaeda"
            run_checked(["git", "clone", GLAEDA_URL, os.fspath(target)], Path.home())
            local.glaeda = target
        elif step.key == "update":
            run_checked(["git", "-C", os.fspath(local.glaeda), "pull", "--ff-only"], Path.home())
        elif step.key == "download":
            download_candidate()
        elif step.key == "setup":
            receipt = mini_setup_receipt(local.glaeda, apply=True)
            if not receipt.get("ready"):
                print("\nglaeda-mini-setup is blocked on: " + (", ".join(receipt.get("blocking", [])) or "unknown"))
                steps = human_steps(receipt)
                if steps:
                    print("Operator steps it suggests:")
                    for line in steps:
                        print(f"  {line}")
                raise Failure("do the steps above, then run scripts/persistent-compile up again")
        elif step.key == "enroll":
            enroll = ["--cmux-root", os.fspath(ROOT), "--apply", "--candidate", os.fspath(candidate_archive()),
                      "--sha256", CANDIDATE_SHA256, "--source", CANDIDATE_SOURCE]
            enroll += ["--node-id", args.node_id] if args.node_id else []
            if glaeda_python(local.glaeda, "glaeda-mini-enroll", *enroll).returncode:
                raise Failure("Glaeda enrollment stopped (see above); fix it and run scripts/persistent-compile up again")
            local = read_local(os.fspath(local.glaeda))
        elif step.key == "register":
            name = args.name or default_runner_name(local)
            register_runner(name, token)
            local = read_local(os.fspath(local.glaeda))
        elif step.key == "start":
            start_service(runner_dir())
    print(f"\n{local.runner_name or 'the runner'} is up. Check from anywhere: scripts/persistent-compile")
    return 0


def download_candidate() -> None:
    directory = candidate_dir()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    ok, error = gh("run", "download", CANDIDATE_RUN, "--repo", "teamleaderleo/glaeda",
                   "--name", CANDIDATE_ARTIFACT, "--dir", os.fspath(directory))
    if not ok:
        raise Failure(f"could not download Glaeda candidate run {CANDIDATE_RUN} ({error}). Artifacts expire after "
                      "30 days: ask for a new candidate and update CANDIDATE_* in scripts/ci/persistent_compile_fleet.py")
    if not candidate_archive().is_file():
        raise Failure(f"the downloaded artifact has no {candidate_archive().name}")
    # glaeda-mini-enroll verifies the bytes against CANDIDATE_SHA256 before staging anything.


def cmd_token(_: argparse.Namespace) -> int:
    data = gh_api(f"orgs/{ORG}/actions/runners/registration-token", "POST") or {}
    if not data.get("token"):
        raise Failure("GitHub returned no registration token")
    print(f"Registration token for {GROUP}, valid until {data.get('expires_at')}. On the mini, run:\n")
    print(f"  {TOKEN_ENV}={data['token']} scripts/persistent-compile up --node-id cmux-mac-NNN")
    return 0


def glaeda_transition(local: LocalState, target: str) -> None:
    if local.enrollment is None:
        print("no Glaeda enrollment on this mini; skipping the Glaeda state change")
        return
    if local.enrollment.get("state") == target:
        return
    if local.glaeda is None:
        raise Failure("cannot find the Glaeda checkout; set GLAEDA_ROOT or pass --glaeda-root")
    # The acceptance receipt is bound to the fleet tool that wrote it, which is the
    # staged candidate's copy, not whatever the checkout has moved on to.
    staged_tool = generation_dir() / "scripts" / "cmux_fleet.py"
    tool = staged_tool if staged_tool.is_file() else local.glaeda / "scripts" / "cmux_fleet.py"
    argv = [sys.executable, "-B", os.fspath(tool), "transition-apply", os.fspath(enrollment_path()), "--to", target]
    if target == "eligible":
        argv += ["--acceptance", os.fspath(acceptance_path())]
    run_checked(argv, local.glaeda)
    print(f"Glaeda: {local.enrollment.get('nodeId')} is {target}")


def cmd_drain(args: argparse.Namespace) -> int:
    require_mac()
    local = read_local(args.glaeda_root)
    directory = runner_dir()
    if not local.runner_configured:
        raise Failure(f"no runner is configured in {directory}")
    name = local.runner_name or "the runner"
    # Two control planes: Glaeda's state is what routing reads, the runner
    # service is what GitHub assigns to. Draining one without the other leaves
    # the mini taking work (docs/ci/mac-fleet.md 3.5). The service is the half
    # that stops GitHub, so a Glaeda failure must not prevent it.
    glaeda_error = None
    try:
        glaeda_transition(local, "draining")
    except Failure as error:
        glaeda_error = error
    deadline = time.monotonic() + (0 if args.now else DRAIN_WAIT_SECONDS)
    if worker_running(directory) and not args.now:
        print(f"{name} is running a job; stopping as soon as it finishes (--now stops it immediately)")
    # Poll tightly: between the job ending and the stop, GitHub can assign another.
    while worker_running(directory) and time.monotonic() < deadline:
        time.sleep(2)
    stop_service(directory)
    print(f"{name} is stopped and stays stopped across reboots. Undo: scripts/persistent-compile resume")
    if glaeda_error is not None:
        raise Failure(f"the runner is stopped, but Glaeda was not moved to draining: {glaeda_error}")
    return 0


def cmd_resume(args: argparse.Namespace) -> int:
    require_mac()
    local = read_local(args.glaeda_root)
    if not local.runner_configured:
        raise Failure("no runner is configured here; run: scripts/persistent-compile up")
    glaeda_transition(local, "eligible")
    start_service(runner_dir())
    print(f"{local.runner_name or 'the runner'} is taking jobs again")
    return 0


def cmd_unregister(args: argparse.Namespace) -> int:
    require_mac()
    local = read_local(args.glaeda_root)
    directory = runner_dir()
    if not local.runner_configured:
        print(f"no runner is configured in {directory}")
        return 0
    print("unregister:")
    if not confirm(args, [f"stop and remove the {local.runner_name} launchd agent",
                          f"remove {local.runner_name} from {GROUP} (org removal token from your gh login)"]):
        return 0
    plist = service_plist(directory)
    stop_service(directory)
    if plist is not None:
        plist.unlink(missing_ok=True)
        (directory / ".service").unlink(missing_ok=True)
        launchctl("enable", f"gui/{os.getuid()}/{plist.stem}")  # forget the disabled override
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
    p.add_argument("-y", "--yes", action="store_true", help="do it without asking")
    p.add_argument("--glaeda-root", help="Glaeda checkout (default: $GLAEDA_ROOT, else ~/glaeda)")
    # -y works before or after the command; SUPPRESS keeps a subcommand from resetting it.
    yes = argparse.ArgumentParser(add_help=False)
    yes.add_argument("-y", "--yes", action="store_true", default=argparse.SUPPRESS, help="do it without asking")
    root = argparse.ArgumentParser(add_help=False)
    root.add_argument("--glaeda-root", default=argparse.SUPPRESS, help="Glaeda checkout")
    sub = p.add_subparsers(dest="command", metavar="command")
    d = sub.add_parser("doctor", parents=[root], help="where things stand and the next command (the default)")
    d.add_argument("--local", action="store_true", help="also inspect this machine when it is not a Mac")
    up = sub.add_parser("up", parents=[yes, root], help="on a mini: set up, enroll, register and start; safe to re-run")
    up.add_argument("--node-id", help="opaque fleet id for a first enrollment, such as cmux-mac-002")
    up.add_argument("--name", help="runner name (default: <node id>-persistent-compile)")
    sub.add_parser("group", parents=[yes], help="org admin: create or repair the runner group")
    sub.add_parser("token", help="org admin: print a one-hour registration token for another mini")
    pi = sub.add_parser("pilot", help="route only these PR numbers or branch names")
    pi.add_argument("targets", nargs="+")
    sub.add_parser("all", help="route every trusted PR")
    sub.add_parser("off", help="route nothing")
    dr = sub.add_parser("drain", parents=[root], help="on a mini: stop taking jobs once the current one ends")
    dr.add_argument("--now", action="store_true", help="do not wait for a running job")
    sub.add_parser("resume", parents=[root], help="on a mini: take jobs again")
    sub.add_parser("unregister", parents=[yes, root], help="on a mini: remove its runner")
    return p


COMMANDS = {
    None: cmd_doctor, "doctor": cmd_doctor, "up": cmd_up, "group": cmd_group, "token": cmd_token,
    "pilot": cmd_pilot, "all": cmd_all, "off": cmd_off,
    "drain": cmd_drain, "resume": cmd_resume, "unregister": cmd_unregister,
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
