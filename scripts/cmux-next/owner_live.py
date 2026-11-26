"""Who holds an OWNERS.md area now: the owner cell resolved to a live acpmux session, and the push notice sent to it.

An OWNERS.md owner is a name written once ("PL-acpmux (session cmux-4f; lead decision 2026-10-23)"). The session it
names ends, and nothing rewrote the row, so every push into the acpmux crate printed "owner PL-acpmux (session
cmux-4f ...)" for a month after cmux-4f was gone and reached no one (cmux#50549, 2026-11-22). The owner of a row is
whoever holds it now, read from the live sessions at push time, in this order:

1. a live session tagged `owns=` with the row's workstream (`acpmux session tag SESSION owns=PL-acpmux`; a comma list holds
   several): a holder takes a workstream by tagging itself, and gives it up by ending;
2. a live lane the row's role names: `lanes tabs-refine,tab-strip-*` (fnmatch globs on the session's short name, commas
   between them; `|` would split the OWNERS.md table cell), the most recently active one (never a PR finisher, `finish-REPO-N-...`, which holds one PR). A role outlives every session that fills it, so a row written
   `lanes ...` does not go dead when one lane ends (2026-11-23: seven rows named ended sessions, cmux-b6, cmux-4f,
   a590, and their pushes went to the coordinator);
3. the session the cell names (`session cmux-4f`), if it is live;
4. its successor: a live session tagged `succeeds=` with the named session's id, or the named row's `failover=HOST/NEW`,
   followed to the end of the chain;
5. the row's fallback, as OWNERS.md says ("When a workstream ends, its row goes back to the Performance Lead"): a
   live session tagged `owns=PL-lead`;
6. the coordinator: a live session tagged `owns=coordinator`, else the fleet registry's `coordinators.current`
   (`CMUX_FLEET_REGISTRY`, else ~/Projects/leo-workspace/machines/fleet-registry.json), followed through
   `coordinators.retired` to its successor, if that session is live.

The pre-push hook prints the holder on the owner line and sends it one `acpmux send --class action` notice per area
and pushed head (a stand-in, the Performance Lead or the coordinator, one per area a UTC day, asking for a holder) (deduplicated in ~/.cache/cmux/owner-notices.json), so a push into an area reaches a live session
without the pusher looking anyone up. Never on CI (`CI` set), never when acpmux is missing, never longer than
LIST_TIMEOUT_S plus SEND_TIMEOUT_S, and never a refusal: a failed listing or send is one line in the report.
`CMUX_OWNER_NOTIFY=0` prints the holder and sends nothing, as does a push outside an acpmux session (no sender).
"""
from __future__ import annotations

import fnmatch
import hashlib
import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

LIST_TIMEOUT_S = 20
SEND_TIMEOUT_S = 10
CHAIN_MAX = 8
NOTICES_KEEP = 500
DEAD = {"closed", "stopped", "failed", "dead", "disconnected", "retired"}
WORKSTREAM = re.compile(r"\bPL-[A-Za-z0-9][\w-]*")
SESSION = re.compile(r"\bsessions? ([A-Za-z0-9][\w./-]*[A-Za-z0-9])")
LANES = re.compile(r"\blanes ([A-Za-z0-9*?\[\]][\w*?\[\]./,-]*)")
# A PR finisher the stall dispatcher starts (`finish-cmux-52161-sidebar`) holds one pull request, not an area: its
# name carries the PR's area word, so a role glob like `*sidebar*` matched it and every sidebar push went to it
# (2026-11-23: ~25 notices to finish-cmux-52161-sidebar). Role globs skip it; an `owns=` tag still counts.
FINISHER = re.compile(r"^finish-[\w.-]*?-\d+(?:-|$)")
LEAD = "PL-lead"
COORDINATOR = "coordinator"


def cell_names(cell: str) -> tuple[list[str], list[str]]:
    """(workstreams, sessions) an owner cell names: `PL-acpmux`, and `cmux-4f` from "session cmux-4f"."""
    return list(dict.fromkeys(WORKSTREAM.findall(cell or ""))), list(dict.fromkeys(SESSION.findall(cell or "")))


