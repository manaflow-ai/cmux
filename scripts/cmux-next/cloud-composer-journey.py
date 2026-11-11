#!/usr/bin/env python3
"""The Cloud start journey a person takes: the new-chat composer of the real app, Cloud picked.

Leo, 2026-11-10: "how did NONE of these work/get tested?", "i already told you to test these", "did you
guys not test these". Every other Cloud journey (cloud-journey.ts, cloud-chat-proof.py,
cloud-chat-matrix.py) drives the CLI or the API with one small repo, so nothing exercised the composer
the way a person does. This one drives the composer's own actions in a launched app and runs a matrix:

  folder:  small-repo, parent (a folder holding several repos), plain (no Git), over-limit (past the
           20 GB copy cap, sparse), none (no folder: Cloud's fresh home)
  account: personal, team (a team the account is in), removed (a team the account is not in, left in the
           app's saved selection the way a removal leaves it)
  mode:    default, bypass (Bypass permissions)

Each cell asserts:
  * says-matches-does: what the composer says (its Cloud refusal "Cloud isn't available for this chat",
    the team it names, the Mode chip) matches what happens;
  * outcome: the start succeeds and the agent replies, or it is refused BEFORE a machine is leased, with
    an actionable message (not a bare Retry);
  * no machine is left behind: every machine this app made in the cell is deleted, and a refused start
    made none;
  * the chips name what they show: the Mode chip never reads a bare "Mode", the team tag never names a
    team the account is not in. (Truncation of the chips is the gallery's check,
    webviews/src/agent-session/acpmux/cloudComposerChips.gallery.ts, where widths are measured.)

Two drivers, one matrix:

  --app APP   (CI) launches a tagged DEV build signed in as the agent test account from
              --credentials-file and drives its composer through `debug.agent_pane` (new tab, folder pick,
              run place, Mode menu, Return), the verbs a click or key runs, in a window that never
              activates. cloud-composer-journey.yml runs it against a nightly's source commit.
  --cli CLI   (live) a running app's own CLI, such as "/Applications/cmux NIGHTLY.app/Contents/Resources/
              bin/cmux" with CMUX_BUNDLE_ID=com.cmuxterm.app.nightly. A Release build answers no `app call`,
              so the composer verbs are out of reach there: each cell starts through `cmux chat --on vm:new
              --from-folder`, the start the composer's Cloud send shares, and the composer-only columns say
              "not readable (Release build)". It never switches the person's team or mode (those cells are
              skipped), never steals focus, and holds /tmp/cmux-live-driver.lock so only one driver works in
              a person's app at a time.

Output: journey.json and journey.md (one row per cell) in --out; exit 1 when a cell fails or a machine is
left. Run on demand on CI: `gh workflow run cloud-composer-journey.yml --ref feat-cmux-next -f nightly_build=4291415492601`.
Live, in a person's NIGHTLY after a fix (one command; CMUX_BUNDLE_ID is read from the bundle):
  python3 scripts/cmux-next/cloud-composer-journey.py \
    --cli "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux" --out /tmp/composer-journey
"""

from __future__ import annotations

import argparse
import fcntl
import importlib.util
import json
import os
import plistlib
import random
import secrets
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("cloud_chat_matrix", HERE / "cloud-chat-matrix.py")
matrix_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(matrix_mod)  # type: ignore[union-attr]
Matrix = matrix_mod.Matrix
clean = matrix_mod.clean
small_repo = matrix_mod.small_repo
EVIDENCE_SCAN = matrix_mod.EVIDENCE_SCAN
HUGE_PLAIN_BYTES = matrix_mod.HUGE_PLAIN_BYTES

