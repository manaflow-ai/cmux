#!/usr/bin/env python3
"""Guard: only a release identity claims http/https at Default LSHandlerRank.

Resources/Info.plist declares http and https so cmux can be picked as the
default browser ("Make cmux the Default Browser"). At Default rank, Launch
Services treats the app as a primary browser for those schemes. A DEV, tagged
or staging build (com.cmuxterm.app.debug*, com.cmuxterm.app.staging*) should
not compete for links with the user's real browser, so it declares them at
Alternate: it still shows up as a browser and can still be made the default,
so the feature can be tested on it.

The rank is the CMUX_WEB_URL_HANDLER_RANK build setting: Alternate in the
Debug configuration, Default in Release. Scripts that build a dev bundle id
with the Release configuration (the cmux NEXT DEV app through
check-cmux-scheme-compile.sh, reload.sh --release, reloads.sh) set it back to
Alternate. Release channels (stable, NIGHTLY, RC, cmux NEXT nightly) build
with Release and change their bundle id only after the build, so they keep
Default.

Usage:
    python3 tests/test_web_url_handler_rank.py
"""

from __future__ import annotations

import pathlib
import plistlib
import re
import subprocess
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
INFO_PLIST = REPO_ROOT / "Resources" / "Info.plist"
PBXPROJ = REPO_ROOT / "cmux.xcodeproj" / "project.pbxproj"
SCHEME_COMPILE = REPO_ROOT / "scripts" / "cmux-next" / "check-cmux-scheme-compile.sh"
RELOAD = REPO_ROOT / "scripts" / "reload.sh"
RELOADS = REPO_ROOT / "scripts" / "reloads.sh"

SETTING = "CMUX_WEB_URL_HANDLER_RANK"
WEB_SCHEMES = {"http", "https"}

DEV_BUNDLE_IDS = (
    "com.cmuxterm.app.debug",  # cmux DEV (Debug dogfood, reload.sh without a tag)
    "com.cmuxterm.app.debug.next",  # cmux NEXT DEV (tip)
    "com.cmuxterm.app.debug.my-tag",  # reload.sh --tag my-tag
    "com.cmuxterm.app.staging",  # reloads.sh
    "com.cmuxterm.app.staging.my-tag",
)
RELEASE_BUNDLE_IDS = (
    "com.cmuxterm.app",  # stable
    "com.cmuxterm.app.next",  # stable cmux NEXT
    "com.cmuxterm.app.nightly",
    "com.cmuxterm.app.nightly.cmux-next",  # cmux NEXT nightly
    "com.cmuxterm.app.rc",
    "com.cmuxterm.app.debugger",  # not a dev id: only debug and debug.<tag> are
)


def web_url_types(plist: dict) -> list[dict]:
    return [
        entry
        for entry in plist.get("CFBundleURLTypes", [])
        if WEB_SCHEMES & {str(s).lower() for s in entry.get("CFBundleURLSchemes", [])}
    ]


def configuration_settings(pbxproj: str) -> dict[str, dict[str, str]]:
    """Build settings of each configuration that uses Resources/Info.plist, by name."""
    found: dict[str, dict[str, str]] = {}
    pattern = re.compile(
        r"isa = XCBuildConfiguration;\s*buildSettings = \{(?P<body>.*?)\n\t\t\t\};\s*name = (?P<name>\w+);",
        re.S,
    )
    for match in pattern.finditer(pbxproj):
        body = match.group("body")
        settings = {
            m.group(1): m.group(2).strip('"')
            for m in re.finditer(r"^\s*([A-Z_][A-Z0-9_]*) = (.*?);$", body, re.M)
        }
        if settings.get("INFOPLIST_FILE") == "Resources/Info.plist":
            found[match.group("name")] = settings
    return found


RANK_VAR = "web_url_handler_rank"
# /bin/bash on macOS is bash 3.2, which cannot parse a `case` pattern's `)`
# inside `$(...)`; the fleet's reload.sh run failed that way. The rank is set
# by a plain `case` statement and passed through a variable.
SHELL = "/bin/bash" if pathlib.Path("/bin/bash").exists() else "bash"


def rank_override(script: pathlib.Path) -> str:
    """The shell that sets the script's web_url_handler_rank from the bundle id."""
    text = script.read_text()
    rel = script.relative_to(REPO_ROOT)
    if re.search(rf"{SETTING}=[^\n]*\$\(\s*case\b", text):
        raise AssertionError(f"{rel} computes {SETTING} with a case inside $(...); bash 3.2 cannot parse it")
    match = re.search(
        rf'^\s*{RANK_VAR}=Default\n\s*(case "\$(?:BUNDLE_ID|bundle_id)" in .*? esac)$', text, re.M
    )
    if not match:
        raise AssertionError(f"{rel} sets no {RANK_VAR} from the bundle id")
    if not re.search(rf'{SETTING}=\\?"?\${RANK_VAR}"?', text):
        raise AssertionError(f"{rel} does not pass {SETTING}=${RANK_VAR} to xcodebuild")
    return f"{RANK_VAR}=Default; {match.group(1)}; echo \"${RANK_VAR}\""


def run_override(snippet: str, bundle_id: str) -> str:
    out = subprocess.run(
        [SHELL, "-c", f"bundle_id=$1; BUNDLE_ID=$1; {snippet}", "rank", bundle_id],
        capture_output=True,
        text=True,
        check=True,
    )
    return out.stdout.strip()


class WebURLHandlerRankTests(unittest.TestCase):
    def test_info_plist_rank_is_the_build_setting(self) -> None:
        plist = plistlib.loads(INFO_PLIST.read_bytes())
        entries = web_url_types(plist)
        self.assertTrue(entries, "Resources/Info.plist declares no http/https URL type")
        for entry in entries:
            self.assertEqual(
                entry.get("LSHandlerRank"),
                f"$({SETTING})",
                "the http/https URL type's rank must come from the build setting, so a dev "
                "variant can declare Alternate",
            )

    def test_configurations_set_the_rank(self) -> None:
        configs = configuration_settings(PBXPROJ.read_text())
        self.assertEqual(set(configs), {"Debug", "Release"})
        self.assertEqual(configs["Debug"].get(SETTING), "Alternate")
        self.assertEqual(configs["Release"].get(SETTING), "Default")

    def test_dev_bundle_ids_built_by_scripts_get_alternate(self) -> None:
        for script in (SCHEME_COMPILE, RELOAD):
            snippet = rank_override(script)
            for bundle_id in DEV_BUNDLE_IDS:
                with self.subTest(script=script.name, bundle_id=bundle_id):
                    self.assertEqual(run_override(snippet, bundle_id), "Alternate")
            for bundle_id in RELEASE_BUNDLE_IDS:
                with self.subTest(script=script.name, bundle_id=bundle_id):
                    self.assertEqual(run_override(snippet, bundle_id), "Default")

    def test_staging_release_build_gets_alternate(self) -> None:
        self.assertTrue(
            f"XCODEBUILD_ARGS+=({SETTING}=Alternate)" in RELOADS.read_text(),
            f"scripts/reloads.sh must pass {SETTING}=Alternate to its Release build",
        )

    def test_detector_finds_web_url_types(self) -> None:
        sample = {
            "CFBundleURLTypes": [
                {"CFBundleURLSchemes": ["HTTPS"], "LSHandlerRank": "Default"},
                {"CFBundleURLSchemes": ["cmux"], "LSHandlerRank": "Default"},
            ]
        }
        self.assertEqual(len(web_url_types(sample)), 1)


if __name__ == "__main__":
    unittest.main()
