#!/usr/bin/env python3
"""Behavior tests for the final signed IPA identity gate."""

import os
import plistlib
import stat
import subprocess
import tempfile
import zipfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
VERIFIER = REPO_ROOT / "ios" / "scripts" / "verify-ipa-release-identity.sh"
APP_ID_VALIDATOR = REPO_ROOT / "ios" / "scripts" / "require-numeric-app-store-id.sh"
TEAM_ID = "7WLXT3NR37"
BUNDLE_ID = "com.cmux.app"
APP_ID = f"{TEAM_ID}.{BUNDLE_ID}"


def write_executable(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def make_ipa(root: Path, bundle_id: str) -> Path:
    app = root / "fixture" / "Payload" / "cmux.app"
    app.mkdir(parents=True)
    with (app / "Info.plist").open("wb") as handle:
        plistlib.dump({"CFBundleIdentifier": bundle_id}, handle)
    (app / "embedded.mobileprovision").write_text("fixture", encoding="utf-8")
    ipa = root / "cmux.ipa"
    with zipfile.ZipFile(ipa, "w") as archive:
        for path in app.parent.parent.rglob("*"):
            archive.write(path, path.relative_to(app.parent.parent))
    return ipa


def run_verifier(info_bundle_id: str, signed_app_id: str, profile_app_id: str) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fake_bin = root / "bin"
        fake_bin.mkdir()
        signed_entitlements = root / "signed-entitlements.plist"
        profile = root / "profile.plist"
        with signed_entitlements.open("wb") as handle:
            plistlib.dump({"application-identifier": signed_app_id}, handle)
        with profile.open("wb") as handle:
            plistlib.dump({"Entitlements": {"application-identifier": profile_app_id}}, handle)

        write_executable(
            fake_bin / "codesign",
            """#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" --verify "* ]]; then exit 0; fi
cat "$FAKE_SIGNED_ENTITLEMENTS"
""",
        )
        write_executable(
            fake_bin / "security",
            """#!/usr/bin/env bash
set -euo pipefail
cat "$FAKE_PROFILE_PLIST"
""",
        )

        env = os.environ.copy()
        env["PATH"] = f"{fake_bin}:{env['PATH']}"
        env["FAKE_SIGNED_ENTITLEMENTS"] = str(signed_entitlements)
        env["FAKE_PROFILE_PLIST"] = str(profile)
        return subprocess.run(
            [str(VERIFIER), str(make_ipa(root, info_bundle_id)), BUNDLE_ID, TEAM_ID],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)
    print(f"ok: {message}")


def run_app_id_validator(value: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(APP_ID_VALIDATOR), value, "test-app-id"],
        text=True,
        capture_output=True,
        check=False,
    )


def main() -> None:
    matching = run_verifier(BUNDLE_ID, APP_ID, APP_ID)
    check(matching.returncode == 0, f"matching final IPA identity passes: {matching.stderr}")

    wrong_bundle = run_verifier("com.cmuxterm.app", APP_ID, APP_ID)
    check(wrong_bundle.returncode != 0, "wrong Info.plist bundle id fails closed")
    check("Info.plist bundle id" in wrong_bundle.stderr, "bundle mismatch identifies the authoritative source")

    wrong_signature = run_verifier(BUNDLE_ID, f"{TEAM_ID}.com.cmuxterm.app", APP_ID)
    check(wrong_signature.returncode != 0, "wrong signed application-identifier fails closed")
    check("signed application-identifier" in wrong_signature.stderr, "signature mismatch is explicit")

    wrong_profile = run_verifier(BUNDLE_ID, APP_ID, f"{TEAM_ID}.com.cmuxterm.app")
    check(wrong_profile.returncode != 0, "wrong embedded profile application-identifier fails closed")
    check("profile application-identifier" in wrong_profile.stderr, "profile mismatch is explicit")

    numeric_app_id = run_app_id_validator("6783338052")
    check(numeric_app_id.returncode == 0, "numeric App Store app id passes")
    bundle_app_id = run_app_id_validator(BUNDLE_ID)
    check(bundle_app_id.returncode != 0, "bundle id is rejected before ASC upload")
    check("must be numeric" in bundle_app_id.stderr, "bundle-id rejection is explicit")


if __name__ == "__main__":
    main()
