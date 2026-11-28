#!/usr/bin/env python3
"""Read a fresh, request-bound INTERNAL TestFlight window in a trusted job.

Only protected code receives ASC credentials. PR jobs consume the resulting
artifact. uploaded_at orders available builds; it is NOT their publication time.
"""
from __future__ import annotations

from datetime import datetime, timezone
import json
import re
import urllib.parse
import urllib.request

APP_ID = "6791408425"
REPO = "manaflow-ai/cmux"
ASC = "https://api.appstoreconnect.apple.com/v1/"
GITHUB = f"https://api.github.com/repos/{REPO}/"
SOURCE = re.compile(r"\bfeat-cmux-next ([0-9a-f]{10,40})\b")
YOLO_SOURCE = re.compile(r"^cmux-next iPhone[^\r\n]* YOLO, feat-cmux-next [0-9a-f]{10,40}"
                         r" \+ (?:#[0-9]+ )+\(([0-9a-f]{10,40})\)\. Internal testers only\.$")
SHA = re.compile(r"[0-9a-f]{40}")
SCAN_LIMIT = 20
UNAVAILABLE = {"PROCESSING", "PROCESSING_EXCEPTION", "MISSING_EXPORT_COMPLIANCE",
               "READY_FOR_BETA_TESTING", "EXPIRED", "FAILED"}


def source_prefixes(note):
    # ios_internal_notes.lead_line records the base after feat-cmux-next for
    # YOLO builds; only the parenthesized stack SHA describes the shipped app.
    yolo = [line for line in note.splitlines() if line.startswith("cmux-next iPhone") and " YOLO," in line]
    if yolo:
        matches = [YOLO_SOURCE.fullmatch(line) for line in yolo]
        if not all(matches):
            raise ValueError("YOLO source notes omit the exact built stack SHA")
        return {match.group(1) for match in matches}
    return set(SOURCE.findall(note))


