#!/usr/bin/env python3
"""Refuse iOS app text and Info.plist entries that App Store Connect rejects after upload.

Apple finds these only in processing, after the build is uploaded (cmux INTERNAL builds on
2026-10-20 failed with ITMS-90626 for "transcribed on this iPhone" in an App Intent description).
This check finds them before upload: on the source tree (pre-push gate, CI) and on the built app
(cmux-next-ios/scripts/testflight-build.sh and the INTERNAL builder, before signing).

  check-app-store-rules.py --source ROOT   # cmux-next-ios sources under ROOT (a checkout or the gate's tree)
  check-app-store-rules.py --app APP       # a built CmuxMobileApp.app

Rules (each finding names its rule):
  90626-reserved-term    App Intents text (intent titles and descriptions, App Shortcut phrases and
                         short titles, and their translations in every language) and
                         NSSiriUsageDescription name no Apple trademark: RESERVED_TERMS.
  90626-phrase-app-name  every App Shortcut phrase contains the app name (${applicationName}).
  usage-device-name      no usage description (NS*UsageDescription) names one Apple device
                         (iPhone, iPad, iPod, Apple Watch): the app runs on several. "Mac" stays
                         allowed there: it names the user's paired computer, not this device.
  90683-purpose-string   the app uses an API that needs a purpose string (USAGE_APIS) and the
                         Info.plist has none, or it is empty.
  background-mode        every UIBackgroundModes value is one iOS knows (BACKGROUND_MODES).
  90474-ipad-orientation an app that runs on iPad without UIRequiresFullScreen lists all four
                         iPad orientations.

Exit 1 with one line per finding ("<file>: <rule>: <text>"), else 0. There is no escape hatch:
Apple has none either.
"""
from __future__ import annotations

import argparse
import json
import plistlib
import re
import sys
from pathlib import Path

# Apple trademarks App Intents text may not contain (ITMS-90626 and the App Intents
# naming rules). Matched case-sensitively, not inside a longer Latin word, so "このiPhoneで"
# matches and "Machine" or "pineapple" do not.
RESERVED_TERMS = (
    "Apple", "Siri", "iPhone", "iPad", "iPod", "Mac", "MacBook", "iMac", "macOS", "iOS", "iPadOS",
    "watchOS", "tvOS", "visionOS", "Apple Watch", "AirPods", "HomePod", "Apple TV", "Vision Pro",
    "CarPlay", "iCloud", "App Store", "FaceTime", "iMessage", "AirPlay", "AirDrop",
)
DEVICE_TERMS = ("iPhone", "iPad", "iPod", "Apple Watch")


def term_pattern(terms: tuple[str, ...]) -> re.Pattern[str]:
    alternatives = "|".join(re.escape(t) for t in sorted(terms, key=len, reverse=True))
    return re.compile(rf"(?<![A-Za-z])(?:{alternatives})(?![A-Za-z])")


RESERVED = term_pattern(RESERVED_TERMS)
DEVICES = term_pattern(DEVICE_TERMS)

# API (Objective-C class or Swift symbol) -> the purpose string iOS and App Store Connect require.
# A tuple value means any one of the keys is enough.
USAGE_APIS: dict[str, str | tuple[str, ...]] = {
    "SFSpeechRecognizer": "NSSpeechRecognitionUsageDescription",
    "AVAudioRecorder": "NSMicrophoneUsageDescription",
    "AVAudioApplication": "NSMicrophoneUsageDescription",
    "AVCaptureDevice": "NSCameraUsageDescription",
    "PHPhotoLibrary": "NSPhotoLibraryUsageDescription",
    "CLLocationManager": ("NSLocationWhenInUseUsageDescription", "NSLocationAlwaysAndWhenInUseUsageDescription"),
    "CNContactStore": "NSContactsUsageDescription",
    "CBCentralManager": "NSBluetoothAlwaysUsageDescription",
    "CBPeripheralManager": "NSBluetoothAlwaysUsageDescription",
    "EKEventStore": ("NSCalendarsFullAccessUsageDescription", "NSCalendarsWriteOnlyAccessUsageDescription",
                     "NSRemindersFullAccessUsageDescription"),
    "LAContext": "NSFaceIDUsageDescription",
    "CMMotionManager": "NSMotionUsageDescription",
    "HKHealthStore": "NSHealthShareUsageDescription",
    "MPMediaLibrary": "NSAppleMusicUsageDescription",
    "ATTrackingManager": "NSUserTrackingUsageDescription",
    "NFCNDEFReaderSession": "NFCReaderUsageDescription",
}

