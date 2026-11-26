"""Grant prompts per app identity: what the onboarding run asked macOS for, read three ways.

Lawrence asked that Screen Sharing and Computer Use ask for their permissions as one app. This module
counts, for one onboarding run in a fresh VM, which app identities asked for Accessibility and Screen
Recording, so a run before and a run after a change give comparable numbers:

  log      tccd's own log (`log stream` in the guest for the whole run): per request (msgID) the
           service, the function, preflight or not, the process tccd charges (responsible, else
           accessing, else requesting) and its result. A non-preflight request is an ask: the first
           one per identity and service is the prompt or the System Settings grant a person meets.
  db       the system and the user TCC.db rows for the two services, before and after the run
           (`sudo -n sqlite3`; a guest whose ssh session has no Full Disk Access says unreadable).
  screen   the macOS prompts the person answered, as OCR read them (onboarding.py records them).

`summary()` gives `grant_prompts`: one row per (identity, service) that asked, with the count of asks
and how tccd answered, and `grant_prompt_count`, the number of grants a fresh Mac meets.
"""

from __future__ import annotations

import json
import re
import shlex

SERVICES = ("kTCCServiceAccessibility", "kTCCServiceScreenCapture")
PREDICATE = 'subsystem == "com.apple.TCC" OR process == "tccd"'
DBS = (("system", "/Library/Application Support/com.apple.TCC/TCC.db"),
       ("user", "/Users/admin/Library/Application Support/com.apple.TCC/TCC.db"))


def start_command(log_path: str, pid_path: str) -> str:
    """The guest command that starts tccd's log stream in the background and records its pid."""
    return (f"nohup /usr/bin/log stream --style ndjson --level debug --predicate {shlex.quote(PREDICATE)} "
            f">{shlex.quote(log_path)} 2>&1 </dev/null & echo $! >{shlex.quote(pid_path)}")


def stop_command(pid_path: str) -> str:
    """Stops the stream this run started (its own pid, from the file start_command wrote)."""
    return f"p=$(cat {shlex.quote(pid_path)} 2>/dev/null) && [ -n \"$p\" ] && kill \"$p\" 2>/dev/null; true"


def db_commands() -> list[tuple[str, str]]:
    """(name, guest command) per TCC.db: the command prints its rows for the two services as JSON."""
    services = ",".join("'%s'" % s for s in SERVICES)
    query = ("SELECT service, client, client_type, auth_value, auth_reason, last_modified FROM access "
             f"WHERE service IN ({services})")
    return [(name, f"sudo -n /usr/bin/sqlite3 -json {shlex.quote('file:' + path + '?mode=ro')} {shlex.quote(query)}")
            for name, path in DBS]


def db_read(name: str, returncode: int, stdout: str, stderr: str) -> dict:
    """One TCC.db read: its rows, or why it is unreadable (no Full Disk Access, no sudo)."""
    if returncode != 0:
        return {"db": name, "readable": False, "error": (stderr or stdout).strip()[:300]}
    try:
        rows = json.loads(stdout) if stdout.strip() else []
    except ValueError:
        return {"db": name, "readable": False, "error": "not JSON: " + stdout.strip()[:200]}
    return {"db": name, "readable": True, "rows": rows}


def _grab(pattern: str, message: str) -> str | None:
    match = re.search(pattern, message)
    return match.group(1) if match else None


