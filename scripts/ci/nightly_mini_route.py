#!/usr/bin/env python3
"""Try the nightly app build on an owned Mac mini first, with hosted fallback.

Dispatches .github/workflows/nightly-mini-build.yml for one exact commit, waits
a bounded time for a mini to pick it up and a bounded time for it to finish,
and reports either the producer's artifact or the reason the hosted build must
run. Every outcome other than a clean success is a fallback, never an error:
nightly.yml then builds on Blacksmith exactly as it did before this route.

The bounded observation, cancellation handling and GitHub plumbing are shared
with the pull-request compile route in persistent_mac_route.py.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import signal
import subprocess
import sys
from pathlib import Path


_SHARED = Path(__file__).with_name("persistent_mac_route.py")
_spec = importlib.util.spec_from_file_location("persistent_mac_route", _SHARED)
shared = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(shared)

WORKFLOW = "nightly-mini-build.yml"
JOB_NAME = "Nightly mini app build"
SELECTORS = frozenset({"build-only", "all"})
# A cold universal Release build on an M4 Pro mini is the long case. A warm
# incremental one is minutes. Past these bounds Blacksmith is faster.
MAX_QUEUE_SECONDS = 1800
MAX_EXECUTION_SECONDS = 4 * 3600


def artifact_name(request_id: str) -> str:
    return f"nightly-mini-build-{request_id}"


def run_title(request_id: str) -> str:
    return f"nightly-mini-build-{request_id}"


def eligible(selector: str, build_only: bool, forced: bool) -> tuple[bool, str]:
    """Which nightly runs may try a mini.

    `build-only` admits the unsigned measurement runs only. `all` also admits
    runs whose products are signed and published, which is a trust decision
    (docs/ci/mac-fleet.md, "Nightly lane") and must stay a deliberate variable
    flip. A manual build-only dispatch may ask for a mini without the variable.
    """
    if build_only and (forced or selector in SELECTORS):
        return True, "eligible"
    if not build_only and selector == "all":
        return True, "eligible"
    return False, "not_selected"


class GitHub(shared.GitHub):
    def dispatch_nightly(self, ref: str, fields: dict[str, str]) -> None:
        argv = ["gh", "workflow", "run", WORKFLOW, "--repo", self.repository, "--ref", ref]
        for key, value in fields.items():
            argv.extend(["--field", f"{key}={value}"])
        result = subprocess.run(argv, text=True, capture_output=True, check=False)
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or f"workflow dispatch exited {result.returncode}")


def matching_run(api: GitHub, request_id: str, ref: str) -> dict[str, object] | None:
    payload = api.api(f"actions/workflows/{WORKFLOW}/runs?event=workflow_dispatch&per_page=50")
    runs = payload.get("workflow_runs", []) if isinstance(payload, dict) else []
    matches = [
        run for run in runs
        if isinstance(run, dict)
        and run.get("display_title") == run_title(request_id)
        and run.get("head_branch") == ref
    ]
    if not matches:
        return None
    return max(matches, key=lambda run: int(run.get("id", 0)))


def build_job(api: GitHub, run_id: int) -> dict[str, object] | None:
    matched = [job for job in shared.jobs(api, run_id) if job.get("name") == JOB_NAME]
    if len(matched) > 1:
        raise RuntimeError("producer run has multiple build jobs")
    return matched[0] if matched else None


def report(output: Path, **values: object) -> int:
    values = {
        "use_mini": "false",
        "fallback_reason": "",
        "producer_run_id": "",
        "artifact_id": "",
        "queue_to_start_seconds": "",
        "producer_seconds": "",
        **values,
    }
    shared.write_outputs(output, values)
    print(json.dumps(values, sort_keys=True))
    return 0


def route(args: argparse.Namespace, api: GitHub, waiter) -> int:
    """Dispatch, bound and collect one producer run. Returns the exit code."""
    out = args.github_output
    request_id = f"{args.run_id}-{args.run_attempt}"
    run_id: int | None = None
    dispatched = False
    try:
        started = shared.now()
        api.dispatch_nightly(
            args.ref,
            {"request_id": request_id, "source_sha": args.source_sha, "icon_name": args.icon_name},
        )
        dispatched = True

        def observe_run():
            run = matching_run(api, request_id, args.ref)
            return run is not None, run

        run = waiter.until(started + 60, observe_run)
        if run is None:
            return report(out, fallback_reason="producer_not_observable")
        run_id = int(run["id"])

        def observe_queue():
            job = build_job(api, run_id)
            if job and (job.get("started_at") or job.get("status") in shared.TERMINAL):
                return True, job
            return False, None

        job = waiter.until(shared.now() + args.queue_seconds, observe_queue, initial_delay=2.0, max_delay=15.0)
        if not job or not job.get("started_at"):
            if not job:
                shared.cancel(api, run_id)
                return report(out, fallback_reason="queue_timeout", producer_run_id=run_id)
            return report(out, fallback_reason=f"producer_{job.get('conclusion') or 'failed'}", producer_run_id=run_id)
        created = shared.parse_time(str(job.get("created_at") or ""))
        began = shared.parse_time(str(job.get("started_at") or ""))
        queued = round(max(0.0, (began - created).total_seconds()), 3) if created and began else ""

        def observe_execution():
            current = build_job(api, run_id)
            done = bool(current) and current.get("status") in shared.TERMINAL
            return done, current if done else None

        # The GITHUB_TOKEN budget is shared by the whole repository; a
        # 45-minute build does not need a poll every few seconds.
        done = waiter.until(shared.now() + args.execution_seconds, observe_execution, initial_delay=15.0, max_delay=60.0)
        if done is None:
            shared.cancel(api, run_id)
            return report(out, fallback_reason="execution_budget_exceeded", producer_run_id=run_id, queue_to_start_seconds=queued)
        if done.get("conclusion") != "success":
            return report(out, fallback_reason=f"producer_{done.get('conclusion') or 'failed'}", producer_run_id=run_id, queue_to_start_seconds=queued)
        finished = shared.parse_time(str(done.get("completed_at") or ""))
        seconds = round(max(0.0, (finished - began).total_seconds()), 3) if finished and began else ""

        listing = api.api(f"actions/runs/{run_id}/artifacts?per_page=100")
        artifacts = [
            item for item in (listing.get("artifacts", []) if isinstance(listing, dict) else [])
            if isinstance(item, dict) and item.get("name") == artifact_name(request_id) and item.get("expired") is False
        ]
        if len(artifacts) != 1:
            return report(out, fallback_reason="producer_artifact_missing", producer_run_id=run_id, queue_to_start_seconds=queued, producer_seconds=seconds)
        return report(
            out,
            use_mini="true",
            producer_run_id=run_id,
            artifact_id=int(artifacts[0]["id"]),
            queue_to_start_seconds=queued,
            producer_seconds=seconds,
        )
    except shared.RetryCancelled:
        # The nightly run was cancelled mid-wait: do not leave a mini building
        # for nobody.
        if run_id is None and dispatched:
            found = matching_run(api, request_id, args.ref)
            run_id = int(found["id"]) if found else None
        if run_id is not None:
            shared.cancel(api, run_id)
        report(out, fallback_reason="routing_cancelled", producer_run_id=run_id or "")
        return 128 + (waiter.cancel_signal or signal.SIGTERM)
    except (RuntimeError, KeyError, TypeError, ValueError, subprocess.SubprocessError) as error:
        print(f"nightly mini route fell back to hosted: {error}", file=sys.stderr)
        if run_id is not None:
            shared.cancel(api, run_id)
        return report(out, fallback_reason="routing_error", producer_run_id=run_id or "")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selector", default="")
    parser.add_argument("--build-only", choices=("true", "false"), required=True)
    parser.add_argument("--forced", choices=("true", "false"), default="false")
    parser.add_argument("--repository", required=True)
    parser.add_argument("--ref", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--icon-name", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--run-attempt", required=True)
    parser.add_argument("--queue-seconds", type=int, default=300)
    parser.add_argument("--execution-seconds", type=int, default=2700)
    parser.add_argument("--github-output", type=Path, required=True)
    args = parser.parse_args(argv)

    ok, reason = eligible(args.selector.strip(), args.build_only == "true", args.forced == "true")
    if not ok:
        return report(args.github_output, fallback_reason=reason)
    if not re.fullmatch(r"[a-f0-9]{40}", args.source_sha) or not re.fullmatch(r"[A-Za-z0-9_-]+", args.icon_name):
        return report(args.github_output, fallback_reason="invalid_request")
    if not (0 < args.queue_seconds <= MAX_QUEUE_SECONDS and 0 < args.execution_seconds <= MAX_EXECUTION_SECONDS):
        return report(args.github_output, fallback_reason="invalid_budget")

    waiter = shared.RetryWait()
    shared.install_cancel_handlers(waiter)
    return route(args, GitHub(args.repository), waiter)


if __name__ == "__main__":
    raise SystemExit(main())
