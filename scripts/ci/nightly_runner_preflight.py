#!/usr/bin/env python3
"""Fail a nightly in minutes when a runner label it is about to wait on has no online runner.

2026-11-10: someone set CI_NIGHTLY_MINI=cmux-lawrence-2-light, CI_NIGHTLY_MINI_BUILDER=cmux-lawrence-2 and
CI_NIGHTLY_SIGN_RUNNER=cmux-lawrence-2 at about 21:31Z. That host is not in the fleet registry; its runners went
offline at 00:45Z, and every nightly job then sat queued on a label no online runner carried, for over 3 h, while
the dedicated nightly Macs (cmux7s-mac-mini and cmux15, label glaeda-nightly-only-m4pro) stood idle. GitHub keeps a
queued job for up to 24 h and never says why, and the run holds its concurrency group the whole time.

This runs first, before `decide`, on a GitHub-hosted runner (never on the label it judges), and reads only
vars.CI_RUNNER_STATE: the runner census runner-heal publishes every two minutes (schema runner-state/v1; gzip,
base64 JSON). It fails the job, and so the run, when the census is fresh and a label the run's routing variables
name is carried by no runner, or only by offline ones (compared case-insensitively, as GitHub matches runs-on). It
never cancels anything. A census that is missing, incomplete or older than MAX_AGE_S (10 min) says nothing either way:
a warning, and the run goes on. On a failure, and only then, it makes its one kind of API call: with the job's
GITHUB_TOKEN (issues: write, no other secret) it opens or comments on the nightly's failure incident (notify()), the
issue its owner watches, since report-nightly-failure never runs for a run that stopped here.

Labels judged (the run's `runs-on` reads, nightly.yml):
- decide's label: vars.CI_NIGHTLY_MINI when set, else vars.CI_NIGHTLY_ONLY_RUNNER, else glaeda-nightly-only-m4pro;
- vars.CI_NIGHTLY_MINI_BUILDER, when CI_NIGHTLY_MINI is set (build-nightly-app's route then), except on the cache-seed
  schedule, which builds no app.
vars.CI_NIGHTLY_SIGN_RUNNER routes only the promote jobs, which run in a promote dispatch this job does not run in.
A GitHub-hosted (ubuntu-*, macos-N*, macos-latest*, windows-*) or Blacksmith label is not ours to count and is
skipped; a custom label that merely ends in -latest is judged.

HQ's hourly detector (cmuxterm-hq tools/fleet-reconcilers/now_runner_vars.py, docs/handbook/
runner-var-points-at-dead-host.md) pages the same drift between runs.
"""
from __future__ import annotations

import base64
import datetime as dt
import gzip
import io
import json
import os
import re
import sys

SCHEMA = "runner-state/v1"
REPOSITORY = "manaflow-ai/cmux"
# The census refreshes every 2 min; past 10 it says nothing about now. It was 30, which let a census that had stopped
# refreshing fail a run for a runner that had come back since (review of #40992; the pool readers allow 5).
MAX_AGE_S = 10 * 60
MAX_BYTES = 2 * 1024 * 1024
DEDICATED = "glaeda-nightly-only-m4pro"  # leo-workspace machines/fleet-registry.json nightly_dedicated
DEDICATED_HOSTS = "cmux7s-mac-mini and cmux15"
CACHE_SEED_CRON = "17 */6 * * *"  # nightly.yml: the scheduled cache seed, which builds no app
# GitHub's hosted families and Blacksmith only: a custom label that merely ends in -latest is ours to judge. Labels
# compare case-insensitively, as GitHub matches runs-on.
NOT_OURS = re.compile(r"^(?:ubuntu-|macos-\d|macos-latest|windows-|blacksmith-)", re.I)
ANNOTATION = re.compile(r"^::\w+ title=[^:]*::")


def parse_ts(value) -> dt.datetime | None:
    try:
        t = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)


def decode(raw: str | None) -> tuple[dict | None, str | None]:
    """(census, why unread): the runner-state/v1 document for manaflow-ai/cmux, else None and the reason."""
    if not raw:
        return None, "vars.CI_RUNNER_STATE is empty"
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(base64.b64decode(raw, validate=True))) as src:
            body = src.read(MAX_BYTES + 1)
        if len(body) > MAX_BYTES:
            return None, "vars.CI_RUNNER_STATE is too large"
        doc = json.loads(body)
    except Exception as err:  # noqa: BLE001 - binascii, zlib, OSError, ValueError: all mean unread
        return None, f"vars.CI_RUNNER_STATE does not decode ({type(err).__name__})"
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA or doc.get("repository") != REPOSITORY:
        return None, "vars.CI_RUNNER_STATE is not a runner-state/v1 census of manaflow-ai/cmux"
    if doc.get("complete") is not True:
        return None, "vars.CI_RUNNER_STATE is an incomplete census"
    if not parse_ts(doc.get("generated_at")) or not isinstance(doc.get("repository_runners"), list) \
            or not isinstance(doc.get("runner_groups"), dict):
        return None, "vars.CI_RUNNER_STATE lacks its time or runner lists"
    return doc, None