FOLDERS = ("small-repo", "parent", "plain", "over-limit", "none")
ACCOUNTS = ("personal", "team", "removed")
MODES = ("default", "bypass")
# A refusal of a folder past the cap must come before a machine, and fast (size_cap.rs checks first).
OVER_LIMIT_MUST_REFUSE = True
# Words that alone tell a person nothing they can act on.
UNACTIONABLE = re.compile(r"^\s*(retry|try again|something went wrong|error|failed|cloud start failed)\.?\s*$", re.I)
UNAVAILABLE = "isn't available for this chat"
LIVE_LOCK = "/tmp/cmux-live-driver.lock"
# Machines other runs name (cloud-chat-matrix cwm-, cloud-chat-proof ccp-, cloud-journey jr-): never ours.
OTHER_RUNS = re.compile(r"^(cwm-|ccp-|jr-|cloud journey)")
STALE_TEAM_DEFAULT = "team_cmuxjourneyremoved0000"
TEAM_KEY = "cmux.auth.selectedTeamID"


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    where = parser.add_mutually_exclusive_group(required=True)
    where.add_argument("--app", help="a tagged DEV app bundle to launch, signed in from --credentials-file (CI)")
    where.add_argument("--cli", help="the CLI of a running app (live: the person's own app)")
    parser.add_argument("--tag", default=f"ccj-{secrets.token_hex(4)}", help="names this run")
    parser.add_argument("--cloud-backend", choices=("staging", "prod"))
    parser.add_argument("--expected-api-origin")
    parser.add_argument("--credentials-file")
    parser.add_argument("--grant-claude-login", action="store_true",
                        help="with --app: the launched app's scratch cmux.json says yes to the Claude login copy")
    parser.add_argument("--team", default=os.environ.get("CMUX_JOURNEY_PRODUCT_TEAM", ""),
                        help="the team cells' team id (a team the account is in)")
    parser.add_argument("--removed-team", default=STALE_TEAM_DEFAULT,
                        help="a team id the account is not in, seeded as the app's saved selection")
    parser.add_argument("--only", default="", help="comma list of cell filters: folder, account or mode names, "
                                                     "or full ids like small-repo/personal/default")
    parser.add_argument("--timeout", type=int, default=600, help="seconds one start may take to reply")
    parser.add_argument("--out", required=True)
    parser.add_argument("--nightly", default="", help="the nightly build this app is (for the report)")
    parser.add_argument("--keep-fixtures", action="store_true")
    args = parser.parse_args(argv)
    if args.app and not (args.cloud_backend and args.expected_api_origin and args.credentials_file):
        parser.error("--app needs --cloud-backend, --expected-api-origin and --credentials-file")
    if args.grant_claude_login and not args.app:
        parser.error("--grant-claude-login works only with --app, the app this run launches")
    # Matrix (cloud-chat-matrix.py) reads these.
    args.login = ""
    args.parallel = 1
    return args


def selected(only: str, folder: str, account: str, mode: str) -> bool:
    words = [w for w in only.split(",") if w]
    if not words:
        return True
    cell = f"{folder}/{account}/{mode}"
    return any(w == cell or w in (folder, account, mode) for w in words)


# Fixtures ------------------------------------------------------------------------------------------------

def fixture(kind: str, root: Path) -> Path | None:
    path = root / kind
    if kind == "none":
        return None
    if kind == "small-repo":
        small_repo(path)
    elif kind == "parent":
        # Leo's ~/Projects: a parent of many repos. Small here; what matters is that it is a parent.
        path.mkdir(parents=True)
        for name in ("api", "web", "tools"):
            small_repo(path / name)
        (path / "notes.txt").write_text("a parent folder of several repositories\n")
    elif kind == "plain":
        path.mkdir(parents=True)
        (path / "README.txt").write_text("a plain folder, no Git\n")
        (path / "data.csv").write_text("a,b\n1,2\n")
    elif kind == "over-limit":
        path.mkdir(parents=True)
        (path / "README.txt").write_text("past the 20 GB copy cap (a sparse file)\n")
        with open(path / "disk.img", "wb") as sparse:
            sparse.truncate(HUGE_PLAIN_BYTES)
    return path


# The app ---------------------------------------------------------------------------------------------------

