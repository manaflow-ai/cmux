#!/usr/bin/env python3
"""Converge the owned minis' registered GitHub runner labels to what glaeda's manifest rules issue now.

GitHub fixes a self-hosted runner's labels at registration, and a mini holds no admin token, so a label
rule change in glaeda (glaeda_fleet_labels.py) reached a runner only when someone ran `fleet runner relabel
HOST --apply`. This reconciler runs on a schedule (runner-label-reconcile.yml) with the route App's
organization runner-label permission. For every organization runner carrying glaeda's `glaeda-mini` label it
adds the labels missing from glaeda_fleet_labels.widened_labels() of the current ones, through the labels API.
The rule lives only in glaeda (loaded from its checkout, GLAEDA_LABELS); nothing here restates it.

It only adds labels the rule issues (widened_labels never removes one), touches no runner whose labels
already match, and is idempotent: a second run changes nothing. A dry run (the default; --apply acts)
prints the same plan. Changing labels does not interrupt a running job.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence

API = "https://api.github.com"
MINI_LABEL = "glaeda-mini"


def load_rules(path: str) -> Any:
    spec = importlib.util.spec_from_file_location("glaeda_fleet_labels", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def custom_labels(runner: Mapping[str, Any]) -> list[str]:
    return [str(label.get("name")) for label in runner.get("labels") or []
            if isinstance(label, Mapping) and label.get("type") == "custom"]


def plan(runners: Iterable[Mapping[str, Any]], widen: Callable[[list[str]], list[str]]
         ) -> list[tuple[Mapping[str, Any], list[str], list[str]]]:
    """(runner, its custom labels, the labels to set) for each glaeda mini runner whose labels differ."""
    out = []
    for runner in runners:
        current = custom_labels(runner)
        if MINI_LABEL not in current:
            continue
        wanted = widen(current)
        if wanted != current and set(wanted) != set(current):
            out.append((runner, current, wanted))
    return out


class GitHub:
    def __init__(self, token: str, org: str):
        self.token, self.org = token, org

    def _call(self, method: str, path: str, body: Any = None) -> Any:
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(f"{API}{path}", data=data, method=method, headers={
            "Accept": "application/vnd.github+json", "Authorization": f"Bearer {self.token}",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "cmux-runner-label-reconcile"})
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)

    def runners(self) -> list[Mapping[str, Any]]:
        found: list[Mapping[str, Any]] = []
        page = 1
        while True:
            batch = self._call("GET", f"/orgs/{self.org}/actions/runners?per_page=100&page={page}").get("runners") or []
            found.extend(batch)
            if len(batch) < 100:
                return found
            page += 1

    def runner(self, runner_id: int) -> Mapping[str, Any]:
        return self._call("GET", f"/orgs/{self.org}/actions/runners/{int(runner_id)}")

    def add_labels(self, runner_id: int, labels: Sequence[str]) -> None:
        self._call("POST", f"/orgs/{self.org}/actions/runners/{int(runner_id)}/labels", {"labels": list(labels)})


def main(argv: Sequence[str] | None = None, env: Mapping[str, str] = os.environ, api: Any = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--org", default="manaflow-ai")
    args = parser.parse_args(argv)
    rules = load_rules(env["GLAEDA_LABELS"])
    widen = getattr(rules, "widened_labels", None)
    if widen is None:
        # A glaeda main that predates the rule: nothing to converge to, so change nothing.
        print("glaeda's label rules have no widened_labels(); nothing to reconcile")
        return 0
    api = api or GitHub(env["GITHUB_TOKEN_RUNNERS"], args.org)
    todo = plan(api.runners(), widen)
    failed = changed = 0
    for runner, current, wanted in todo:
        added = [label for label in wanted if label not in current]
        print(f"{runner.get('name')}: {'add' if args.apply else 'would add'} {' '.join(added)}")
        if not args.apply:
            continue
        try:
            # Re-read just before writing: a relabel may have re-registered it since the listing.
            fresh = custom_labels(api.runner(runner["id"]))
            if MINI_LABEL not in fresh:
                continue
            added = [label for label in widen(fresh) if label not in fresh]
            if not added:
                continue
            # Add only missing labels: a full replacement could undo a concurrent relabel.
            api.add_labels(runner["id"], added)
            changed += 1
        except urllib.error.HTTPError as error:
            if error.code == 404:
                # Removed or re-registered since the listing: the next run sees its new registration.
                print(f"{runner.get('name')}: gone since the listing; skipped")
                continue
            failed += 1
            print(f"::warning title=runner labels::{runner.get('name')}: {error}; retried next run")
        except (urllib.error.URLError, OSError, ValueError) as error:
            failed += 1
            print(f"::warning title=runner labels::{runner.get('name')}: {error}; retried next run")
    done = f"{changed} runner(s) relabelled" if args.apply else f"{len(todo)} runner(s) to relabel"
    print(f"{done}; the rest match glaeda's rules")
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        Path(summary).write_text(f"### Runner labels\n\n{done if args.apply else done + ' (dry run)'}.\n")
    # Red only when writes failed and none landed, so a broken token or permission shows; one flaky runner does not.
    return 1 if failed and not changed else 0

if __name__ == "__main__":
    sys.exit(main())
