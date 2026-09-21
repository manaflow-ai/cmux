#!/usr/bin/env python3
"""Summarize compiled-product transport evidence from one GitHub Actions CI run."""
from __future__ import annotations

import argparse
from datetime import datetime
import json
from pathlib import Path
import re
import subprocess

REPOSITORY = "manaflow-ai/cmux"
PRODUCER = "macOS compile admission"
CONSUMERS = {"tests-build-and-lag", *(f"app-host unit tests ({index}/6)" for index in range(1, 7))}
MARKERS = ("CMUX_TEST_PRODUCT_TRANSFER ", "CMUX_R2_ARTIFACT_ATTEMPT ", "CMUX_TEST_PRODUCT_RESTORE ")


def gh_json(path: str) -> dict:
    raw = subprocess.check_output(["gh", "api", f"repos/{REPOSITORY}/{path}"], text=True, timeout=30)
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("unexpected GitHub API response")
    return value


def jobs_for_run(run_id: int) -> list[dict]:
    jobs: list[dict] = []
    for page in range(1, 5):
        response = gh_json(f"actions/runs/{run_id}/jobs?per_page=100&page={page}")
        batch = response.get("jobs")
        if not isinstance(batch, list):
            raise ValueError("run jobs unavailable")
        jobs.extend(item for item in batch if isinstance(item, dict))
        if len(batch) < 100:
            break
    return jobs


def log_for_job(run_id: int, job_id: int) -> str:
    return subprocess.check_output(
        ["gh", "run", "view", str(run_id), "--repo", REPOSITORY, "--job", str(job_id), "--log"],
        text=True, errors="replace", timeout=120,
    )


def marker_records(log: str) -> list[dict]:
    records = []
    for line in log.splitlines():
        for marker in MARKERS:
            index = line.find(marker)
            if index < 0:
                continue
            try:
                value = json.loads(line[index + len(marker):].strip())
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                value["_marker"] = marker.strip()
                records.append(value)
            break
    return records


def timestamp(value: object) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def elapsed_seconds(start: object, end: object) -> float | None:
    left, right = timestamp(start), timestamp(end)
    if left is None or right is None or right < left:
        return None
    return round((right - left).total_seconds(), 3)