def cell_lanes(cell: str) -> list[str]:
    """The lane-name globs a role cell names: `tabs-refine` and `tab-strip-*` from "lanes tabs-refine,tab-strip-*"."""
    return [g for m in LANES.findall(cell or "") for g in m.split(",") if g]


def _tags(row: dict) -> dict:
    tags = row.get("tags")
    return tags if isinstance(tags, dict) else {}


def _name(row: dict) -> str:
    return str(row.get("name") or row.get("shortName") or "")


def _short(name: str) -> str:
    return name.rsplit("/", 1)[-1]


def is_live(row: dict) -> bool:
    """A session that can take a message now: not closed, stopped, failed or disconnected, and not stale."""
    return str(row.get("status") or "").casefold() not in DEAD and row.get("stale") is not True and bool(_name(row))


def owns(row: dict, workstream: str) -> bool:
    return workstream in [w.strip() for w in str(_tags(row).get("owns") or "").split(",")]


def _named(rows: list[dict], name: str) -> list[dict]:
    """The rows called NAME (HOST/NAME or a bare name on any host), live first, then newest."""
    found = [r for r in rows if name in (_name(r), _short(_name(r)), r.get("sessionId"))]
    return sorted(found, key=lambda r: (not is_live(r), -(r.get("updatedAt") or 0)))


def successor(rows: list[dict], name: str) -> str | None:
    """The live session that took over NAME: its `failover=HOST/NEW`, or a live row tagged `succeeds=` its id, followed
    to the end of the chain (CHAIN_MAX hops, a loop ends it)."""
    seen, current = set(), name
    for _ in range(CHAIN_MAX):
        if current in seen:
            return None
        seen.add(current)
        named = _named(rows, current)
        if named and is_live(named[0]):
            return _name(named[0]) if current != name else None
        ids = {str(r.get("sessionId")) for r in named if r.get("sessionId")}
        nxt = next((str(_tags(r).get("failover")) for r in named if _tags(r).get("failover")), None)
        if nxt is None:
            heirs = sorted((r for r in rows if str(_tags(r).get("succeeds") or "") in ids),
                           key=lambda r: (not is_live(r), -(r.get("updatedAt") or 0)))
            nxt = _name(heirs[0]) if heirs else None
        if not nxt:
            return None
        current = nxt
    return None


def registry_coordinator(path: Path | None = None) -> str | None:
    """coordinators.current of the fleet registry, followed through coordinators.retired ({old: new}), or None."""
    path = path or Path(os.environ.get("CMUX_FLEET_REGISTRY")
                        or Path.home() / "Projects/leo-workspace/machines/fleet-registry.json")
    try:
        coords = json.loads(path.read_text(encoding="utf-8")).get("coordinators") or {}
    except (OSError, ValueError, AttributeError):
        return None
    current, retired = coords.get("current"), coords.get("retired")
    retired = retired if isinstance(retired, dict) else {}
    for _ in range(CHAIN_MAX):
        nxt = retired.get(current) if isinstance(current, str) else None
        if not isinstance(nxt, str) or nxt == current:
            break
        current = nxt
    return current if isinstance(current, str) and current else None


def holder(cell: str, rows: list[dict], coordinator: str | None = None) -> tuple[str | None, str]:
    """(live session, how) for the owner CELL, or (None, why none)."""
    workstreams, sessions = cell_names(cell)
    live = [r for r in rows if is_live(r)]
    for w in workstreams:
        tagged = sorted((r for r in live if owns(r, w)), key=lambda r: -(r.get("updatedAt") or 0))
        if tagged:
            return _name(tagged[0]), f"holds owns={w}"
    globs = cell_lanes(cell)
    if globs:
        lanes = sorted((r for r in live if not FINISHER.match(_short(_name(r)))
                        and any(fnmatch.fnmatchcase(_short(_name(r)), g) for g in globs)),
                       key=lambda r: -(r.get("updatedAt") or 0))
        if lanes:
            return _name(lanes[0]), f"a lane of {','.join(globs)}"
    for s in sessions:
        named = _named(rows, s)
        if named and is_live(named[0]):
            return _name(named[0]), "named"
    for s in sessions:
        heir = successor(rows, s)
        if heir:
            return heir, f"successor of {s}"
    gone = ", ".join(sessions) + " gone" if sessions else (f"no live lane of {','.join(globs)}" if globs else "no live holder")
    if workstreams:
        lead = sorted((r for r in live if owns(r, LEAD)), key=lambda r: -(r.get("updatedAt") or 0))
        if lead:
            return _name(lead[0]), f"{gone}; the Performance Lead ({LEAD})"
    tagged = sorted((r for r in live if owns(r, COORDINATOR)), key=lambda r: -(r.get("updatedAt") or 0))
    if tagged:
        return _name(tagged[0]), f"{gone}; the coordinator"
    coordinator = coordinator if coordinator is not None else registry_coordinator()
    if coordinator:
        named = _named(rows, coordinator)
        if named and is_live(named[0]):
            return _name(named[0]), f"{gone}; the coordinator"
        heir = successor(rows, coordinator)
        if heir:
            return heir, f"{gone}; the coordinator's successor"
    return None, f"{gone}; no live lead or coordinator"