def date(value):
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("ASC uploadedDate requires timezone")
    return result.astimezone(timezone.utc)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Reader:
    """Fixed hosts, no redirects/retries, bounded body and timeout per request."""
    def __init__(self, asc_token, github_token):
        self.asc_token = asc_token
        self.github_token = github_token

    def read(self, url):
        if url.startswith(ASC):
            token = self.asc_token
        elif url.startswith(GITHUB):
            token = self.github_token
        else:
            raise ValueError("publication reader only permits ASC and repository API URLs")
        headers = {"Accept": "application/json", "User-Agent": "cmux-ios-publication/1"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        request = urllib.request.Request(url, headers=headers)
        with urllib.request.build_opener(NoRedirect).open(request, timeout=60) as response:
            data = response.read(1_000_001)
        if len(data) > 1_000_000:
            raise ValueError("publication response exceeds 1 MB bound")
        return json.loads(data)

    def builds(self):
        query = urllib.parse.urlencode({
            "filter[app]": APP_ID, "filter[processingState]": "VALID",
            "sort": "-uploadedDate", "limit": str(SCAN_LIMIT),
            "include": "buildBetaDetail,betaBuildLocalizations",
            "fields[builds]": "version,uploadedDate,processingState,expired,buildBetaDetail,betaBuildLocalizations",
            "fields[buildBetaDetails]": "internalBuildState",
            "fields[betaBuildLocalizations]": "whatsNew,locale",
        })
        return self.read(ASC + "builds?" + query)

    def source(self, prefix):
        if not re.fullmatch(r"[0-9a-f]{10,40}", prefix):
            raise ValueError("source prefix must be hexadecimal")
        result = self.read(GITHUB + "commits/" + prefix).get("sha", "")
        if not SHA.fullmatch(result) or not result.startswith(prefix):
            raise ValueError("ASC note source does not resolve to its full repository commit")
        return result


def snapshot(document, resolve_source, *, head_sha, request_id, producer, now=None):
    """First three available builds in authoritative ASC uploadedDate order.

    VALID alone is insufficient: require unexpired and IN_BETA_TESTING. Fewer
    than three inside the bound yields no verdict, never an incomplete window.
    An old-workflow rerun receives a current uploadedDate from ASC.
    """
    if not SHA.fullmatch(head_sha) or not re.fullmatch(r"[0-9]+:[0-9]+", request_id):
        raise ValueError("request needs full head SHA and run-id:attempt identity")
    if not SHA.fullmatch(producer.get("workflow_sha", "")):
        raise ValueError("producer needs exact trusted workflow SHA")
    if producer.get("workflow_ref") != f"{REPO}/.github/workflows/ios-asc-ops.yml@refs/heads/main":
        raise ValueError("producer must run the protected publication snapshot workflow")
    if any(not str(producer.get(k, "")).isdigit() for k in ("run_id", "run_attempt")):
        raise ValueError("producer needs run ID and attempt")
    builds = document.get("data")
    if not isinstance(builds, list) or len(builds) > SCAN_LIMIT:
        raise ValueError("invalid bounded ASC build response")
    included = {}
    for item in document.get("included", []):
        key = (item["type"], item["id"])
        if key in included:
            raise ValueError("duplicate ASC included resource")
        included[key] = item
    releases, seen, previous = [], set(), None
    for build in builds:
        attributes = build["attributes"]
        uploaded_at = attributes["uploadedDate"]
        uploaded = date(uploaded_at)
        if previous is not None and uploaded > previous:
            raise ValueError("ASC response is not sorted by uploadedDate descending")
        previous = uploaded
        if attributes.get("processingState") != "VALID":
            raise ValueError("ASC VALID filter returned an unprocessed build")
        if not isinstance(attributes.get("expired"), bool):
            raise ValueError("ASC build has no explicit expiration evidence")
        if attributes["expired"]:
            continue
        relationships = build.get("relationships", {})
        detail_ref = relationships.get("buildBetaDetail", {}).get("data")
        if not detail_ref:
            raise ValueError("ASC build has no internal availability relationship")
        detail = included.get((detail_ref["type"], detail_ref["id"]))
        if not detail:
            raise ValueError("ASC omitted internal availability evidence")
        state = detail.get("attributes", {}).get("internalBuildState")
        if state in UNAVAILABLE:
            continue
        if state != "IN_BETA_TESTING":
            raise ValueError("ASC build has missing or unknown internal availability state")
        release_id = attributes.get("version", "")
        if not isinstance(release_id, str) or not release_id.isdigit() or release_id in seen:
            raise ValueError("ASC build version is missing or duplicated")
        seen.add(release_id)
        prefixes = set()
        for ref in relationships.get("betaBuildLocalizations", {}).get("data", []):
            localization = included.get((ref["type"], ref["id"]), {})
            note = localization.get("attributes", {}).get("whatsNew", "") or ""
            prefixes.update(source_prefixes(note))
        if len(prefixes) != 1:
            raise ValueError(f"ASC build {release_id} has missing or conflicting source notes")
        prefix = prefixes.pop()
        sha = resolve_source(prefix)
        if not SHA.fullmatch(sha) or not sha.startswith(prefix):
            raise ValueError("source resolver must return the full matching commit SHA")
        releases.append({
            "platform": "ios", "sha": sha, "release_id": release_id,
            "uploaded_at": uploaded_at,
            "evidence": {"kind": "testflight-available", "url": ASC + "builds/" + build["id"],
                         "asc_build_id": build["id"], "internal_build_state": state},
        })
        if len(releases) == 3:
            break
    if len(releases) != 3:
        raise ValueError("ASC bounded window does not prove three available internal builds")
    observed = now or datetime.now(timezone.utc)
    if observed.tzinfo is None:
        raise ValueError("snapshot observation requires timezone")
    return {"schema_version": 1, "status": "complete", "generated_at": observed.isoformat(),
            "order": "uploadedDate-desc", "app_id": APP_ID, "releases": releases,
            "request": {"repository": REPO, "head_sha": head_sha, "request_id": request_id},
            "producer": producer}
