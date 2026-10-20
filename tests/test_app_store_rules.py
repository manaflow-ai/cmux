#!/usr/bin/env python3
"""scripts/cmux-next/check-app-store-rules.py finds what App Store Connect rejects after upload.

cmux INTERNAL builds failed Apple processing on 2026-10-20 with ITMS-90626: an App Intent
description said "transcribed on this iPhone". The checker runs on the source tree (pre-push gate,
cmux-next checks) and on the built app (testflight-build.sh, the INTERNAL builder before signing).
This test runs it on app bundles shaped like Xcode's output, on source trees, and on this checkout.
"""
from __future__ import annotations

import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts/cmux-next/check-app-store-rules.py"

CLEAN_INFO = {
    "CFBundleExecutable": "CmuxMobileApp",
    "NSMicrophoneUsageDescription": "Record audio messages for Chief and your agents.",
    "NSSpeechRecognitionUsageDescription": "Turn your voice notes into text on this device.",
    "NSLocalNetworkUsageDescription": "Connect directly to your Mac on this network.",
    "UIBackgroundModes": ["audio"],
    "UIDeviceFamily": [1],
}


def actions(description: str, phrase: str = "Call Chief in ${applicationName}") -> dict:
    return {
        "actions": {
            "RecordChiefVoiceNoteIntent": {
                "identifier": "RecordChiefVoiceNoteIntent",
                "fullyQualifiedTypeName": "CmuxMobileApp.RecordChiefVoiceNoteIntent",
                "title": {"key": "Record Voice Note for Chief"},
                "descriptionMetadata": {"descriptionText": {"key": description}},
            }
        },
        "autoShortcuts": [{
            "actionIdentifier": "RecordChiefVoiceNoteIntent",
            "phraseTemplates": [{"key": phrase}],
            "shortTitle": {"key": "Voice Note for Chief"},
            "systemImageName": "waveform",
        }],
        "generator": {"name": "xcode-tools", "version": "17F113"},
    }


def make_app(root: Path, *, description: str = "It is transcribed on this device.", info: dict | None = None,
             binary: bytes = b"_OBJC_CLASS_$_AVAudioApplication _OBJC_CLASS_$_SFSpeechRecognizer",
             phrase: str = "Call Chief in ${applicationName}", tables: dict[str, dict[str, str]] | None = None) -> Path:
    app = root / "CmuxMobileApp.app"
    (app / "Metadata.appintents").mkdir(parents=True)
    (app / "Metadata.appintents/extract.actionsdata").write_text(json.dumps(actions(description, phrase)))
    (app / "Info.plist").write_bytes(plistlib.dumps(CLEAN_INFO if info is None else info))
    (app / "CmuxMobileApp").write_bytes(binary)
    for rel, table in (tables or {}).items():
        (app / rel).parent.mkdir(parents=True, exist_ok=True)
        (app / rel).write_bytes(plistlib.dumps(table, fmt=plistlib.FMT_BINARY))
    return app


def make_source(root: Path, intents: str, project_props: str) -> Path:
    (root / "cmux-next-ios/App").mkdir(parents=True)
    (root / "cmux-next-ios/App/ChiefVoiceIntents.swift").write_text(intents)
    (root / "cmux-next-ios/project.yml").write_text(
        "targets:\n  CmuxMobileApp:\n    type: application\n    info:\n      path: App/Info.plist\n      properties:\n"
        + "".join(f"        {line}\n" for line in project_props.strip().splitlines()))
    return root


INTENTS = '''import AppIntents
// App Intents for the iPhone Action Button (a comment: Apple never reads it).
struct RecordChiefVoiceNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Record Voice Note for Chief"
    static let description = IntentDescription("%s")
}
struct Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RecordChiefVoiceNoteIntent(), phrases: ["Voice note for Chief in \\(.applicationName)"%s],
                    shortTitle: "Voice Note for Chief", systemImageName: "waveform")
    }
}
'''
PROPS = """
NSMicrophoneUsageDescription: Record audio messages for Chief and your agents.
NSLocalNetworkUsageDescription: Connect directly to your Mac on this network.
UIBackgroundModes: [audio]
"""


def check(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, "-I", str(CHECKER), *args], capture_output=True, text=True)