BACKGROUND_MODES = {
    "audio", "location", "voip", "fetch", "remote-notification", "processing", "external-accessory",
    "bluetooth-central", "bluetooth-peripheral", "nearby-interaction", "push-to-talk", "newsstand-content",
}
IPAD_ORIENTATIONS = {
    "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
    "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight",
}
# The actionsdata keys whose LocalizedStringResource ("key") the user reads.
INTENT_TEXT_FIELDS = {"title", "descriptionText", "phraseTemplates", "shortTitle", "synonyms",
                      "displayRepresentation", "typeDisplayRepresentation", "caseDisplayRepresentations",
                      "parameterSummary", "requestValueDialog", "subtitle"}
PHRASE_APP_NAME = "${applicationName}"


class Findings:
    def __init__(self) -> None:
        self.lines: list[str] = []

    def add(self, where: str, rule: str, text: str) -> None:
        line = f"{where}: {rule}: {text}"
        if line not in self.lines:
            self.lines.append(line)

    def intent_text(self, where: str, text: str) -> None:
        for term in sorted(set(RESERVED.findall(text))):
            self.add(where, "90626-reserved-term", f"\"{term}\" in \"{text}\"")

    def usage(self, where: str, key: str, value: object) -> None:
        if not isinstance(value, str) or not value.strip():
            self.add(where, "90683-purpose-string", f"{key} is empty")
            return
        if key == "NSSiriUsageDescription":
            self.intent_text(where, value)
        for term in sorted(set(DEVICES.findall(value))):
            self.add(where, "usage-device-name", f"{key} names \"{term}\": \"{value}\"")

    def info(self, where: str, info: dict, used_apis: set[str]) -> None:
        for key, value in info.items():
            if key.endswith("UsageDescription") or key == "NFCReaderUsageDescription":
                self.usage(where, key, value)
        for api in sorted(used_apis):
            need = USAGE_APIS[api]
            keys = need if isinstance(need, tuple) else (need,)
            if not any(isinstance(info.get(k), str) and info[k].strip() for k in keys):
                self.add(where, "90683-purpose-string", f"uses {api} but has no {' or '.join(keys)}")
        for mode in info.get("UIBackgroundModes", []) or []:
            if mode not in BACKGROUND_MODES:
                self.add(where, "background-mode", f"UIBackgroundModes has unknown value \"{mode}\"")
        families = {str(f) for f in info.get("UIDeviceFamily", []) or []}
        if "2" in families and not info.get("UIRequiresFullScreen"):
            listed = set(info.get("UISupportedInterfaceOrientations~ipad") or info.get("UISupportedInterfaceOrientations") or [])
            if not IPAD_ORIENTATIONS <= listed:
                self.add(where, "90474-ipad-orientation", "runs on iPad but does not list all four orientations")


# ---------------------------------------------------------------- source mode

SWIFT_STRING = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
SWIFT_COMMENT = re.compile(r"//[^\n]*|/\*.*?\*/", re.DOTALL)


def swift_literals(text: str) -> list[str]:
    # Comments go first, so "the iPhone Action Button" in a comment is not text Apple reads.
    code = SWIFT_COMMENT.sub("", text.replace('"""', '"'))
    return [m.group(1) for m in SWIFT_STRING.finditer(code)]