class Journey(Matrix):
    """cloud-chat-matrix's Matrix (launch, sign-in wait, CLI calls, kill) plus the composer verbs."""

    def __init__(self, args):
        super().__init__(args)
        self.composer = False  # set once `debug.agent_pane` answers
        self.made: set[str] = set()
        self.home_pane: str | None = None  # the pane the cells open their new chat tabs in

    # -- app calls
    def call(self, method: str, params: dict | None = None, timeout: int = 90) -> dict:
        code, out, err = self.cmux("app", "call", method, json.dumps(params or {}), "--json", timeout=timeout)
        value = self.parsed(out) if code == 0 else {}
        if code != 0:
            problem = self.error(out, err)
            return {"error": problem.get("message") or clean(err or out, 300), "code": problem.get("code")}
        return value

    def pane(self, action: str, pane: str | None = None, timeout: int = 90, **params) -> dict:
        body = {"action": action, **params}
        if pane:
            body["pane"] = pane
        return self.call("debug.agent_pane", body, timeout=timeout)

    def page_text(self, selector: str) -> list[str]:
        value = self.call("debug.page", {"page": "cmux.agent", "action": "query", "selector": selector})
        return [str(e.get("text", "")) for e in (value.get("elements") or []) if isinstance(e, dict)]

    def machine_rows(self) -> dict[str, dict]:
        code, out, _ = self.cmux("cloud", "list-machines", "--json", timeout=60)
        rows = (self.parsed(out).get("machines") or []) if code == 0 else []
        return {r["machine_id"]: r for r in rows if isinstance(r, dict) and r.get("machine_id")}

    def creations(self) -> list[dict]:
        value = self.call("cloud.machines", {}) if self.composer else {}
        return [r for r in (value.get("creations") or []) if isinstance(r, dict)]

    def team_id(self) -> str:
        return str(self.call("auth.status").get("team_id") or "") if self.composer else ""

    def switch_team(self, team: str) -> str:
        """The palette's Switch Active Team (openTeamPicker), as a person picks it."""
        value = self.call("action.run", {"id": "openTeamPicker", "args": {"team": team}})
        if value.get("error"):
            return f"switch to {team}: {value['error']}"
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.team_id() == team:
                return ""
            time.sleep(1)
        return f"switch to {team}: the app still works in {self.team_id() or 'no team'}"

    def bundle_id(self) -> str:
        with open(Path(self.args.app) / "Contents/Info.plist", "rb") as handle:
            return plistlib.load(handle).get("CFBundleIdentifier", "")

    def seed_stale_team(self, team: str) -> str:
        """Quit, write `team` into every saved team selection key the app has, relaunch: what a removal from
        a team leaves on a person's Mac. Answers a problem, or ''."""
        bundle = self.bundle_id()
        self.cmux("app", "quit", "--json", timeout=30)
        if self.launcher is not None:
            try:
                self.launcher.wait(timeout=60)
            except subprocess.TimeoutExpired:
                return "the app did not quit to seed the stale team"
            self.launcher = None
        exported = subprocess.run(["defaults", "export", bundle, "-"], capture_output=True)
        keys = []
        if exported.returncode == 0:
            keys = [k for k in plistlib.loads(exported.stdout) if k.startswith(TEAM_KEY)]
        for key in keys or [TEAM_KEY]:
            subprocess.run(["defaults", "write", bundle, key, "-string", team], check=False)
        problem = self.launch()
        if problem:
            return problem
        self.composer = "error" not in self.call("debug.agent_pane", {"action": "engine"})
        return ""


# One cell --------------------------------------------------------------------------------------------------

def actionable(message: str) -> bool:
    message = (message or "").strip()
    return len(message) >= 20 and not UNACTIONABLE.match(message)


def answer_prompt(word: str) -> tuple[str, str]:
    """A prompt whose answer holds a token the prompt does not: the reply proves the agent answered."""
    a, b = random.randint(11, 49), random.randint(11, 49)
    return (f"What is {a} plus {b}? Answer with only the number, then a space, then the word {word}. "
            "Do not run any command."), f"{a + b} {word}"


def guest_has(journey: Journey, machine: str, needle: str) -> bool:
    """Whether the agent's transcript on the machine holds `needle` (the reply's token)."""
    command = ('for d in "$HOME/.claude/projects" /home/cmux/.claude/projects /root/.claude/projects '
               '"$HOME/.codex/sessions" /home/cmux/.codex/sessions; do [ -d "$d" ] && grep -rlF -- '
               f'{json.dumps(needle)} "$d" 2>/dev/null; done | head -n 1')
    code, out, _ = journey.cmux("cloud", "exec", "--target", f"machine:{machine}", "--command", command, "--json",
                                timeout=120)
    answer = journey.parsed(out) if code == 0 else {}
    return bool(str(answer.get("stdout") or "").strip())


