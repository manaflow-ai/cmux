#!/usr/bin/env python3
"""Set or remove one allowlisted env variable on the cmux.com Vercel project.

Run by .github/workflows/vercel-env.yml, inside its protected environment.
.github/vercel-env-allowlist.json is the only source of names, the project and
the targets; a name it does not list is refused before any request is made.

The value comes from VERCEL_ENV_VALUE (the workflow maps it from a GitHub
secret of the same name). It is never printed, never put in a URL, and every
message this script writes is passed through redact() first. There is no
debug mode.

Only the branchless entry for the chosen target is managed. An entry shared by
both targets is never rewritten in place, because that would change the other
target too: `remove` narrows it to the other target, then `set` creates this
target's own entry.

  GH_TOKEN=... scripts/ci/vercel_env.py --check-environment
  VERCEL_TOKEN=... [VERCEL_ENV_VALUE=...] \\
    scripts/ci/vercel_env.py --name NAME --target production|preview --action set|remove

--check-environment refuses unless the allowlist's GitHub environment exists
with required reviewers and a deployment branch policy of exactly `main`. GitHub creates a
missing environment on first use with no protection at all, and the repo-level
VERCEL_TOKEN would then reach an unapproved run; this check fails it instead.

Exit status: 0 done (or already absent), 1 refused or failed, 2 usage.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[2]
ALLOWLIST = ROOT / ".github" / "vercel-env-allowlist.json"
API = "https://api.vercel.com"
SENSITIVE = "sensitive"
ENCRYPTED = "encrypted"


class Refused(Exception):
    """A request this script will not make, with the reason."""


_SECRETS: list[str] = []


def register_secret(value: str | None) -> None:
    if not value:
        return
    _SECRETS.append(value)
    # A multi-line value is masked line by line too, so no fragment survives.
    _SECRETS.extend(line for line in value.splitlines() if len(line.strip()) >= 4)


def redact(text: object) -> str:
    out = str(text)
    for secret in sorted(set(_SECRETS), key=len, reverse=True):
        out = out.replace(secret, "***")
    return out


def say(message: str, error: bool = False) -> None:
    print(redact(message), file=sys.stderr if error else sys.stdout, flush=True)


def load_allowlist(path: Path = ALLOWLIST) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    for name, entry in data["variables"].items():
        if not isinstance(entry.get("secret"), bool):
            raise ValueError(f"{name}: allowlist entry needs secret: true|false")
    return data


def targets_of(entry: dict[str, Any]) -> list[str]:
    target = entry.get("target") or []
    return [target] if isinstance(target, str) else list(target)


def matching(envs: list[dict[str, Any]], name: str, target: str) -> list[dict[str, Any]]:
    """Branchless entries for `name` that apply to `target`."""
    return [e for e in envs if e.get("key") == name and target in targets_of(e) and not e.get("gitBranch")]


def plan(envs: list[dict[str, Any]], name: str, target: str, action: str, secret: bool) -> dict[str, Any]:
    """Decide one request from the current env list. Pure, so tests can drive it."""
    found = matching(envs, name, target)
    if len(found) > 1:
        raise Refused(f"{name} has {len(found)} branchless entries for {target}; resolve them in Vercel first")
    entry = found[0] if found else None
    if action == "remove":
        if entry is None:
            return {"op": "none", "outcome": "already absent"}
        rest = [t for t in targets_of(entry) if t != target]
        if rest:
            return {"op": "narrow", "id": entry["id"], "target": rest, "outcome": f"removed from {target}, kept for {', '.join(rest)}"}
        return {"op": "delete", "id": entry["id"], "outcome": "removed"}
    if action != "set":
        raise Refused(f"unknown action {action}")
    want = SENSITIVE if secret else ENCRYPTED
    if entry is None:
        return {"op": "create", "type": want, "outcome": "created"}
    others = [t for t in targets_of(entry) if t != target]
    if others:
        raise Refused(
            f"{name} for {target} shares one entry with {', '.join(others)}; run remove for {target} first, then set"
        )
    if entry.get("type") != want:
        raise Refused(f"{name} must be {want} but its {target} entry is {entry.get('type')}; run remove for {target} first, then set")
    return {"op": "update", "id": entry["id"], "previousUpdatedAt": entry.get("updatedAt"), "outcome": "updated"}


def verify(envs: list[dict[str, Any]], name: str, target: str, action: str, secret: bool, step: dict[str, Any]) -> str:
    """Read-back check on names, targets and types only. Returns the entry type."""
    found = matching(envs, name, target)
    if action == "remove":
        if found:
            raise Refused(f"{name} is still present for {target} after remove")
        return "-"
    if len(found) != 1:
        raise Refused(f"expected one {name} entry for {target} after set, found {len(found)}")
    entry = found[0]
    if targets_of(entry) != [target]:
        raise Refused(f"{name} entry covers {targets_of(entry)} after set, expected only {target}")
    want = SENSITIVE if secret else ENCRYPTED
    if entry.get("type") != want:
        raise Refused(f"{name} was written as {entry.get('type')}, expected {want}")
    if step["op"] == "update":
        before, after = step.get("previousUpdatedAt"), entry.get("updatedAt")
        if before is not None and (after is None or after <= before):
            raise Refused(f"{name} for {target} shows no update after set")
    return str(entry.get("type"))


Request = Callable[[str, str, dict[str, Any] | None], Any]


def http_request(token: str, team_id: str) -> Request:
    def request(method: str, path: str, body: dict[str, Any] | None = None) -> Any:
        sep = "&" if "?" in path else "?"
        url = f"{API}{path}{sep}teamId={urllib.parse.quote(team_id)}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {token}")
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                raw = response.read()
        except urllib.error.HTTPError as error:
            # The status only. Vercel's body is never read: its message or code
            # may echo the value, and a partial copy would get past redact().
            raise Refused(f"Vercel {method} {path.split('?')[0]} returned HTTP {error.code}") from None
        except urllib.error.URLError as error:
            raise Refused(f"Vercel {method} {path.split('?')[0]} failed: {type(error.reason).__name__}") from None
        return json.loads(raw) if raw else {}

    return request


def list_envs(request: Request, project_id: str) -> list[dict[str, Any]]:
    envs: dict[str, dict[str, Any]] = {}
    path = f"/v10/projects/{project_id}/env"
    for _ in range(50):
        page = request("GET", path, None)
        before = len(envs)
        for entry in page.get("envs", []):
            envs[entry["id"]] = entry
        nxt = (page.get("pagination") or {}).get("next")
        if not nxt or len(envs) == before:
            return list(envs.values())
        path = f"/v10/projects/{project_id}/env?until={urllib.parse.quote(str(nxt))}"
    raise Refused("Vercel env list did not finish paging")


def apply(request: Request, project_id: str, name: str, target: str, value: str | None, step: dict[str, Any]) -> None:
    op = step["op"]
    if op == "create":
        result = request("POST", f"/v10/projects/{project_id}/env", {"key": name, "value": value, "type": step["type"], "target": [target]})
        if result.get("failed"):
            raise Refused(f"Vercel refused to create {name} ({len(result['failed'])} failed)")
    elif op == "update":
        request("PATCH", f"/v9/projects/{project_id}/env/{step['id']}", {"value": value})
    elif op == "narrow":
        request("PATCH", f"/v9/projects/{project_id}/env/{step['id']}", {"target": step["target"]})
    elif op == "delete":
        request("DELETE", f"/v9/projects/{project_id}/env/{step['id']}", None)


def check_environment(doc: dict[str, Any], branch_policies: dict[str, Any] | None, name: str) -> None:
    """Refuse an environment unless it needs a reviewer and admits only main."""
    rules = doc.get("protection_rules") or []
    reviewers = [r for r in rules if r.get("type") == "required_reviewers" and r.get("reviewers")]
    if not reviewers:
        raise Refused(f"environment {name} has no required reviewers; an admin must add them before this workflow runs")
    policy = doc.get("deployment_branch_policy") or {}
    if policy.get("protected_branches") is not False or policy.get("custom_branch_policies") is not True:
        raise Refused(f"environment {name} must use selected branches with exactly main; an admin must set that")
    listed = [
        (p.get("name"), p.get("type", "branch"))
        for p in (branch_policies or {}).get("branch_policies") or []
    ]
    if listed != [("main", "branch")]:
        raise Refused(f"environment {name} admits {listed or 'no'} refs; it must admit exactly the branch main")


def github_get(token: str, path: str, name: str) -> dict[str, Any]:
    url = f"https://api.github.com{path}"
    req = urllib.request.Request(url)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        raise Refused(f"could not read environment {name}: HTTP {error.code}") from None
    except urllib.error.URLError as error:
        raise Refused(f"could not read environment {name}: {type(error.reason).__name__}") from None


def fetch_environment(token: str, repository: str, name: str) -> tuple[dict[str, Any], dict[str, Any] | None]:
    base = f"/repos/{repository}/environments/{urllib.parse.quote(name)}"
    doc = github_get(token, base, name)
    policy = doc.get("deployment_branch_policy") or {}
    if policy.get("custom_branch_policies") is not True:
        return doc, None
    return doc, github_get(token, f"{base}/deployment-branch-policies?per_page=100", name)


def summary(lines: list[str]) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(redact("\n".join(lines)) + "\n")


def run(args: argparse.Namespace, env: dict[str, str], request: Request | None = None) -> int:
    allow = load_allowlist(Path(args.allowlist))
    entry = allow["variables"].get(args.name)
    if entry is None:
        raise Refused(f"{args.name} is not in {ALLOWLIST.relative_to(ROOT)}")
    if args.target not in allow["targets"]:
        raise Refused(f"target {args.target} is not one of {', '.join(allow['targets'])}")
    token = env.get("VERCEL_TOKEN", "")
    register_secret(token)
    value = env.get("VERCEL_ENV_VALUE", "") if args.action == "set" else None
    register_secret(value)
    if not token:
        raise Refused(f"VERCEL_TOKEN is not set in the {allow['environment']} environment")
    if args.action == "set" and not value:
        # GitHub stores no empty secret, so empty means missing. A variable
        # whose empty value means something (CMUX_RUN_SANDBOX_USER_IDS: nobody)
        # gets that meaning from remove: unset reads as empty at runtime.
        raise Refused(f"secret {args.name} is missing in the {allow['environment']} environment (to clear a variable, run remove)")

    project = allow["project"]
    request = request or http_request(token, project["teamId"])
    secret = entry["secret"]
    step = plan(list_envs(request, project["id"]), args.name, args.target, args.action, secret)
    apply(request, project["id"], args.name, args.target, value, step)
    kind = verify(list_envs(request, project["id"]), args.name, args.target, args.action, secret, step)
    say(f"{args.name} {args.target}: {step['outcome']} (type {kind})")
    summary([
        "### Vercel env change",
        "",
        "| Project | Variable | Target | Action | Result | Type |",
        "| --- | --- | --- | --- | --- | --- |",
        f"| {project['teamSlug']}/{project['name']} | `{args.name}` | {args.target} | {args.action} | {step['outcome']} | {kind} |",
        "",
        "Vercel applies env changes to new deployments only: the next main deploy picks this up,"
        " or redeploy the current production deployment from the Vercel dashboard.",
    ])
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check-environment", action="store_true")
    parser.add_argument("--name")
    parser.add_argument("--target")
    parser.add_argument("--action", choices=["set", "remove"])
    parser.add_argument("--allowlist", default=str(ALLOWLIST))
    args = parser.parse_args(argv)
    if not args.check_environment and not (args.name and args.target and args.action):
        parser.error("--name, --target and --action are required")
    try:
        if args.check_environment:
            name = load_allowlist(Path(args.allowlist))["environment"]
            token = os.environ.get("GH_TOKEN", "")
            register_secret(token)
            doc, branch_policies = fetch_environment(token, os.environ["GITHUB_REPOSITORY"], name)
            check_environment(doc, branch_policies, name)
            say(f"environment {name} requires a reviewer and admits only main")
            return 0
        return run(args, dict(os.environ))
    except Refused as error:
        say(f"::error::{error}", error=True)
    except Exception as error:  # noqa: BLE001  (never a traceback: it could quote a request)
        say(f"::error::failed with {type(error).__name__}", error=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
