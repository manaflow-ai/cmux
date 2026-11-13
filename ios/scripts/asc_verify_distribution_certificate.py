#!/usr/bin/env python3
"""Check that the release signing certificate is the team's Apple Distribution certificate.

The production App Store job imports IOS_DISTRIBUTION_CERTIFICATE_BASE64 into a
temporary keychain and signs with it. Before it signs, this check asks App Store
Connect, with the release key, whether that exact certificate is an active
DISTRIBUTION certificate of the team:

  1. read the certificate (PEM) the job exported from its keychain: its serial
     number, its team (the subject's OU) and its SHA-1;
  2. list the team's DISTRIBUTION certificates
     (GET /v1/certificates?filter[certificateType]=DISTRIBUTION);
  3. pass only if one of them is certificateType DISTRIBUTION, not expired and
     not deactivated, and its certificateContent is the same certificate.

It prints only the serial number and the team, never the certificate's
private key, the API key or a token, and fails with a GitHub ::error:: line.

Credentials as asc_max_build.py: ASC_API_KEY_ID, ASC_API_ISSUER_ID and
ASC_API_KEY_PATH (or ASC_API_KEY_P8_BASE64). CMUX_ASC_API_BASE_URL (loopback
only) points it at a test server.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asc_max_build  # noqa: E402

OFFICIAL_API_BASE = "https://api.appstoreconnect.apple.com"
DEFAULT_TEAM = "7WLXT3NR37"


class CheckFailed(Exception):
    pass


def _api_base() -> str:
    override = os.environ.get("CMUX_ASC_API_BASE_URL")
    if not override:
        return OFFICIAL_API_BASE
    parsed = urllib.parse.urlsplit(override)
    if parsed.scheme not in {"http", "https"} or parsed.hostname not in {"127.0.0.1", "::1", "localhost"}:
        raise RuntimeError("CMUX_ASC_API_BASE_URL is restricted to loopback tests")
    return override.rstrip("/")


def _timeout() -> int:
    raw = os.environ.get("ASC_TIMEOUT_SECONDS", "60")
    if not raw.isdigit() or not 1 <= int(raw) <= 600:
        raise RuntimeError("ASC_TIMEOUT_SECONDS must be an integer between 1 and 600")
    return int(raw)


def normalize_serial(serial: str) -> str:
    """Hex serial, upper case, no separators or leading zeros."""
    cleaned = re.sub(r"[^0-9A-Fa-f]", "", serial).upper().lstrip("0")
    return cleaned or "0"


def read_certificate(pem_path: Path) -> tuple[str, str, str]:
    """(serial, team, sha1) of the PEM certificate at pem_path."""
    pem = pem_path.read_text(encoding="ascii", errors="strict")
    blocks = re.findall(r"-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----", pem, re.S)
    if len(blocks) != 1:
        raise CheckFailed(f"expected exactly one certificate in the exported PEM, found {len(blocks)}")
    der = base64.b64decode("".join(blocks[0].split()))
    result = subprocess.run(
        ["openssl", "x509", "-inform", "DER", "-noout", "-serial", "-subject", "-nameopt", "RFC2253"],
        input=der,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise CheckFailed("openssl could not read the exported certificate")
    out = result.stdout.decode("utf-8", "replace")
    serial_match = re.search(r"^serial=([0-9A-Fa-f:]+)\s*$", out, re.M)
    subject_match = re.search(r"^subject=(.*)$", out, re.M)
    if not serial_match or not subject_match:
        raise CheckFailed("the exported certificate has no serial number or subject")
    ou = re.findall(r"(?:^|,)OU=([^,]+)", subject_match.group(1).strip())
    team = ou[0] if len(ou) == 1 else ""
    return normalize_serial(serial_match.group(1)), team, hashlib.sha1(der).hexdigest().upper()


def _get(token: str, base: str, path: str, timeout: int) -> dict:
    request = urllib.request.Request(base + path)
    request.add_header("Authorization", "Bearer " + token)
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.loads(response.read() or b"{}")
        except urllib.error.HTTPError as error:
            try:
                code = str(((json.loads(error.read() or b"{}").get("errors") or [{}])[0]).get("code", "unknown"))
            except (json.JSONDecodeError, AttributeError):
                code = "unknown"
            if error.code >= 500 and attempt < 2:
                continue
            hint = ""
            if error.code in (401, 403):
                hint = "; the key needs the Admin role, or App Manager with access to Certificates, Identifiers & Profiles"
            raise CheckFailed(f"App Store Connect certificates list HTTP {error.code} (code={code}){hint}") from None
        except urllib.error.URLError as error:
            if attempt < 2:
                continue
            raise CheckFailed(f"App Store Connect unreachable: {error.reason}") from None
    raise CheckFailed("App Store Connect certificates list failed")


def _expired(expiration: str | None, now: dt.datetime) -> bool:
    if not expiration:
        return True
    try:
        when = dt.datetime.fromisoformat(expiration.replace("Z", "+00:00"))
    except ValueError:
        return True
    if when.tzinfo is None:
        when = when.replace(tzinfo=dt.timezone.utc)
    return when <= now


def verify(pem_path: Path, team: str, now: dt.datetime | None = None) -> str:
    serial, cert_team, sha1 = read_certificate(pem_path)
    print(f"release certificate: serial {serial}, team {cert_team or 'none'}")
    if cert_team != team:
        raise CheckFailed(f"the release certificate (serial {serial}) belongs to team {cert_team or 'none'}, not {team}")
    now = now or dt.datetime.now(dt.timezone.utc)
    query = urllib.parse.urlencode(
        {
            # Serial numbers are compared here, normalized: App Store Connect
            # may keep leading zeros that openssl drops.
            "filter[certificateType]": "DISTRIBUTION",
            "fields[certificates]": "certificateType,serialNumber,expirationDate,activated,certificateContent",
            "limit": "200",
        }
    )
    body = _get(asc_max_build._token(), _api_base(), "/v1/certificates?" + query, _timeout())
    rows = body.get("data") if isinstance(body, dict) else None
    if not isinstance(rows, list):
        raise CheckFailed("App Store Connect returned no certificate list")
    seen: list[str] = []
    for row in rows:
        attrs = row.get("attributes") if isinstance(row, dict) else None
        if not isinstance(attrs, dict) or normalize_serial(str(attrs.get("serialNumber") or "")) != serial:
            continue
        kind = str(attrs.get("certificateType") or "unknown")
        if kind != "DISTRIBUTION":
            seen.append(f"type {kind}")
            continue
        if attrs.get("activated") is False:
            seen.append("deactivated")
            continue
        if _expired(attrs.get("expirationDate"), now):
            seen.append("expired")
            continue
        try:
            listed = hashlib.sha1(base64.b64decode(attrs.get("certificateContent") or "")).hexdigest().upper()
        except (ValueError, TypeError):
            listed = ""
        if listed != sha1:
            seen.append("different certificate content")
            continue
        return serial
    detail = f" (found: {', '.join(seen)})" if seen else ""
    raise CheckFailed(
        f"no active DISTRIBUTION certificate with serial {serial} on team {team} in App Store Connect{detail}"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--certificate-pem", type=Path, required=True, help="the imported certificate, PEM")
    parser.add_argument("--team", default=DEFAULT_TEAM)
    args = parser.parse_args(argv)
    try:
        serial = verify(args.certificate_pem, args.team)
    except CheckFailed as error:
        print(f"::error::{error}")
        return 1
    except Exception as error:  # noqa: BLE001 - one clear line, no traceback with environment details
        print(f"::error::release certificate check failed: {type(error).__name__}: {error}")
        return 1
    print(f"ok: serial {serial} is an active DISTRIBUTION certificate on team {args.team}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
