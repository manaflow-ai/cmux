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


def asc_run(*args: str) -> str:
    """Run asc. Only call shapes the repo's other asc callers use
    (.github/scripts/install-app-store-provisioning-profile.sh): full JSON, filtered
    here, no --fields and no list filter but the type, since the runner's asc may predate them."""
    proc = subprocess.run(["asc", *args], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"asc {' '.join(args[:2])} failed: {proc.stderr.strip()[-600:]}")
    return proc.stdout


def asc(*args: str) -> dict:
    # asc may append warnings after the document.
    return json.JSONDecoder().raw_decode(asc_run(*args, "--output", "json").lstrip())[0]


def keychain_identities(keychain: str) -> list[str]:
    out = subprocess.run(
        ["security", "find-identity", "-v", "-p", "codesigning", keychain],
        capture_output=True, text=True, check=True,
    ).stdout
    return sorted({m.group(1) for m in re.finditer(r"\b([0-9A-F]{40})\b", out)})


def keychain_certificate(keychain: str, identity: str) -> bytes:
    """The DER certificate in the keychain whose SHA-1 is identity."""
    out = subprocess.run(
        ["security", "find-certificate", "-a", "-Z", "-p", keychain],
        capture_output=True, text=True, check=True,
    ).stdout
    for pem in re.findall(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", out, re.S):
        der = base64.b64decode("".join(pem.split()))
        if hashlib.sha1(der).hexdigest().upper() == identity:
            return der
    return b""


def _der(buf: bytes, i: int) -> tuple[int, int, int]:
    """(tag, start of contents, end of contents) of the DER element at i."""
    tag, n = buf[i], buf[i + 1]
    i += 2
    if n & 0x80:
        k = n & 0x7F
        n = int.from_bytes(buf[i:i + k], "big")
        i += k
    return tag, i, i + n


def certificate_serial(der: bytes) -> str:
    """The certificate's serial number as upper-case hex, as App Store Connect's
    serialNumber spells it (no leading zeros), or empty when der is not a certificate."""
    try:
        _, cert, _ = _der(der, 0)          # Certificate
        _, i, _ = _der(der, cert)          # tbsCertificate
        tag, start, end = _der(der, i)
        if tag == 0xA0:                    # [0] version
            tag, start, end = _der(der, end)
        if tag != 0x02:
            return ""
        return der[start:end].hex().upper().lstrip("0") or "0"
    except IndexError:
        return ""


def _norm(value) -> str:
    return "".join(ch for ch in str(value).upper() if ch.isalnum()).lstrip("0")


def certificate_id(certs: dict, identity: str, serial: str) -> str:
    """The App Store Connect id of CI's certificate: its certificateContent's SHA-1 is
    identity, or (when the listing has no content) its serialNumber is serial."""
    for c in certs.get("data", []):
        a = c.get("attributes", {})
        content = a.get("certificateContent")
        if content and hashlib.sha1(base64.b64decode(content)).hexdigest().upper() == identity:
            return c["id"]
        if serial and a.get("serialNumber") and _norm(a["serialNumber"]) == _norm(serial):
            return c["id"]
    return ""


def profile_content(p: dict, out_dir: Path) -> str:
    """A listed profile's base64 content: from the listing, else `asc profiles download`."""
    content = p.get("attributes", {}).get("profileContent")
    if content:
        return content
    dest = out_dir / f"download-{p['id']}.mobileprovision"
    asc_run("profiles", "download", "--id", p["id"], "--output", str(dest))
    try:
        return base64.b64encode(dest.read_bytes()).decode()
    finally:
        dest.unlink(missing_ok=True)


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
        certs = asc("certificates", "list", "--certificate-type", "IOS_DISTRIBUTION,DISTRIBUTION", "--paginate")
        cert_id = certificate_id(certs, identity, certificate_serial(keychain_certificate(args.keychain, identity)))
        if not cert_id:
            fail(f"CI's certificate {identity} is not an active certificate in App Store Connect (revoked or expired). "
                 "An Admin creates an Apple Distribution certificate and replaces IOS_DISTRIBUTION_CERTIFICATE_BASE64 / _PASSWORD "
                 "in the release environment; this step then makes the profiles for it.")
        bundles = asc("bundle-ids", "list", "--paginate")
        profiles = asc("profiles", "list", "--profile-type", "IOS_APP_STORE", "--paginate")
        bundle_ids = {b["attributes"]["identifier"]: b["id"] for b in bundles.get("data", [])}

        for bid, name, env_name, base in targets:
            team_bundle = f"{args.team}.{bid}"
            if bid not in bundle_ids:
                fail(f"no App ID {bid} in App Store Connect")
            chosen, stale = None, []
            for p in profiles.get("data", []):
                a = p.get("attributes", {})
                if a.get("name") != name:
                    continue
                if a.get("profileState") != "ACTIVE":
                    stale.append((p["id"], a.get("profileState", "?")))
                    continue
                if chosen is not None:
                    continue
                content = profile_content(p, out_dir)
                why = usable(decode_profile(content), identity, team_bundle, args.min_days)
                if why:
                    stale.append((p["id"], why))
                else:
                    chosen = content
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
                chosen = profile_content(created["data"], out_dir)
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