def runners(doc: dict) -> list[dict]:
    """Every runner of the census (the repository's and each runner group's): name, status, labels."""
    rows = list(doc.get("repository_runners") or [])
    for group in (doc.get("runner_groups") or {}).values():
        rows += group if isinstance(group, list) else []
    out = []
    for r in rows:
        if not isinstance(r, dict) or not isinstance(r.get("name"), str):
            continue
        labels = [l.get("name") if isinstance(l, dict) else l for l in r.get("labels") or []]
        out.append({"name": r["name"], "status": r.get("status"), "labels": [l for l in labels if isinstance(l, str)]})
    return out


def targets(env: dict) -> list[tuple[str, str]]:
    """[(variable, label)] this run's routing will wait on, from the workflow's env (see the module doc)."""
    mini = (env.get("CI_NIGHTLY_MINI") or "").strip()
    only = (env.get("CI_NIGHTLY_ONLY_RUNNER") or "").strip()
    out = [("CI_NIGHTLY_MINI", mini) if mini else ("CI_NIGHTLY_ONLY_RUNNER", only) if only
           else ("(default)", DEDICATED)]
    builder = (env.get("CI_NIGHTLY_MINI_BUILDER") or "").strip()
    # build-nightly-app never runs on the 6-hourly cache-seed schedule, so its builder is not waited on there.
    seed = env.get("GITHUB_EVENT_NAME") == "schedule" and env.get("NIGHTLY_SCHEDULE") == CACHE_SEED_CRON
    if mini and builder and not seed:
        out.append(("CI_NIGHTLY_MINI_BUILDER", builder))
    # CI_NIGHTLY_SIGN_RUNNER routes only the promote jobs, which run in a promote dispatch this preflight skips: not
    # judged here (the hourly HQ detector covers it).
    return out


def fix(variable: str, label: str) -> str:
    if variable.startswith("CI_NIGHTLY_MINI"):
        return (f"if {label} is not coming back, `gh variable delete {variable} -R {REPOSITORY}`: the nightly then "
                f"takes its default route (the dedicated nightly Macs, {DEDICATED} on {DEDICATED_HOSTS})")
    if variable == "CI_NIGHTLY_ONLY_RUNNER" and label != DEDICATED:
        return (f"`gh variable set {variable} -R {REPOSITORY} --body {DEDICATED}` (the dedicated nightly Macs on "
                f"{DEDICATED_HOSTS}), or bring {label}'s runners back")
    return f"bring the runners of {label} back online ({DEDICATED_HOSTS} for {DEDICATED})"


def judge(env: dict, now: dt.datetime) -> tuple[bool, list[str]]:
    """(ok, lines). ok is False only on proof: a fresh, complete census in which a judged label has no online runner.
    Lines are GitHub annotations (::error:: / ::warning:: / plain)."""
    checks = [(v, l) for v, l in targets(env) if not NOT_OURS.search(l)]
    if not checks:
        return True, ["every routing label of this run is GitHub-hosted or Blacksmith: nothing to judge"]
    doc, why = decode(env.get("CI_RUNNER_STATE"))
    if doc is None:
        return True, [f"::warning title=Nightly runner preflight::{why}; the run goes on unjudged"]
    at = parse_ts(doc["generated_at"])
    age = (now - at).total_seconds()
    if age > MAX_AGE_S or age < -120:
        return True, [f"::warning title=Nightly runner preflight::the runner census is {int(age // 60)} min old "
                      f"(generated {doc['generated_at']}); the run goes on unjudged"]
    rows = runners(doc)
    ok, lines = True, []
    for variable, label in checks:
        carrying = [r for r in rows if label.lower() in {name.lower() for name in r["labels"]}]
        online = [r for r in carrying if r["status"] == "online"]
        source = f"{variable}={label}" if variable != "(default)" else f"the default label {label}"
        if online:
            lines.append(f"{source}: {len(online)} of {len(carrying)} runners online")
            continue
        ok = False
        if carrying:
            names = ", ".join(sorted(r["name"] for r in carrying)[:6])
            state = f"all {len(carrying)} runners that carry it are offline ({names})"
        else:
            state = "no runner registered with manaflow-ai/cmux carries it"
        lines.append(f"::error title=Nightly runner preflight::{source}: {state} (census {doc['generated_at']}). "
                     f"Every job on it would sit queued for up to 24 h. Fix: {fix(variable, label)}.")
    return ok, lines


