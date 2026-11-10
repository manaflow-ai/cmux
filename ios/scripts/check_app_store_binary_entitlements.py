#!/usr/bin/env python3
"""Check, without a build, that the iOS App Store binary carries no system VPN.

App Review rejected the Network Extension / Personal VPN capability in the
public App Store app. The App Store lane (ios/scripts/upload-testflight.sh
--lane appstore, which upload-app-store.sh runs) signs the host with
Config/cmux-appstore-release.entitlements and strips the packet tunnel
extension the Xcode project embeds for the beta app. This reads the project,
the xcconfigs, the entitlements and the upload script, and fails when:

- the App Store host entitlements carry a Network Extension or VPN key;
- the upload script stops signing the App Store host with those entitlements,
  stops clearing the CloudVPN provider declaration, or lets the App Store lane
  turn the VPN on;
- an extension the host embeds carries Network Extension / VPN entitlements
  and the App Store archive does not strip it (and the IPA check reject it);
- any other embedded extension carries such an entitlement.

Exit 0 when clean, 1 with each problem printed, 2 on a read error.
"""

from __future__ import annotations

import argparse
import plistlib
import re
import sys
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
IOS_DIR = REPO_ROOT / "ios"
PROJECT = IOS_DIR / "cmux-ios.xcodeproj/project.pbxproj"
UPLOAD_SCRIPT = IOS_DIR / "scripts/upload-testflight.sh"
APP_STORE_ENTITLEMENTS = "Config/cmux-appstore-release.entitlements"
HOST_TARGET = "cmux"
RELEASE_CONFIGURATION = "Release"

NETWORK_EXTENSION_KEY = "com.apple.developer.networking.networkextension"
PERSONAL_VPN_KEY = "com.apple.developer.networking.vpn.api"
VPN_KEYS = (NETWORK_EXTENSION_KEY, PERSONAL_VPN_KEY)
VPN_VALUE_MARKERS = ("packet-tunnel", "app-proxy", "dns-proxy", "content-filter", "allow-vpn")


# --- minimal OpenStep plist parser (enough for project.pbxproj) -------------

_TOKEN = re.compile(
    r"""\s*(?:
        (?P<comment>/\*.*?\*/|//[^\n]*)
      | (?P<punct>[{}();=,])
      | "(?P<quoted>(?:[^"\\]|\\.)*)"
      | (?P<bare>[^\s{}();=,"]+)
    )""",
    re.S | re.X,
)


def _tokens(text: str):
    pos = 0
    end = len(text)
    while pos < end:
        match = _TOKEN.match(text, pos)
        if not match:
            if text[pos:].strip() == "":
                return
            raise ValueError(f"cannot parse project at offset {pos}")
        pos = match.end()
        if match.group("comment") is not None:
            continue
        if match.group("punct") is not None:
            yield ("p", match.group("punct"))
        elif match.group("quoted") is not None:
            yield ("s", bytes(match.group("quoted"), "utf-8").decode("unicode_escape"))
        elif match.group("bare") is not None:
            yield ("s", match.group("bare"))


def parse_pbxproj(text: str) -> dict:
    if text.startswith("// !$*UTF8*$!"):
        text = text.split("\n", 1)[1]
    tokens = list(_tokens(text))
    index = 0

    def value():
        nonlocal index
        kind, tok = tokens[index]
        index += 1
        if kind == "s":
            return tok
        if tok == "{":
            out = {}
            while tokens[index] != ("p", "}"):
                key = value()
                assert tokens[index] == ("p", "="), f"expected = after {key!r}"
                index += 1
                out[key] = value()
                assert tokens[index] == ("p", ";"), f"expected ; after {key!r}"
                index += 1
            index += 1
            return out
        if tok == "(":
            out = []
            while tokens[index] != ("p", ")"):
                out.append(value())
                if tokens[index] == ("p", ","):
                    index += 1
            index += 1
            return out
        raise ValueError(f"unexpected token {tok!r}")

    return value()


# --- xcconfig ----------------------------------------------------------------

_ASSIGN = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$")
_INCLUDE = re.compile(r'^\s*#include\??\s+"([^"]+)"')


