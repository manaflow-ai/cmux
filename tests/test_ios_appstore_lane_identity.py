#!/usr/bin/env python3
"""Behavioral tests for the iOS production App Store lane identity."""

from __future__ import annotations

import base64
import http.server
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import urllib.parse
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TEAM_ID = "7WLXT3NR37"
APPSTORE_BUNDLE_ID = "com.cmux.app"
APPSTORE_APP_ID = f"{TEAM_ID}.{APPSTORE_BUNDLE_ID}"
BETA_BUNDLE_ID = "dev.cmux.app.beta"
BETA_APP_ID = f"{TEAM_ID}.{BETA_BUNDLE_ID}"
ASC_APP_ID = "6783338052"
ASC_VERSION_ID = "version-1.0.0"
ASC_BUILD_ID = "build-1.0.0"
IDENTITY = f"Apple Distribution: Manaflow, Inc. ({TEAM_ID})"
APPSTORE_MARKETING_VERSION = "1.0.0"
BETA_MARKETING_VERSION = "1.0.4"

FAILURES: list[str] = []


def _check(condition: bool, message: str) -> None:
    if condition:
        print(f"ok: {message}")
    else:
        FAILURES.append(message)
        print(f"FAIL: {message}")


def _plist_bytes(value: object) -> bytes:
    return plistlib.dumps(value, fmt=plistlib.FMT_XML)


def _profile_plist(
    bundle_id: str = APPSTORE_BUNDLE_ID,
    name: str = "cmux App Store Distribution Test",
) -> dict[str, object]:
    app_id = f"{TEAM_ID}.{bundle_id}"
    return {
        "Name": name,
        "UUID": "00000000-0000-0000-0000-000000000001",
        "Entitlements": {
            "application-identifier": app_id,
            "com.apple.developer.team-identifier": TEAM_ID,
            "get-task-allow": False,
            "aps-environment": "production",
            "com.apple.developer.applesignin": ["Default"],
            "keychain-access-groups": [app_id],
        },
    }