# --- the notice: a failed preflight opens or updates the nightly's failure incident ---------------------------------
# report-nightly-failure (nightly.yml) never runs for this failure: it is keyed on decide's should_publish, and it runs
# on the very label the preflight found dead. So the preflight files the incident itself, under the same label
# (`<release tag>-failure`) and title, which close-nightly-failure-issue closes at the next good publication.
CHANNELS = {"nightly-next": ("nightly-next", "cmux NIGHTLY")}  # ref -> (release tag, app name), as decide sets them
NOTICE_TIMEOUT_S = 20


def github(method: str, path: str, token: str, body: dict | None = None, *, http=None):
    """One GitHub REST call by one deadline (deadline_http): (status, parsed JSON or None)."""
    import urllib.request
    if http is None:
        import deadline_http
        http = deadline_http.request
    req = urllib.request.Request(f"https://api.github.com/repos/{REPOSITORY}/{path}", method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
                                          "Content-Type": "application/json", "User-Agent": "cmux-nightly-preflight"})
    status, raw, _ = http(req, NOTICE_TIMEOUT_S)
    try:
        return status, json.loads(raw) if raw else None
    except ValueError:
        return status, None


def notify(lines: list[str], env: dict, *, call=github) -> str:
    """Open or comment on the channel's failure issue with the preflight's error lines; what it did, for the log."""
    channel = CHANNELS.get(env.get("GITHUB_REF_NAME") or "")
    token = env.get("GITHUB_TOKEN") or ""
    if not channel or not token:
        return f"no failure issue: {'no token' if channel else 'not a nightly-next run'}"
    tag, app = channel
    label, ref = f"{tag}-failure", env["GITHUB_REF_NAME"]
    run_url = (f"{env.get('GITHUB_SERVER_URL') or 'https://github.com'}/{REPOSITORY}/actions/runs/"
               f"{env.get('GITHUB_RUN_ID') or '?'}")
    errors = [ANNOTATION.sub("", line) for line in lines if line.startswith("::error")]
    body = (f"{app} run {run_url} stopped in runner-preflight on {env.get('GITHUB_SHA') or '?'} ({ref}): a runner "
            "label it would wait on has no online runner, so it failed in minutes instead of queueing for hours.\n\n"
            + "".join(f"- {line}\n" for line in errors)
            + f"\nThe next successful publication closes this incident. Run: {run_url}")
    status, _ = call("GET", f"labels/{label}", token)
    if status == 404:
        call("POST", "labels", token, {"name": label, "color": "b60205", "description": f"{app} publish failing"})
    status, found = call("GET", f"issues?labels={label}&state=open&per_page=1", token)
    if status != 200 or not isinstance(found, list):
        raise RuntimeError(f"listing the {label} issues answered {status}")
    if found:
        number = found[0].get("number")
        status, _ = call("POST", f"issues/{number}/comments", token, {"body": body})
        what = f"commented on #{number}"
    else:
        status, made = call("POST", "issues", token, {"title": f"{app} build is failing on {ref}", "labels": [label],
                                                      "body": body})
        what = f"opened #{(made or {}).get('number')}"
    if status not in (200, 201):
        raise RuntimeError(f"the {label} issue write answered {status}")
    return f"{what} ({label})"


def main() -> int:
    env = dict(os.environ)
    ok, lines = judge(env, dt.datetime.now(dt.timezone.utc))
    print("\n".join(lines))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        plain = [ANNOTATION.sub("", line) for line in lines]
        with open(summary, "a", encoding="utf-8") as out:
            out.write("### Nightly runner preflight\n\n" + "".join(f"- {line}\n" for line in plain))
    if not ok:
        try:
            print(f"nightly runner preflight: {notify(lines, env)}")
        except Exception as err:  # noqa: BLE001 - the red run is the notice of last resort
            print(f"::warning title=Nightly runner preflight::the failure issue was not written ({type(err).__name__}: "
                  f"{str(err)[:160]}); this red run is the only notice")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
