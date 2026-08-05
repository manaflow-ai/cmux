#!/usr/bin/env python3
"""Guard CLI event-stream scan complexity and localization coverage."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLI_SOURCE = ROOT / "CLI" / "cmux.swift"
CATALOG = ROOT / "Resources" / "Localizable.xcstrings"
EVENT_KEYS = {
    "cli.events.error.invalidTimeout",
    "cli.events.error.timeout",
    "cli.events.help.snapshot",
    "cli.events.help.timeout",
}
SUPPORTED_LOCALES = {
    "ar",
    "bs",
    "da",
    "de",
    "en",
    "es",
    "fr",
    "it",
    "ja",
    "km",
    "ko",
    "nb",
    "pl",
    "pt-BR",
    "ru",
    "th",
    "tr",
    "uk",
    "zh-Hans",
    "zh-Hant",
}
MISSING_SCAN_OFFSET_MESSAGE = "CLI event reader is missing its persistent scan offset"
MISSING_INCREMENTAL_SEARCH_MESSAGE = "readStreamLine is missing its incremental newline search"
FULL_RESCAN_MESSAGE = "readStreamLine still rescans the complete buffered frame"
MISSING_OFFSET_RESET_MESSAGE = "stream scan offset must reset on close and frame consumption"


def validate_incremental_stream_scan(source: str) -> None:
    start = source.index("    private func readStreamLine(")
    end = source.index("    private func waitForReadableStream(", start)
    body = source[start:end]

    declaration = "private var streamLineSearchOffset = 0"
    incremental_search = "streamReadBuffer[searchStart...].firstIndex(of: 0x0A)"
    if declaration not in source:
        raise AssertionError(MISSING_SCAN_OFFSET_MESSAGE)
    if incremental_search not in body:
        raise AssertionError(MISSING_INCREMENTAL_SEARCH_MESSAGE)
    if "streamReadBuffer.firstIndex(of: 0x0A)" in body:
        raise AssertionError(FULL_RESCAN_MESSAGE)
    reset_count = source.count("streamLineSearchOffset = 0") - source.count(declaration)
    if reset_count < 2:
        raise AssertionError(MISSING_OFFSET_RESET_MESSAGE)


def validate_event_localizations() -> None:
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    strings = catalog["strings"]
    for key in EVENT_KEYS:
        actual = set(strings[key]["localizations"])
        if actual != SUPPORTED_LOCALES:
            missing = sorted(SUPPORTED_LOCALES - actual)
            extra = sorted(actual - SUPPORTED_LOCALES)
            raise AssertionError(f"{key} locale mismatch: missing={missing}, extra={extra}")


def main() -> None:
    validate_incremental_stream_scan(CLI_SOURCE.read_text(encoding="utf-8"))
    validate_event_localizations()
    print("PASS: CLI event stream scans incrementally and all event strings cover supported locales")


if __name__ == "__main__":
    main()