def _write_executable(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def _install_fake_tools(fakebin: Path) -> None:
    fakebin.mkdir(parents=True, exist_ok=True)
    common = f"""
import plistlib
from pathlib import Path

TEAM_ID = {TEAM_ID!r}
APPSTORE_BUNDLE_ID = {APPSTORE_BUNDLE_ID!r}
APPSTORE_APP_ID = {APPSTORE_APP_ID!r}
BETA_BUNDLE_ID = {BETA_BUNDLE_ID!r}
BETA_APP_ID = {BETA_APP_ID!r}
IDENTITY = {IDENTITY!r}

def plist_bytes(value):
    return plistlib.dumps(value, fmt=plistlib.FMT_XML)

def write_plist(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plist_bytes(value))

APPSTORE_PROFILE = {_profile_plist()!r}
BETA_PROFILE = {_profile_plist(BETA_BUNDLE_ID, "cmux Beta Distribution Test")!r}

def profile_for_bundle(bundle_id):
    if bundle_id == BETA_BUNDLE_ID:
        return BETA_PROFILE
    return APPSTORE_PROFILE

def bundle_id_for_target(path):
    target = Path(path)
    info = target / "Info.plist" if target.is_dir() else target
    try:
        value = plistlib.loads(info.read_bytes()).get("CFBundleIdentifier", "")
    except Exception:
        value = ""
    return value or APPSTORE_BUNDLE_ID

def entitlements_for_bundle(bundle_id):
    return profile_for_bundle(bundle_id)["Entitlements"]
"""

    _write_executable(
        fakebin / "PlistBuddy",
        """#!/usr/bin/env python3
import plistlib
import sys
from pathlib import Path


def load(path):
    p = Path(path)
    if not p.exists() or p.stat().st_size == 0:
        return {}
    return plistlib.loads(p.read_bytes())


def save(path, value):
    Path(path).write_bytes(plistlib.dumps(value, fmt=plistlib.FMT_XML))


def parts(path):
    return [part for part in path.split(":") if part]


def get(root, path):
    current = root
    for part in parts(path):
        if isinstance(current, list):
            current = current[int(part)]
        else:
            current = current[part]
    return current


def set_value(root, path, value):
    keys = parts(path)
    current = root
    for key in keys[:-1]:
        current = current.setdefault(key, {})
    current[keys[-1]] = value


args = sys.argv[1:]
if args[:1] != ["-c"] or len(args) < 3:
    raise SystemExit(1)

command = args[1]
plist_path = args[2]
plist = load(plist_path)

if command.startswith("Print "):
    value = get(plist, command.removeprefix("Print ").strip())
    if isinstance(value, (dict, list)):
        sys.stdout.buffer.write(plistlib.dumps(value, fmt=plistlib.FMT_XML))
    else:
        print(value)
    raise SystemExit(0)

if command.startswith("Add "):
    _, key_path, value_type, raw_value = (command.split(" ", 3) + [""])[:4]
    if value_type == "dict":
        value = {}
    elif value_type == "string":
        value = raw_value
    else:
        raise SystemExit(1)
    set_value(plist, key_path, value)
    save(plist_path, plist)
    raise SystemExit(0)

if command.startswith("Merge "):
    source = load(command.removeprefix("Merge ").strip())
    if isinstance(source, dict) and isinstance(plist, dict):
        for key, value in source.items():
            plist.setdefault(key, value)
    save(plist_path, plist)
    raise SystemExit(0)

raise SystemExit(1)
""",
    )

    _write_executable(
        fakebin / "plutil",
        """#!/usr/bin/env python3
import json
import plistlib
import sys
from pathlib import Path


def read_plist(path):
    if path == "-":
        data = sys.stdin.buffer.read()
    else:
        data = Path(path).read_bytes()
    if not data:
        return {}
    return plistlib.loads(data)


def write_plist(path, value):
    Path(path).write_bytes(plistlib.dumps(value, fmt=plistlib.FMT_XML))


def set_value(root, key, value):
    parts = key.split(".")
    current = root
    for part in parts[:-1]:
        current = current.setdefault(part, {})
    current[parts[-1]] = value


args = sys.argv[1:]
if args[:2] == ["-create", "xml1"] and len(args) == 3:
    write_plist(args[2], {})
    raise SystemExit(0)

if args[:1] == ["-insert"] and len(args) >= 5:
    key = args[1]
    kind = args[2]
    value_arg = args[3]
    plist_path = args[4]
    plist = read_plist(plist_path)
    if kind == "-string":
        value = value_arg
    elif kind == "-bool":
        value = value_arg.upper() in {"YES", "TRUE", "1"}
    else:
        raise SystemExit(1)
    set_value(plist, key, value)
    write_plist(plist_path, plist)
    raise SystemExit(0)

if args[:1] == ["-extract"]:
    key = args[1]
    output = args[args.index("-o") + 1]
    source = args[-1]
    value = read_plist(source)[key]
    write_plist(output, value)
    raise SystemExit(0)

if args[:1] == ["-lint"] and len(args) == 2:
    read_plist(args[1])
    raise SystemExit(0)

if args[:1] == ["-p"] and len(args) == 2:
    print(json.dumps(read_plist(args[1]), sort_keys=True))
    raise SystemExit(0)

raise SystemExit(1)
""",
    )

    _write_executable(
        fakebin / "xcodebuild",
        f"""#!/usr/bin/env python3
import json
import os
import plistlib
import shutil
import sys
import zipfile
from pathlib import Path
{common}

args = sys.argv[1:]
Path(os.environ["CMUX_FAKE_XCODEBUILD_LOG"]).open("a", encoding="utf-8").write(json.dumps(args) + "\\n")

def after(flag):
    try:
        return args[args.index(flag) + 1]
    except (ValueError, IndexError):
        return ""

def setting(prefix):
    for arg in args:
        if arg.startswith(prefix):
            return arg[len(prefix):]
    return ""

if "archive" in args:
    archive = Path(after("-archivePath"))
    bundle_id = setting("PRODUCT_BUNDLE_IDENTIFIER=")
    build_number = setting("CURRENT_PROJECT_VERSION=") or "1"
    marketing_version = setting("MARKETING_VERSION=") or {BETA_MARKETING_VERSION!r}
    crash_reporting_enabled = setting("CMUX_CRASH_REPORTING_ENABLED=") or "YES"
    app = archive / "Products" / "Applications" / "cmux.app"
    write_plist(
        archive / "Info.plist",
        {{
            "ApplicationProperties": {{
                "CFBundleIdentifier": bundle_id,
                "CFBundleVersion": build_number,
                "CFBundleShortVersionString": marketing_version,
            }}
        }},
    )
    write_plist(
        app / "Info.plist",
        {{
            "CFBundleExecutable": "cmux",
            "CFBundleIdentifier": bundle_id,
            "CFBundleVersion": build_number,
            "CFBundleShortVersionString": marketing_version,
            "CMUXCrashReportingEnabled": crash_reporting_enabled,
        }},
    )
    sys.exit(0)

if "-exportArchive" in args:
    archive = Path(after("-archivePath"))
    export_path = Path(after("-exportPath"))
    export_options = Path(after("-exportOptionsPlist"))
    shutil.copyfile(export_options, os.environ["CMUX_FAKE_EXPORT_OPTIONS_COPY"])
    app_info = next((archive / "Products" / "Applications").glob("*.app/Info.plist"))
    archived_info = plistlib.loads(app_info.read_bytes())
    bundle_id = archived_info["CFBundleIdentifier"]
    payload_root = export_path / "Payload"
    app = payload_root / "cmux.app"
    write_plist(app / "Info.plist", archived_info)
    if os.environ.get("CMUX_FAKE_EMBED_INVALID_FRAMEWORK_SHELL") == "1":
        write_plist(
            app / "Frameworks" / "Iroh.framework" / "Info.plist",
            {{
                "CFBundleIdentifier": "computer.iroh.Iroh",
                "CFBundlePackageType": "FMWK",
            }},
        )
    profile_marker = "beta profile" if bundle_id == BETA_BUNDLE_ID else "fake profile"
    (app / "embedded.mobileprovision").write_text(profile_marker, encoding="utf-8")
    ipa = export_path / "cmux.ipa"
    ipa.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(ipa, "w") as zf:
        for item in payload_root.rglob("*"):
            zf.write(item, item.relative_to(export_path))
    sys.exit(0)

sys.exit(0)
""",
    )

    _write_executable(
        fakebin / "codesign",
        f"""#!/usr/bin/env python3
import plistlib
import sys
{common}

args = sys.argv[1:]
if "--verify" in args:
    sys.exit(0)
if "-d" in args and "--entitlements" in args:
    bundle_id = bundle_id_for_target(args[-1])
    sys.stdout.buffer.write(plist_bytes(entitlements_for_bundle(bundle_id)))
    sys.exit(0)
if "--force" in args:
    sys.exit(0)
sys.exit(0)
""",
    )

    _write_executable(
        fakebin / "security",
        f"""#!/usr/bin/env python3
import copy
import plistlib
import sys
from pathlib import Path
{common}
LEGACY_PROFILE = copy.deepcopy(APPSTORE_PROFILE)
LEGACY_PROFILE["Entitlements"] = dict(APPSTORE_PROFILE["Entitlements"])
LEGACY_PROFILE["Entitlements"]["application-identifier"] = f"{{TEAM_ID}}.com.cmuxterm.app"
LEGACY_PROFILE["Entitlements"]["keychain-access-groups"] = [f"{{TEAM_ID}}.com.cmuxterm.app"]

args = sys.argv[1:]
if args[:3] == ["find-identity", "-v", "-p"]:
    print(f'  1) ABCDEF "{{IDENTITY}}"')
    sys.exit(0)
if len(args) >= 2 and args[0] == "cms" and args[1] == "-D":
    profile = APPSTORE_PROFILE
    if "-i" in args:
        source = Path(args[args.index("-i") + 1])
        if source.exists():
            body = source.read_bytes()
            if b"legacy profile" in body:
                profile = LEGACY_PROFILE
            elif b"beta profile" in body:
                profile = BETA_PROFILE
    sys.stdout.buffer.write(plist_bytes(profile))
    sys.exit(0)
if args and args[0] == "find-certificate":
    print("-----BEGIN CERTIFICATE-----")
    print("-----END CERTIFICATE-----")
    sys.exit(0)
sys.exit(0)
""",
    )

    _write_executable(
        fakebin / "asc",
        """#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

log = os.environ.get("CMUX_FAKE_ASC_LOG")
if log:
    Path(log).open("a", encoding="utf-8").write(json.dumps(sys.argv[1:]) + "\\n")

args = sys.argv[1:]
if args[:2] == ["apps", "view"]:
    app_id = args[args.index("--id") + 1]
    print(json.dumps({
        "data": {
            "id": app_id,
            "attributes": {
                "bundleId": os.environ.get("CMUX_FAKE_ASC_APP_BUNDLE_ID", "com.cmux.app")
            }
        }
    }))
    sys.exit(0)

if args[:2] == ["versions", "list"]:
    print(json.dumps({"data": [{"id": "version-1.0.0"}]}))
    sys.exit(0)

sys.exit(0)
""",
    )


def _base_env(tmp: Path, fakebin: Path) -> dict[str, str]:
    tmp.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["PATH"] = f"{fakebin}{os.pathsep}{env.get('PATH', '')}"
    for key in (
        "ASC_APP_ID",
        "IOS_APPSTORE_APP_ID",
        "IOS_APPSTORE_BUNDLE_ID",
        "IOS_APPSTORE_BUNDLE_IDENTIFIER",
    ):
        env.pop(key, None)
    env["CMUX_FAKE_XCODEBUILD_LOG"] = str(tmp / "xcodebuild.jsonl")
    env["CMUX_FAKE_EXPORT_OPTIONS_COPY"] = str(tmp / "ExportOptions.plist")
    env["CMUX_FAKE_ASC_LOG"] = str(tmp / "asc.jsonl")
    env["IOS_DISTRIBUTION_IDENTITY"] = IDENTITY
    env["PLISTBUDDY"] = str(fakebin / "PlistBuddy")
    return env


def _asc_upload_env(tmp: Path, fakebin: Path) -> dict[str, str]:
    env = _base_env(tmp, fakebin)
    env["ASC_APP_ID"] = ASC_APP_ID
    env["ASC_API_KEY_ID"] = "KEY123"
    env["ASC_API_ISSUER_ID"] = "ISSUER123"
    env["ASC_API_KEY_P8_BASE64"] = base64.b64encode(b"fake p8").decode()
    return env


def _run(
    args: list[str],
    *,
    env: dict[str, str],
    tmp: Path,
    cwd: Path = ROOT,
    log_failure: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        args,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if log_failure and result.returncode != 0:
        print(result.stdout)
        print(result.stderr, file=sys.stderr)
    return result


def _version_tuple(version: str) -> tuple[int, int, int]:
    parts = [int(part) for part in version.split(".")]
    while len(parts) < 3:
        parts.append(0)
    return parts[0], parts[1], parts[2]


def _bump_patch(version: str) -> str:
    major, minor, patch = _version_tuple(version)
    return f"{major}.{minor}.{patch + 1}"


def _write_fake_archive(path: Path, *, bundle_id: str, build_number: str, marketing_version: str) -> None:
    app = path / "Products" / "Applications" / "cmux.app"
    info = {
        "CFBundleExecutable": "cmux",
        "CFBundleIdentifier": bundle_id,
        "CFBundleVersion": build_number,
        "CFBundleShortVersionString": marketing_version,
    }
    (path).mkdir(parents=True, exist_ok=True)
    app.mkdir(parents=True, exist_ok=True)
    (path / "Info.plist").write_bytes(
        _plist_bytes(
            {
                "ApplicationProperties": {
                    "CFBundleIdentifier": bundle_id,
                    "CFBundleVersion": build_number,
                    "CFBundleShortVersionString": marketing_version,
                }
            }
        )
    )
    (app / "Info.plist").write_bytes(_plist_bytes(info))


def _copy_isolated_ios_upload_repo(target: Path) -> Path:
    repo = target / "repo"
    for relative in (
        "ios/scripts/upload-testflight.sh",
        "ios/Config/Shared.xcconfig",
        "ios/Config/cmux-release.entitlements",
    ):
        source = ROOT / relative
        destination = repo / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)

    subprocess.run(["git", "init"], cwd=repo, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "Test Runner"], cwd=repo, check=True)
    subprocess.run(["git", "commit", "--allow-empty", "-m", "init"], cwd=repo, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    subprocess.run(["git", "tag", "ios-v1.0.0"], cwd=repo, check=True)
    return repo


def _copy_isolated_ios_version_repo(target: Path) -> Path:
    repo = target / "repo"
    for relative in (
        "ios/scripts/bump-ios-version.sh",
        "ios/Config/Shared.xcconfig",
    ):
        source = ROOT / relative
        destination = repo / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
    return repo


def _read_xcconfig_setting(path: Path, key: str) -> str:
    values = []
    for line in path.read_text(encoding="utf-8").splitlines():
        before_comment = line.split("//", 1)[0].strip()
        if not before_comment.startswith(f"{key} "):
            continue
        name, _, value = before_comment.partition("=")
        if name.strip() == key:
            values.append(value.strip())
    return values[-1] if values else ""


def test_upload_beta_lane_uses_beta_marketing_version(tmp: Path, fakebin: Path) -> None:
    env = _base_env(tmp, fakebin)
    env["CMUX_IOS_UPLOAD_DIR"] = str(tmp / "upload")
    env["CMUX_BUILD_NUMBER_OUT_FILE"] = str(tmp / "build-number.txt")
    result = _run(
        [
            "bash",
            str(ROOT / "ios" / "scripts" / "upload-testflight.sh"),
            "--lane",
            "beta",
            "--signing",
            "manual",
            "--export-only",
            "--build-number",
            "20260710041749",
        ],
        env=env,
        tmp=tmp,
    )
    _check(result.returncode == 0, "beta export-only lane succeeds with fake Apple tools")

    xcodebuild_calls = [
        json.loads(line)
        for line in (tmp / "xcodebuild.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    archive_call = next(call for call in xcodebuild_calls if "archive" in call)
    _check(
        f"PRODUCT_BUNDLE_IDENTIFIER={BETA_BUNDLE_ID}" in archive_call,
        "beta archive command stamps the beta bundle id",
    )
    _check(
        f"MARKETING_VERSION={BETA_MARKETING_VERSION}" in archive_call,
        "beta archive command stamps the beta marketing version",
    )
    _check(
        f"MARKETING_VERSION={APPSTORE_MARKETING_VERSION}" not in archive_call,
        "beta archive command does not stamp the App Store marketing version",
    )
    _check(
        "CMUX_CRASH_REPORTING_ENABLED=YES" in archive_call,
        "beta archive keeps crash reporting enabled",
    )

    export_options = plistlib.loads((tmp / "ExportOptions.plist").read_bytes())
    profiles = export_options.get("provisioningProfiles", {})
    _check(
        profiles.get(BETA_BUNDLE_ID) == "cmux Beta Distribution",
        "export options map the beta profile to dev.cmux.app.beta",
    )

    ipa_line = next(line for line in result.stdout.splitlines() if line.startswith("IPA_PATH="))
    ipa_path = Path(ipa_line.removeprefix("IPA_PATH="))
    with zipfile.ZipFile(ipa_path) as zf:
        info = plistlib.loads(zf.read("Payload/cmux.app/Info.plist"))
    _check(
        info.get("CFBundleIdentifier") == BETA_BUNDLE_ID,
        "final signed beta IPA Info.plist is dev.cmux.app.beta",
    )
    _check(
        info.get("CFBundleShortVersionString") == BETA_MARKETING_VERSION,
        "final signed beta IPA keeps the beta marketing version",
    )


def test_upload_strips_framework_without_valid_executable(tmp: Path, fakebin: Path) -> None:
    env = _base_env(tmp, fakebin)
    env["CMUX_IOS_UPLOAD_DIR"] = str(tmp / "upload")
    env["CMUX_FAKE_EMBED_INVALID_FRAMEWORK_SHELL"] = "1"
    result = _run(
        [
            "bash",
            str(ROOT / "ios" / "scripts" / "upload-testflight.sh"),
            "--lane",
            "beta",
            "--signing",
            "manual",
            "--export-only",
            "--build-number",
            "20260710041753",
        ],
        env=env,
        tmp=tmp,
    )
    _check(result.returncode == 0, "upload strips an invalid embedded framework shell")
    _check(
        "stripping embedded framework without a valid dynamic-library executable "
        "(<executable missing>)" in result.stdout,
        "upload reports why the invalid framework shell was stripped",
    )
    ipa_line = next(line for line in result.stdout.splitlines() if line.startswith("IPA_PATH="))
    ipa_path = Path(ipa_line.removeprefix("IPA_PATH="))
    with zipfile.ZipFile(ipa_path) as zf:
        ipa_entries = zf.namelist()
    _check(
        not any(
            entry.startswith("Payload/cmux.app/Frameworks/Iroh.framework/")
            for entry in ipa_entries
        ),
        "final signed IPA omits the stripped framework shell",
    )


def test_upload_beta_archive_path_accepts_marketing_version_override(tmp: Path, fakebin: Path) -> None:
    override_version = "1.0.3"
    archive = tmp / "cmux-beta.xcarchive"
    _write_fake_archive(
        archive,
        bundle_id=BETA_BUNDLE_ID,
        build_number="20260710041748",
        marketing_version=override_version,
    )
    env = _base_env(tmp, fakebin)
    env["BETA_MARKETING_VERSION"] = override_version
    env["CMUX_IOS_UPLOAD_DIR"] = str(tmp / "upload")
    result = _run(
        [
            "bash",
            str(ROOT / "ios" / "scripts" / "upload-testflight.sh"),
            "--lane",
            "beta",
            "--archive-path",
            str(archive),
            "--signing",
            "manual",
            "--export-only",
        ],
        env=env,
        tmp=tmp,
    )
    _check(result.returncode == 0, "beta archive override export succeeds")

    ipa_line = next(line for line in result.stdout.splitlines() if line.startswith("IPA_PATH="))
    ipa_path = Path(ipa_line.removeprefix("IPA_PATH="))
    with zipfile.ZipFile(ipa_path) as zf:
        info = plistlib.loads(zf.read("Payload/cmux.app/Info.plist"))
    _check(
        info.get("CFBundleShortVersionString") == override_version,
        "reused beta archive keeps the override marketing version",
    )


def test_upload_beta_auto_version_uses_checked_in_beta_floor(tmp: Path, fakebin: Path) -> None:
    isolated_repo = _copy_isolated_ios_upload_repo(tmp / "isolated")
    expected_version = _bump_patch(BETA_MARKETING_VERSION)
    env = _base_env(tmp, fakebin)
    env["CMUX_IOS_UPLOAD_DIR"] = str(tmp / "upload")
    result = _run(
        [
            "bash",
            str(isolated_repo / "ios" / "scripts" / "upload-testflight.sh"),
            "--lane",
            "beta",
            "--auto-version",
            "--signing",
            "manual",
            "--export-only",
            "--build-number",
            "20260710041752",
        ],
        env=env,
        tmp=tmp,
        cwd=isolated_repo,
    )

    _check(result.returncode == 0, "beta auto-version export succeeds with a lower release tag")
    xcodebuild_calls = [
        json.loads(line)
        for line in (tmp / "xcodebuild.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    archive_call = next(call for call in xcodebuild_calls if "archive" in call)
    stamped_version = next(
        arg.removeprefix("MARKETING_VERSION=")
        for arg in archive_call
        if arg.startswith("MARKETING_VERSION=")
    )
    _check(
        stamped_version == expected_version,
        "beta auto-version uses the greater of release tags and checked-in beta version",
    )
    _check(
        _version_tuple(stamped_version) > _version_tuple(BETA_MARKETING_VERSION),
        "beta auto-version does not decrease below the checked-in beta version",
    )


def test_bump_ios_version_accepts_trailing_appstore_lane(tmp: Path, fakebin: Path) -> None:
    isolated_repo = _copy_isolated_ios_version_repo(tmp / "isolated-version")
    config = isolated_repo / "ios" / "Config" / "Shared.xcconfig"
    result = _run(
        [
            "bash",
            str(isolated_repo / "ios" / "scripts" / "bump-ios-version.sh"),
            "1.0.1",
            "--lane",
            "appstore",
        ],
        env=os.environ.copy(),
        tmp=tmp,
        cwd=isolated_repo,
    )

    _check(result.returncode == 0, "bump helper accepts trailing --lane appstore")
    _check(
        _read_xcconfig_setting(config, "CMUX_IOS_APPSTORE_MARKETING_VERSION") == "1.0.1",
        "trailing appstore lane updates the App Store marketing version",
    )
    _check(
        _read_xcconfig_setting(config, "CMUX_IOS_BETA_MARKETING_VERSION") == BETA_MARKETING_VERSION,
        "trailing appstore lane leaves the beta marketing version unchanged",
    )
    _check(
        "CMUX_IOS_APPSTORE_MARKETING_VERSION" not in result.stdout + result.stderr,
        "bump helper output describes the lane without exposing the internal xcconfig key",
    )


def test_upload_appstore_lane_uses_production_bundle_id(tmp: Path, fakebin: Path) -> None:
    env = _base_env(tmp, fakebin)
    env["CMUX_IOS_UPLOAD_DIR"] = str(tmp / "upload")
    env["CMUX_BUILD_NUMBER_OUT_FILE"] = str(tmp / "build-number.txt")
    result = _run(
        [
            "bash",
            str(ROOT / "ios" / "scripts" / "upload-app-store.sh"),
            "--signing",
            "manual",
            "--export-only",
            "--build-number",
            "20260710041750",
        ],
        env=env,
        tmp=tmp,
    )
    _check(result.returncode == 0, "appstore export-only lane succeeds with fake Apple tools")
    _check("signed IPA bundle identity verified: com.cmux.app" in result.stdout, "signed IPA identity gate passes")

    xcodebuild_calls = [
        json.loads(line)
        for line in (tmp / "xcodebuild.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    archive_call = next(call for call in xcodebuild_calls if "archive" in call)
    _check(
        f"PRODUCT_BUNDLE_IDENTIFIER={APPSTORE_BUNDLE_ID}" in archive_call,
        "archive command stamps com.cmux.app",
    )
    _check(
        f"MARKETING_VERSION={APPSTORE_MARKETING_VERSION}" in archive_call,
        "archive command stamps the App Store marketing version",
    )
    _check(
        f"MARKETING_VERSION={BETA_MARKETING_VERSION}" not in archive_call,
        "archive command does not stamp the beta marketing version",
    )
    _check(
        "CMUX_CRASH_REPORTING_ENABLED=NO" in archive_call,
        "App Store archive disables crash reporting",
    )
    _check(
        all("PRODUCT_BUNDLE_IDENTIFIER=com.cmuxterm.app" not in call for call in archive_call),
        "archive command does not stamp the retired com.cmuxterm.app id",
    )

    export_options = plistlib.loads((tmp / "ExportOptions.plist").read_bytes())
    profiles = export_options.get("provisioningProfiles", {})
    _check(
        profiles.get(APPSTORE_BUNDLE_ID) == "cmux App Store Distribution",
        "export options map the App Store profile to com.cmux.app",
    )
    _check("com.cmuxterm.app" not in profiles, "export options do not include the retired app id")

    ipa_line = next(line for line in result.stdout.splitlines() if line.startswith("IPA_PATH="))
    ipa_path = Path(ipa_line.removeprefix("IPA_PATH="))
    with zipfile.ZipFile(ipa_path) as zf:
        info = plistlib.loads(zf.read("Payload/cmux.app/Info.plist"))
    _check(info.get("CFBundleIdentifier") == APPSTORE_BUNDLE_ID, "final signed IPA Info.plist is com.cmux.app")
    _check(
        info.get("CFBundleShortVersionString") == APPSTORE_MARKETING_VERSION,
        "final signed IPA keeps the App Store marketing version",
    )
    _check(
        info.get("CMUXCrashReportingEnabled") == "NO",
        "final signed IPA disables crash reporting",
    )


def test_upload_appstore_checks_asc_app_bundle_id_before_upload(tmp: Path, fakebin: Path) -> None:
    env = _asc_upload_env(tmp, fakebin)
    env["CMUX_IOS_UPLOAD_DIR"] = str(tmp / "upload")
    env["CMUX_BUILD_NUMBER_OUT_FILE"] = str(tmp / "build-number.txt")
    result = _run(
        [
            "bash",
            str(ROOT / "ios" / "scripts" / "upload-app-store.sh"),
            "--signing",
            "manual",
        ],
        env=env,
        tmp=tmp,
    )
    _check(result.returncode == 0, "appstore upload lane succeeds with fake asc")
    _check(
        f"configured app record verified: {ASC_APP_ID} bundle id {APPSTORE_BUNDLE_ID}" in result.stdout,
        "upload lane verifies ASC app bundle id before upload",
    )

    asc_calls = [
        json.loads(line)
        for line in (tmp / "asc.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    app_view_index = next(index for index, call in enumerate(asc_calls) if call[:2] == ["apps", "view"])
    upload_index = next(index for index, call in enumerate(asc_calls) if call[:2] == ["builds", "upload"])
    _check(app_view_index < upload_index, "ASC app bundle id is resolved before build upload")
    app_view_call = asc_calls[app_view_index]
    _check(app_view_call[app_view_call.index("--id") + 1] == ASC_APP_ID, "ASC app lookup uses numeric app id")


def test_profile_installer_accepts_production_profile_by_default(tmp: Path, fakebin: Path) -> None:
    env = _base_env(tmp, fakebin)
    env["RUNNER_TEMP"] = str(tmp / "runner")
    env["HOME"] = str(tmp / "home")
    env["GITHUB_ENV"] = str(tmp / "github-env")
    Path(env["RUNNER_TEMP"]).mkdir(parents=True, exist_ok=True)
    env["IOS_APPSTORE_PROVISIONING_PROFILE_BASE64"] = base64.b64encode(b"fake profile").decode()
    result = _run(
        ["bash", str(ROOT / ".github" / "scripts" / "install-app-store-provisioning-profile.sh")],
        env=env,
        tmp=tmp,
    )
    _check(result.returncode == 0, "profile installer accepts a com.cmux.app App Store profile")
    github_env = Path(env["GITHUB_ENV"]).read_text(encoding="utf-8")
    _check(
        "IOS_APPSTORE_PROVISIONING_PROFILE_NAME=cmux App Store Distribution Test" in github_env,
        "profile installer exports the resolved App Store profile name",
    )


def test_profile_installer_ignores_stale_primary_secret(tmp: Path, fakebin: Path) -> None:
    env = _base_env(tmp, fakebin)
    env["RUNNER_TEMP"] = str(tmp / "runner")
    env["HOME"] = str(tmp / "home")
    env["GITHUB_ENV"] = str(tmp / "github-env")
    Path(env["RUNNER_TEMP"]).mkdir(parents=True, exist_ok=True)
    env["IOS_APPSTORE_PROVISIONING_PROFILE_BASE64"] = base64.b64encode(b"legacy profile").decode()
    env["IOS_PROD_PROVISIONING_PROFILE_BASE64"] = base64.b64encode(b"fake profile").decode()
    result = _run(
        ["bash", str(ROOT / ".github" / "scripts" / "install-app-store-provisioning-profile.sh")],
        env=env,
        tmp=tmp,
    )
    _check(result.returncode == 0, "profile installer ignores a stale primary profile secret")
    _check("primary profile secret targets" in result.stderr, "profile installer reports the stale profile candidate")
    github_env = Path(env["GITHUB_ENV"]).read_text(encoding="utf-8")
    _check(
        "IOS_APPSTORE_PROVISIONING_PROFILE_NAME=cmux App Store Distribution Test" in github_env,
        "profile installer falls back to a matching production profile",
    )


def test_validate_appstore_release_requires_numeric_app_id(tmp: Path, fakebin: Path) -> None:
    env = _base_env(tmp, fakebin)
    env["ASC_APP_ID"] = ASC_APP_ID
    result = _run(
        ["bash", str(ROOT / "ios" / "scripts" / "validate-app-store-release.sh")],
        env=env,
        tmp=tmp,
    )
    _check(result.returncode == 0, "App Store validation helper runs with fake asc")
    asc_calls = [
        json.loads(line)
        for line in (tmp / "asc.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    validate_call = next(call for call in asc_calls if call and call[0] == "validate")
    app_index = validate_call.index("--app") + 1
    _check(validate_call[app_index] == ASC_APP_ID, "validation helper uses the numeric App Store Connect app id")
    version_index = validate_call.index("--version") + 1
    _check(
        validate_call[version_index] == APPSTORE_MARKETING_VERSION,
        "validation helper defaults to the App Store marketing version",
    )

    bad_env = _base_env(tmp / "bad-app", fakebin)
    bad_result = _run(
        [
            "bash",
            str(ROOT / "ios" / "scripts" / "validate-app-store-release.sh"),
            "--app",
            APPSTORE_BUNDLE_ID,
            "--version",
            APPSTORE_MARKETING_VERSION,
        ],
        env=bad_env,
        tmp=tmp / "bad-app",
        log_failure=False,
    )
    _check(bad_result.returncode != 0, "validation helper rejects bundle id as --app")
    _check("must be numeric" in bad_result.stderr, "validation helper explains that --app must be numeric")


def test_validate_appstore_release_uses_device_screenshot_directories(
    tmp: Path, fakebin: Path
) -> None:
    screenshots = tmp / "screenshots"
    iphone = screenshots / "en-US" / "iphone"
    ipad = screenshots / "en-US" / "ipad"
    iphone.mkdir(parents=True)
    ipad.mkdir(parents=True)
    (iphone / "01-workspaces.png").write_bytes(b"iphone")
    (ipad / "01-workspaces.png").write_bytes(b"ipad")

    env = _base_env(tmp, fakebin)
    result = _run(
        [
            "bash",
            str(ROOT / "ios" / "scripts" / "validate-app-store-release.sh"),
            "--app",
            ASC_APP_ID,
            "--version",
            APPSTORE_MARKETING_VERSION,
            "--screenshots-dir",
            str(screenshots),
            "--screenshot-device-type",
            "IPHONE_69",
            "--screenshot-device-type",
            "IPAD_PRO_3GEN_129",
        ],
        env=env,
        tmp=tmp,
        log_failure=False,
    )
    _check(result.returncode == 0, "App Store validation accepts the canonical screenshot layout")

    asc_calls = [
        json.loads(line)
        for line in (tmp / "asc.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    screenshot_calls = [call for call in asc_calls if call[:2] == ["screenshots", "validate"]]
    paths_by_device = {
        call[call.index("--device-type") + 1]: call[call.index("--path") + 1]
        for call in screenshot_calls
    }
    _check(
        paths_by_device.get("IPHONE_69") == str(iphone),
        "iPhone validation targets the directory containing iPhone images",
    )
    _check(
        paths_by_device.get("IPAD_PRO_3GEN_129") == str(ipad),
        "iPad validation targets the directory containing iPad images",
    )


def test_validate_appstore_release_prepares_content_rights_and_build(
    tmp: Path, fakebin: Path
) -> None:
    env = _base_env(tmp, fakebin)
    env["ASC_APP_ID"] = ASC_APP_ID
    result = _run(
        [
            "bash",
            str(ROOT / "ios" / "scripts" / "validate-app-store-release.sh"),
            "--build-id",
            ASC_BUILD_ID,
            "--prepare-submission",
        ],
        env=env,
        tmp=tmp,
        log_failure=False,
    )
    _check(result.returncode == 0, "App Store validation helper prepares submission state")

    asc_log = tmp / "asc.jsonl"
    asc_calls = [
        json.loads(line)
        for line in asc_log.read_text(encoding="utf-8").splitlines()
    ] if asc_log.exists() else []
    content_rights_call = next(
        (call for call in asc_calls if call[:2] == ["apps", "update"]),
        None,
    )
    attach_build_call = next(
        (call for call in asc_calls if call[:2] == ["versions", "attach-build"]),
        None,
    )
    validate_call = next(
        (call for call in asc_calls if call and call[0] == "validate"),
        None,
    )
    _check(
        content_rights_call == [
            "apps",
            "update",
            "--id",
            ASC_APP_ID,
            "--content-rights",
            "USES_THIRD_PARTY_CONTENT",
        ],
        "submission preparation declares that cmux accesses user-controlled third-party content",
    )
    _check(
        attach_build_call == [
            "versions",
            "attach-build",
            "--version-id",
            ASC_VERSION_ID,
            "--build",
            ASC_BUILD_ID,
        ],
        "submission preparation attaches the selected build to version 1.0.0",
    )
    if content_rights_call and attach_build_call and validate_call:
        _check(
            asc_calls.index(content_rights_call) < asc_calls.index(validate_call)
            and asc_calls.index(attach_build_call) < asc_calls.index(validate_call),
            "submission state is prepared before canonical readiness validation",
        )
    else:
        _check(False, "submission state is prepared before canonical readiness validation")


def test_bootstrap_appstore_availability_creates_all_territories_once(tmp: Path) -> None:
    tmp.mkdir(parents=True, exist_ok=True)
    requests: list[tuple[str, str, dict[str, object] | None]] = []
    availability_created = False

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: object) -> None:
            pass

        def _write_json(self, status: int, body: dict[str, object]) -> None:
            payload = json.dumps(body).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self) -> None:
            nonlocal availability_created
            parsed = urllib.parse.urlsplit(self.path)
            requests.append(("GET", self.path, None))
            _check(
                self.headers.get("Authorization", "").startswith("Bearer "),
                "availability bootstrap authenticates every API request",
            )
            if parsed.path == f"/v1/apps/{ASC_APP_ID}/appAvailabilityV2":
                body: dict[str, object] = {
                    "data": (
                        {"type": "appAvailabilities", "id": "availability-1"}
                        if availability_created
                        else None
                    )
                }
                self._write_json(200, body)
                return
            if parsed.path == "/v1/territories":
                if urllib.parse.parse_qs(parsed.query).get("cursor") == ["next"]:
                    self._write_json(
                        200,
                        {
                            "data": [{"type": "territories", "id": "JPN"}],
                            "links": {},
                        },
                    )
                    return
                host, port = self.server.server_address
                self._write_json(
                    200,
                    {
                        "data": [
                            {"type": "territories", "id": "USA"},
                            {"type": "territories", "id": "CAN"},
                        ],
                        "links": {
                            "next": f"http://{host}:{port}/v1/territories?cursor=next"
                        },
                    },
                )
                return
            self._write_json(404, {"errors": [{"code": "NOT_FOUND"}]})

        def do_POST(self) -> None:
            nonlocal availability_created
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length))
            requests.append(("POST", self.path, body))
            if self.path != "/v2/appAvailabilities":
                self._write_json(404, {"errors": [{"code": "NOT_FOUND"}]})
                return
            data = body.get("data", {})
            relationships = data.get("relationships", {})
            territory_relationship = relationships.get("territoryAvailabilities", {})
            linkage = territory_relationship.get("data", [])
            included = body.get("included", [])
            linkage_ids = {
                item.get("id") for item in linkage if isinstance(item, dict)
            }
            included_ids = {
                item.get("id") for item in included if isinstance(item, dict)
            }
            if (
                linkage_ids != included_ids
                or not linkage_ids
                or not all(
                    isinstance(item_id, str)
                    and re.fullmatch(r"\$\{local-[a-z0-9-]+\}", item_id)
                    for item_id in linkage_ids
                )
            ):
                self._write_json(
                    409,
                    {"errors": [{"code": "ENTITY_ERROR.INCLUDED.INVALID_ID"}]},
                )
                return
            availability_created = True
            self._write_json(
                201,
                {"data": {"type": "appAvailabilities", "id": "availability-1"}},
            )

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        key_path = tmp / "AuthKey_TEST.p8"
        openssl = shutil.which("openssl")
        _check(openssl is not None, "availability test found OpenSSL")
        key_result = subprocess.run(
            [
                openssl or "openssl",
                "ecparam",
                "-name",
                "prime256v1",
                "-genkey",
                "-noout",
                "-out",
                str(key_path),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        _check(key_result.returncode == 0, "availability test generated an ES256 key")
        env = os.environ.copy()
        env.update(
            {
                "ASC_API_KEY_ID": "TESTKEY123",
                "ASC_API_ISSUER_ID": "00000000-0000-0000-0000-000000000000",
                "ASC_API_KEY_PATH": str(key_path),
                "ASC_TIMEOUT_SECONDS": "120",
                "CMUX_ASC_API_BASE_URL": f"http://127.0.0.1:{server.server_port}",
            }
        )
        command = [
            sys.executable,
            str(ROOT / "ios" / "scripts" / "asc_bootstrap_app_availability.py"),
            "--app",
            ASC_APP_ID,
        ]
        first = subprocess.run(command, env=env, capture_output=True, text=True, check=False)
        if first.returncode != 0:
            print(first.stdout)
            print(first.stderr, file=sys.stderr)
        _check(first.returncode == 0, "availability bootstrap creates initial availability")

        post_requests = [request for request in requests if request[0] == "POST"]
        _check(len(post_requests) == 1, "availability bootstrap creates exactly one record")
        payload = post_requests[0][2] if post_requests else {}
        data = payload.get("data", {}) if isinstance(payload, dict) else {}
        attributes = data.get("attributes", {}) if isinstance(data, dict) else {}
        relationships = data.get("relationships", {}) if isinstance(data, dict) else {}
        territory_relationship = (
            relationships.get("territoryAvailabilities", {})
            if isinstance(relationships, dict)
            else {}
        )
        linkage = (
            territory_relationship.get("data", [])
            if isinstance(territory_relationship, dict)
            else []
        )
        included = payload.get("included", []) if isinstance(payload, dict) else []
        _check(
            attributes.get("availableInNewTerritories") is True,
            "availability includes future App Store territories",
        )
        _check(
            {item.get("id") for item in linkage if isinstance(item, dict)}
            == {"${local-usa}", "${local-can}", "${local-jpn}"},
            "availability links every current territory",
        )
        _check(
            len(included) == 3
            and all(
                isinstance(item, dict)
                and item.get("attributes", {}).get("available") is True
                and item.get("attributes", {}).get("preOrderEnabled") is False
                for item in included
            ),
            "every territory is immediately available without pre-order",
        )

        second = subprocess.run(command, env=env, capture_output=True, text=True, check=False)
        _check(second.returncode == 0, "availability bootstrap is idempotent")
        _check(
            len([request for request in requests if request[0] == "POST"]) == 1,
            "existing availability is not created again",
        )

        requests_before_invalid_timeout = len(requests)
        invalid_timeout_env = env.copy()
        invalid_timeout_env["ASC_TIMEOUT_SECONDS"] = "invalid"
        invalid_timeout = subprocess.run(
            command,
            env=invalid_timeout_env,
            capture_output=True,
            text=True,
            check=False,
        )
        _check(
            invalid_timeout.returncode != 0
            and "ASC_TIMEOUT_SECONDS must be an integer" in invalid_timeout.stderr,
            "availability bootstrap validates the configured API timeout",
        )
        _check(
            len(requests) == requests_before_invalid_timeout,
            "invalid timeout configuration fails before an API request",
        )
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def main() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        tmp = Path(temp_dir)
        fakebin = tmp / "bin"
        _install_fake_tools(fakebin)
        test_upload_beta_lane_uses_beta_marketing_version(tmp / "beta-upload-test", fakebin)
        test_upload_strips_framework_without_valid_executable(
            tmp / "beta-framework-strip-test", fakebin
        )
        test_upload_beta_archive_path_accepts_marketing_version_override(tmp / "beta-archive-override-test", fakebin)
        test_upload_beta_auto_version_uses_checked_in_beta_floor(tmp / "beta-auto-version-test", fakebin)
        test_bump_ios_version_accepts_trailing_appstore_lane(tmp / "version-bump-test", fakebin)
        test_upload_appstore_lane_uses_production_bundle_id(tmp / "upload-test", fakebin)
        test_upload_appstore_checks_asc_app_bundle_id_before_upload(tmp / "upload-live-test", fakebin)
        test_profile_installer_accepts_production_profile_by_default(tmp / "profile-test", fakebin)
        test_profile_installer_ignores_stale_primary_secret(tmp / "profile-stale-test", fakebin)
        test_validate_appstore_release_requires_numeric_app_id(tmp / "validate-test", fakebin)
        test_validate_appstore_release_uses_device_screenshot_directories(
            tmp / "validate-screenshots-test", fakebin
        )
        test_validate_appstore_release_prepares_content_rights_and_build(
            tmp / "prepare-submission-test", fakebin
        )
        test_bootstrap_appstore_availability_creates_all_territories_once(
            tmp / "availability-bootstrap-test"
        )

    if FAILURES:
        print(f"\n{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("\nall ios appstore lane identity tests passed")


if __name__ == "__main__":
    main()
