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
ACTIONS_INPUTS = (
    r"Packages/macOS/CmuxNext/Sources/"
    r"|Packages/macOS/CmuxNext/Tests/CmuxNextActionsTests/|Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/LinkExportTests\.swift"
    r"|scripts/cmux-next/regenerate-action-exports\.sh"
)
SETTINGS_INPUTS = (
    r"Packages/macOS/CmuxNext/Sources/"
    r"|Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests/(SettingsSchemaExportTests|ManagedPreferencesManifestTests)\.swift"
    r"|scripts/cmux-next/regenerate-settings-exports\.sh|scripts/ci/defaults_guard\.py$"
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
    (("plans/cmux-next/action-surfaces.json", "plans/cmux-next/actions.md", "plans/cmux-next/links.json"),
     ACTIONS_INPUTS, "scripts/cmux-next/regenerate-action-exports.sh (a Mac; the autofix)"),
    (SETTINGS_EXPORTS,
     SETTINGS_INPUTS, "scripts/cmux-next/regenerate-settings-exports.sh (a Mac; the autofix)"),
    # The defaults snapshot reads the action and settings exports and the app's Swift sources.
    (("schemas/defaults/cmux-next.json",),
     r"Packages/macOS/CmuxNext/Sources/|" + ACTIONS_INPUTS + "|" + SETTINGS_INPUTS + r"|scripts/ci/defaults_guard\.py$",
     "python3 scripts/ci/defaults_guard.py snapshot"),
    (("web/data/cmux-shortcuts.generated.json",),
     ACTIONS_INPUTS + r"|web/scripts/export-docs-shortcuts\.ts$",
     "web/scripts/export-docs-shortcuts.ts"),
    (("cmux-tui/crates/cmux-app-host/generated/*",),
     r"cmux-tui/spec/resource-operations-v2\.json$|backend/catalog/cloud-operations\.json$|first-party-apps/"
     r"|cmux-tui/crates/cmux-app-host/tools/|" + ACTIONS_INPUTS,
     "cmux-tui/crates/cmux-app-host/tools/gen-cmux-global.ts"),
    (("cmux-tui/bindings/*/.cmux-resource-api.json", "cmux-tui/bindings/*.cmux-sdk-manifest.json",
      "cmux-tui/bindings/python/cmux/raw/_generated/*", "cmux-tui/bindings/cpp/include/cmux/raw/generated/*",
      "cmux-tui/bindings/cpp/src/raw/generated/*", "cmux-tui/bindings/go/raw/generated_*.go",
      "cmux-tui/bindings/typescript/src/raw/generated/*", "cmux-tui/bindings/rust/src/generated/*",
      "cmux-tui/bindings/zig/src/raw/generated/*", "cmux-tui/bindings/java/src/com/cmux/raw/*"),
     SDK_INPUTS, "cmux-tui/bindings/codegen/generate.py and sync-resource-api.py"),
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
        why = ("only the base autofix writes it" if found[0].pattern == BOT_ONLY
               else "this pull request changes none of its inputs")
        messages.append(
            f"{path}: generated by {found[1]}, but {why}. "
            f"Drop it (git checkout origin/feat-cmux-next -- {path}, or delete it if the base has none); "
            "the base autofix regenerates it after each merge.")
    return messages


def drop(paths: Iterable[str], changed: set[str]) -> list[str]:
    """Of `paths`, the ones a pull request that changed `changed` does not own."""
    return [path for path in paths if path not in changed and not caused(path, changed)]


def read_lines(text: str) -> list[str]:
    return [line.strip() for line in text.splitlines() if line.strip()]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("drift", "drop"))
    parser.add_argument("--changed", required=True, help="file with the pull request's changed paths, one per line")
    args = parser.parse_args(argv)
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
