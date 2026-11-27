#!/usr/bin/env python3
"""Resolve shipped phone/Mac sources, not merely green compilation runs.

Publication jobs append a receipt with 'record'; CI reads a trusted registry with
'resolve'. N counts releases before source deduplication: repeated releases retain
their IDs but build the source only once. 'host' means a shipped Mac source paired
with the PR phone; 'dial' means a shipped phone source paired with the PR Mac.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from email.utils import parsedate_to_datetime
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

DEFAULT_REGISTRY = Path(__file__).with_name("mobile_pair_shipped_window.json")
SHA = re.compile(r"[0-9a-f]{40}")
EVIDENCE = {"ios": "testflight-processed", "mac": "nightly-feed-published"}


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError("published_at must be an ISO 8601 timestamp")
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("published_at must include a timezone")
    return result.astimezone(timezone.utc)


def validate_entry(entry):
    if not isinstance(entry, dict) or entry.get("platform") not in EVIDENCE:
        raise ValueError("publication needs platform ios or mac")
    if not isinstance(entry.get("sha"), str) or not SHA.fullmatch(entry["sha"]):
        raise ValueError("publication needs a full source SHA")
    if not isinstance(entry.get("release_id"), str) or not entry["release_id"].strip():
        raise ValueError("publication needs a release ID")
    timestamp(entry.get("published_at"))
    proof = entry.get("evidence", {})
    if not isinstance(proof, dict) or proof.get("kind") != EVIDENCE[entry["platform"]]:
        raise ValueError("compilation/upload-only is not publication evidence")
    url = proof.get("url", "")
    if not isinstance(url, str) or not url.startswith("https://"):
        raise ValueError("publication evidence needs an HTTPS receipt URL")
    return entry


def validate_registry(registry):
    if not isinstance(registry, dict) or registry.get("schema_version") != 1:
        raise ValueError("unsupported shipped-window registry schema")
    releases = registry.get("releases")
    if not isinstance(releases, list):
        raise ValueError("registry needs a releases list")
    seen = set()
    for entry in releases:
        validate_entry(entry)
        key = (entry["platform"], entry["release_id"])
        if key in seen:
            raise ValueError("duplicate platform/release ID in registry")
        seen.add(key)
    return registry


def record(registry, entry):
    """Idempotent publication hook; an existing release can never change source."""
    validate_registry(registry)
    validate_entry(entry)
    key = (entry["platform"], entry["release_id"])
    for previous in registry["releases"]:
        if (previous["platform"], previous["release_id"]) == key:
            if previous["sha"] != entry["sha"]:
                raise ValueError("published release ID cannot change source SHA")
            return registry
    return {**registry, "releases": registry["releases"] + [entry]}


def resolve(registry, count=3):
    validate_registry(registry)
    if count < 1:
        raise ValueError("count must be positive")
    rows = []
    selected = []
    for platform, role in (("ios", "dial"), ("mac", "host")):
        releases = sorted(
            (r for r in registry["releases"] if r["platform"] == platform),
            key=lambda r: (timestamp(r["published_at"]), r["release_id"]),
            reverse=True,
        )[:count]
        if len(releases) != count:
            raise ValueError(f"{platform}: need {count} published releases, found {len(releases)}")
        selected.extend(releases)
        by_sha = {}
        for release in releases:
            row = by_sha.setdefault(release["sha"], {
                "role": role, "sha": release["sha"], "release_ids": [],
            })
            row["release_ids"].append(release["release_id"])
        rows.extend(by_sha.values())
    identity = {"count": count, "include": rows}
    fingerprint = hashlib.sha256(
        json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    return {"include": rows, "fingerprint": fingerprint, "releases": selected}



APPCAST = "https://files-next.cmux.com/nightly-next/appcast-arm64.xml"
REPO = "manaflow-ai/cmux"
CMUX_NS = "{https://cmux.com/xml-namespaces/cmux}"
SPARKLE_NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
IOS_TITLE = re.compile(r"cmux-next-ios INTERNAL ([0-9a-f]{40})(?: \(submittable\))?$")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class PublicationReader:
    """One bounded snapshot, no retries/polling; never send GitHub auth to logs."""
    def __init__(self, token=None):
        self.token = token

    def read(self, url, authenticated=False):
        if not url.startswith("https://"):
            raise ValueError("publication receipt URL must use HTTPS")
        headers = {"User-Agent": "phone-compatibility-window/1"}
        if authenticated:
            if not url.startswith("https://api.github.com/"):
                raise ValueError("GitHub token may only go to api.github.com")
            if self.token:
                headers["Authorization"] = f"Bearer {self.token}"
            headers["Accept"] = "application/vnd.github+json"
        request = urllib.request.Request(url, headers=headers)
        opener = urllib.request.build_opener(NoRedirect)
        try:
            with opener.open(request, timeout=30) as response:
                data = response.read(10_000_001)
        except urllib.error.HTTPError as error:
            if error.code == 302 and authenticated and url.endswith("/logs"):
                # Signed log URLs are fetched without the GitHub bearer token.
                return self.read(error.headers["Location"])
            raise
        if len(data) > 10_000_000:
            raise ValueError("publication response exceeds 10 MB bound")
        return data.decode("utf-8")

    def api(self, path, **query):
        url = f"https://api.github.com/repos/{REPO}/{path}"
        if query:
            url += "?" + urllib.parse.urlencode(query)
        return json.loads(self.read(url, authenticated=True))

    def log(self, job_id):
        return self.read(f"https://api.github.com/repos/{REPO}/actions/jobs/{job_id}/logs",
                         authenticated=True)


def receipt(platform, sha, release_id, published_at, url):
    return validate_entry({
        "platform": platform, "sha": sha, "release_id": release_id,
        "published_at": published_at,
        "evidence": {"kind": EVIDENCE[platform], "url": url},
    })


def appcast_receipts(text):
    items = ET.fromstring(text).findall("./channel/item")
    if not items:
        raise ValueError("NIGHTLY appcast has no published items")
    releases, previous = [], {}
    for item in items:
        sha = (item.findtext(CMUX_NS + "sourceCommit") or "").strip()
        release_id = (item.findtext(SPARKLE_NS + "version") or "").strip()
        enclosure = item.find("enclosure")
        url = enclosure.get("url", "") if enclosure is not None else ""
        date = parsedate_to_datetime(item.findtext("pubDate") or "").isoformat()
        releases.append(receipt("mac", sha, release_id, date, url))
        previous[release_id] = (item.findtext(CMUX_NS + "sinceCommit") or "").strip()
    return releases, previous


def ios_receipt(run, job, log):
    title = IOS_TITLE.fullmatch(run.get("display_title", ""))
    builds = re.findall(r"==> wait for App Store Connect to process ([0-9]+)", log)
    processed = re.findall(r"- Uploaded to cmux INTERNAL at ([0-9TZ:.-]+); processed\.", log)
    if not title or len(set(builds)) != 1 or not processed:
        raise ValueError(f"iOS run {run['id']}: no processed TestFlight build receipt")
    result = receipt("ios", title[1], builds[0], processed[-1],
                     f"https://github.com/{REPO}/actions/runs/{run['id']}/job/{job['id']}")
    if run.get("run_attempt"):
        result["evidence"]["run_attempt"] = run["run_attempt"]
    return result


def mac_receipt(run, job, log, expected_sha):
    sources = re.findall(r"(?m)^.*?Z source_sha=([0-9a-f]{40})\s*$", log)
    builds = re.findall(r"the live feed's newest build is ([0-9]+), the build this run published", log)
    published = re.search(
        r"(?m)^([0-9TZ:.-]+) the live feed's newest build is ([0-9]+), the build this run published",
        log,
    )
    if not sources or sources[-1] != expected_sha or not builds or not published:
        raise ValueError(f"Mac run {run['id']}: no matching live-feed publication receipt")
    return receipt("mac", expected_sha, builds[-1], published[1],
                   f"https://github.com/{REPO}/actions/runs/{run['id']}/job/{job['id']}")


def successful_step(job, name):
    return job.get("conclusion") == "success" and any(
        step.get("name") == name and step.get("conclusion") == "success"
        for step in job.get("steps", [])
    )


def refresh(registry, reader, count=3):
    """Refresh releases; existing receipts save log/API reads, never mask failures.

    The appcast's oldest sinceCommit identifies its predecessor, which still
    needs a publication receipt. At most 20 iOS runs and 20 historical Mac runs
    are inspected. Exhaustion, unavailable logs and rate limits fail closed.
    """
    validate_registry(registry)
    if not 1 <= count <= 3:
        raise ValueError("live refresh supports a window of 1 to 3 releases")
    mac, previous = appcast_receipts(reader.read(APPCAST))
    mac.sort(key=lambda r: timestamp(r["published_at"]), reverse=True)
    mac = mac[:count]
    if len(mac) < count:
        oldest = mac[-1]
        predecessor = previous[oldest["release_id"]]
        if not SHA.fullmatch(predecessor):
            raise ValueError("NIGHTLY feed does not identify the preceding source")
        history = sorted(
            (r for r in registry["releases"]
             if r["platform"] == "mac"
             and timestamp(r["published_at"]) < timestamp(oldest["published_at"])),
            key=lambda r: timestamp(r["published_at"]), reverse=True,
        )
        # A persisted window is a contiguous publication snapshot. It may fill
        # a short feed only when its newest older source is the feed's named
        # predecessor; unrelated/stale history must never fill the gap.
        if history and history[0]["sha"] == predecessor:
            mac.extend(history[:count - len(mac)])
        if len(mac) < count:
            # A one-item appcast needs two predecessors. Read one bounded run
            # snapshot and use actual publication receipts, not run conclusions.
            # Older runs may finish publishing out of order, so collect the
            # bounded snapshot before sorting by publication time.
            runs = reader.api(
                "actions/workflows/nightly.yml/runs", branch="nightly-next",
                status="completed", per_page=20,
                created="<=" + timestamp(oldest["published_at"]).isoformat(),
            )["workflow_runs"]
            candidates = {r["release_id"]: r for r in mac
                          if timestamp(r["published_at"]) < timestamp(oldest["published_at"])}
            for run in runs[:20]:
                jobs = reader.api(f"actions/runs/{run['id']}/jobs", per_page=100)["jobs"]
                job = next((j for j in jobs if j["name"] == "published-build" and
                            successful_step(j, "Read the published build back from the live feed")), None)
                if not job:
                    continue
                log = reader.log(job["id"])
                sources = re.findall(r"(?m)^.*?Z source_sha=([0-9a-f]{40})\s*$", log)
                if not sources:
                    raise ValueError(f"Mac run {run['id']}: no published source receipt")
                candidate = mac_receipt(run, job, log, sources[-1])
                if timestamp(candidate["published_at"]) >= timestamp(oldest["published_at"]):
                    continue
                prior = candidates.get(candidate["release_id"])
                if prior and prior["sha"] != candidate["sha"]:
                    raise ValueError("historical release ID has conflicting source receipts")
                candidates[candidate["release_id"]] = candidate
            history = sorted(candidates.values(),
                             key=lambda r: timestamp(r["published_at"]), reverse=True)
            if not history or history[0]["sha"] != predecessor:
                raise ValueError("NIGHTLY history does not confirm the feed's preceding source")
            mac = [r for r in mac if timestamp(r["published_at"]) >= timestamp(oldest["published_at"])]
            mac.extend(history[:count - len(mac)])

    ios = []
    runs = reader.api("actions/workflows/ios-internal-nightly.yml/runs",
                      branch="rc/cnx-ios-builder", status="completed", per_page=20)["workflow_runs"]
    for run in runs[:20]:
        title = IOS_TITLE.fullmatch(run.get("display_title", ""))
        if not title:
            continue
        prefix = f"https://github.com/{REPO}/actions/runs/{run['id']}/job/"
        known = next((r for r in registry["releases"] if r["platform"] == "ios"
                      and r["sha"] == title[1] and r["evidence"]["url"].startswith(prefix)
                      and run.get("run_attempt") is not None
                      and r["evidence"].get("run_attempt") == run["run_attempt"]), None)
        if known:
            ios.append(known)
        else:
            attempt = f"attempts/{run['run_attempt']}/" if run.get("run_attempt") else ""
            jobs = reader.api(f"actions/runs/{run['id']}/{attempt}jobs", per_page=100)["jobs"]
            job = next((j for j in jobs if j["name"] == "Sign, validate, upload to cmux INTERNAL"
                        and successful_step(j, "Sign, validate, upload")), None)
            if not job:
                continue
            ios.append(ios_receipt(run, job, reader.log(job["id"])))
    # GitHub lists runs by creation time, while a rerun can publish much later.
    # Inspect the whole bounded snapshot before selecting publication order.
    ios.sort(key=lambda r: timestamp(r["published_at"]), reverse=True)
    ios = ios[:count]
    # Discard unselected old entries: stale seed records cannot fill a live gap.
    result = {"schema_version": 1, "releases": ios + mac}
    resolve(result, count)
    return result

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("resolve", "record", "refresh"):
        command = sub.add_parser(name)
        command.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
        if name in ("resolve", "refresh"):
            command.add_argument("--count", type=int, default=3)
            if name == "resolve":
                command.add_argument("--github-output", type=Path)
            else:
                command.add_argument("--output", type=Path, required=True)
        else:
            command.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        registry = json.loads(args.registry.read_text())
        if args.command == "record":
            result = record(registry, json.loads(args.receipt.read_text()))
            args.registry.write_text(json.dumps(result, indent=2) + "\n")
        elif args.command == "refresh":
            result = refresh(registry, PublicationReader(os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")), args.count)
            args.output.write_text(json.dumps(result, indent=2) + "\n")
        else:
            result = resolve(registry, args.count)
            if args.github_output:
                with args.github_output.open("a") as output:
                    output.write("matrix=" + json.dumps({"include": result["include"]}, separators=(",", ":")) + "\n")
                    output.write("fingerprint=" + result["fingerprint"] + "\n")
        print(json.dumps(result, sort_keys=True))
    except (OSError, ValueError, TypeError, KeyError, ET.ParseError) as error:
        parser.exit(1, f"shipped-window: {error}\n")


if __name__ == "__main__":
    main()