def new_machines(journey: Journey, before: set[str], since: float) -> list[str]:
    """Machines this app made since the cell began: its own creations first, else new ids not named by
    another run (the account is shared with other CI runs, whose machines are never ours to delete)."""
    ids = {str(r.get("machine_id") or r.get("id") or "") for r in journey.creations()} - {""}
    rows = journey.machine_rows()
    fresh = {m for m, row in rows.items() if m not in before and not OTHER_RUNS.match(str(row.get("title") or ""))}
    return sorted((ids & set(rows)) | (ids - before) | fresh) if journey.composer else sorted(fresh)


def cell_composer(journey: Journey, folder_kind: str, folder: Path | None, account: str, mode: str,
                  team_for_account: str, timeout: int) -> dict:
    cell = {"folder": folder_kind, "account": account, "mode": mode, "driver": "composer", "problems": []}
    problems = cell["problems"]
    before = set(journey.machine_rows())
    started = time.monotonic()

    # A new agent chat tab, as Agent Chat to New Tab makes it (no focus), then the composer's own picks.
    opened = journey.call("action.run", {"id": "new.agentChat.tab"})
    if opened.get("error"):
        cell["result"] = f"fail: new chat tab: {opened['error']}"
        return cell
    state, pane = {}, None
    for _ in range(30):
        state = journey.pane("chat_state", journey.home_pane)
        if state.get("pane") and not state.get("error"):
            pane = state["pane"]
            break
        # Several panes show a chat (an earlier cell's Cloud chat opened in its machine's workspace): the
        # pane the first cell used, else the newest listed.
        listed = [p for p in (state.get("agent_panes") or []) if isinstance(p, str)]
        if listed and not journey.home_pane:
            journey.home_pane = listed[-1]
        time.sleep(1)
    journey.home_pane = journey.home_pane or pane
    if not pane:
        cell["result"] = f"fail: no new chat pane ({clean(str(state.get('error')), 200)})"
        return cell
    if folder is not None:
        picked = journey.pane("pick_folder", pane, cwd=str(folder))
        if picked.get("error"):
            problems.append(f"folder pick: {picked['error']}")
        # A folder the person has not trusted asks first; the composer's own button answers.
        journey.pane("click", pane, text="Trust")  # trust.trust
    run = journey.pane("run_mode", pane, mode="cloud")
    cell["run_mode"] = run.get("runMode")
    if run.get("error") or run.get("runMode") != "cloud":
        problems.append(f"Cloud pick: {run.get('error') or run.get('runMode')}")

    # What the composer says before Return: the team it names, the Mode chip, any Cloud refusal.
    cell["team_tag"] = " ".join(journey.page_text(".acpmux-team-tag-name")).strip()
    if account == "removed" and journey.args.removed_team and journey.args.removed_team in cell["team_tag"]:
        problems.append("the team tag names a team the account is not in")
    mode_chip = " ".join(journey.page_text(".acpmux-access-trigger .acpmux-mode-text")).strip()
    cell["mode_chip"] = mode_chip
    if mode_chip == "Mode":
        problems.append('the Mode chip reads a bare "Mode"')
    if mode == "bypass":
        menu = journey.pane("open_menu", pane, label="Mode")  # the Mode picker's own label (PICKER_LABELS.mode)
        if menu.get("error"):
            problems.append(f"no Mode menu with Cloud picked ({clean(str(menu['error']), 120)})")
        clicked = journey.pane("click", pane, text="Bypass permissions")
        if clicked.get("error"):
            problems.append(f"Mode menu offers no Bypass permissions with Cloud picked ({clean(clicked['error'], 120)})")
        journey.pane("close_menus", pane)
        cell["mode_chip_after"] = " ".join(journey.page_text(".acpmux-access-trigger .acpmux-mode-text")).strip()
        if cell["mode_chip_after"] and "Bypass" not in cell["mode_chip_after"]:
            problems.append(f"the Mode chip reads {cell['mode_chip_after']!r} after picking Bypass permissions")
    said_unavailable_before = any(UNAVAILABLE in t for t in journey.page_text(".acpmux-composer, .acpmux-composer-strip"))

    # Return.
    word = f"cj{secrets.token_hex(4)}"
    prompt, reply_token = answer_prompt(word)
    sent = journey.pane("compose_send", pane, text=prompt, timeout=60)
    cell["sent"] = sent.get("sent")
    said_unavailable = said_unavailable_before or any(UNAVAILABLE in t for t in journey.page_text("body"))
    cell["said_unavailable"] = said_unavailable

    # Follow the start: the card fails (it stays), or the tab closes into the machine's chat.
    outcome, message, deadline = "", "", time.monotonic() + timeout
    while time.monotonic() < deadline:
        progress = journey.pane("run_mode", pane)
        if progress.get("error"):
            outcome = "started"  # the start closed this tab: the chat is the machine's
            break
        start = progress.get("cloudStart") or {}
        if isinstance(start, dict) and start.get("state") == "failed":
            outcome, message = "refused", str(start.get("message") or "")
            cell["refused_here"] = bool(start.get("refusedHere"))
            cell["retryable"] = bool(start.get("retryable"))
            cell["code"] = start.get("code")
            break
        if isinstance(start, dict) and start.get("ask"):
            outcome, message = "asked", str((start.get("ask") or {}).get("title") or "")
            break
        if sent.get("sent") is False and not start:
            outcome, message = "kept", " ".join(journey.page_text("[role='alert'], .acpmux-composer-notice")).strip()
            break
        time.sleep(3)
    cell["outcome"] = outcome or "timeout"
    cell["message"] = clean(message, 300)
    made = new_machines(journey, before, started)
    cell["machines_made"] = made

    # Says vs does.
    if said_unavailable and (outcome == "started" or made):
        problems.append("the composer said Cloud isn't available, yet a start ran")
    # Outcome rules.
    if outcome == "started":
        if folder_kind == "over-limit" and OVER_LIMIT_MUST_REFUSE:
            problems.append("a folder past the copy cap was started instead of refused")
        if account == "removed":
            current = journey.team_id()
            if current == team_for_account:
                problems.append("started in a team the account is not in")
        machine = made[0] if made else ""
        replied = False
        reply_deadline = time.monotonic() + timeout
        while machine and time.monotonic() < reply_deadline:
            if guest_has(journey, machine, reply_token):
                replied = True
                break
            time.sleep(10)
        cell["replied"] = replied
        if not replied:
            problems.append("started, but no reply from the agent" if machine else "started, but no machine to read")
    elif outcome in ("refused", "kept"):
        if made:
            problems.append(f"refused AFTER leasing a machine ({', '.join(made)})")
        if not actionable(message):
            problems.append(f"the refusal is not actionable: {clean(message, 120)!r}")
        if folder_kind in ("small-repo", "plain", "none") and account != "removed":
            problems.append("a start that should run was refused")
    elif outcome == "asked":
        problems.append(f"the start waits on a question CI cannot answer: {clean(message, 120)}")
    else:
        problems.append(f"no outcome within {timeout} s")

    # Leave nothing behind.
    left = [m for m in made if not journey.kill(m)]
    cell["machines_left"] = left
    if left:
        problems.append(f"machines left: {', '.join(left)}")
    journey.call("action.run", {"id": "closeTab", "target": pane})
    cell["seconds"] = round(time.monotonic() - started, 1)
    cell["result"] = "pass" if not problems else "fail: " + "; ".join(problems)
    return cell


