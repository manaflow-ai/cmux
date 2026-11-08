#!/usr/bin/env python3
"""nightly.yml: the published build that the post-publication jobs describe.

nightly-next is one loop (Leo, 2026-11-06): one run at a time builds, signs, publishes and writes the
GitHub release, whose body and tag the next run's decide reads, and the push group's newest head runs
next. Then the loop run's dispatch-published-in uploads this record and dispatches nightly.yml
(nightly_next_post_publish), whose published-build checks it and hands it to the deltas, notes, reel and
PR comments, outside the push group. Main's nightly, RC and manual nightly-next runs run the whole tail
in their own run, from the same record of that run's own jobs.

    nightly_published_build.py pack
        NEEDS (toJSON(needs)), RUN_ID, RUN_ATTEMPT, SHA: writes the record to RECORD_FILE, for this run's
        nightly-published-build-<attempt> artifact, and prints the dispatch input: this run's id and attempt.
    nightly_published_build.py source
        SOURCE (the dispatch input): writes the run and attempt to check to GITHUB_OUTPUT (none for an input
        from an older push run).
    nightly_published_build.py check-source
        SOURCE, GITHUB_REPOSITORY, SOURCE_RUN_FILE (that run attempt from the API): exits 1 unless it is a
        push or manual run of this repository's nightly.yml on nightly-next.
    nightly_published_build.py outputs
        SOURCE and RECORD_FILE (the checked run's artifact), or with no SOURCE: NEEDS, RUN_ID, RUN_ATTEMPT,
        SHA: writes the record to GITHUB_OUTPUT.

Anyone who may dispatch the workflow writes the input, and the tail checks out the record's build commit
with the Sparkle key and release credentials. So the input names only the run, the API confirms what that
run is, and the record comes from that run's own artifact, which only its jobs can write. An input from a
push run older than this (no "tail") carries unchecked fields, so it runs nothing.
"""
from __future__ import annotations

import json
import os
import re
import secrets
import sys

# job -> (output prefix, outputs the post-publication jobs read)
FIELDS = {
    "decide": ("", ("track", "release_name", "release_tag", "channel", "dmg_prefix", "feeds",
                    "fast_build", "should_publish", "variants", "feed_base", "no_publish", "published_sha",
                    "head_sha", "app_name", "notary_test")),
    "publish-nightly": ("publish_", ("already_published", "behind", "behind_hours", "build", "build_sha",
                                     "downloads", "refused", "source", "source_archive", "tag_status",
                                     "tested_pattern", "tip_sha", "variant_pattern")),
    "build-nightly-app": ("", ("daemon_build", "daemon_version")),
    "resolve-nightly-cmux-tui-client": ("resolve_", ("build_sha",)),
}
# push_clean: no job this one needs failed or was cancelled. In the dispatched run, close-nightly-failure-issue
# cannot see the run that published, whose own failed build (a recovered build published after it) reports.
RUN_FIELDS = ("source_run", "source_attempt", "source_sha", "publish_result", "push_clean")
NAMES = RUN_FIELDS + tuple(prefix + name for prefix, names in FIELDS.values() for name in names)
SHA = re.compile(r"[0-9a-f]{40}")


def record(needs: dict, run_id: str, attempt: str, sha: str) -> dict[str, str]:
    out = {"source_run": run_id, "source_attempt": attempt, "source_sha": sha,
           "publish_result": str((needs.get("publish-nightly") or {}).get("result") or ""),
           "push_clean": "false" if any((job or {}).get("result") in ("failure", "cancelled")
                                        for job in needs.values()) else "true"}
    for job, (prefix, names) in FIELDS.items():
        outputs = (needs.get(job) or {}).get("outputs") or {}
        for name in names:
            out[prefix + name] = str(outputs.get(name) or "")
    return out


def comments(rec: dict[str, str]) -> bool:
    """published-in's old dispatch condition: a new build of this run, not a recovered or already published one."""
    return (rec["track"] == "nightly-next" and rec["should_publish"] == "true" and rec["no_publish"] != "true"
            and rec["published_sha"] != "" and rec["publish_result"] == "success"
            and rec["publish_already_published"] != "true" and rec["publish_refused"] != "true"
            and rec["publish_source"] != "recovered")


def valid(rec: dict) -> bool:
    return (isinstance(rec, dict) and set(rec) == set(NAMES) and all(isinstance(v, str) for v in rec.values())
            and rec["source_run"].isdigit() and rec["source_attempt"].isdigit() and bool(SHA.fullmatch(rec["source_sha"])))