def summarize(run: dict, jobs: list[dict], records_by_job: dict[int, list[dict]]) -> dict:
    producer = next((job for job in jobs if job.get("name") == PRODUCER), None)
    consumers = [job for job in jobs if job.get("name") in CONSUMERS]
    consumers.sort(key=lambda job: str(job.get("name")))

    producer_ready = None
    if producer:
        for step in producer.get("steps", []):
            if isinstance(step, dict) and step.get("name") == "Upload compiled app-host test product":
                producer_ready = step.get("completed_at")
                break

    last_completed = max(
        (timestamp(job.get("completed_at")) for job in consumers if timestamp(job.get("completed_at")) is not None),
        default=None,
    )
    producer_started = timestamp(producer.get("started_at")) if producer else None
    ready = timestamp(producer_ready)

    selected_jobs = ([producer] if producer else []) + consumers
    selected_seconds = [elapsed_seconds(job.get("started_at"), job.get("completed_at")) for job in selected_jobs]
    consumer_seconds = [elapsed_seconds(job.get("started_at"), job.get("completed_at")) for job in consumers]
    selected_seconds = [value for value in selected_seconds if value is not None]
    consumer_seconds = [value for value in consumer_seconds if value is not None]

    consumer_records = []
    transports = {"r2": 0, "github": 0, "unknown": 0}
    cache_results: dict[str, int] = {}
    fallback_reasons: dict[str, int] = {}
    artifact_ids = set()
    observed_bytes = 0

    for job in consumers:
        job_id = int(job["id"])
        records = records_by_job.get(job_id, [])
        transfers = [record for record in records if record.get("_marker") == "CMUX_TEST_PRODUCT_TRANSFER"]
        attempts = [record for record in records if record.get("_marker") == "CMUX_R2_ARTIFACT_ATTEMPT"]
        restores = [record for record in records if record.get("_marker") == "CMUX_TEST_PRODUCT_RESTORE"]
        transfer = transfers[-1] if transfers else None
        attempt = attempts[-1] if attempts else None
        restore = restores[-1] if restores else None

        route = str((transfer or {}).get("transport") or (restore or {}).get("route") or "unknown")
        if route not in transports:
            route = "unknown"
        transports[route] += 1
        cache = (transfer or {}).get("cache")
        if isinstance(cache, str) and cache:
            cache_results[cache] = cache_results.get(cache, 0) + 1
        reason = (attempt or {}).get("fallback_reason")
        if isinstance(reason, str) and reason:
            fallback_reasons[reason] = fallback_reasons.get(reason, 0) + 1

        artifact_id = (transfer or attempt or {}).get("artifact_id")
        if artifact_id not in (None, ""):
            artifact_ids.add(str(artifact_id))
        bytes_value = (transfer or {}).get("downloaded_bytes")
        if bytes_value is None:
            bytes_value = (transfer or {}).get("archive_bytes")
        if isinstance(bytes_value, int) and bytes_value >= 0:
            observed_bytes += bytes_value

        consumer_records.append({
            "job": job.get("name"),
            "job_id": job_id,
            "conclusion": job.get("conclusion"),
            "runner_seconds": elapsed_seconds(job.get("started_at"), job.get("completed_at")),
            "transfer": transfer,
            "r2_attempt": attempt,
            "restore": restore,
        })

    artifact_size = None
    if len(artifact_ids) == 1:
        try:
            artifact = gh_json(f"actions/artifacts/{next(iter(artifact_ids))}")
            value = artifact.get("size_in_bytes")
            if isinstance(value, int) and value >= 0:
                artifact_size = value
        except (ValueError, subprocess.SubprocessError, json.JSONDecodeError):
            pass

    return {
        "repository": REPOSITORY,
        "run_id": run.get("id"),
        "run_url": run.get("html_url"),
        "event": run.get("event"),
        "status": run.get("status"),
        "conclusion": run.get("conclusion"),
        "consumer_count": len(consumers),
        "expected_consumer_count": len(CONSUMERS),
        "complete_consumer_set": {job.get("name") for job in consumers} == CONSUMERS,
        "producer_to_last_consumer_seconds": (
            round((last_completed - producer_started).total_seconds(), 3)
            if last_completed is not None and producer_started is not None else None
        ),
        "artifact_ready_to_last_consumer_seconds": (
            round((last_completed - ready).total_seconds(), 3)
            if last_completed is not None and ready is not None and last_completed >= ready else None
        ),
        "aggregate_producer_and_consumer_runner_minutes": (
            round(sum(selected_seconds) / 60, 3) if selected_seconds else None
        ),
        "aggregate_consumer_runner_minutes": (
            round(sum(consumer_seconds) / 60, 3) if consumer_seconds else None
        ),
        "transport_counts": transports,
        "cache_results": cache_results,
        "fallback_reasons": fallback_reasons,
        "artifact_id": next(iter(artifact_ids)) if len(artifact_ids) == 1 else None,
        "provider_artifact_bytes": artifact_size,
        "observed_consumer_payload_bytes": observed_bytes,
        "consumers": consumer_records,
    }


def collect(run_id: int) -> dict:
    run = gh_json(f"actions/runs/{run_id}")
    jobs = jobs_for_run(run_id)
    records = {}
    for job in jobs:
        if job.get("name") not in CONSUMERS or not isinstance(job.get("id"), int):
            continue
        try:
            records[job["id"]] = marker_records(log_for_job(run_id, job["id"]))
        except subprocess.SubprocessError:
            records[job["id"]] = []
    return summarize(run, jobs, records)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_id", type=int)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    record = collect(args.run_id)
    rendered = json.dumps(record, indent=2, sort_keys=True)
    print(rendered)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered + "\n")


if __name__ == "__main__":
    main()
