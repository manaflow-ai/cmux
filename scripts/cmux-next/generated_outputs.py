#!/usr/bin/env python3
"""Which committed generated files a pull request may change (#21946).

A generated file is the output of a generator run over its inputs. A pull
request that changes an output without changing any of its inputs carries
drift it did not cause: a copy regenerated against a newer base, or a stale
one a merge kept. It then conflicts with every other pull request that does
the same, and a later merge can silently drop the base's newer rows. The base
autofix (cmux-next-base-autofix.yml) regenerates every output on
feat-cmux-next after each merge, so a pull request never needs to carry one it
did not cause.

OUTPUTS maps each output (fnmatch pattern, `*` crosses `/`) to a regex its
inputs match. Two readers:

  generated_outputs.py drift --changed FILE
      The pull request's changed paths (one per line in FILE). Prints each
      output it changes whose inputs it does not change, with the fix; exit 1
      when there is one.
  generated_outputs.py drop --changed FILE < paths
      For the PR autofix's push: of the paths on stdin (the repair patch),
      prints those the pull request does not own. A path is owned when the
      pull request changed it, or when it is an output whose inputs the pull
      request changed. pr-autofix-apply.sh leaves the rest out of the push.
  generated_outputs.py bot-only < paths
      Of the paths on stdin, prints the bot-only ones (no input of theirs is a
      pull request's: only the base autofix writes them). pr-autofix-apply.sh
      drops them from every push, with or without --changed.
"""
from __future__ import annotations

import argparse
import fnmatch
import re
import sys
from collections.abc import Iterable
from pathlib import Path

# The Swift exports compile their module and its dependencies: a setting can be
# declared in CmuxNextDesign (SidebarNavigationSettings, AttentionSettings), so
# any CmuxNext source is an input, not only CmuxNextSettings or CmuxNextActions.
# The Rust action catalog (cmux-action-catalog) is one too: the app reads its catalog from it, and the
# crate's swift_parity test holds action-surfaces.json to it, so a catalog change carries the export.
ACTIONS_INPUTS = (
    r"Packages/macOS/CmuxNext/Sources/"
    r"|Packages/macOS/CmuxNext/Tests/CmuxNextActionsTests/|Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/LinkExportTests\.swift"
    r"|cmux-tui/crates/cmux-action-catalog/"
    r"|scripts/cmux-next/regenerate-action-exports\.sh"
)
SETTINGS_INPUTS = (
    r"Packages/macOS/CmuxNext/Sources/"
    r"|Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests/(SettingsSchemaExportTests|ManagedPreferencesManifestTests)\.swift"
    r"|scripts/cmux-next/regenerate-settings-exports\.sh|scripts/ci/defaults_guard\.py$"
    # A settings row is its JSON source; the SwiftPM plugin writes the Swift (#50929).
    r"|schemas/settings/source/|scripts/cmux-next/gen-settings-sources\.py$"
)


def _settings_exports() -> tuple[str, ...]:
    """settings-exports.txt beside this file, the one list of what the settings export writes, so
    the OUTPUTS row for them cannot drift from it (review of #23915)."""
    text = (Path(__file__).resolve().parent / "settings-exports.txt").read_text(encoding="utf-8")
    listed = [line.split("#", 1)[0].strip() for line in text.splitlines()]
    exports = tuple(path for path in listed if path)
    if not exports:
        raise SystemExit("scripts/cmux-next/settings-exports.txt lists no export")
    return exports


SETTINGS_EXPORTS = _settings_exports()
SDK_INPUTS = r"cmux-tui/spec/|cmux-tui/bindings/codegen/|cmux-tui/bindings/rust/scripts/sync-resource-api\.py"
CAPABILITY_INPUTS = (
    r"Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Connection/DaemonEndpoint\.swift$"
    r"|Packages/macOS/CmuxNext/Tests/CmuxNextDaemonTests/DaemonCapabilityExportTests\.swift$"
    r"|scripts/cmux-next/check-daemon-capabilities-fresh\.py$"
    r"|scripts/cmux-next/tests/daemon-capabilities-fresh\.test\.sh$"
)

# An input regex that no path matches: only the base autofix writes the output.
BOT_ONLY = r"(?!)"