def requests(lines: list[str]) -> list[dict]:
    """tccd's requests for the two services, one per msgID, in the order they started."""
    found: dict[str, dict] = {}
    order: list[str] = []
    for line in lines:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        message = event.get("eventMessage") or ""
        msg_id = _grab(r"msgID=([0-9.]+)", message)
        if not msg_id:
            continue
        if msg_id not in found:
            found[msg_id] = {"msg_id": msg_id, "time": event.get("timestamp")}
            order.append(msg_id)
        entry = found[msg_id]
        if message.startswith("AUTHREQ_CTX:"):
            entry.update(service=_grab(r"service=(\w+)", message), function=_grab(r"function=(\w+)", message),
                         preflight=_grab(r"preflight=(\w+)", message))
        elif message.startswith("AUTHREQ_ATTRIBUTION:"):
            for role in ("accessing", "requesting", "responsible"):
                value = _grab(role + r"=\{TCCDProcess: identifier=([^,}]+)", message)
                if value:
                    entry[role] = value
        elif message.startswith("AUTHREQ_PROMPTING:"):
            entry["prompting"] = True
        elif message.startswith("AUTHREQ_RESULT:"):
            entry["result"] = message[len("AUTHREQ_RESULT: "):][:200]
            entry["auth_value"] = _grab(r"authValue=(\d+)", message)
            entry["auth_reason"] = _grab(r"authReason=(\d+)", message)
    return [found[k] for k in order if found[k].get("service") in SERVICES]


def identity(request: dict) -> str:
    """The app identity tccd charges a request to: the responsible process unless it disclaimed."""
    return request.get("responsible") or request.get("accessing") or request.get("requesting") or "?"


def is_cmux(identity_: str) -> bool:
    return identity_.startswith("com.cmuxterm.") or "cmux" in identity_.lower()


def is_preflight(request: dict) -> bool:
    return str(request.get("preflight")).lower() in ("yes", "true", "1")


def summary(lines: list[str], db_before: dict, db_after: dict, prompts_seen: list[dict]) -> dict:
    reqs = requests(lines)
    by_pair: dict[tuple[str, str], dict] = {}
    for r in reqs:
        pair = (identity(r), r["service"])
        row = by_pair.setdefault(pair, {"identity": pair[0], "service": pair[1], "asks": 0, "preflights": 0,
                                        "prompting": 0, "functions": [], "first_ask": None, "results": []})
        if is_preflight(r):
            row["preflights"] += 1
            continue
        row["asks"] += 1
        row["prompting"] += 1 if r.get("prompting") else 0
        row["first_ask"] = row["first_ask"] or r.get("time")
        if r.get("function") and r["function"] not in row["functions"]:
            row["functions"].append(r["function"])
        if r.get("auth_value") is not None and len(row["results"]) < 6:
            row["results"].append({"auth_value": r["auth_value"], "auth_reason": r.get("auth_reason")})
    asked = [row for row in by_pair.values() if row["asks"]]
    asked.sort(key=lambda row: (row["first_ask"] or "", row["identity"], row["service"]))

    def rows(db: dict) -> list[dict]:
        out = []
        for name, found in db.items():
            for r in found.get("rows") or []:
                out.append(dict(r, db=name))
        return out

    before = {(r.get("client"), r.get("service")) for r in rows(db_before)}
    new_rows = [r for r in rows(db_after) if (r.get("client"), r.get("service")) not in before]
    return {
        "services": list(SERVICES),
        "log_lines": len(lines),
        "grant_prompts": asked,
        "grant_prompt_count": len(asked),
        "identities": sorted({row["identity"] for row in asked}),
        # The asks by cmux's own identities (com.cmuxterm.*, or a cmux path), apart from macOS's own.
        "cmux_grant_prompt_count": sum(1 for row in asked if is_cmux(row["identity"])),
        "cmux_identities": sorted({row["identity"] for row in asked if is_cmux(row["identity"])}),
        "preflight_only": sorted({"%s %s" % k for k, v in by_pair.items() if not v["asks"]}),
        "db_new_rows": new_rows,
        "db_readable": {name: bool(found.get("readable")) for name, found in db_after.items()},
        "prompts_seen": prompts_seen,
        "requests": reqs[:400],
    }


def line(result: dict) -> str:
    """One line for onboarding.log and the matrix summary."""
    pairs = ", ".join("%s %s x%d" % (r["identity"], r["service"].replace("kTCCService", ""), r["asks"])
                      for r in result.get("grant_prompts", []))
    return "TCC grant_prompts=%d cmux=%d cmux_identities=%d seen=%d [%s]" % (
        result.get("grant_prompt_count", 0), result.get("cmux_grant_prompt_count", 0), len(result.get("cmux_identities", [])),
        len(result.get("prompts_seen", [])), pairs or "-")