def from_env() -> dict[str, str]:
    return record(json.loads(os.environ.get("NEEDS") or "{}"), os.environ["RUN_ID"], os.environ["RUN_ATTEMPT"],
                  os.environ["SHA"])


def pack() -> int:
    rec = from_env()
    with open(os.environ["RECORD_FILE"], "w", encoding="utf-8") as handle:
        json.dump(rec, handle, sort_keys=True)
    print(json.dumps({"source_run": rec["source_run"], "source_attempt": rec["source_attempt"], "tail": "artifact"},
                     separators=(",", ":"), sort_keys=True))
    return 0


def source_ref() -> tuple[str, str] | None:
    """The run and attempt the input names, None for an older push run's input; ValueError if malformed."""
    source = json.loads(os.environ.get("SOURCE") or "{}")
    if not isinstance(source, dict) or "tail" not in source:
        return None
    run, attempt = source.get("source_run"), source.get("source_attempt")
    if source["tail"] != "artifact" or not isinstance(run, str) or not isinstance(attempt, str) \
            or not run.isdigit() or not attempt.isdigit():
        raise ValueError("the dispatch input must name its source run and attempt, and carry no record")
    return run, attempt


def write_source() -> int:
    if not os.environ.get("SOURCE"):
        return 0  # the run that published: no other run to check
    try:
        ref = source_ref()
    except ValueError as error:
        print(f"published-build: {error}", file=sys.stderr)
        return 1
    if ref is None:
        print("::warning::published-build: this input comes from a push run older than the checked record; "
              "its fields are unchecked, so nothing runs")
        return 0
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
        handle.write(f"run={ref[0]}\nattempt={ref[1]}\n")
    return 0


def check_source() -> int:
    ref = source_ref()
    with open(os.environ["SOURCE_RUN_FILE"], encoding="utf-8") as handle:
        run = json.load(handle)
    repo = os.environ["GITHUB_REPOSITORY"].lower()
    checks = {
        "the run named": ref is not None and str(run.get("id")) == ref[0] and str(run.get("run_attempt")) == ref[1],
        # Manual builds, unsigned resumes, continuations and republishes publish from a dispatched run.
        "a push or manual run": run.get("event") in ("push", "workflow_dispatch"),
        "on nightly-next": run.get("head_branch") == "nightly-next",
        "of nightly.yml": run.get("path") == ".github/workflows/nightly.yml",
        "in this repository": str((run.get("repository") or {}).get("full_name", "")).lower() == repo
        and str((run.get("head_repository") or {}).get("full_name", "")).lower() == repo,
    }
    failed = [name for name, ok in checks.items() if not ok]
    if failed:
        print(f"published-build: the source run is not {', '.join(failed)}", file=sys.stderr)
        return 1
    print(f"published-build: run {ref[0]} attempt {ref[1]} is a nightly.yml {run.get('event')} run on nightly-next")
    return 0


def write_outputs() -> int:
    try:
        ref = source_ref() if os.environ.get("SOURCE") else None
    except ValueError as error:
        print(f"published-build: {error}", file=sys.stderr)
        return 1
    if os.environ.get("SOURCE") and ref is None:
        rec, cross_run, comment = {}, "", False
    elif ref is not None:
        with open(os.environ["RECORD_FILE"], encoding="utf-8") as handle:
            rec = json.load(handle)
        if not valid(rec) or rec["track"] != "nightly-next" or (rec["source_run"], rec["source_attempt"]) != ref:
            # Only nightly-next dispatches this run; its environment is release-next (decide's, by ref).
            print("published-build: the record is malformed, not nightly-next or not the checked run's",
                  file=sys.stderr)
            return 1
        cross_run, comment = "true", comments(rec)
    else:
        rec, cross_run = from_env(), ""
        comment = comments(rec)  # nightly-next comments its PRs from the run that published
    values = {name: rec.get(name, "") for name in NAMES}
    values.update(cross_run=cross_run, comment="true" if comment else "false")
    # publish-nightly's downloads is a Markdown list: a value with a newline goes in a delimited block.
    delimiter = f"EOF_{secrets.token_hex(16)}"
    lines = [f"{name}<<{delimiter}\n{value}\n{delimiter}" if "\n" in value or "\r" in value else f"{name}={value}"
             for name, value in values.items()]
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
        handle.write("".join(line + "\n" for line in lines))
    print("\n".join(lines))
    return 0


MODES = {"pack": pack, "source": write_source, "check-source": check_source, "outputs": write_outputs}

if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) == 2 else ""
    if mode in MODES:
        sys.exit(MODES[mode]())
    print(__doc__, file=sys.stderr)
    sys.exit(2)