def read_xcconfig(path: Path, seen: set[Path] | None = None) -> dict[str, str]:
    seen = seen or set()
    if path in seen or not path.is_file():
        return {}
    seen.add(path)
    settings: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = re.sub(r"(?<!:)//.*$", "", raw)
        include = _INCLUDE.match(raw)
        if include:
            settings.update(read_xcconfig(path.parent / include.group(1), seen))
            continue
        match = _ASSIGN.match(line)
        if match:
            settings[match.group(1)] = match.group(2)
    return settings


def expand(value: str, settings: dict[str, str], depth: int = 0) -> str:
    if depth > 10:
        return value
    def sub(match):
        return expand(settings.get(match.group(1), ""), settings, depth + 1)
    return re.sub(r"\$[({]([A-Za-z_][A-Za-z0-9_]*)[)}]", sub, value)


# --- the project model ---------------------------------------------------------

@dataclass(frozen=True)
class Extension:
    product: str  # e.g. CloudVPN.appex
    target: str
    entitlements: str  # path relative to ios/, "" when none


def _objects(project: dict) -> dict:
    return project["objects"]


def _target_release_settings(objects: dict, target: dict, ios_dir: Path) -> dict[str, str]:
    config_list = objects[target["buildConfigurationList"]]
    for config_id in config_list["buildConfigurations"]:
        config = objects[config_id]
        if config.get("name") != RELEASE_CONFIGURATION:
            continue
        settings: dict[str, str] = {}
        base = config.get("baseConfigurationReference")
        if base:
            ref = objects[base]
            settings.update(read_xcconfig(ios_dir / "Config" / ref["path"]))
        for key, val in config.get("buildSettings", {}).items():
            if isinstance(val, str):
                settings[key] = val
        return settings
    return {}


def embedded_extensions(project: dict, ios_dir: Path, host: str = HOST_TARGET) -> list[Extension]:
    objects = _objects(project)
    targets = {o["name"]: o for o in objects.values() if isinstance(o, dict) and o.get("isa") == "PBXNativeTarget"}
    if host not in targets:
        raise ValueError(f"project has no {host!r} target")
    by_product = {}
    for name, target in targets.items():
        ref = target.get("productReference")
        if ref and ref in objects:
            by_product[ref] = (name, target)
    out = []
    for phase_id in targets[host].get("buildPhases", []):
        phase = objects[phase_id]
        if phase.get("isa") != "PBXCopyFilesBuildPhase":
            continue
        for build_file_id in phase.get("files", []):
            file_ref = objects[build_file_id].get("fileRef")
            product = objects.get(file_ref, {}).get("path", "")
            if not product.endswith(".appex"):
                continue
            name, target = by_product.get(file_ref, (None, None))
            if target is None:
                out.append(Extension(product, "", ""))
                continue
            settings = _target_release_settings(objects, target, ios_dir)
            entitlements = expand(settings.get("CODE_SIGN_ENTITLEMENTS", ""), settings)
            out.append(Extension(product, name, entitlements))
    return out


def vpn_entitlements(entitlements: dict) -> list[str]:
    found = []
    for key, val in entitlements.items():
        values = val if isinstance(val, list) else [val]
        if key in VPN_KEYS or key.startswith("com.apple.developer.networking.vpn"):
            found.append(f"{key}{values!r}")
            continue
        for item in values:
            if isinstance(item, str) and any(m in item for m in VPN_VALUE_MARKERS):
                found.append(f"{key}[{item}]")
    return found


def load_plist(path: Path) -> dict:
    with path.open("rb") as handle:
        body = plistlib.load(handle)
    if not isinstance(body, dict):
        raise ValueError(f"{path} is not a dictionary plist")
    return body


def _appstore_feature_block(script: str) -> str:
    start = script.find('if [[ "$APPSTORE_SYSTEM_VPN_DISABLED" -eq 1 ]]; then\n  BUILD_FEATURE_ARGS+=(')
    if start < 0:
        return ""
    return script[start:script.find("\nfi\n", start)]