def catalog_values(catalog: dict, key: str) -> list[tuple[str, str]]:
    """[(language, text)] of one xcstrings key, every language and plural/device variation."""
    out: list[tuple[str, str]] = []

    def walk(language: str, node: object) -> None:
        if isinstance(node, dict):
            unit = node.get("stringUnit")
            if isinstance(unit, dict) and isinstance(unit.get("value"), str):
                out.append((language, unit["value"]))
            for child in node.values():
                if isinstance(child, (dict, list)) and child is not unit:
                    walk(language, child)
        elif isinstance(node, list):
            for child in node:
                walk(language, child)

    for language, node in (catalog.get("strings", {}).get(key, {}).get("localizations", {}) or {}).items():
        walk(language, node)
    return out


def project_info(project_yml: Path) -> dict:
    """The CmuxMobileApp target's Info.plist properties in project.yml (xcodegen `info: properties:`)."""
    try:
        import yaml  # noqa: PLC0415  (only the source mode needs it)
    except ImportError:
        return _project_info_without_yaml(project_yml.read_text(encoding="utf-8"))
    data = yaml.safe_load(project_yml.read_text(encoding="utf-8")) or {}
    for target in (data.get("targets") or {}).values():
        if isinstance(target, dict) and target.get("type") == "application":
            return ((target.get("info") or {}).get("properties")) or {}
    return {}


def _project_info_without_yaml(text: str) -> dict:
    # Enough YAML for the `properties:` block: `Key: value` and `Key: [a, b]` lines.
    info: dict = {}
    inside, indent = False, 0
    for raw in text.splitlines():
        line = raw.split(" #")[0].rstrip()
        if not line.strip() or line.strip().startswith("#"):
            continue
        depth = len(line) - len(line.lstrip())
        if line.strip() == "properties:":
            inside, indent = True, depth
            continue
        if inside and depth <= indent:
            inside = False
        if inside and depth == indent + 2 and ":" in line:
            key, _, value = line.strip().partition(":")
            value = value.strip()
            if value.startswith("[") and value.endswith("]"):
                info[key] = [v.strip().strip("'\"") for v in value[1:-1].split(",") if v.strip()]
            elif value:
                info[key] = value.strip("'\"")
    return info


def check_source(root: Path, findings: Findings) -> None:
    app_root = root / "cmux-next-ios"
    swift_files = sorted(p for p in app_root.rglob("*.swift") if ".build" not in p.parts and "verify" not in p.parts)
    intent_keys: set[str] = set()
    used_apis: set[str] = set()
    for path in swift_files:
        text = path.read_text(encoding="utf-8", errors="replace")
        rel = path.relative_to(root).as_posix()
        code = SWIFT_COMMENT.sub("", text)
        used_apis |= {api for api in USAGE_APIS if re.search(rf"\b{api}\b", code)}
        if not re.search(r"^\s*(public |internal |@preconcurrency )*import AppIntents\b", text, re.MULTILINE):
            continue
        for literal in swift_literals(text):
            # `\(.applicationName)` is how Swift spells the phrase placeholder.
            findings.intent_text(rel, literal.replace("\\(.applicationName)", PHRASE_APP_NAME))
            intent_keys.add(literal)
        for phrases in re.findall(r"phrases:\s*\[(.*?)\]", SWIFT_COMMENT.sub("", text), re.DOTALL):
            for phrase in swift_literals(phrases):
                if "\\(.applicationName)" not in phrase:
                    findings.add(rel, "90626-phrase-app-name", f"phrase \"{phrase}\" lacks the app name")
    for catalog_path in sorted(app_root.rglob("*.xcstrings")):
        if ".build" in catalog_path.parts or "verify" in catalog_path.parts:
            continue
        rel = catalog_path.relative_to(root).as_posix()
        try:
            catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        except ValueError as error:
            findings.add(rel, "catalog", f"not readable JSON: {error}")
            continue
        whole = catalog_path.stem in ("AppShortcuts", "InfoPlist")
        for key in catalog.get("strings", {}):
            if not whole and key not in intent_keys:
                continue
            for language, value in catalog_values(catalog, key):
                if catalog_path.stem == "InfoPlist":
                    findings.usage(f"{rel} [{language}]", key, value) if key.endswith("UsageDescription") else None
                else:
                    findings.intent_text(f"{rel} [{language}]", value)
    project = app_root / "project.yml"
    if project.is_file():
        findings.info(project.relative_to(root).as_posix(), project_info(project), used_apis)