class BuiltApp(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_the_rejected_description_is_refused(self) -> None:
        result = check("--app", str(make_app(self.root, description="It is transcribed on this iPhone and sent to your Chief.")))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('90626-reserved-term: "iPhone"', result.stdout)

    def test_a_clean_app_passes(self) -> None:
        result = check("--app", str(make_app(self.root)))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_every_reserved_term_class_is_refused(self) -> None:
        for text in ("Ask Siri to call Chief", "Open on your Mac", "Works on iPad", "Sync with iCloud", "Built for Apple"):
            with self.subTest(text=text), tempfile.TemporaryDirectory() as tmp:
                result = check("--app", str(make_app(Path(tmp), description=text)))
                self.assertEqual(result.returncode, 1, text)

    def test_words_that_contain_a_term_pass(self) -> None:
        result = check("--app", str(make_app(self.root, description="Machine notes, pineapple, Macro tasks")))
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_a_translation_is_checked_in_every_language(self) -> None:
        tables = {"ja.lproj/Localizable.strings": {"It is transcribed on this device.": "このiPhoneで文字起こしされます。"}}
        result = check("--app", str(make_app(self.root, tables=tables)))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("ja.lproj/Localizable.strings [ja]", result.stdout)

    def test_app_shortcuts_strings_are_checked(self) -> None:
        tables = {"de.lproj/AppShortcuts.strings": {"Call Chief in ${applicationName}": "Chief auf dem iPhone anrufen ${applicationName}"}}
        result = check("--app", str(make_app(self.root, tables=tables)))
        self.assertEqual(result.returncode, 1, result.stdout)

    def test_a_phrase_without_the_app_name_is_refused(self) -> None:
        result = check("--app", str(make_app(self.root, phrase="Call my Chief")))
        self.assertIn("90626-phrase-app-name", result.stdout)

    def test_a_missing_purpose_string_is_refused(self) -> None:
        info = {k: v for k, v in CLEAN_INFO.items() if k != "NSSpeechRecognitionUsageDescription"}
        result = check("--app", str(make_app(self.root, info=info)))
        self.assertEqual(result.returncode, 1)
        self.assertIn("90683-purpose-string: uses SFSpeechRecognizer", result.stdout)

    def test_an_empty_purpose_string_is_refused(self) -> None:
        result = check("--app", str(make_app(self.root, info=CLEAN_INFO | {"NSMicrophoneUsageDescription": " "})))
        self.assertIn("NSMicrophoneUsageDescription is empty", result.stdout)

    def test_a_usage_description_naming_this_iphone_is_refused(self) -> None:
        info = CLEAN_INFO | {"NSSpeechRecognitionUsageDescription": "Turn voice notes into text on this iPhone."}
        result = check("--app", str(make_app(self.root, info=info)))
        self.assertIn('usage-device-name: NSSpeechRecognitionUsageDescription names "iPhone"', result.stdout)

    def test_an_unknown_background_mode_is_refused(self) -> None:
        result = check("--app", str(make_app(self.root, info=CLEAN_INFO | {"UIBackgroundModes": ["audio", "recording"]})))
        self.assertIn('background-mode: UIBackgroundModes has unknown value "recording"', result.stdout)

    def test_an_ipad_app_lists_every_orientation(self) -> None:
        info = CLEAN_INFO | {"UIDeviceFamily": [1, 2], "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"]}
        result = check("--app", str(make_app(self.root, info=info)))
        self.assertIn("90474-ipad-orientation", result.stdout)


class Source(unittest.TestCase):
    def test_the_rejected_description_is_refused_and_comments_are_not(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = make_source(Path(tmp), INTENTS % ("It is transcribed on this iPhone.", ""), PROPS)
            result = check("--source", str(root))
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertEqual(result.stdout.count("90626-reserved-term"), 1, result.stdout)
            self.assertIn("cmux-next-ios/App/ChiefVoiceIntents.swift", result.stdout)

    def test_clean_sources_pass(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = make_source(Path(tmp), INTENTS % ("It is transcribed on this device.", ""), PROPS)
            result = check("--source", str(root))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_phrase_without_the_app_name_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = make_source(Path(tmp), INTENTS % ("Fine.", ', "Voice note for Chief"'), PROPS)
            self.assertIn("90626-phrase-app-name", check("--source", str(root)).stdout)

    def test_speech_without_a_purpose_string_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = make_source(Path(tmp), INTENTS % ("Fine.", ""), PROPS)
            (root / "cmux-next-ios/App/Transcriber.swift").write_text("import Speech\nlet r = SFSpeechRecognizer()\n")
            self.assertIn("uses SFSpeechRecognizer", check("--source", str(root)).stdout)

    def test_this_checkout_passes(self) -> None:
        result = check("--source", str(ROOT))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