def list_sessions(timeout: float = LIST_TIMEOUT_S) -> tuple[list[dict] | None, str | None]:
    """(acpmux's session records, None) or (None, why not): every host's, closed ones included (successor chains)."""
    if os.environ.get("CI") or not shutil.which("acpmux"):
        return None, None
    try:
        out = subprocess.run(["acpmux", "ls", "--json"], capture_output=True, text=True, timeout=timeout)
        doc = json.loads(out.stdout or "null")
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        return None, f"acpmux ls failed ({type(error).__name__})"
    rows = doc.get("sessions") if isinstance(doc, dict) else doc
    if not isinstance(rows, list):
        return None, None
    rows = [r for r in rows if isinstance(r, dict)]
    return merge_tagged(rows, _tagged(TAG_KEYS, timeout)), None


TAG_KEYS = ("owns", "succeeds", "failover")


def _tagged(keys, timeout: float) -> list[dict]:
    """The rows carrying any of KEYS, read with `ls --tag KEY`. The full `ls --json` listing serves a peer's rows from
    its cached copy, which can lack the tags set since (2026-11-23: four `owns=` tags set from cosmic-gray read None
    in the full listing on gcp-agent-lane-11 and `--tag owns` found them), so a tag is read where it is filtered."""
    found = []
    for key in keys:
        try:
            out = subprocess.run(["acpmux", "--json", "ls", "--tag", key, "--fields", "name,sessionId,tags"],
                                 capture_output=True, text=True, timeout=timeout)
            doc = json.loads(out.stdout or "null")
        except (OSError, subprocess.TimeoutExpired, ValueError):
            continue
        part = doc.get("sessions") if isinstance(doc, dict) else doc
        found += [r for r in part or [] if isinstance(r, dict)]
    return found


def merge_tagged(rows: list[dict], tagged: list[dict]) -> list[dict]:
    """ROWS with the tags of each TAGGED row (matched by sessionId, else name) folded into its own."""
    by = {}
    for t in tagged:
        if isinstance(t.get("tags"), dict):
            by.setdefault(t.get("sessionId") or t.get("name"), {}).update(t["tags"])
    if not by:
        return rows
    out = []
    for r in rows:
        extra = by.get(r.get("sessionId")) or by.get(r.get("name"))
        out.append({**r, "tags": {**_tags(r), **extra}} if extra else r)
    return out


def _notices_path() -> Path:
    return Path(os.environ.get("CMUX_OWNER_NOTICES") or Path.home() / ".cache/cmux/owner-notices.json")


# A notice goes out as the pushing session or not at all. On 2026-11-25 a push run outside any acpmux session sent
# one from the bare host (thread from:gcp-agent-lane-8, no Sent-by, "no live or closed session named
# 'gcp-agent-lane-8'"), so its reader could neither answer nor tell who pushed. acpmux names the sender from
# ACPMUX_SESSION_ID (or a session token); with neither set the push prints the holder and sends nothing.
SENDER_ENV = ("ACPMUX_SESSION_ID", "ACPMUX_SESSION_TOKEN")
NO_SENDER = "no acpmux session to send as (ACPMUX_SESSION_ID unset); tell the holder yourself"


def sender() -> str | None:
    """The pushing session's id or token, or None outside an acpmux session."""
    return next((os.environ[name] for name in SENDER_ENV if os.environ.get(name, "").strip()), None)