def cell_cli(journey: Journey, folder_kind: str, folder: Path | None, account: str, mode: str,
             timeout: int) -> dict:
    """Live: the start the composer shares, through the person's app's CLI. Composer columns unreadable."""
    cell = {"folder": folder_kind, "account": account, "mode": mode, "driver": "cli", "problems": [],
            "team_tag": "not readable (Release build)", "mode_chip": "not readable (Release build)"}
    if account != "personal" or mode != "default":
        cell["result"] = "skipped: live mode never switches the person's team or mode"
        return cell
    problems = cell["problems"]
    before = set(journey.machine_rows())
    started = time.monotonic()
    word = f"cj{secrets.token_hex(4)}"
    prompt, reply_token = answer_prompt(word)
    words = ["chat", "--on", "vm:new", "--prompt", prompt, "--wait", "--timeout", f"{timeout}s", "--json"]
    if folder is not None:
        words[3:3] = ["--from-folder", str(folder)]
    code, out, err = journey.cmux(*words, timeout=timeout + 120)
    answer = journey.parsed(out) if code == 0 else {}
    made = sorted((set(journey.machine_rows()) - before) | ({answer["machine_id"]} if answer.get("machine_id") else set()))
    cell["machines_made"] = made
    if code == 0:
        cell["outcome"] = "started"
        cell["replied"] = reply_token in str(answer.get("reply") or "")
        if folder_kind == "over-limit":
            problems.append("a folder past the copy cap was started instead of refused")
        if not cell["replied"]:
            problems.append("started, but no reply from the agent")
    else:
        message = journey.error(out, err).get("message") or clean(err or out, 300)
        cell["outcome"], cell["message"] = "refused", clean(message, 300)
        if made:
            problems.append(f"refused AFTER leasing a machine ({', '.join(made)})")
        if not actionable(message):
            problems.append(f"the refusal is not actionable: {clean(message, 120)!r}")
        if folder_kind in ("small-repo", "plain", "none"):
            problems.append("a start that should run was refused")
    left = [m for m in made if not journey.kill(m)]
    cell["machines_left"] = left
    if left:
        problems.append(f"machines left: {', '.join(left)}")
    cell["seconds"] = round(time.monotonic() - started, 1)
    cell["result"] = "pass" if not problems else "fail: " + "; ".join(problems)
    return cell