# ---------------------------------------------------------------- built-app mode

def localized_tables(app: Path) -> list[tuple[str, str, dict]]:
    """[(file, language, {key: text})] of every compiled .strings table in the app's .lproj folders."""
    out = []
    for path in sorted(app.glob("*.lproj/*.strings")) + sorted(app.glob("*.lproj/*.stringsdict")):
        try:
            table = plistlib.loads(path.read_bytes())
        except Exception:  # noqa: BLE001  (old-style text .strings)
            table = dict(re.findall(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', path.read_text(errors="replace")))
        if isinstance(table, dict):
            flat = {k: v for k, v in table.items() if isinstance(v, str)}
            out.append((path.relative_to(app).as_posix(), path.parent.stem, flat))
    return out


def intent_texts(node: object, field: str | None = None):
    """(field, text) of every user-read LocalizedStringResource in an actionsdata tree."""
    if isinstance(node, dict):
        if field in INTENT_TEXT_FIELDS and isinstance(node.get("key"), str):
            yield field, node["key"]
        for key, child in node.items():
            yield from intent_texts(child, key if key in INTENT_TEXT_FIELDS else field)
    elif isinstance(node, list):
        for child in node:
            yield from intent_texts(child, field)


def used_apis_in_binaries(app: Path) -> set[str]:
    binaries = [app / app.stem]
    info_path = app / "Info.plist"
    if info_path.is_file():
        executable = plistlib.loads(info_path.read_bytes()).get("CFBundleExecutable")
        if executable:
            binaries = [app / executable]
    binaries += sorted(p / p.stem for p in (app / "Frameworks").glob("*.framework"))
    used: set[str] = set()
    for binary in binaries:
        if not binary.is_file():
            continue
        data = binary.read_bytes()
        used |= {api for api in USAGE_APIS if f"_OBJC_CLASS_$_{api}".encode() in data}
    return used


def check_app(app: Path, findings: Findings) -> None:
    metadata = app / "Metadata.appintents"
    intent_keys: set[str] = set()
    for path in sorted(metadata.glob("*.actionsdata")):
        rel = path.relative_to(app).as_posix()
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except ValueError as error:
            findings.add(rel, "catalog", f"not readable JSON: {error}")
            continue
        for field, text in intent_texts(data):
            findings.intent_text(rel, text)
            intent_keys.add(text)
            if field == "phraseTemplates" and PHRASE_APP_NAME not in text:
                findings.add(rel, "90626-phrase-app-name", f"phrase \"{text}\" lacks the app name")
    for rel, language, table in localized_tables(app):
        name = Path(rel).stem
        for key, value in table.items():
            where = f"{rel} [{language}]"
            if name == "AppShortcuts" or key in intent_keys:
                findings.intent_text(where, value)
            elif name == "InfoPlist" and key.endswith("UsageDescription"):
                findings.usage(where, key, value)
    info_path = app / "Info.plist"
    if info_path.is_file():
        findings.info("Info.plist", plistlib.loads(info_path.read_bytes()), used_apis_in_binaries(app))
    else:
        findings.add(app.name, "info-plist", "missing Info.plist")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--source", type=Path, help="a tree holding cmux-next-ios/")
    mode.add_argument("--app", type=Path, help="a built .app bundle")
    args = parser.parse_args(argv)
    findings = Findings()
    if args.source:
        check_source(args.source.resolve(), findings)
        what = "cmux-next-ios sources"
    else:
        check_app(args.app.resolve(), findings)
        what = args.app.name
    if findings.lines:
        print(f"error: {what}: App Store Connect would reject this (scripts/cmux-next/check-app-store-rules.py):",
              file=sys.stderr)
        for line in findings.lines:
            print(line)
        return 1
    print(f"ok: {what}: no App Store review rule broken")
    return 0


if __name__ == "__main__":
    sys.exit(main())