def check(ios_dir: Path = IOS_DIR) -> list[str]:
    problems: list[str] = []
    upload = (ios_dir / "scripts/upload-testflight.sh").read_text(encoding="utf-8")
    project = parse_pbxproj((ios_dir / "cmux-ios.xcodeproj/project.pbxproj").read_text(encoding="utf-8"))

    # 1. The App Store lane turns the VPN off and nothing turns it back on.
    if not re.search(r'if \[\[ "\$LANE" == "appstore" \]\]; then\n\s*APPSTORE_SYSTEM_VPN_DISABLED=1', upload):
        problems.append("upload-testflight.sh no longer sets APPSTORE_SYSTEM_VPN_DISABLED=1 for --lane appstore")
    for match in re.finditer(r"^\s*CLOUD_VPN_REQUIRED=1\s*$", upload, re.M):
        guard = upload[max(0, match.start() - 200):match.start()].rsplit("\nif ", 1)[-1]
        if '"$LANE" == "beta"' not in guard:
            problems.append("upload-testflight.sh sets CLOUD_VPN_REQUIRED=1 outside the beta-lane guard")

    # 2. The App Store host is signed with the VPN-free entitlements.
    block = _appstore_feature_block(upload)
    if not block:
        problems.append("upload-testflight.sh has no App Store BUILD_FEATURE_ARGS block (APPSTORE_SYSTEM_VPN_DISABLED)")
    else:
        lines = {line.strip().strip("'") for line in block.splitlines()}
        for setting in (
            f"CODE_SIGN_ENTITLEMENTS={APP_STORE_ENTITLEMENTS}",
            f"CMUX_APP_CODE_SIGN_ENTITLEMENTS={APP_STORE_ENTITLEMENTS}",
            "CMUX_CLOUD_VPN_PROVIDER_BUNDLE_IDENTIFIER=",
        ):
            if setting not in lines:
                problems.append(f"App Store archive no longer passes {setting}")

    # The block that strips the archive before the App Store export.
    strip_block_start = upload.find(
        'if [[ "$APPSTORE_SYSTEM_VPN_DISABLED" -eq 1 ]]; then\n  if [[ "$SIGNING" != "manual" ]]'
    )
    strip_block = upload[strip_block_start:upload.find("\nfi\n", strip_block_start)] if strip_block_start >= 0 else ""
    if not strip_block:
        problems.append("upload-testflight.sh has no App Store archive strip block (APPSTORE_SYSTEM_VPN_DISABLED)")
    if """'Delete :CMUXCloudVPNProviderBundleIdentifier' "$ARCHIVE_APP/Info.plist\"""" not in strip_block:
        problems.append("App Store archive no longer deletes the CMUXCloudVPNProviderBundleIdentifier declaration")

    host_path = ios_dir / APP_STORE_ENTITLEMENTS
    try:
        found = vpn_entitlements(load_plist(host_path))
    except (OSError, plistlib.InvalidFileException, ValueError) as exc:
        problems.append(f"cannot read {APP_STORE_ENTITLEMENTS}: {exc}")
    else:
        if found:
            problems.append(f"{APP_STORE_ENTITLEMENTS} carries VPN entitlements: {', '.join(found)}")

    # 3. Every embedded extension is VPN-free, or the App Store export strips it.
    extensions = embedded_extensions(project, ios_dir)
    if not extensions:
        problems.append("found no extensions embedded in the cmux target; the project parser is out of date")
    for ext in extensions:
        if not ext.target:
            problems.append(f"{ext.product} is embedded in the App Store app but no target builds it")
            continue
        if not ext.entitlements:
            continue
        try:
            found = vpn_entitlements(load_plist(ios_dir / ext.entitlements))
        except (OSError, plistlib.InvalidFileException, ValueError) as exc:
            problems.append(f"{ext.product}: cannot read {ext.entitlements}: {exc}")
            continue
        if not found:
            continue
        stripped = f'rm -rf "$ARCHIVE_APP/PlugIns/{ext.product}"' in strip_block
        rejected = re.search(
            r'CLOUD_VPN_REQUIRED:-0\}" -eq 0 && -d "\$app/PlugIns/' + re.escape(ext.product) + '"', upload
        )
        if not stripped:
            problems.append(
                f"{ext.product} ({ext.entitlements}: {', '.join(found)}) is embedded and the App Store archive does not strip it"
            )
        if not rejected:
            problems.append(f"the App Store IPA check no longer rejects an embedded {ext.product}")
    return problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ios-dir", type=Path, default=IOS_DIR)
    args = parser.parse_args(argv)
    try:
        problems = check(args.ios_dir)
    except (OSError, ValueError, KeyError, AssertionError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        return 1
    print("ok: the App Store host entitlements and embedded extensions carry no system VPN")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
