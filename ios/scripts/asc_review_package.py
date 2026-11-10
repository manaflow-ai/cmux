#!/usr/bin/env python3
"""Keep the App Store Connect review package in step with ios/AppStoreReview.

Subcommands, all through the public App Store Connect API with the CI key
(ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_PATH or ASC_API_KEY_P8_BASE64):

  sync-notes          Render ios/AppStoreReview/review-notes-asc.txt with the
                      live values App Store Connect already holds (demo account,
                      public inbox, contact) and write it to the version's App
                      Review notes. Live values never live in git.
  sync-listing        Set every locale of the version to the Support URL in
                      metadata/version/<version>/en-US.json, and en-US to its
                      description, then read them back and fail on any locale
                      that still differs (a locale left on the home page is a
                      Guideline 1.5 rejection) or whose description names a
                      plan in the manifest's listing_must_not_name.
  upload-images       Upload subscription-images/<product id>.png as the
                      promotional image of each subscription that has none.
  gate                Read `asc validate --output json` reports and fail on every
                      blocking finding, except the ones subscriptions.json
                      explains: a product submitted with this version is
                      READY_TO_SUBMIT until the version is submitted, and a
                      product left out of this version is not reviewed.
  verify-submission   After a review submission: every submit_with_version
                      product must have entered review and no other product may
                      have. Otherwise the submission is cancelled (it has not
                      reached a reviewer yet) and the step fails with the fix.

The first subscriptions of an app ride on an app version's submission. The
public API cannot select them on the version (only App Store Connect's web
session can), so verify-submission checks the outcome instead of trusting it.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asc_max_build  # noqa: E402  (ES256 token minting shared with the upload lane)

OFFICIAL_API_BASE = "https://api.appstoreconnect.apple.com"
IOS_DIR = Path(__file__).resolve().parents[1]
REVIEW_DIR = IOS_DIR / "AppStoreReview"
DEFAULT_MANIFEST = REVIEW_DIR / "subscriptions.json"
DEFAULT_NOTES_TEMPLATE = REVIEW_DIR / "review-notes-asc.txt"
DEFAULT_IMAGES_DIR = REVIEW_DIR / "subscription-images"
VERSION_METADATA_DIR = REVIEW_DIR / "metadata" / "version"
NOTES_LIMIT = 4000
IN_REVIEW_STATES = {"WAITING_FOR_REVIEW", "IN_REVIEW"}
# A product Apple already approved (with an earlier version) does not ride again.
SUBMITTED_OK_STATES = IN_REVIEW_STATES | {"APPROVED"}
# A submission that entered review during the verification wait is still
# withdrawn: a mismatch must never stay in front of a reviewer.
OPEN_SUBMISSION_STATES = ("READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES")
# An image counts once App Store Connect has its bytes; anything else is a
# reservation a failed run left behind, deleted and uploaded again.
IMAGE_DELIVERED_STATES = {"UPLOAD_COMPLETE", "COMPLETE"}
PLACEHOLDER = re.compile(r"\{\{([A-Z_]+)\}\}")
MAILINATOR_URL = re.compile(r"https?://(?:www\.)?mailinator\.com/[^\s)]+", re.IGNORECASE)


class PackageError(RuntimeError):
    pass


def note(message: str) -> None:
    print(f"asc-review-package: {message}", file=sys.stderr)


# --- API -------------------------------------------------------------------


def api_base() -> str:
    override = os.environ.get("CMUX_ASC_API_BASE_URL")
    if not override:
        return OFFICIAL_API_BASE
    host = urllib.parse.urlsplit(override).hostname
    if host not in {"127.0.0.1", "::1", "localhost"}:
        raise PackageError("CMUX_ASC_API_BASE_URL is restricted to loopback tests")
    return override.rstrip("/")


class Api:
    def __init__(self, token: str | None = None) -> None:
        self._token = token
        self.base = api_base()
        self.timeout = int(os.environ.get("ASC_TIMEOUT_SECONDS", "60"))

    def token(self) -> str:
        if self._token is None:
            self._token = os.environ.get("CMUX_ASC_TEST_TOKEN") if self.base != OFFICIAL_API_BASE else None
            if not self._token:
                self._token = asc_max_build._token()
        return self._token

    def request(self, method: str, path: str, body: Any = None) -> Any:
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Authorization", "Bearer " + self.token())
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            try:
                code = asc_max_build._asc_error_code(json.loads(error.read() or b"{}"))
            except ValueError:
                code = "unknown"
            # Only the status and Apple's scalar code: error bodies can echo detail.
            raise PackageError(f"{method} {path.split('?')[0]} -> HTTP {error.code} ({code})") from None

    def get(self, path: str) -> Any:
        return self.request("GET", path)

    def get_all(self, path: str) -> list[dict]:
        items: list[dict] = []
        url = path
        for _ in range(50):
            body = self.get(url)
            items.extend(body.get("data") or [])
            nxt = (body.get("links") or {}).get("next")
            if not nxt:
                return items
            parts = urllib.parse.urlsplit(nxt)
            url = parts.path + ("?" + parts.query if parts.query else "")
        raise PackageError(f"too many pages at {path.split('?')[0]}")


def version_id(api: Api, app: str, version: str) -> str:
    query = urllib.parse.urlencode({"filter[versionString]": version, "filter[platform]": "IOS", "limit": "5"})
    data = api.get(f"/v1/apps/{app}/appStoreVersions?{query}").get("data") or []
    if not data:
        raise PackageError(f"App Store version {version} not found for app {app}")
    return data[0]["id"]


def subscriptions(api: Api, group_id: str) -> dict[str, dict]:
    """Subscriptions of the group by product id: {product: {id, state, name}}."""
    out = {}
    for item in api.get_all(f"/v1/subscriptionGroups/{group_id}/subscriptions?limit=200"):
        attrs = item.get("attributes") or {}
        out[attrs.get("productId", "")] = {"id": item["id"], "state": attrs.get("state", ""), "name": attrs.get("name", "")}
    return out


def load_manifest(path: Path) -> dict:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    submit = set(manifest.get("submit_with_version") or {})
    excluded = set(manifest.get("not_in_this_version") or {})
    if not manifest.get("group_id") or not submit:
        raise PackageError(f"{path}: group_id and submit_with_version are required")
    for name in manifest.get("listing_must_not_name") or {}:
        if not isinstance(name, str) or len(name.strip()) < 4:
            raise PackageError(f"{path}: listing_must_not_name entries must be plan names, got {name!r}")
    if submit & excluded:
        raise PackageError(f"{path}: {sorted(submit & excluded)} both submitted and excluded")
    return manifest


# --- sync-notes --------------------------------------------------------------


def render_notes(template: str, detail: dict) -> str:
    demo = (detail.get("demoAccountName") or "").strip()
    inbox = ""
    match = MAILINATOR_URL.search(detail.get("notes") or "")
    if match:
        inbox = match.group(0).rstrip(".,")
    elif demo.lower().endswith("@mailinator.com"):
        local = demo.split("@", 1)[0]
        inbox = "https://www.mailinator.com/v4/public/inboxes.jsp?" + urllib.parse.urlencode({"to": local})
    values = {
        "DEMO_ACCOUNT_EMAIL": demo,
        "MAILINATOR_PUBLIC_INBOX_URL": inbox,
        "REVIEW_CONTACT_EMAIL": (detail.get("contactEmail") or "").strip(),
        "REVIEW_CONTACT_PHONE": (detail.get("contactPhone") or "").strip(),
    }
    missing = sorted({name for name in PLACEHOLDER.findall(template) if not values.get(name)})
    if missing:
        raise PackageError(
            "App Review Information lacks " + ", ".join(missing)
            + "; fill the demo account and contact fields in App Store Connect"
        )
    notes = PLACEHOLDER.sub(lambda m: values[m.group(1)], template).strip() + "\n"
    if len(notes) > NOTES_LIMIT:
        raise PackageError(f"rendered notes are {len(notes)} characters; App Store Connect allows {NOTES_LIMIT}")
    return notes


def sync_notes(api: Api, app: str, version: str, template_path: Path, dry_run: bool) -> bool:
    vid = version_id(api, app, version)
    body = api.get(f"/v1/appStoreVersions/{vid}/appStoreReviewDetail")
    data = body.get("data")
    if not data:
        raise PackageError(f"version {version} has no App Review Information; fill it in App Store Connect")
    detail = data.get("attributes") or {}
    notes = render_notes(template_path.read_text(encoding="utf-8"), detail)
    if (detail.get("notes") or "").strip() == notes.strip():
        note("App Review notes already match the repository")
        return False
    if dry_run:
        note("App Review notes differ from the repository (dry run, not written)")
        return True
    api.request("PATCH", f"/v1/appStoreReviewDetails/{data['id']}", {
        "data": {"type": "appStoreReviewDetails", "id": data["id"], "attributes": {"notes": notes}},
    })
    note(f"App Review notes for {version} written from {template_path.name}")
    return True


# --- sync-listing ------------------------------------------------------------


def version_listing(version: str, metadata_dir: Path = VERSION_METADATA_DIR) -> dict:
    """The en-US listing in git: its supportUrl applies to every locale."""
    path = metadata_dir / version / "en-US.json"
    try:
        listing = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise PackageError(f"{path}: cannot read the listing ({error})") from None
    url = (listing.get("supportUrl") or "").strip()
    if not url.startswith("https://"):
        raise PackageError(f"{path}: supportUrl must be an https URL, got {url!r}")
    if not (listing.get("description") or "").strip():
        raise PackageError(f"{path}: description is empty")
    return listing


def listing_problems(item: dict, support_url: str, banned: list[str]) -> list[str]:
    attrs = item.get("attributes") or {}
    locale = attrs.get("locale") or item["id"]
    problems = []
    if (attrs.get("supportUrl") or "").strip() != support_url:
        problems.append(f"{locale} supportUrl is {attrs.get('supportUrl')!r}, not {support_url}")
    description = attrs.get("description") or ""
    for name in banned:
        if name.casefold() in description.casefold():
            problems.append(f"{locale} description names {name}, which this version does not offer")
    return problems


def sync_listing(api: Api, app: str, version: str, listing: dict, banned: list[str], dry_run: bool) -> list[str]:
    support_url = listing["supportUrl"].strip()
    description = listing["description"]
    vid = version_id(api, app, version)
    path = f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations?limit=50"
    localizations = api.get_all(path)
    if not localizations:
        raise PackageError(f"version {version} has no localizations")
    for item in localizations:
        attrs = item.get("attributes") or {}
        locale = attrs.get("locale") or item["id"]
        changes = {}
        if (attrs.get("supportUrl") or "").strip() != support_url:
            changes["supportUrl"] = support_url
        if locale == "en-US" and (attrs.get("description") or "") != description:
            changes["description"] = description
        if not changes:
            continue
        if dry_run:
            note(f"{locale}: {', '.join(sorted(changes))} differ from the repository (dry run, not written)")
            continue
        api.request("PATCH", f"/v1/appStoreVersionLocalizations/{item['id']}", {
            "data": {"type": "appStoreVersionLocalizations", "id": item["id"], "attributes": changes},
        })
        note(f"{locale}: {', '.join(sorted(changes))} written from the repository")
    current = localizations if dry_run else api.get_all(path)
    wrong = [line for item in current for line in listing_problems(item, support_url, banned)]
    # Read back after a write too: a write that did not take fails here.
    wrong += [
        "en-US description differs from the repository"
        for item in current
        if (item.get("attributes") or {}).get("locale") == "en-US"
        and (item.get("attributes") or {}).get("description") != description
    ]
    for line in wrong:
        note("BLOCKING: " + line)
    if not wrong:
        note(f"all {len(current)} locale(s) of {version} use Support URL {support_url} and name only offered plans")
    return wrong


# --- upload-images -----------------------------------------------------------


def png_size(data: bytes) -> tuple[int, int]:
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise PackageError("not a PNG")
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")


def image_state(image: dict) -> str:
    return (((image.get("attributes") or {}).get("assetDeliveryState") or {}).get("state")) or ""


def upload_images(api: Api, manifest: dict, images_dir: Path) -> list[str]:
    subs = subscriptions(api, manifest["group_id"])
    uploaded = []
    for path in sorted(images_dir.glob("*.png")):
        product = path.stem
        if product not in subs:
            raise PackageError(f"{path.name}: no subscription {product} in group {manifest['group_id']}")
        data = path.read_bytes()
        if png_size(data) != (1024, 1024):
            raise PackageError(f"{path.name}: promotional images are 1024x1024")
        sub_id = subs[product]["id"]
        existing = api.get(f"/v1/subscriptions/{sub_id}/images").get("data") or []
        delivered = [image for image in existing if image_state(image) in IMAGE_DELIVERED_STATES]
        if delivered:
            note(f"{product} already has a promotional image ({image_state(delivered[0])})")
            continue
        for image in existing:
            api.request("DELETE", f"/v1/subscriptionImages/{image['id']}")
            note(f"{product}: removed unfinished promotional image {image['id']} ({image_state(image) or 'no state'})")
        reserved = api.request("POST", "/v1/subscriptionImages", {
            "data": {
                "type": "subscriptionImages",
                "attributes": {"fileName": path.name, "fileSize": len(data)},
                "relationships": {"subscription": {"data": {"type": "subscriptions", "id": sub_id}}},
            },
        })["data"]
        for op in (reserved.get("attributes") or {}).get("uploadOperations") or []:
            offset, length = int(op.get("offset", 0)), int(op.get("length", len(data)))
            req = urllib.request.Request(op["url"], data=data[offset:offset + length], method=op.get("method", "PUT"))
            for header in op.get("requestHeaders") or []:
                req.add_header(header["name"], header["value"])
            with urllib.request.urlopen(req, timeout=api.timeout):
                pass
        api.request("PATCH", f"/v1/subscriptionImages/{reserved['id']}", {
            "data": {
                "type": "subscriptionImages",
                "id": reserved["id"],
                "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()},
            },
        })
        note(f"{product}: promotional image uploaded")
        uploaded.append(product)
    return uploaded


# --- gate --------------------------------------------------------------------


def report_checks(report: Any) -> list[dict]:
    if not isinstance(report, dict) or "checks" not in report:
        raise PackageError("validation report has no checks list; asc did not produce a report")
    checks = report["checks"]
    if checks is None:  # asc marshals an empty Go slice as null
        return []
    if not isinstance(checks, list):
        raise PackageError("validation report has no checks list; asc did not produce a report")
    return checks


def resource_id(check: dict) -> str:
    raw = str(check.get("resourceId") or check.get("resource") or "")
    return raw.split(":", 1)[1] if ":" in raw else raw


def is_blocking(check: dict, strict: bool) -> bool:
    if isinstance(check.get("blocking"), bool):
        return check["blocking"]
    severity = str(check.get("severity", "")).lower()
    return severity == "error" or (strict and severity == "warning")


def gate(reports: list[Any], manifest: dict, load_subs, strict: bool) -> list[str]:
    """Return the blocking findings no manifest rule explains (empty means pass).

    load_subs() maps product ids to subscriptions; it is called only when a
    blocking finding names a subscription.
    """
    by_id: dict[str, str] | None = None
    submit = manifest["submit_with_version"]
    excluded = manifest.get("not_in_this_version") or {}
    failures, explained = [], []
    for report in reports:
        report_strict = strict or (isinstance(report, dict) and bool(report.get("strict")))
        for check in report_checks(report):
            if not is_blocking(check, report_strict):
                continue
            cid = str(check.get("id", ""))
            product = ""
            if cid.startswith("subscriptions."):
                if by_id is None:
                    by_id = {info["id"]: product for product, info in load_subs().items()}
                product = by_id.get(resource_id(check), "")
            line = f"{cid}: {check.get('message', '')}"
            if cid.startswith("subscriptions.") and product in excluded:
                explained.append(f"{line}  [not in this version: {excluded[product]}]")
            elif (
                cid == "subscriptions.review_readiness.needs_attention"
                and product in submit
                and "READY_TO_SUBMIT" in str(check.get("message", ""))
            ):
                explained.append(f"{line}  [submitted with this version; verify-submission checks it enters review]")
            else:
                failures.append(line)
    for line in explained:
        note("expected: " + line)
    for line in failures:
        note("BLOCKING: " + line)
    return failures


# --- verify-submission -------------------------------------------------------


def submissions_for_version(api: Api, app: str, vid: str) -> list[str]:
    """Open iOS review submissions that carry this app version, and only those."""
    query = urllib.parse.urlencode({"filter[platform]": "IOS", "filter[state]": ",".join(OPEN_SUBMISSION_STATES)})
    found = []
    for submission in api.get_all(f"/v1/apps/{app}/reviewSubmissions?{query}"):
        items = api.get_all(f"/v1/reviewSubmissions/{submission['id']}/items?include=appStoreVersion&limit=50")
        if any(
            (((item.get("relationships") or {}).get("appStoreVersion") or {}).get("data") or {}).get("id") == vid
            for item in items
        ):
            found.append(submission["id"])
    return found


def verify_submission(api: Api, app: str, version: str, manifest: dict, wait_seconds: int, cancel: bool) -> list[str]:
    submit = set(manifest["submit_with_version"])
    deadline = time.monotonic() + wait_seconds
    while True:
        subs = subscriptions(api, manifest["group_id"])
        problems = []
        for product in sorted(submit):
            state = (subs.get(product) or {}).get("state", "missing")
            if state not in SUBMITTED_OK_STATES:
                problems.append(f"{product} is {state}, not in review with the version")
        for product, info in sorted(subs.items()):
            if product not in submit and info["state"] in IN_REVIEW_STATES:
                problems.append(f"{product} entered review but the app does not offer it in this version")
        if not problems or time.monotonic() >= deadline:
            break
        # App Store Connect sends no event when a submission's items change
        # state; re-reading the states until the deadline is the only signal.
        time.sleep(10)
    if not problems:
        note("submission carries exactly: " + ", ".join(sorted(submit)))
        return []
    for line in problems:
        note("BLOCKING: " + line)
    if cancel:
        vid = version_id(api, app, version)
        for sid in submissions_for_version(api, app, vid):
            api.request("PATCH", f"/v1/reviewSubmissions/{sid}", {
                "data": {"type": "reviewSubmissions", "id": sid, "attributes": {"canceled": True}},
            })
            note(f"cancelled review submission {sid} of {version} before a reviewer saw it")
    note(
        "fix once in App Store Connect: the version page > In-App Purchases and Subscriptions > select exactly "
        + ", ".join(sorted(submit)) + " > Save, then dispatch the workflow again"
    )
    return problems


# --- CLI ---------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", default=os.environ.get("ASC_APP_ID", ""))
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    sub = parser.add_subparsers(dest="command", required=True)
    notes_p = sub.add_parser("sync-notes")
    notes_p.add_argument("--version", required=True)
    notes_p.add_argument("--template", type=Path, default=DEFAULT_NOTES_TEMPLATE)
    notes_p.add_argument("--dry-run", action="store_true")
    support_p = sub.add_parser("sync-listing")
    support_p.add_argument("--version", required=True)
    support_p.add_argument("--dry-run", action="store_true")
    images_p = sub.add_parser("upload-images")
    images_p.add_argument("--dir", type=Path, default=DEFAULT_IMAGES_DIR)
    gate_p = sub.add_parser("gate")
    gate_p.add_argument("--report", type=Path, action="append", required=True)
    gate_p.add_argument("--strict", action="store_true")
    verify_p = sub.add_parser("verify-submission")
    verify_p.add_argument("--version", required=True)
    verify_p.add_argument("--wait-seconds", type=int, default=120)
    verify_p.add_argument("--no-cancel", action="store_true")
    args = parser.parse_args(argv)

    if not re.fullmatch(r"[0-9]+", args.app or ""):
        parser.error("--app must be the numeric App Store Connect app id")
    try:
        api = Api()
        manifest = load_manifest(args.manifest)
        if args.command == "sync-notes":
            sync_notes(api, args.app, args.version, args.template, args.dry_run)
            return 0
        if args.command == "sync-listing":
            listing = version_listing(args.version)
            banned = sorted(manifest.get("listing_must_not_name") or {})
            return 1 if sync_listing(api, args.app, args.version, listing, banned, args.dry_run) else 0
        if args.command == "upload-images":
            upload_images(api, manifest, args.dir)
            return 0
        if args.command == "gate":
            reports = []
            for path in args.report:
                try:
                    reports.append(json.loads(path.read_text(encoding="utf-8")))
                except ValueError as error:
                    raise PackageError(f"{path}: not a JSON validation report ({error})") from None
            failures = gate(reports, manifest, lambda: subscriptions(api, manifest["group_id"]), args.strict)
            if failures:
                note(f"{len(failures)} blocking finding(s)")
                return 1
            note("readiness gate passed")
            return 0
        if args.command == "verify-submission":
            return 1 if verify_submission(api, args.app, args.version, manifest, args.wait_seconds, not args.no_cancel) else 0
    except PackageError as error:
        note(f"error: {error}")
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