# Report ----------------------------------------------------------------------------------------------------

def grid(cells: list[dict]) -> str:
    rows = ["| Folder | Account | Mode | Result | Outcome | Composer said | Mode chip | Machines made / left | s |",
            "|---|---|---|---|---|---|---|---|---|"]
    for c in cells:
        result = c.get("result", "")
        mark = "pass" if result == "pass" else ("skip" if result.startswith("skipped") else "**RED**")
        if mark == "skip":
            result = result.removeprefix("skipped: ")
        said = "Cloud unavailable" if c.get("said_unavailable") else (c.get("team_tag") or "")
        detail = result if mark != "pass" else ""
        rows.append("| {f} | {a} | {m} | {mark}{d} | {o} | {s} | {chip} | {made} / {left} | {sec} |".format(
            f=c.get("folder"), a=c.get("account"), m=c.get("mode"), mark=mark,
            d=(": " + clean(detail.removeprefix("fail: "), 220).replace("|", "/")) if detail else "",
            o=c.get("outcome", ""), s=clean(said, 60).replace("|", "/"),
            chip=clean(str(c.get("mode_chip_after") or c.get("mode_chip") or ""), 40).replace("|", "/"),
            made=len(c.get("machines_made") or []), left=len(c.get("machines_left") or []), sec=c.get("seconds", "")))
    return "\n".join(rows) + "\n"


def finish(report: dict, out: Path, code: int) -> int:
    text = json.dumps(report, indent=2)
    if EVIDENCE_SCAN.search(text):
        text = json.dumps({"tag": report.get("tag"), "result": report.get("result"),
                           "note": "the full report held a secret-shaped value and was not written"})
    (out / "journey.json").write_text(text + "\n")
    head = f"## Cloud composer journey ({report.get('tag')}{', nightly ' + report['nightly'] if report.get('nightly') else ''})\n\n"
    (out / "journey.md").write_text(head + f"{report.get('result', '')}\n\n" + grid(report.get("cells") or []))
    print((out / "journey.md").read_text(), flush=True)
    return code