# A notice names its pusher as HOST/NAME, the address `lane-gh send` and inbox_reply take. On 2026-11-26 three notices
# reached a coordinator labelled with a bare host ("gcp-agent-lane-5", "fs-agent-lane-7", "gcp-codex-lane-12") and
# inbox_reply failed with "no live or closed session named 'gcp-agent-lane-5' on any machine": the holder could not
# answer the pusher. The notice now carries the address it was sent from, and a session acpmux cannot name sends none.
NO_SENDER_NAME = "the pushing session has no HOST/NAME acpmux can resolve; tell the holder yourself"


def sender_name(timeout: float = LIST_TIMEOUT_S) -> str | None:
    """The pushing session as HOST/NAME (from `acpmux session info`), or None when acpmux cannot name it."""
    ident = (os.environ.get("ACPMUX_SESSION_ID") or os.environ.get("ACPMUX_SESSION_NAME") or "").strip()
    if not ident:
        return None
    try:
        out = subprocess.run(["acpmux", "session", "info", ident, "--fields", "machine,name"],
                             capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    fields = dict(line.split("\t", 1) for line in out.stdout.splitlines() if "\t" in line)
    host, name = fields.get("machine", "").strip(), _short(fields.get("name", "").strip())
    return f"{host}/{name}" if host and name else None


def signed(text: str, me: str) -> str:
    """TEXT with a line naming the pusher, so the holder can answer it."""
    return f"{text}\n\nFrom {me}; answer with `lane-gh send {me} -` or `acpmux send {me} -`."


def notify(to: str, area: str, head: str, text: str) -> str | None:
    """Send TEXT to TO once per (TO, AREA, HEAD); None when sent or already sent, else why it was not."""
    if os.environ.get("CMUX_OWNER_NOTIFY") == "0":
        return "CMUX_OWNER_NOTIFY=0"
    if not sender():
        return NO_SENDER
    me = sender_name()
    if not me:
        return NO_SENDER_NAME
    text = signed(text, me)
    key = hashlib.sha1(f"{to}\n{area}\n{head}".encode()).hexdigest()[:16]
    path = _notices_path()
    try:
        sent = json.loads(path.read_text(encoding="utf-8"))
        sent = sent if isinstance(sent, dict) else {}
    except (OSError, ValueError):
        sent = {}
    if key in sent:
        return None
    try:
        out = subprocess.run(["acpmux", "send", "--no-wait", "--class", "action", to, "-"], input=text,
                             capture_output=True, text=True, timeout=SEND_TIMEOUT_S)
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"send failed ({type(error).__name__})"
    if out.returncode != 0:
        return f"send failed ({(out.stderr or out.stdout).strip()[:160]})"
    sent[key] = time.time()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        keep = dict(sorted(sent.items(), key=lambda kv: kv[1])[-NOTICES_KEEP:])
        path.write_text(json.dumps(keep), encoding="utf-8")
    except OSError:
        pass
    return None


def is_fallback(how: str) -> bool:
    """A holder() answer that is the Performance Lead or the coordinator standing in, not the area's own holder."""
    return "; the " in how


def unheld_notice(area: str, cell: str, files: list[str], head: str, branch: str | None, doc: str) -> str:
    return (f"OWNERS.md area {area} has no live holder ({cell}), so its pushes come to you; this one: {branch or 'a branch'} "
            f"at {head[:12]} ({len(files)} file(s), {files[0]}). Give it a live holder: tag one "
            f"(`acpmux session tag SESSION owns=WORKSTREAM`) or rewrite the OWNERS.md row. You hear of it once a day "
            f"while it stays unheld.")


def notice(area: str, cell: str, files: list[str], head: str, branch: str | None, doc: str) -> str:
    shown = ", ".join(files[:6]) + (f" and {len(files) - 6} more" if len(files) > 6 else "")
    return (f"A push to {branch or 'a branch'} at {head[:12]} changes {area}, which OWNERS.md gives to {cell}; you hold "
            f"it now. Files: {shown}. Read {doc}; `git show {head[:12]}` for the change. If it is not yours, tag the "
            f"holder (`acpmux session tag SESSION owns=WORKSTREAM`) or fix the OWNERS.md row.")
