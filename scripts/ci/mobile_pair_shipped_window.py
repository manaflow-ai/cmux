#!/usr/bin/env python3
"""Resolve shipped phone/Mac sources, not merely green compilation runs.

Publication jobs append a receipt with 'record'; CI reads a trusted registry with
'resolve'. N counts releases before source deduplication: repeated releases retain
their IDs but build the source only once. 'host' means a shipped Mac source paired
with the PR phone; 'dial' means a shipped phone source paired with the PR Mac.
"""
from __future__ import annotations

import argparse
import io
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
import zipfile

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
    proof = entry.get("evidence", {})
    available = entry["platform"] == "ios" and isinstance(proof, dict) and proof.get("kind") == "testflight-available"
    timestamp(entry.get("uploaded_at") if available else entry.get("published_at"))
    if available and (proof.get("internal_build_state") != "IN_BETA_TESTING" or not proof.get("asc_build_id")):
        raise ValueError("iOS publication needs an available INTERNAL build")
    if not isinstance(proof, dict) or (not available and proof.get("kind") != EVIDENCE[entry["platform"]]):
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
        releases = [r for r in registry["releases"] if r["platform"] == platform]
        ordered = [r for r in releases if "window_order" in r]
        if ordered:
            if len(ordered) != len(releases) or sorted(r["window_order"] for r in ordered) != list(range(len(releases))):
                raise ValueError("authority order must cover the complete platform window")
            releases.sort(key=lambda r: r["window_order"])
        else:
            releases.sort(key=lambda r: (timestamp(r["published_at"]), r["release_id"]), reverse=True)
        releases = releases[:count]
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
IOS_SNAPSHOT_WORKFLOW = ".github/workflows/ios-publication-snapshot.yml"
IOS_SNAPSHOT_BRANCH = "rc/cnx-ios-builder"
IOS_SNAPSHOT_REF = f"{REPO}/{IOS_SNAPSHOT_WORKFLOW}@refs/heads/{IOS_SNAPSHOT_BRANCH}"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class PublicationReader:
    """One bounded snapshot, no retries/polling; never send GitHub auth to logs."""
    def __init__(self, token=None):
        self.token = token

    def read_bytes(self, url, authenticated=False):
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
            if error.code == 302 and authenticated and url.endswith("/zip"):
                # Signed artifact URLs are fetched without the GitHub bearer token.
                return self.read_bytes(error.headers["Location"])
            raise
        if len(data) > 10_000_000:
            raise ValueError("publication response exceeds 10 MB bound")
        return data

    def read(self, url, authenticated=False):
        return self.read_bytes(url, authenticated).decode("utf-8")

    def api(self, path, **query):
        url = f"https://api.github.com/repos/{REPO}/{path}"
        if query:
            url += "?" + urllib.parse.urlencode(query)
        return json.loads(self.read(url, authenticated=True))

    def artifact(self, artifact_id):
        return self.read_bytes(f"https://api.github.com/repos/{REPO}/actions/artifacts/{artifact_id}/zip",
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


def mac_publication_window(text, count):
    """History is committed atomically with the live feed, never inferred from runs."""
    root = ET.fromstring(text)
    histories = root.findall("./channel/" + CMUX_NS + "publicationHistory")
    if len(histories) != 1 or histories[0].get("schemaVersion") != "1":
        raise ValueError("NIGHTLY feed needs publisher-owned publication history")
    nodes = list(histories[0])
    if not count <= len(nodes) <= 3:
        raise ValueError(f"NIGHTLY publication history needs {count} releases (maximum 3)")
    releases = []
    for node in nodes:
        if node.tag != CMUX_NS + "publication":
            raise ValueError("unknown NIGHTLY publication history record")
        releases.append(receipt(
            "mac", node.get("sourceCommit"), node.get("build"),
            parsedate_to_datetime(node.get("pubDate", "")).isoformat(), node.get("enclosure"),
        ))
    validate_registry({"schema_version": 1, "releases": releases})
    live, _ = appcast_receipts(text)
    if live[0]["release_id"] != releases[0]["release_id"]:
        raise ValueError("NIGHTLY history does not start at the live publication")
    indexed = {r["release_id"]: r for r in releases}
    for item in live:
        prior = indexed.get(item["release_id"])
        if prior is None or prior["sha"] != item["sha"]:
            raise ValueError("NIGHTLY history conflicts with the live feed")
    return [dict(entry, window_order=index) for index, entry in enumerate(releases[:count])]


def ios_publication_window(snapshot, count):
    """Validate the fresh ASC available-build window without inventing publication times."""
    if snapshot.get("schema_version") != 1 or snapshot.get("status") != "complete":
        raise ValueError("iOS publication snapshot is not complete")
    timestamp(snapshot.get("generated_at"))
    releases = snapshot.get("releases")
    if not isinstance(releases, list) or not count <= len(releases) <= 3:
        raise ValueError(f"iOS publication snapshot needs {count} available releases (maximum 3)")
    validate_registry({"schema_version": 1, "releases": releases})
    dates = []
    for entry in releases:
        if entry["platform"] != "ios" or entry["evidence"]["kind"] != "testflight-available":
            raise ValueError("iOS snapshot needs authoritative available-build receipts")
        dates.append(timestamp(entry["uploaded_at"]))
    if dates != sorted(dates, reverse=True):
        raise ValueError("iOS snapshot must retain App Store Connect uploadedDate order")
    return [dict(entry, window_order=index) for index, entry in enumerate(releases[:count])]


def trusted_ios_snapshot(reader, *, producer_run, producer_sha, request_id, head_sha):
    """Authenticate immutable artifact provenance before trusting any JSON claims."""
    if not str(producer_run).isdigit() or not SHA.fullmatch(producer_sha) or not SHA.fullmatch(head_sha):
        raise ValueError("snapshot needs exact producer run, workflow SHA and request head")
    if not re.fullmatch(r"[0-9]+:[0-9]+", request_id):
        raise ValueError("snapshot request must be gate run-id:attempt")
    run = reader.api(f"actions/runs/{producer_run}")
    if (str(run.get("id")) != str(producer_run) or run.get("event") != "workflow_dispatch"
            or run.get("path") != IOS_SNAPSHOT_WORKFLOW or run.get("head_branch") != IOS_SNAPSHOT_BRANCH
            or run.get("head_sha") != producer_sha or run.get("conclusion") != "success"
            or run.get("status") != "completed" or run.get("repository", {}).get("full_name") != REPO):
        raise ValueError("snapshot producer is not the successful exact protected workflow")
    response = reader.api(f"actions/runs/{producer_run}/artifacts", per_page=100)
    artifacts = response.get("artifacts", [])
    if response.get("total_count") != len(artifacts) or len(artifacts) > 100:
        raise ValueError("snapshot artifact list exceeds its bound")
    name = "ios-publication-snapshot-" + request_id.replace(":", "-")
    matches = [a for a in artifacts if a.get("name") == name]
    if len(matches) != 1 or matches[0].get("expired") is not False:
        raise ValueError("snapshot needs one unexpired request-bound artifact")
    artifact = matches[0]
    if not isinstance(artifact.get("size_in_bytes"), int) or not 0 < artifact["size_in_bytes"] <= 1_000_000:
        raise ValueError("snapshot artifact exceeds its size bound")
    archive = reader.artifact(artifact["id"])
    if len(archive) > 1_000_000:
        raise ValueError("snapshot archive exceeds its size bound")
    with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
        members = zipped.infolist()
        if len(members) != 1 or members[0].filename != "ios-publication.json" or members[0].file_size > 100_000:
            raise ValueError("snapshot archive has unexpected contents")
        snapshot = json.loads(zipped.read(members[0]))
    expected = {"repository": REPO, "head_sha": head_sha, "request_id": request_id}
    producer = snapshot.get("producer", {})
    if (snapshot.get("request") != expected or str(producer.get("run_id")) != str(producer_run)
            or str(producer.get("run_attempt")) != str(run.get("run_attempt"))
            or producer.get("workflow_sha") != producer_sha or producer.get("workflow_ref") != IOS_SNAPSHOT_REF):
        raise ValueError("snapshot is not bound to this request and authenticated producer")
    if snapshot.get("app_id") != "6791408425" or snapshot.get("order") != "uploadedDate-desc":
        raise ValueError("snapshot must describe the INTERNAL available-build order")
    return snapshot


def refresh(registry, reader, count=3, *, producer_run, producer_sha, request_id, head_sha):
    """Bounded authority reads; cache/run samples never prove shipped ordering.

    iOS is a fresh secret-free artifact from an exact protected ASC query. Mac
    history shares the appcast publication CAS. No PR source receives ASC keys.
    """
    validate_registry(registry)
    if not 1 <= count <= 3:
        raise ValueError("live refresh supports a window of 1 to 3 releases")
    mac = mac_publication_window(reader.read(APPCAST), count)
    snapshot = trusted_ios_snapshot(reader, producer_run=producer_run, producer_sha=producer_sha,
                                    request_id=request_id, head_sha=head_sha)
    ios = ios_publication_window(snapshot, count)
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
                for option in ("producer-run", "producer-sha", "request-id", "head-sha"):
                    command.add_argument("--" + option, required=True)
        else:
            command.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        registry = json.loads(args.registry.read_text())
        if args.command == "record":
            result = record(registry, json.loads(args.receipt.read_text()))
            args.registry.write_text(json.dumps(result, indent=2) + "\n")
        elif args.command == "refresh":
            result = refresh(registry, PublicationReader(os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")), args.count,
                             producer_run=args.producer_run, producer_sha=args.producer_sha,
                             request_id=args.request_id, head_sha=args.head_sha)
            args.output.write_text(json.dumps(result, indent=2) + "\n")
        else:
            result = resolve(registry, args.count)
            if args.github_output:
                with args.github_output.open("a") as output:
                    output.write("matrix=" + json.dumps({"include": result["include"]}, separators=(",", ":")) + "\n")
                    output.write("fingerprint=" + result["fingerprint"] + "\n")
        print(json.dumps(result, sort_keys=True))
    except (OSError, ValueError, TypeError, KeyError, ET.ParseError, zipfile.BadZipFile) as error:
        parser.exit(1, f"shipped-window: {error}\n")


if __name__ == "__main__":
    main()