def main(argv=None) -> int:
    args = parse_args(argv)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    lock = None
    if args.cli:
        # One live driver in a person's app at a time (another helper may be driving it).
        lock = open(LIVE_LOCK, "w")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(f"another driver holds {LIVE_LOCK}; run again when it is done", file=sys.stderr)
            return 75
    if args.cli and not os.environ.get("CMUX_BUNDLE_ID"):
        # The CLI inside an app bundle talks to that app: name it, so a NIGHTLY's CLI never reaches another cmux.
        plist = Path(args.cli).resolve().parents[2] / "Info.plist"
        if plist.is_file():
            with open(plist, "rb") as handle:
                os.environ["CMUX_BUNDLE_ID"] = plistlib.load(handle).get("CFBundleIdentifier", "")
    journey = Journey(args)
    root = Path(tempfile.mkdtemp(prefix="cmux-composer-journey-"))
    report = {"tag": args.tag, "nightly": args.nightly, "driver": "composer" if args.app else "cli", "cells": [],
              "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}

    def cancelled(signum, frame):
        journey.stop()
        sys.exit(128 + signum)
    signal.signal(signal.SIGTERM, cancelled)
    try:
        problem = journey.launch()
        if problem:
            report["result"] = f"fail: {problem}"
            return finish(report, out, 1)
        if args.app:
            probe = journey.call("debug.agent_pane", {"action": "engine"})
            # "no pane shows an agent tab" still proves the verb exists.
            journey.composer = "app.call_debug_only" not in str(probe.get("code")) and "unknown method" not in str(probe.get("error"))
            if not journey.composer:
                report["result"] = f"fail: the app has no debug.agent_pane ({probe.get('error')})"
                return finish(report, out, 1)
        fixtures = {kind: fixture(kind, root) for kind in FOLDERS}
        personal = journey.team_id()
        report["teams"] = {"personal": personal, "team": args.team, "removed": args.removed_team}
        order = [a for a in ("personal", "team", "removed") if a in ACCOUNTS]
        for account in order:
            team = {"personal": personal, "team": args.team, "removed": args.removed_team}[account]
            wanted = [(f, m) for f in FOLDERS for m in MODES if selected(args.only, f, account, m)]
            if not wanted:
                continue
            setup = ""
            if args.app and account == "team":
                setup = "no --team (CMUX_JOURNEY_PRODUCT_TEAM) given" if not team else journey.switch_team(team)
            elif args.app and account == "removed":
                setup = journey.seed_stale_team(team)
                report["removed_team_after_launch"] = journey.team_id()
            for folder_kind, mode in wanted:
                if setup.startswith("no --team"):
                    # Not a product red: the account has no team to test in. The table says so, and so does the run.
                    cell = {"folder": folder_kind, "account": account, "mode": mode,
                            "result": "skipped: not run: the agent account has no team (set CMUX_JOURNEY_PRODUCT_TEAM)"}
                elif setup:
                    cell = {"folder": folder_kind, "account": account, "mode": mode, "result": f"fail: setup: {setup}"}
                elif args.app:
                    try:
                        cell = cell_composer(journey, folder_kind, fixtures[folder_kind], account, mode, team, args.timeout)
                    except Exception as error:  # one cell's crash is its own row
                        cell = {"folder": folder_kind, "account": account, "mode": mode,
                                "result": f"fail: harness: {clean(repr(error), 300)}"}
                else:
                    cell = cell_cli(journey, folder_kind, fixtures[folder_kind], account, mode, args.timeout)
                report["cells"].append(cell)
                print(f"[{cell['result'][:160]}] {folder_kind}/{account}/{mode}", flush=True)
        left: list[str] = []
        report["machines_left"] = sorted({m for c in report["cells"] for m in (c.get("machines_left") or [])}) + left
        failed = [c for c in report["cells"] if not c["result"].startswith(("pass", "skipped"))]
        report["result"] = "pass" if not failed and not report["machines_left"] else (
            f"fail: {len(failed)} of {len(report['cells'])} cells red"
            + (f", {len(report['machines_left'])} machines left" if report["machines_left"] else ""))
        return finish(report, out, 0 if report["result"] == "pass" else 1)
    finally:
        if args.app:
            journey.quit()
        if not args.keep_fixtures:
            shutil.rmtree(root, ignore_errors=True)
        if lock is not None:
            lock.close()


if __name__ == "__main__":
    sys.exit(main())