# (output patterns, input regex, how it is regenerated)
OUTPUTS: tuple[tuple[tuple[str, ...], str, str], ...] = (
    # Bot-only. A Package.swift change already routes every tier
    # (scripts/ci/cmux_next_route.py FULL_INPUTS), so a pull request needs no
    # graph of its own, and a copy it carried went stale as soon as the base
    # added a target. The base autofix regenerates it after each merge.
    (("Packages/macOS/CmuxNext/ci-target-graph.json",), BOT_ONLY,
     "scripts/cmux-next/ci-target-graph.py; only the base autofix writes it"),
    (("plans/cmux-next/daemon-capabilities.json",), CAPABILITY_INPUTS,
     "scripts/cmux-next/check-daemon-capabilities-fresh.py --write (the autofix)"),
    (("plans/cmux-next/action-surfaces.json", "plans/cmux-next/action-catalog.json",
      "plans/cmux-next/actions.md", "plans/cmux-next/links.json"),
     ACTIONS_INPUTS, "scripts/cmux-next/regenerate-action-exports.sh (a Mac; the autofix)"),
    (SETTINGS_EXPORTS,
     SETTINGS_INPUTS, "scripts/cmux-next/regenerate-settings-exports.sh (a Mac; the autofix)"),
    # Bot-only (RFD 0045). Nothing at a pull request head reads the defaults snapshot, and CI
    # never runs check-fresh. A copy a pull request carried went stale as
    # soon as the base changed a default. The base autofix regenerates it after each merge.
    (("schemas/defaults/cmux-next.json",), BOT_ONLY,
     "python3 scripts/ci/defaults_guard.py snapshot; only the base autofix writes it"),
    # Bot-only (RFD 0048). The docs copies of the action catalog and the settings schema: the web
    # tests build the same data from the catalog and the schema at the pull request head and never
    # compare the copies, and the docs pages only render them, so a copy one base autofix run behind
    # its inputs lags and never fails. The base autofix regenerates them after each merge
    # (base-autofix.sh steps 1e, 1e1 and 1e1').
    (("web/data/cmux-shortcuts.generated.json",), BOT_ONLY,
     "bun web/scripts/export-docs-shortcuts.ts; only the base autofix writes it"),
    (("web/data/next-docs/cli-reference.generated.json", "web/data/next-docs/palette-reference.generated.json",
      "web/data/next-docs/settings-reference.generated.json"), BOT_ONLY,
     "bun web/scripts/export-next-docs.ts; only the base autofix writes it"),
    (("cmux-tui/crates/cmux-app-host/generated/*",),
     r"cmux-tui/spec/resource-operations-v2\.json$|backend/catalog/cloud-operations\.json$|first-party-apps/"
     r"|cmux-tui/crates/cmux-app-host/(tools|schema)/|" + ACTIONS_INPUTS,
     "cmux-tui/crates/cmux-app-host/tools/gen-cmux-global.ts"),
    (("cmux-tui/bindings/*/.cmux-resource-api.json", "cmux-tui/bindings/*.cmux-sdk-manifest.json",
      "cmux-tui/bindings/python/cmux/raw/_generated/*", "cmux-tui/bindings/cpp/include/cmux/raw/generated/*",
      "cmux-tui/bindings/cpp/src/raw/generated/*", "cmux-tui/bindings/go/raw/generated_*.go",
      "cmux-tui/bindings/typescript/src/raw/generated/*", "cmux-tui/bindings/rust/src/generated/*",
      "cmux-tui/bindings/zig/src/raw/generated/*", "cmux-tui/bindings/java/src/com/cmux/raw/*"),
     SDK_INPUTS, "python3 cmux-tui/bindings/codegen/generate.py --write and "
     "python3 cmux-tui/bindings/rust/scripts/sync-resource-api.py (the autofix)"),
    (("clients/ts/cloud/src/generated.ts", "cmux-tui/crates/cmux-cloud-wire/src/generated/*"),
     r"backend/catalog/cloud-operations\.json$|backend/packages/protocol/(scripts/export-(rust-)?client\.ts|src/automation-caps\.ts)$",
     "backend/packages/protocol/scripts/export-client.ts"),
    (("scripts/ghosttykit-checksums.txt",), r"ghostty$", "the base autofix's GhosttyKit pin"),
    # Shrink only: a pull request that fixes a listed type drops its row.
    (("scripts/lint-namespace-types-ratchet.txt",),
     r"Packages/|ios/cmux/|scripts/lint-ios-package-conventions\.sh$|scripts/lint_swift_namespaces\.py$",
     "base-autofix.sh's namespace ratchet step"),
)


def output_of(path: str) -> tuple[re.Pattern[str], str] | None:
    """(input regex, how it is regenerated) when `path` is a generated output."""
    for patterns, inputs, how in OUTPUTS:
        if any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns):
            return re.compile(inputs), how
    return None


def caused(path: str, changed: Iterable[str]) -> bool:
    """Whether a pull request that changed `changed` caused `path`'s regeneration."""
    found = output_of(path)
    if found is None:
        return False
    inputs, _ = found
    return any(inputs.match(other) and output_of(other) is None for other in changed)


def drift(changed: list[str]) -> list[str]:
    """One message per output in `changed` that no other change in `changed` caused."""
    messages = []
    for path in changed:
        found = output_of(path)
        if found is None or caused(path, changed):
            continue
        why = ("only the base autofix writes it" if bot_only(path)
               else "this pull request changes none of its inputs")
        messages.append(
            f"{path}: generated by {found[1]}, but {why}. "
            f"Drop it (git checkout origin/feat-cmux-next -- {path}, or delete it if the base has none); "
            "the base autofix regenerates it after each merge.")
    return messages


def bot_only(path: str) -> bool:
    """Whether only the base autofix writes `path`."""
    found = output_of(path)
    return found is not None and found[0].pattern == BOT_ONLY


def drop(paths: Iterable[str], changed: set[str]) -> list[str]:
    """Of `paths`, the ones a pull request that changed `changed` does not own."""
    return [path for path in paths if path not in changed and not caused(path, changed)]


def read_lines(text: str) -> list[str]:
    return [line.strip() for line in text.splitlines() if line.strip()]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("drift", "drop", "bot-only"))
    parser.add_argument("--changed", help="file with the pull request's changed paths, one per line")
    args = parser.parse_args(argv)
    if args.command == "bot-only":
        for path in read_lines(sys.stdin.read()):
            if bot_only(path):
                print(path)
        return 0
    if args.changed is None:
        parser.error(f"{args.command} needs --changed")
    with open(args.changed, encoding="utf-8") as handle:
        changed = read_lines(handle.read())
    if args.command == "drift":
        messages = drift(changed)
        for message in messages:
            print(message)
        return 1 if messages else 0
    for path in drop(read_lines(sys.stdin.read()), set(changed)):
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
