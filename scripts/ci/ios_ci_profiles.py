#!/usr/bin/env python3
"""Fetch, or regenerate, the cmux INTERNAL App Store profiles for CI's own certificate.

The signer (.github/workflows/ios-internal-nightly.yml, `upload`) runs this after it
imports IOS_DISTRIBUTION_CERTIFICATE_BASE64 into its keychain. For the app and its two
notification extensions it finds the ACTIVE App Store profile named
"<prefix>", "<prefix> Notification Content", "<prefix> Notification Service" that lists
that certificate and is valid for at least --min-days more days. When there is none (the
profile was regenerated without CI's certificate, invalidated by a capability change, or
expired), it deletes the stale ones of that name and creates a new one for CI's
certificate through the App Store Connect API key, so the profile never drifts from the
certificate (docs/handbook/signing-profile-drifts-from-its-certificate.md in
cmuxterm-hq). It writes CMUX_MOBILE_PROFILE_PATH and the two extension paths to
$GITHUB_ENV for cmux-next-ios/scripts/testflight-build.sh.

Detector: it fails, before anything is signed, naming the certificate and the profile,
when a profile it would hand on does not list CI's certificate.

Setting: regenerating deletes and creates profiles in the team's App Store Connect account,
so it can be turned off. CMUX_IOS_CI_PROFILE_REGENERATE (the repository variable of that
name in ios-internal-nightly.yml; on by default) set to 0, false, no or off, or
--no-regenerate, only fetches: with no usable profile it fails naming each stale one and
what an Admin does in the portal, and changes nothing there.

Needs `asc` on PATH with ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY_PATH set. Prints
no secret: certificate SHA-1s and App Store Connect ids only.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

PORTAL = "https://developer.apple.com/account/resources/profiles/list"


def fail(msg: str) -> None:
    print(f"::error::{msg}", file=sys.stderr)
    sys.exit(1)


def asc(*args: str) -> dict:
    proc = subprocess.run(["asc", *args, "--output", "json"], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"asc {' '.join(args[:2])} failed: {proc.stderr.strip()[-600:]}")
    # asc may append warnings after the document.
    return json.JSONDecoder().raw_decode(proc.stdout.lstrip())[0]


def keychain_identities(keychain: str) -> list[str]:
    out = subprocess.run(
        ["security", "find-identity", "-v", "-p", "codesigning", keychain],
        capture_output=True, text=True, check=True,
    ).stdout
    return sorted({m.group(1) for m in re.finditer(r"\b([0-9A-F]{40})\b", out)})


def decode_profile(content_b64: str) -> dict:
    raw = base64.b64decode(content_b64)
    plist = subprocess.run(["security", "cms", "-D"], input=raw, capture_output=True, check=True).stdout
    return plistlib.loads(plist)


def profile_sha1s(p: dict) -> set[str]:
    return {hashlib.sha1(c).hexdigest().upper() for c in p.get("DeveloperCertificates", [])}


def usable(p: dict, identity: str, team_bundle: str, min_days: int) -> str:
    """Empty when the decoded profile is usable, else why not."""
    if p.get("Entitlements", {}).get("application-identifier") != team_bundle:
        return f"is for {p.get('Entitlements', {}).get('application-identifier')}, not {team_bundle}"
    if identity not in profile_sha1s(p):
        return f"does not list CI's certificate {identity} (it lists {', '.join(sorted(profile_sha1s(p))) or 'none'})"
    exp = p["ExpirationDate"]
    if exp.tzinfo is None:
        exp = exp.replace(tzinfo=dt.timezone.utc)
    if exp - dt.datetime.now(dt.timezone.utc) < dt.timedelta(days=min_days):
        return f"expires {exp:%Y-%m-%d}"
    return ""


REGENERATE_ENV = "CMUX_IOS_CI_PROFILE_REGENERATE"


def regenerate_default(environ=os.environ) -> bool:
    """Whether a missing or stale profile is regenerated in App Store Connect: on unless
    CMUX_IOS_CI_PROFILE_REGENERATE says 0, false, no or off (an empty value is the default)."""
    value = environ.get(REGENERATE_ENV, "").strip().lower()
    return value not in ("0", "false", "no", "off")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--keychain", required=True)
    ap.add_argument("--team", default="7WLXT3NR37")
    ap.add_argument("--bundle-id", default="dev.cmux.app.internal")
    ap.add_argument("--name", default="cmux Internal Distribution CI")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--min-days", type=int, default=3)
    ap.add_argument("--github-env", default=os.environ.get("GITHUB_ENV", ""))
    ap.add_argument("--regenerate", action=argparse.BooleanOptionalAction, default=regenerate_default(),
                    help=f"delete stale profiles and create one for CI's certificate when none is usable "
                         f"(default: on, unless {REGENERATE_ENV} turns it off)")
    args = ap.parse_args()

    ids = keychain_identities(args.keychain)
    if len(ids) != 1:
        fail(f"the signing keychain holds {len(ids)} code-signing identities, expected exactly 1 (IOS_DISTRIBUTION_CERTIFICATE_BASE64)")
    identity = ids[0]
    print(f"CI's distribution certificate: SHA-1 {identity}")

    targets = [
        (args.bundle_id, args.name, "CMUX_MOBILE_PROFILE_PATH", "profile"),
        (f"{args.bundle_id}.notification-content", f"{args.name} Notification Content",
         "CMUX_MOBILE_CONTENT_EXTENSION_PROFILE_PATH", "ext-profile"),
        (f"{args.bundle_id}.notification-service", f"{args.name} Notification Service",
         "CMUX_MOBILE_SERVICE_EXTENSION_PROFILE_PATH", "svc-profile"),
    ]
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    env_lines: list[str] = []

    try:
        certs = asc("certificates", "list", "--paginate",
                    "--fields", "certificateType,displayName,expirationDate,certificateContent")
        cert_id = next(
            (c["id"] for c in certs.get("data", [])
             if c["attributes"].get("certificateContent")
             and hashlib.sha1(base64.b64decode(c["attributes"]["certificateContent"])).hexdigest().upper() == identity),
            "",
        )
        if not cert_id:
            fail(f"CI's certificate {identity} is not an active certificate in App Store Connect (revoked or expired). "
                 "An Admin creates an Apple Distribution certificate and replaces IOS_DISTRIBUTION_CERTIFICATE_BASE64 / _PASSWORD "
                 "in the release environment; this step then makes the profiles for it.")
        bundles = asc("bundle-ids", "list", "--paginate")
        bundle_ids = {b["attributes"]["identifier"]: b["id"] for b in bundles.get("data", [])}

        for bid, name, env_name, base in targets:
            team_bundle = f"{args.team}.{bid}"
            if bid not in bundle_ids:
                fail(f"no App ID {bid} in App Store Connect")
            found = asc("profiles", "list", "--paginate", "--name", name, "--profile-type", "IOS_APP_STORE",
                        "--fields", "name,profileState,profileContent,expirationDate")
            chosen, stale = None, []
            for p in found.get("data", []):
                a = p["attributes"]
                if a.get("name") != name:
                    continue
                if a.get("profileState") != "ACTIVE" or not a.get("profileContent"):
                    stale.append((p["id"], a.get("profileState", "?")))
                    continue
                why = usable(decode_profile(a["profileContent"]), identity, team_bundle, args.min_days)
                if why:
                    stale.append((p["id"], why))
                elif chosen is None:
                    chosen = a["profileContent"]
            if chosen is None and not args.regenerate:
                stale_list = "; ".join(f"{pid} {why}" for pid, why in stale) or "none exists"
                fail(f"no usable \"{name}\" App Store profile ({stale_list}), and regeneration is off "
                     f"({REGENERATE_ENV}). An Admin opens {PORTAL}, edits or creates \"{name}\" to include "
                     f"the certificate with SHA-1 {identity}, and reruns. Nothing was changed or signed.")
            if chosen is None:
                for pid, why in stale:
                    print(f"\"{name}\" {pid} {why}: deleting it")
                    asc("profiles", "delete", "--id", pid, "--confirm")
                print(f"\"{name}\": creating an App Store profile for {bid} with CI's certificate")
                created = asc("profiles", "create", "--name", name, "--profile-type", "IOS_APP_STORE",
                              "--bundle", bundle_ids[bid], "--certificate", cert_id)
                pid = created["data"]["id"]
                chosen = created["data"]["attributes"].get("profileContent") or asc(
                    "profiles", "list", "--id", pid, "--fields", "profileContent")["data"][0]["attributes"]["profileContent"]
                print(f"::notice::Regenerated \"{name}\" ({pid}) for CI's certificate {identity}")
            p = decode_profile(chosen)
            why = usable(p, identity, team_bundle, 0)
            if why:
                fail(f"\"{name}\" {why}. Nothing was signed.")
            dest = out_dir / f"{base}.mobileprovision"
            dest.write_bytes(base64.b64decode(chosen))
            print(f"\"{name}\": {p['UUID']}, expires {p['ExpirationDate']:%Y-%m-%d}, lists CI's certificate")
            env_lines.append(f"{env_name}={dest}")
    except RuntimeError as e:
        fail(f"{e}. If the App Store Connect key may not manage profiles, an Admin opens {PORTAL}, "
             f"edits each \"{args.name}*\" App Store profile to include the certificate with SHA-1 {identity}, and reruns.")

    if args.github_env:
        with open(args.github_env, "a") as f:
            f.write("\n".join(env_lines) + "\n")
    else:
        print("\n".join(env_lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
