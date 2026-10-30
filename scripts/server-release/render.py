#!/usr/bin/env python3
"""Render pinned server bootstrap scripts from reviewed public release metadata.

This command neither signs nor publishes. The release owner signs the exact
rendered bytes and supplies the channel manifests through the private pipeline.
"""

import argparse
import hashlib
import json
import re
import shlex
from pathlib import Path
from urllib.parse import urlsplit

TARGETS = (
    "x86_64-linux", "aarch64-linux", "aarch64-darwin", "x86_64-darwin",
    "x86_64-windows", "aarch64-windows",
)
TEMPLATES = Path(__file__).parent


def token(value, pattern, name):
    if not isinstance(value, str) or re.fullmatch(pattern, value) is None:
        raise ValueError(f"invalid {name}")
    return value


def validate(plan):
    fields = {"schema", "version", "macos_team_id", "release_keys",
              "windows_publisher_thumbprints", "archives"}
    if (not isinstance(plan, dict) or set(plan) != fields
            or type(plan.get("schema")) is not int or plan["schema"] != 1):
        raise ValueError("invalid release schema")
    token(plan.get("version"), r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", "version")
    token(plan.get("macos_team_id"), r"[A-Z0-9]{10}", "macOS team id")
    keys = plan.get("release_keys")
    if not isinstance(keys, dict) or len(keys) != 2:
        raise ValueError("two release public keys required")
    for name, key in keys.items():
        token(name, r"[A-Za-z0-9._-]+", "release key id")
        token(key, r"[a-f0-9]{64}", "release public key")
    if len(set(keys.values())) != 2:
        raise ValueError("release public keys must differ")
    publishers = plan.get("windows_publisher_thumbprints")
    if not isinstance(publishers, list) or not 1 <= len(publishers) <= 2:
        raise ValueError("Windows publisher thumbprints required")
    for publisher in publishers:
        token(publisher, r"[A-F0-9]{40}", "Windows publisher thumbprint")
    archives = plan.get("archives")
    if not isinstance(archives, dict) or set(archives) != set(TARGETS):
        raise ValueError("all six release targets required")
    for target, archive in archives.items():
        if not isinstance(archive, dict) or set(archive) != {"url", "sha256", "size"}:
            raise ValueError(f"invalid archive for {target}")
        url = archive.get("url")
        if not isinstance(url, str) or any(ord(c) <= 32 or ord(c) >= 127 for c in url):
            raise ValueError("invalid archive URL")
        parsed = urlsplit(url)
        if (parsed.scheme != "https" or not parsed.hostname or parsed.username is not None
                or parsed.password is not None or parsed.fragment or parsed.query
                or (parsed.port is not None and not 1 <= parsed.port <= 65535)):
            raise ValueError("archive URL must be public HTTPS without credentials or query")
        suffix = ".zip" if target.endswith("windows") else ".tar.gz"
        if not parsed.path.endswith(suffix):
            raise ValueError(f"archive suffix must be {suffix}")
        token(archive.get("sha256"), r"[a-f0-9]{64}", "archive sha256")
        size = archive.get("size")
        if type(size) is not int or not 0 < size <= 1024 * 1024 * 1024:
            raise ValueError("invalid archive size")
    return plan


def ps_quote(value):
    return "'" + value.replace("'", "''") + "'"


def render(plan):
    plan = validate(plan)
    keys = "\n".join(f"# release-key {key_id}:{key}" for key_id, key in sorted(plan["release_keys"].items()))
    unix_cases = []
    windows_cases = []
    for target in TARGETS:
        entry = plan["archives"][target]
        if target.endswith("windows"):
            windows_cases.append(
                f"        '{target}' {{ $url = {ps_quote(entry['url'])}; "
                f"$expectedSize = {entry['size']}; $expectedHash = '{entry['sha256']}' }}"
            )
        else:
            unix_cases.append(
                f"        {target}) url={shlex.quote(entry['url'])}; "
                f"expected_size={entry['size']}; expected_hash={entry['sha256']} ;;"
            )
    replacements = {
        "@@KEYS@@": keys,
        "@@UNIX_CASES@@": "\n".join(unix_cases),
        "@@WINDOWS_CASES@@": "\n".join(windows_cases),
        "@@TEAM_ID@@": plan["macos_team_id"],
        "@@PUBLISHERS@@": ", ".join(ps_quote(p) for p in plan["windows_publisher_thumbprints"]),
    }
    result = {}
    for extension in ("sh", "ps1"):
        script = (TEMPLATES / f"install.{extension}.in").read_text()
        # Replace once, so metadata containing a placeholder cannot become code.
        script = re.sub(r"@@[A-Z_]+@@", lambda match: replacements[match[0]], script)
        result[f"install.{extension}"] = script.encode("utf-8")
    result["bootstrap.json"] = (json.dumps(plan, sort_keys=True, indent=2) + "\n").encode()
    result["SHA256SUMS"] = "".join(
        f"{hashlib.sha256(data).hexdigest()}  {name}\n" for name, data in sorted(result.items())
    ).encode()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    artifacts = render(json.loads(args.plan.read_text()))
    # Never overwrite a release candidate or mix it with old signatures.
    args.output.mkdir(mode=0o700, parents=False, exist_ok=False)
    for name, data in artifacts.items():
        (args.output / name).write_bytes(data)


if __name__ == "__main__":
    main()
