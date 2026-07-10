#!/usr/bin/env python3
"""Behavioral tests for the iOS production App Store lane identity."""

from __future__ import annotations

import base64
import json
import os
import plistlib
import stat
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TEAM_ID = "7WLXT3NR37"
APPSTORE_BUNDLE_ID = "com.cmux.app"
APPSTORE_APP_ID = f"{TEAM_ID}.{APPSTORE_BUNDLE_ID}"
ASC_APP_ID = "6783338052"
IDENTITY = f"Apple Distribution: Manaflow, Inc. ({TEAM_ID})"

FAILURES: list[str] = []


def _check(condition: bool, message: str) -> None:
    if condition:
        print(f"ok: {message}")
    else:
        FAILURES.append(message)
        print(f"FAIL: {message}")


def _plist_bytes(value: object) -> bytes:
    return plistlib.dumps(value, fmt=plistlib.FMT_XML)


def _profile_plist() -> dict[str, object]:
    return {
        "Name": "cmux App Store Distribution Test",
        "UUID": "00000000-0000-0000-0000-000000000001",
        "Entitlements": {
            "application-identifier": APPSTORE_APP_ID,
            "com.apple.developer.team-identifier": TEAM_ID,
            "get-task-allow": False,
            "aps-environment": "production",
            "com.apple.developer.applesignin": ["Default"],
            "keychain-access-groups": [APPSTORE_APP_ID],
        },
    }


def _write_executable(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def _install_fake_tools(fakebin: Path) -> None:
    fakebin.mkdir(parents=True, exist_ok=True)
    common = f"""
TEAM_ID = {TEAM_ID!r}
BUNDLE_ID = {APPSTORE_BUNDLE_ID!r}
APP_ID = {APPSTORE_APP_ID!r}
IDENTITY = {IDENTITY!r}

def plist_bytes(value):
    return plistlib.dumps(value, fmt=plistlib.FMT_XML)

def write_plist(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plist_bytes(value))

PROFILE = {_profile_plist()!r}
ENTITLEMENTS = PROFILE["Entitlements"]
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
    marketing_version = setting("MARKETING_VERSION=") or "1.0.4"
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
            "CFBundleIdentifier": bundle_id,
            "CFBundleVersion": build_number,
            "CFBundleShortVersionString": marketing_version,
        }},
    )
    sys.exit(0)

if "-exportArchive" in args:
    archive = Path(after("-archivePath"))
    export_path = Path(after("-exportPath"))
    export_options = Path(after("-exportOptionsPlist"))
    shutil.copyfile(export_options, os.environ["CMUX_FAKE_EXPORT_OPTIONS_COPY"])
    app_info = next((archive / "Products" / "Applications").glob("*.app/Info.plist"))
    bundle_id = plistlib.loads(app_info.read_bytes())["CFBundleIdentifier"]
    payload_root = export_path / "Payload"
    app = payload_root / "cmux.app"
    write_plist(app / "Info.plist", {{"CFBundleIdentifier": bundle_id}})
    (app / "embedded.mobileprovision").write_text("fake profile", encoding="utf-8")
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
    sys.stdout.buffer.write(plist_bytes(ENTITLEMENTS))
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
LEGACY_PROFILE = copy.deepcopy(PROFILE)
LEGACY_PROFILE["Entitlements"] = dict(PROFILE["Entitlements"])
LEGACY_PROFILE["Entitlements"]["application-identifier"] = f"{{TEAM_ID}}.com.cmuxterm.app"
LEGACY_PROFILE["Entitlements"]["keychain-access-groups"] = [f"{{TEAM_ID}}.com.cmuxterm.app"]

args = sys.argv[1:]
if args[:3] == ["find-identity", "-v", "-p"]:
    print(f'  1) ABCDEF "{{IDENTITY}}"')
    sys.exit(0)
if len(args) >= 2 and args[0] == "cms" and args[1] == "-D":
    profile = PROFILE
    if "-i" in args:
        source = Path(args[args.index("-i") + 1])
        if source.exists() and b"legacy profile" in source.read_bytes():
            profile = LEGACY_PROFILE
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
    log_failure: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        args,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if log_failure and result.returncode != 0:
        print(result.stdout)
        print(result.stderr, file=sys.stderr)
    return result


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
        ["bash", str(ROOT / "ios" / "scripts" / "validate-app-store-release.sh"), "--version", "1.0.4"],
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

    bad_env = _base_env(tmp / "bad-app", fakebin)
    bad_result = _run(
        [
            "bash",
            str(ROOT / "ios" / "scripts" / "validate-app-store-release.sh"),
            "--app",
            APPSTORE_BUNDLE_ID,
            "--version",
            "1.0.4",
        ],
        env=bad_env,
        tmp=tmp / "bad-app",
        log_failure=False,
    )
    _check(bad_result.returncode != 0, "validation helper rejects bundle id as --app")
    _check("must be numeric" in bad_result.stderr, "validation helper explains that --app must be numeric")


def main() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        tmp = Path(temp_dir)
        fakebin = tmp / "bin"
        _install_fake_tools(fakebin)
        test_upload_appstore_lane_uses_production_bundle_id(tmp / "upload-test", fakebin)
        test_upload_appstore_checks_asc_app_bundle_id_before_upload(tmp / "upload-live-test", fakebin)
        test_profile_installer_accepts_production_profile_by_default(tmp / "profile-test", fakebin)
        test_profile_installer_ignores_stale_primary_secret(tmp / "profile-stale-test", fakebin)
        test_validate_appstore_release_requires_numeric_app_id(tmp / "validate-test", fakebin)

    if FAILURES:
        print(f"\n{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("\nall ios appstore lane identity tests passed")


if __name__ == "__main__":
    main()
