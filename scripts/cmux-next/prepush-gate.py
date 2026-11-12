#!/usr/bin/env python3
"""cmux-next pre-push gate: refuse a push that adds a static-check violation.

Runs, in seconds and with no build, the static checks of the "cmux-next checks" CI job
(.github/workflows/cmux-next.yml, job `checks`) plus pinned syntax tools, and fails only on what
the pushed commits ADD. Base debt never blocks a push.

Which commits are the push's own (push_range.py, shared with guardrails.py, the arch ratchet and the web lint,
so all of them judge the same range): the commits of each pushed head that none of its remote head, its
remote-tracking ref, this clone's origin/feat-cmux-next, the remote's HEAD and the integration branch it was cut
from reaches. That last one is read, not guessed: the pushed branch's configured upstream when it is a
remote-tracking ref of the pushed remote (`git worktree add -b topic origin/perf/chrome-parity` records it, for
any long-lived branch), plus the known integration refs (push_range.INTEGRATION_REFS: origin/perf/chrome-parity,
origin/main) for a branch cut with --no-track. Each is one more `--not` of git's walk, so git itself stops at the
nearest one by history; none is chosen by name, and none hides a commit nobody pushed (a local branch or another
remote's branch never counts). A push onto an integration branch itself adds none of them. With none of them
nearer, nothing changes: the base is where HEAD meets origin/feat-cmux-next. (2026-10-29: a branch cut from perf
was judged over its 9,426 commits past feat-cmux-next and refused for files it never touched.)
Their boundary is the base: the remote head for a second push (every new commit is judged, nothing pushed
before), where HEAD meets origin/feat-cmux-next for a new branch or a rebase onto it (the upstream commits the
rebase brought in are not judged; the rebased commits are), where HEAD left perf for a branch cut from perf.
A branch that merged origin/feat-cmux-next in is judged over the upstream it
merged, less what its old remote head already had over the upstream it started from (gate_own), so upstream's
changes are never the push's and an upstream removal never pays for the branch's debt. With none of those refs
in the clone, or a shallow clone cut below the pushed commits, every ref of the remote bounds the walk; when even
that gives no boundary the push is refused with what to fetch. The gate prints, per pushed head, the base it
chose and how many commits are its own.

How: the files the push changes are written into two small trees, one at the base and one at the
head, next to the check scripts (from the head) and their baselines (from each side). Every check
runs on both trees; a finding is new when the head has it and the base does not. A finding is keyed
by file, rule and the text of its source line, not its line number, so moving code is not new.

Layers (each one only on files the push changes under Packages/macOS/CmuxNext, cmux-tui, webviews, cmux-next-ios):
  scanners     the CI job's line scanners: concurrency, crash safety, dialog key hints, type scale,
               motion, scrollbars, state roots, process scan, Swift CLI, closed history, test
               notification centers, string tables, module resources, capability text, browser
               chrome icons, App Store review rules (also on cmux-next-ios/ changes), the perf
               source guard, fleet host names in gallery fixtures (also on Packages/ changes)
  ast-grep     scripts/cmux-next/lint/ast-grep-rules: try!, blocking calls, raw font sizes, system
               dialogs, opaque glass (tree-sitter, so comments, strings and `case .alert` never match)
  swiftformat  --lint with scripts/cmux-next/lint/swiftformat.conf; local only: the pre-push hook and a plain
               local run, never --base/--head, --commits or GitHub Actions (no new CI gate, lead 2026-10-27)
  rustfmt      changed cmux-tui/**/*.rs through the pinned rustfmt (cmux-tui/rustfmt.toml); local only, like
               swiftformat; a file the base already left unformatted does not block
  swiftlint    swift-syntax rules only (scripts/cmux-next/lint/swiftlint.yml), no SourceKit
Tool versions are pinned in scripts/cmux-next/lint-tools.lock and downloaded once (sha256 checked)
to $CMUX_LINT_TOOLS_DIR (default ~/Library/Caches/cmux-lint-tools, ~/.cache/cmux-lint-tools on Linux).

Also on every push, whatever it changes: "Ghostty-default keys" (check-ghostty-reserved-keys.py): the
exported default keymap keeps Ghostty's split keys (schemas/keybindings/ghostty-reserved-keys.json),
and the push removes no reserved entry. CMUX_NEXT_CHECKS_SKIP_REASON does not skip it; only a
`Ghostty-defaults-OK: <the user's words>` trailer on a pushed commit does (Lawrence 2026-10-20).
Also on every push: "Sidebar look owner" (plans/cmux-next/sidebar-owner.md): a commit that changes the
sidebar package's code (CmuxNextSidebar/, not its strings, resources or mock) carries a `Sidebar-Look: <the user's words, or "no visual
change">` trailer, and a visual change also edits plans/cmux-next/sidebar-owner.md in the same commit.
233 sidebar commits in four days with no owner undid each other (Lawrence 2026-10-23: "why were there so
many changes to sidebar?"). CMUX_NEXT_CHECKS_SKIP_REASON does not skip it. A commit the owner logged in
that note (its 11-character sha) passes. CI also sweeps every commit since the check landed
(`--only sidebar --commits`), so a push from an old hook copy or a cancelled CI run is still caught.
Also on every push: "Chrome layer look" (schemas/theme/chrome-layer-colors.json): a commit that changes that
file (the colours ChromeLayerColorTests reads off the sidebar, footer and titlebar in the default themes, plain
and over a picture), or a hunk of a chrome-layer token source naming a chrome token, carries a `Chrome-Look-OK:`
trailer quoting Leo: his name and his words in quotes. #39984 dimmed the sidebar for a non-Leo issue (Leo
2026-11-11: "bro why is the sidebar now a different color?"). CMUX_NEXT_CHECKS_SKIP_REASON does not skip it.
Also on every push, in any file: "Merge conflict markers": a file the push adds both a `<<<<<<< ` and
a `>>>>>>> ` line to (c779988d57d, 2026-10-22, broke CmuxNextAppTests). Nothing skips it.
Also on every push: "UI font" (check-ui-font.py): the UI font stays the macOS system font with no
letter-spacing and nothing bundled (schemas/type-scale/ui-font-pin.json; Lawrence 2026-11-07), and no
webviews default font stack names Inter. It is not skippable either; only a `Font-order: <the user's
words>` trailer changes the pin.

Also on every local run (the hook and a plain run; never --base/--head, --commits or GitHub Actions, so CI gains no
gate): "What's New highlights": each release-notes/next/highlights/*.md file the push adds or changes is validated as
the release-notary job's test (scripts/whats-new/test_digest.py, test_the_repository_highlights_validate) validates
it after the merge: digest.parse, then digest.entry_problems (scripts/whats-new/validate.py's rules: a tryIt or docs
link, at most 2 sentences, 240 characters, no internal names). Unchanged highlights are never read. The hook runs
the validator of this clone's origin/feat-cmux-next, never the pushed one (a plain run: the head's). 2026-11-01:
#30774, #31156 and #31140 each landed a highlight that turned that check red on every pull request.
Also on every local run, the same way: "What's New pictures": each New or Improved highlight the push adds names
where its picture comes from: a `gallery:` or `clip:` line, a clip spec (release-notes/next/clips/<id>.json), or a
webview *.gallery.ts(x) change on the branch (whats-new-gallery.yml picks the state). On 2026-11-08, 61 of the 166
New or Improved highlights of 21 days changed only Swift and went out with no picture (goal whats-new-pretty).
Also on every local run, the same way: "Workflow YAML parses": each .github/workflows/*.yml (and composite
action.yml) the push changes must parse at the pushed head (PyYAML, else Ruby's Psych; plus the local actionlint's
new [syntax-check] findings when it is on PATH), for a push to any branch, main and feat-cmux-next included.
CMUX_NEXT_CHECKS_SKIP_REASON does not skip it: GitHub runs no job of a workflow it cannot load (dd8b867f,
2026-11-06: no nightly for 3.5 hours). CI's "Lint every workflow" step is the backstop.
Also on every local run, the same way: "Runs-on variables declare their single-host fallback": when the push changes
.github/workflows/ or .github/single-host-fallbacks.json, check-single-host-fallbacks.py (the installed copy for the
hook) refuses each runs-on variable or single-host label the head reads with no declared fallback that the base did
not already have (cmux#40221 merged two). CI runs it only with --advisory: warnings, never a red step.

Also on every local run, the same way: "Every Cargo.lock matches its manifests" (cargo-locks.py check): when the push
changes any Cargo.toml or Cargo.lock, every tracked Cargo.lock in the repository is resolved with
`cargo update --workspace --locked` (index only, no build, seconds), not only the changed workspace's: a manifest
reaches other workspaces' locks through path dependencies (2026-11-10: eb4f3eb1d94 changed cmux-tui/Cargo.toml, a
direct push, and cmux-app-ffi's lock failed --locked on every pull request until #40883). It refuses only on cargo's
own lock error. CI's rust workspaces plan job runs the same check, and the base autofix rewrites a stale lock on
feat-cmux-next (base-autofix.sh --locks).

Also on every local run, the same way: "Crash ratchet" (crash_ratchet_findings): the Rust classes of CI's crash
ratchet (crash_ratchet.py: unwrap, expect, panic!/unreachable!/todo!/unimplemented!, process::exit/abort, outside
test code), judged per crate over the files the push changes: a crate whose count rises in those files is refused
(2026-11-08: #39304's first head added two non-test `.lock().unwrap()`, passed the hook and CI refused it, because
the crate's count in the gate's small trees never reached its crash-safety-baseline.json row). The ratchet code is
CI's own, never a copy of its rules: the installed reviewed copy for the hook. A row the push raises with a reviewed
Crash-allow-OK commit, and a hit that moved from another crate, are allowed. A main-based push (its tree has no
CmuxNext app entry, or it left origin/main after feat-cmux-next did) runs main's own crash rule instead of
check-crash-safety.sh, which reads that feat-only file: origin/main's crash_ratchet.py when main has one, else
the installed one (main's CI has none today); a reviewed `// crash-allow: <reason>` passes there, as main keeps
no baseline to record it in.

Also on every local run (the hook and a plain run; never --commits, never under GitHub Actions, so CI
gains no gate; Lawrence 2026-10-23): "Guardrails" (guardrails.py, plans/cmux-next/codebase-health.md):
refuses NEW unjustified @unchecked Sendable / nonisolated(unsafe) (the crash ratchet's class and escape, which
its per-module count cannot see before a push), DispatchQueue.main.async, ObservableObject/@Published, store
references in list rows, generic classes with an implicit deinit, waiting action binds, detached tasks without a
priority and bench hooks in shipped builds, in lines the push adds, and CmuxNextApp composition-root growth beyond
its wiring budget or a new App file that is not a move (`app-size`, a net count) and a new type that is not a move
in an existing App file or a moved one (`app-type`); sleeps and assumeIsolated are the scanners' rules above
(check-concurrency.sh, crash_ratchet.py), never repeated here. Warns on CmuxNextApp source growth, `// perf-hot:`
functions and OWNERS.md areas. Skip one push with
CMUX_GUARDRAILS_SKIP_REASON="<rule>[,<rule>]: <why>" (it skips only the named rules); the guardrails get the
gate's own ranges (above), so lines a push only brings in from origin/feat-cmux-next (a merge or rebase onto
it) never count; --no-guardrails turns it off for a manual run.
The guardrails include the arch ratchet (guardrails.py runs arch-ratchet.py; plans/cmux-next/arch-ratchet.json):
it refuses a push that raises the total of an architecture count (layer edges, stateful singletons, global
mutable statics, assumeIsolated outside seam adapters, app broadcast names, observer sites; arch_counts.py
defines them), counting only the files the push changes (a move between packages passes), or that raises the
json's own totals; its rule modules (arch_rules/, the layer gate) refuse what they find. guardrails' ratchet
starts on a thread before the scanners, so a push pays what is left of it at the guardrails (its cost is the
Swift files it reads and analyzes; --timings prints the wait). Its one escape is a dated exception in
arch-ratchet.json; --no-guardrails turns it off for a manual run; it fails open.

Not here (they stay on CI and the fleet): generated-file freshness (gen-*.py --check), god files,
the app size cap, script tests, Swift and Rust builds and tests.

  scripts/cmux-next/prepush-gate.py                  # what HEAD adds over the integration branch it left
  scripts/cmux-next/prepush-gate.py --base A --head B  # exactly what B adds over A
  scripts/cmux-next/prepush-gate.py --pre-push       # the hook: reads pre-push stdin
  scripts/cmux-next/prepush-gate.py --commits A..B   # CI: each commit against its parent, named
Escape hatch for one push: CMUX_NEXT_CHECKS_SKIP_REASON="<check> fails in files this push does not
touch (base <sha>)". The reason is printed; say it in your report.
"""
from __future__ import annotations

import argparse
import ast
import collections
import concurrent.futures
import fcntl
import hashlib
import importlib.util
import json
import os
import platform
import re
import shlex
import shutil
import signal
import subprocess
import sys
import sysconfig
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path

DEFAULT_BASE_REFS = ("origin/feat-cmux-next",)
PKG = "Packages/macOS/CmuxNext"
SCRIPTS = "scripts/cmux-next"
SCOPES = (PKG + "/", "cmux-tui/", "webviews/")
SWIFT_SCOPE = PKG + "/"
# Files a scanner reads besides the changed ones: present in both trees, so they never differ.
CONTEXT = (
    PKG + "/Package.swift",
    PKG + "/Sources/CmuxNextApp/CmuxNextApp.swift",
    PKG + "/Sources/CmuxNextIcons/IconName+Members.swift",
    PKG + "/Sources/CmuxNextIcons/Resources/icon-catalog.json",
    "cmux.xcodeproj/project.pbxproj",
    "cmux-next-ios/project.yml",
    "schemas/motion-scale/motion-scale.json",  # check-motion-tokens.py reads the scale's steps
)
# Check code outside scripts/cmux-next: check-package-dependency-lists.py imports the masker from scripts/ (an installed
# copy reads its own, beside it). Like the check code, it is the head's on both sides.
CHECK_CODE = ("scripts/swift_source_mask.py",)
DATA_SUFFIXES = (".tsv", ".json")
# A push that changes the manifest can drop a dependency an unchanged file imports: the dependency check then
# needs every Swift file of the package, not only the changed ones. It alone gets trees with them all (DEPS_CHECK):
# in the shared trees every other scanner would scan the whole package too (44 s instead of 2 s, measured on a
# manifest-only push).
MANIFEST = PKG + "/Package.swift"
MANIFEST_SOURCES = (PKG + "/Sources/", PKG + "/Tests/")
DEPS_CHECK = "Package dependency lists sorted"
SURFACE_MATERIALS_CHECK = "Each surface's material is one its kind allows (design/surface-materials.md)"
# The check reads its manifest and every file it judges, not only the changed ones: it gets each side's whole set.
SURFACE_MATERIALS_DATA = "schemas/surface-materials/"
SURFACE_MATERIALS_SOURCES = (PKG + "/Sources/", "webviews/src/ui/", "webviews/src/agent-session/")
# Its finding that a baseline import is gone, and the hint line it prints under any finding.
STALE_PAIR = re.compile(r": IMPORT_BASELINE lists (.+?), which is declared or gone now")
DEPS_HINT = "One dependency per line"
DEPS_CHECKER = "scripts/cmux-next/check-package-dependency-lists.py"

# (CI step name, command, path prefixes that make it run). {root} is the tree, {pkg} its CmuxNext
# package, {s} its scripts/cmux-next. Mirrors the job's steps; tests/test_cmux_next_prepush_gate.py
# keeps this list in step with the workflow.
# The exit codes each scanner's verdicts use (audited 2026-11-11): 0 for none and 1 for findings, all of them. Exit 2
# is a refusal to judge in check-crash-safety.sh (not a git checkout), check-state-roots.sh, check-no-process-scan.py
# and check-no-raw-spawn.py (a bad baseline row); any other code, or a signal, is no verdict either. A scanner whose
# verdicts use other codes names them here.
SCANNER_VERDICT_CODES: dict[str, tuple[int, ...]] = {}
DEFAULT_VERDICT_CODES = (0, 1)

SCANNERS = (
    ("Dialog buttons show their keys (u2647)", ["python3", "-I", "{s}/check-dialog-key-hints.py", "{root}"], (PKG + "/", "webviews/")),
    ("Main-thread concurrency", ["/bin/bash", "{s}/check-concurrency.sh", "{pkg}"], (PKG + "/", "Packages/Shared/")),
    ("Crash safety", ["/bin/bash", "{s}/check-crash-safety.sh", "{pkg}"], (PKG + "/", "cmux-tui/")),
    ("Type scale", ["python3", "-I", "{s}/check-swift-type-scale.py", "--root", "{root}",
                    "--baseline", "{s}/swift-type-scale-baseline.tsv"], (PKG + "/",)),
    ("Motion tokens", ["/bin/bash", "{s}/check-motion.sh", "{pkg}"], (PKG + "/",)),
    ("Motion and colour tokens", ["python3", "-I", "{s}/check-motion-tokens.py", "--root", "{root}"],
     # Only paths the gate diffs (SCOPES); CI's step reads the whole tree, the first-party apps and the Rust tokens.
     (PKG + "/", "webviews/src/", "cmux-tui/crates/acpmux/web/")),
    ("Overlays are glass, never solid", ["python3", "-I", "{s}/check-overlay-glass.py", "{root}"], (PKG + "/",)),
    (SURFACE_MATERIALS_CHECK,
     ["python3", "-I", "{s}/check-surface-materials.py", "{root}"],
     (PKG + "/", "webviews/src/", "schemas/surface-materials/", "scripts/cmux-next/check-surface-materials.py")),
    ("Scrollbars thin, one style", ["/bin/bash", "{s}/check-scrollbars.sh", "{root}"], (PKG + "/", "webviews/")),
    ("No literal state roots (per-build isolation S7, cx-is1kf.8)", ["/bin/bash", "{s}/check-state-roots.sh", "{root}"], SCOPES),
    ("No process scanning (holders register themselves, plans/cmux-next/pty-holder.md 4)",
     ["python3", "-I", "{s}/check-no-process-scan.py", "{root}"], SCOPES),
    ("No raw spawns in the daemon (cmux_process, reviews of pl-holder-11)",
     ["python3", "-I", "{s}/check-no-raw-spawn.py", "{root}"], ("cmux-tui/", "scripts/cmux-next/raw-spawn-baseline.tsv")),
    ("Every spawn has an owner (cmux_scope::Scope, cmux_process::Child; cmuxterm-hq#9096)",
     ["python3", "-I", "{s}/check-spawn-owner.py", "{root}"], ("cmux-tui/", "scripts/cmux-next/spawn-owner-baseline.tsv")),
    ("No process-wide test hooks in acpmux (per-thread on_* guards or a serializer, cmux#41350)",
     ["python3", "-I", "{s}/check-test-hooks.py", "{root}"], ("cmux-tui/crates/acpmux/src/",)),
    ("No app id special cases (zero first-party privilege, docs/app-store-platonic-ideal.md 5)",
     ["python3", "-I", "{s}/check-app-id-special-cases.py", "{root}"],
     (PKG + "/", "cmux-tui/", "first-party-apps/", "scripts/cmux-next/app-id-special-cases-baseline.tsv")),
    ("No Swift CLI (the cmux CLI is Rust, plans/cmux-next/cli.md)", ["/bin/bash", "{s}/check-no-swift-cli.sh", "{root}"], (PKG + "/",)),
    ("No Swift closed history (the daemon owns it, plans/cmux-next/reopen-closed.md 9)",
     ["/bin/bash", "{s}/check-no-swift-closed-history.sh", "{root}"], (PKG + "/",)),
    ("Tests inject their notification center", ["/bin/bash", "{s}/check-test-notification-centers.sh", "{pkg}"], (PKG + "/",)),
    ("String tables (21 languages)", ["/bin/bash", "{s}/check-l10n.sh", "{root}"], (PKG + "/",)),
    ("Module resource bundles", ["/bin/bash", "{s}/check-module-resources.sh", "{pkg}"], (PKG + "/",)),
    ("Capability texts never say update the app", ["python3", "-I", "{s}/check-capability-text.py", "--root", "{root}"], ("cmux-tui/",)),
    ("Browser chrome icons", ["python3", "-I", "{s}/lint-browser-chrome-icons.py"], (PKG + "/",)),
    ("App Store review rules (cmux-next-ios intents, Info.plist)",
     ["python3", "-I", "{s}/check-app-store-rules.py", "--source", "{root}"], ("cmux-next-ios/",)),
    ("Perf source guard (no window capture or CATransaction.flush)",
     ["python3", "-I", "{s}/check-perf-source-guard.py", "{root}"], (PKG + "/",)),
    ("No fleet host names in gallery fixtures",
     ["python3", "-I", "{s}/check-fixture-host-names.py", "{root}"], ("Packages/", "webviews/src/")),
    # A target's new import of another local target must be declared (2026-10-29: a63986a4 and e875485c each pushed
    # an undeclared test import straight to feat-cmux-next and turned this CI step red on every pull request).
    # Pure Python, no build: it reads the manifest and the pushed Swift files.
    ("Package dependency lists sorted",
     ["python3", "-I", "{s}/check-package-dependency-lists.py", "{pkg}/Package.swift"], (PKG + "/",)),
)

# Ghostty's default split keys stay Ghostty's (Lawrence 2026-10-20, after 2f3e1f95983).
RESERVED_CHECK = "Ghostty-default keys (schemas/keybindings/ghostty-reserved-keys.json)"
CONFLICT_CHECK = "Merge conflict markers"
# A workflow GitHub cannot load runs no job at all: dd8b867f (2026-11-06, a direct commit) left an unquoted `: ` in a
# nightly.yml input description, every push made a 0-job failed run and no nightly built for 3.5 hours.
WORKFLOW_CHECK = "Workflow YAML parses (.github/workflows, .github/actions)"
WORKFLOW_FILE = re.compile(r"^\.github/(?:workflows/[^/]+|actions/.+/action)\.ya?ml$")
WORKFLOW_HINT = ("Fix the workflow: quote a value that holds `: ` or ` #` (description: \"a: b\"), then push. GitHub "
                 "cannot load a workflow that does not parse and runs none of its jobs, so no skip reason passes it.")
# Ruby's Psych (libyaml), the parser a Mac without PyYAML still has: it parses only, it builds no objects.
RUBY_YAML_PARSE = """require 'psych'
begin
  Psych.parse_stream($stdin.read)
rescue Psych::SyntaxError => e
  puts "#{e.line}:#{e.column}: #{[e.problem, e.context].compact.join(' ')}"
  exit 1
end
"""
# A runs-on variable with no declared fallback (cmux#40221 merged two; the build-fleet policy test read this repository
# live and went red after the merge). Local only: ci-guards.yml runs the same script with --advisory, warnings only.
FALLBACKS_CHECK = "Runs-on variables declare their single-host fallback (.github/single-host-fallbacks.json)"
FALLBACKS_SCRIPT = "scripts/cmux-next/check-single-host-fallbacks.py"
FALLBACKS_DECLARATION = ".github/single-host-fallbacks.json"
FALLBACKS_HINT = ("Declare each name in .github/single-host-fallbacks.json (variables.NAME or labels.LABEL: the "
                  "`fallback` that takes the job and `after_minutes`), then push. Check with "
                  "`python3 scripts/cmux-next/check-single-host-fallbacks.py`.")
CARGO_LOCK_CHECK = "Every Cargo.lock matches its manifests (scripts/cmux-next/cargo-locks.py)"
CARGO_FILE = re.compile(r"(^|/)Cargo\.(toml|lock)$")
CARGO_LOCKS_SCRIPT = SCRIPTS + "/cargo-locks.py"
CARGO_HINT = ("Fix the locks: run `scripts/cmux-next/cargo-locks.py fix` (it runs `cargo update --workspace` in each "
              "stale workspace, which rewrites only what the manifests now need), commit the Cargo.lock files, then "
              "push. A manifest change in one workspace can leave another workspace's lock stale (eb4f3eb1d94).")
SIDEBAR_CHECK = "Sidebar look owner (plans/cmux-next/sidebar-owner.md)"
SIDEBAR_VIEWS = "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Views/"
# The sidebar package's code, not only Views/: a702 (9a2fceefbbb, 2026-10-25) changed the pinned section from tiles
# to rows in Sections/ and the gate never asked. Strings and resources (copy, catalogs) and the mock are left out.
SIDEBAR_CODE = "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/"
SIDEBAR_EXEMPT = ("Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Resources/",
                  "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Mock/",
                  "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Strings")
SIDEBAR_NOTE = "plans/cmux-next/sidebar-owner.md"
SIDEBAR_TRAILER = re.compile(r"^Sidebar-Look:[ \t]*(\S.*)$", re.MULTILINE)
SIDEBAR_NO_VISUAL = re.compile(r"^no visual change\b", re.IGNORECASE)
# The chrome layer (sidebar, footer, titlebar) keeps its colour unless Leo asks (#39984 laid a 20% black dim on the
# sidebar for a non-Leo issue; Leo 2026-11-11: "bro why is the sidebar now a different color?", reverted by #41047).
# ChromeLayerColorTests holds the colours each region paints in the default dark and light themes, plain and over a
# picture, against CHROME_VECTORS; a commit that changes that file, or a hunk of a chrome-layer token source that
# names a chrome token, needs a `Chrome-Look-OK:` trailer quoting Leo: his name and his words in quotes.
CHROME_CHECK = "Chrome layer look (schemas/theme/chrome-layer-colors.json)"
CHROME_VECTORS = "schemas/theme/chrome-layer-colors.json"
CHROME_SOURCES = (f"{PKG}/Sources/CmuxNextDesign/Palette.swift",
                  f"{PKG}/Sources/CmuxNextDesign/PaletteDynamic.swift",
                  f"{PKG}/Sources/CmuxNextDesign/MainPane.swift",
                  f"{PKG}/Sources/CmuxNextSidebar/Views/SidebarStyle.swift",
                  f"{PKG}/Sources/CmuxNextSidebar/Views/SidebarContainerView.swift",
                  f"{PKG}/Sources/CmuxNextSidebar/Logic/SidebarTunables.swift",
                  f"{PKG}/Sources/CmuxNextApp/WindowRootView+Surface.swift",
                  "Packages/Shared/CmuxTheme/Sources/CmuxTheme/ThemeTokens.swift")
CHROME_TOKENS = re.compile(r"\b(surfaceDim\w*|sidebarDim|sidebarBackground|windowBackground|surfaceBackground|"
                           r"chromeBackground|sidebarStep|mainPaneChromeShade|mainPaneShade\w*|applySurfaceFill|"
                           r"SidebarStyle\.ground)\b")
CHROME_TRAILER = re.compile(r"^Chrome-Look-OK:[ \t]*(\S.*)$", re.MULTILINE)
CHROME_LEO = re.compile(r"\bLeo\b")
CHROME_QUOTE = re.compile(r"[\"“][^\"“”]{3,}[\"”]")
# An added line that opens or closes a conflict hunk (`=======` alone is a Markdown or RST rule).
CONFLICT_OPEN = re.compile(r"^<{7} ")
CONFLICT_CLOSE = re.compile(r"^>{7} ")
RESERVED_SCRIPT = SCRIPTS + "/check-ghostty-reserved-keys.py"
RESERVED_LIST = "schemas/keybindings/ghostty-reserved-keys.json"
RESERVED_SURFACES = "plans/cmux-next/action-surfaces.json"
RESERVED_OK = re.compile(r"^Ghostty-defaults-OK:\s*\S", re.MULTILINE)
# A reviewed crash allowlist or baseline raise (lead 2026-10-24: the hook runs the INSTALLED crash data, so a
# reviewed entry, PL-blocking's Debug trap, could not pass it): a commit's `Crash-allow-OK: <reviewer or review id>`
# trailer lets the hook read that commit's own additions to crash-allowlist.json (entries added or with a higher
# count) and crash-safety-baseline.json (rows raised), and nothing else; CI names each commit that adds an allowlist
# entry without one (CRASH_ALLOW_CHECK).
CRASH_ALLOWLIST = SCRIPTS + "/crash-allowlist.json"
CRASH_BASELINE = SCRIPTS + "/crash-safety-baseline.json"
CRASH_OK = re.compile(r"^Crash-allow-OK:[ \t]*(\S.*)$", re.MULTILINE)
# Ratchet baselines a scanner here reads from the scripts folder: file -> (key columns, count column). The hook copies
# its INSTALLED scripts over both trees, and that copy cannot know that a push removed sites and lowered or deleted
# their row in the same commit: the check then reads "fewer than the baseline, lower its row" as a new finding and
# refuses the fix (lead 2026-11-03: the merge service refused #33091, the process-scan base red's fix, this way). So
# each tree reads its own commit's row wherever it is lower than the installed one (a deleted row counts as 0), and
# the installed row everywhere else: a raise or a new row is still judged against the installed copy, as before.
# Left out: crash-safety-baseline.json (a count under its row is only a note there; a raise needs Crash-allow-OK),
# and the baselines no scanner here reads (godfile, layers, main-actor-work, check-menu-actions, rust-panic,
# system-blue, type-scale, app-size): their CI checks read the pushed tree's own copy.
RATCHET_BASELINES = {
    "process-scan-baseline.tsv": ((0,), 1),
    "state-roots-baseline.tsv": ((0,), 1),
    "raw-spawn-baseline.tsv": ((0,), 1),
    "spawn-owner-baseline.tsv": ((0,), 1),
    "app-id-special-cases-baseline.tsv": ((0,), 1),
    "swift-type-scale-baseline.tsv": ((0, 1), 2),
}
CRASH_ALLOW_CHECK = "Crash allowlist review (Crash-allow-OK trailer)"
# check-crash-safety.sh reads the CmuxNext app entry, a file only feat-cmux-next's tree has: a main-based push skips
# that scanner and runs main's crash rule, the crash ratchet (crash_ratchet_findings).
CRASH_SAFETY_CHECK = "Crash safety"
APP_ENTRY = PKG + "/Sources/CmuxNextApp/CmuxNextApp.swift"
MAIN_REF = "origin/main"
CRASH_RATCHET_CHECK = "Crash ratchet (crash_ratchet.py: no crate gains a Rust unwrap, expect, panic or exit)"
CRASH_RATCHET = "crash_ratchet.py"
RUST_CRATES = "cmux-tui/crates/"
CRASH_RATCHET_HINT = ("Crash ratchet: handle the failure instead (a poisoned lock: "
                      "`.lock().unwrap_or_else(PoisonError::into_inner)`); test code is not counted. On "
                      "feat-cmux-next a reviewed `// crash-allow: <reason>` is a waived hit whose row needs recording "
                      "(crash_ratchet.py --record-waivers) in a commit with a `Crash-allow-OK: <reviewer>` trailer; "
                      "on a main-based push the reviewed comment alone passes.")
FREEZE_CHECK = "Coordinator path freeze (WINDOW FREEZE lines)"
# The coordinator's WINDOW (`FREEZE: <path prefix> token=<token>` lines; a `# LIFTED ...` line is not one). It
# exists on the coordinator's Mac only; elsewhere the check finds no file and checks nothing.
WINDOW_FILE = Path(os.environ.get("CMUX_WINDOW_FILE") or
                   Path.home() / "fun/cmuxterm-hq/.cmux-scratch/nx-coordinator/WINDOW")
FREEZE_LINE = re.compile(r"(?m)^FREEZE:[ \t]*(\S+)[ \t]+token=(\S+)")
FREEZE_TRAILER = re.compile(r"(?mi)^Freeze-Token:[ \t]*(\S+)[ \t]*$")

# The UI font is the macOS system font, everywhere (Lawrence 2026-11-07).
UI_FONT_CHECK = "UI font (the system font, schemas/type-scale/ui-font-pin.json)"
UI_FONT_SCRIPT = SCRIPTS + "/check-ui-font.py"
# check-ui-font.py's stop on a read outside its INPUTS (Tree.covered).
UI_FONT_GUARD = "which is not in INPUTS"

# The What's New highlights (release-notes/next/WRITING.md), judged by the release-notary job's own validator.
HIGHLIGHTS_CHECK = "What's New highlights (scripts/whats-new/validate.py, the release-notary test)"
HIGHLIGHTS_DIR = "release-notes/next/highlights/"
HIGHLIGHTS_CODE = ("scripts/whats-new/digest.py", "scripts/whats-new/validate.py")
HIGHLIGHTS_HINT = ("Fix the highlight: add docs: https://cmux.com/docs/<page> or a tryIt; at most 2 sentences, "
                   "240 characters (release-notes/next/WRITING.md).")
# A New or Improved highlight the push adds names where its picture comes from (goal whats-new-pretty; Leo, 2026-10-20:
# "tho i think vids and before/afters for our techincal stuff is p important... we want things to be PRETTY!!!!").
PICTURES_CHECK = "What's New pictures (release-notes/next/WRITING.md, \"A gallery picture\" and \"A clip\")"
PICTURES_GALLERY_FILE = re.compile(r"webviews/.+\.gallery\.tsx?")
PICTURES_CLIPS_DIR = "release-notes/next/clips/"
PICTURES_HINT = ("Give each one a picture: change the webview *.gallery.ts(x) state that shows it on this branch "
                 "(whats-new-gallery.yml picks it), or add a line such as `gallery: agent-pane.composer-send-menu/idle`, "
                 "or, for a native change, write release-notes/next/clips/<id>.json (a clip spec).")
# A variant a gallery file marks as the look its change replaced: a note opening "Before:" (or "Before ("), or a
# variant key (`name: {`) ending in an old-look word; whats-new-gallery.py marked_before reads the same marks. Only
# notes and variant keys count, never a prop such as `before: true`.
PICTURES_BEFORE_MARK = re.compile(r"""^\s*note:\s*["'`]Before\s*[:(]|^\s*["']?(?:[\w.]+-)*(?:before|old|solid|previous)["']?\s*:\s*\{""",
                                  re.M)
PICTURES_BEFORE_HINT = ("An Improved entry's before is its state at the commit before it, and a gallery file the branch "
                        "adds has none there: add the variant that draws the old look, its note opening \"Before:\", "
                        "or name both with `gallery:` and `before:` lines.")
# Run in its own interpreter: argv[1] holds digest.py and validate.py, argv[2] is the result file, then pairs of
# (file name, path to its text). Each file is judged alone, as test_the_repository_highlights_validate judges it: read
# as strict UTF-8 like the test's open() (a file it cannot decode is a test error there, so a finding here), and a file
# digest.parse refuses is its ValueError. The result, one JSON object {name: [problem, ...]}, goes to the result file,
# never to stdout or stderr: a warning the validator prints cannot hide it (review of #31260).
HIGHLIGHTS_PROGRAM = """\
import json, sys
sys.path.insert(0, sys.argv[1])
import digest
out = {}
pairs = sys.argv[3:]
for name, path in zip(pairs[0::2], pairs[1::2]):
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except UnicodeDecodeError as error:
        out[name] = [f"is not UTF-8 text ({error}); the release-notary test cannot read it"]
        continue
    try:
        out[name] = list(digest.entry_problems(digest.parse(name, text)))
    except ValueError as error:
        out[name] = [str(error)]
with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(out, f)
"""
# The validator names the made-up nightly document it wraps one entry in; the finding names the file instead.
HIGHLIGHTS_DOCUMENT = re.compile(r"^[^\s:]+\.json: ")

# Reviewed escapes the CI scanners honor, per ast-grep rule (same line or the comment block above).
ESCAPES = {
    "no-try-bang": re.compile(r"//\s*crash-allow:\s*\S"),
    "no-main-thread-block": re.compile(r"//\s*concurrency-allow:\s*\S"),
    "no-system-dialog": re.compile(r"dialog-keys-exempt:\s*\S"),
    "no-opaque-glass": re.compile(r"//\s*glass-opaque-allow:\s*\S"),
}
COMMENT_LINE = re.compile(r"^\s*(//|\*|/\*)")
LOCATION = re.compile(r"(?P<path>[\w.+@/-]+\.(?:swift|rs|ts|tsx|py|sh|json|xcstrings|md)):(?P<line>\d+)(?::\d+)?")
NUMBER = re.compile(r"\d+")
# Lines a scanner prints that are not findings: summaries, backlogs and warning-tier annotations.
INFO = re.compile(r"^(needs_review \(machine translated\)|\d+ tables, \d+ keys|::warning|.*ratchet debt|perf source guard: )")
# A check that crashed instead of judging (both sides crash alike, so the diff alone would hide it).
BROKEN = re.compile(r"Traceback \(most recent call last\)|No such file or directory|command not found|SyntaxError")
# The warning tiers CI gives the ratchets (cmux-next.yml, checks job).
CI_ENV = {"L10N_STYLE_WARN_MAX": "100", "SCROLLBARS_WARN_MAX": "10", "GODFILES_WARN_SLACK": "20"}


def log(message: str) -> None:
    print(message, file=sys.stderr)


def load_sibling(name: str, filename: str):
    """The module FILENAME beside this file (scripts/cmux-next in a checkout; the hook folder for the installed copy)."""
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# Request bytes go through a file, not a pipe (git_batch.py says why); guardrails.py uses the same helper.
git_batch = load_sibling("cmux_next_git_batch", "git_batch.py")


def git(repo: Path, *args: str, check: bool = True) -> bytes:
    result = git_batch.run(repo, list(args))
    if check and result.returncode != 0:
        raise SystemExit(f"prepush-gate: git {' '.join(args)} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def rev_ok(repo: Path, rev: str) -> bool:
    return subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}"],
                          capture_output=True).returncode == 0


PUSH_RANGE = "push_range.py"
PUSH_RANGE_MODULE = "cmux_next_push_range"


def load_push_range(repo: Path, trusted_scripts: Path | None):
    """push_range.py (the push's own range, shared with guardrails.py, arch-ratchet.py and the web lint): the
    installed reviewed copy for the hook, else this checkout's. The gate cannot judge a push without it: a
    missing copy exits with what to do (main() refuses the push)."""
    name = PUSH_RANGE_MODULE
    if name in sys.modules:
        return sys.modules[name]
    script = (trusted_scripts or repo / SCRIPTS) / PUSH_RANGE
    if not script.is_file():
        raise SystemExit(f"prepush-gate: {script} is missing; rerun scripts/install-git-hooks.sh")
    spec = importlib.util.spec_from_file_location(name, script)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


def changed_files(repo: Path, base: str, head: str) -> list[str]:
    names = git(repo, "diff", "--name-only", "--no-renames", "--diff-filter=ACMRT", "-z", base, head).decode()
    return sorted(n for n in names.split("\0") if n and n.startswith(SCOPES + ("Packages/Shared/", "cmux-next-ios/")))


def ratchet_row_files(repo: Path, base: str, head: str) -> list[str]:
    """Files whose RATCHET_BASELINES row the push adds or changes, present at both revs. The trees hold only changed
    files, so a row added for an untouched file (a base red's fix: a reviewed row for sites already on base) read 0
    sites against its row and was refused as "fewer than the baseline" (#37531, fast gates on the merge)."""
    files: set[str] = set()
    for name, (keys, count) in RATCHET_BASELINES.items():
        rows = [_ratchet_rows(blob.decode(errors="replace"), keys, count) if blob else {}
                for blob in (blob_at(repo, rev, f"{SCRIPTS}/{name}") for rev in (base, head))]
        files.update(key[0] for key in rows[0].keys() | rows[1].keys() if rows[0].get(key) != rows[1].get(key))
    return sorted(p for p in files if p.startswith(SCOPES) and blob_at(repo, base, p) is not None
                  and blob_at(repo, head, p) is not None)


def deleted_package_swift(repo: Path, base: str, head: str) -> list[str]:
    """Package Swift files the push deletes (a rename's old path too). Deleting a baseline import's last file makes its
    IMPORT_BASELINE line stale, so the dependency check runs on them: the base tree holds them, the head tree not."""
    names = git(repo, "diff", "--name-only", "--no-renames", "--diff-filter=D", "-z", base, head).decode()
    return sorted(n for n in names.split("\0") if n.startswith(MANIFEST_SOURCES) and n.endswith(".swift"))


# ---------------------------------------------------------------- pinned tools

def platform_key() -> str:
    system = {"Darwin": "darwin", "Linux": "linux"}.get(platform.system(), platform.system().lower())
    machine = {"aarch64": "arm64", "amd64": "x86_64"}.get(platform.machine(), platform.machine())
    return f"{system}-{machine}"


def tools_dir() -> Path:
    if os.environ.get("CMUX_LINT_TOOLS_DIR"):
        return Path(os.environ["CMUX_LINT_TOOLS_DIR"])
    if platform.system() == "Darwin":
        return Path.home() / "Library" / "Caches" / "cmux-lint-tools"
    return Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "cmux-lint-tools"


def read_lock(lock: Path) -> dict[str, tuple[str, str, str, str]]:
    rows, key = {}, platform_key()
    for line in lock.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        tool, version, plat, url, sha, member = line.split("\t")
        if plat == key:
            rows[tool] = (version, url, sha, member)
    return rows


def release_download():
    """scripts/ci/github_release_download.py: the copy install-git-hooks.sh puts beside the hook's copy of this
    file, else this checkout's, else None. None in a hook installed before it: that install's refresh_checks.py
    rewrites this file from feat-cmux-next but copies nothing from scripts/ci (#38454 review)."""
    name = "cmux_github_release_download"
    if name not in sys.modules:
        script = Path(__file__).with_name("github_release_download.py")
        if not script.is_file():
            script = Path(__file__).resolve().parent.parent / "ci" / "github_release_download.py"
        if not script.is_file():
            return None
        spec = importlib.util.spec_from_file_location(name, script)
        module = importlib.util.module_from_spec(spec)
        try:
            spec.loader.exec_module(module)
        except ImportError:
            # The helper imports deadline_http.py from beside itself. A hook installed before that has an older
            # refresh_checks.py, which rewrites the helper from feat-cmux-next but not deadline_http.py: download
            # directly, as with no helper, until scripts/install-git-hooks.sh runs again.
            return None
        sys.modules[name] = module
    return sys.modules[name]


def download(url: str, archive: Path) -> None:
    """The pinned archive at `url`, through the release-assets API when its GitHub release download fails
    (github_release_download.py). The caller's sha256 check judges either."""
    fetcher = release_download()
    if fetcher is None:
        log("prepush-gate: github_release_download.py is not installed, so a failed release download is not retried "
            "through the release-assets API; rerun scripts/install-git-hooks.sh")
        with urllib.request.urlopen(url, timeout=120) as response, open(archive, "wb") as out:
            shutil.copyfileobj(response, out)
        return
    try:
        fetcher.download(url, archive, log=lambda message: log(f"prepush-gate: {message}"))
    except fetcher.NoAsset as error:
        raise SystemExit(f"prepush-gate: {error}") from error


def ensure_tool(lock: Path, tool: str) -> Path:
    """The pinned binary, downloaded and sha256-checked once per version."""
    rows = read_lock(lock)
    if tool not in rows:
        raise SystemExit(f"prepush-gate: {tool} has no pinned build for {platform_key()} in {lock}")
    version, url, sha, member = rows[tool]
    target = tools_dir() / f"{tool}-{version}-{platform_key()}" / tool
    if target.is_file() and os.access(target, os.X_OK):
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    log(f"prepush-gate: downloading {tool} {version} (once) from {url}")
    with tempfile.TemporaryDirectory(dir=target.parent) as tmp:
        archive = Path(tmp) / "tool.zip"
        download(url, archive)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        if digest != sha:
            raise SystemExit(f"prepush-gate: {tool} download sha256 {digest} != pinned {sha}; refusing it")
        with zipfile.ZipFile(archive) as zf:
            extracted = Path(zf.extract(member, tmp))
        extracted.chmod(0o755)
        os.replace(extracted, target)
    return target


# ---------------------------------------------------------------- trees

def write_tree(repo: Path, dest: Path, files: dict[str, str], index: bool = True) -> None:
    """Write {path: rev} blobs into dest (one `git cat-file --batch`), then (INDEX) index them for ls-files."""
    paths = sorted(files)
    try:
        blobs = git_batch.cat_file(repo, [f"{files[p]}:{p}" for p in paths])
    except git_batch.GitError as error:
        raise SystemExit(f"prepush-gate: {error}")
    for path in paths:
        blob = blobs[f"{files[path]}:{path}"]
        if blob is None:
            continue  # missing at this rev (added or deleted file)
        target = dest / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(blob)
        if path.endswith(".sh"):
            target.chmod(0o755)
    (dest / PKG / "Sources").mkdir(parents=True, exist_ok=True)
    (dest / PKG / "Tests").mkdir(parents=True, exist_ok=True)
    if not index:
        return
    # A hook runs with GIT_DIR (and maybe GIT_INDEX_FILE, GIT_WORK_TREE) of the pushing checkout:
    # without them stripped, init and add would rewrite that repository instead of the temp tree.
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    subprocess.run(["git", "init", "-q", str(dest)], check=True, env=env, capture_output=True)
    subprocess.run(["git", "-C", str(dest), "add", "-A"], check=True, capture_output=True, env=env)


def ls_tree(repo: Path, rev: str, prefix: str) -> list[str]:
    out = git(repo, "ls-tree", "-r", "-z", "--name-only", rev, "--", prefix).decode()
    return [p for p in out.split("\0") if p]


def build_trees(repo: Path, base: str, head: str, changed: list[str], work: Path,
                trusted_scripts: Path | None = None, index: bool = True) -> tuple[Path, Path]:
    # The check scripts and their data sit at the top of scripts/cmux-next (plus lint/); its test,
    # release and harness subfolders are not read by any check and would only slow the copy.
    scripts = [] if trusted_scripts else [p for p in ls_tree(repo, head, SCRIPTS + "/")
                                          if "/" not in p[len(SCRIPTS) + 1:] or p.startswith(SCRIPTS + "/lint/")]
    base_data = set(ls_tree(repo, base, SCRIPTS + "/"))
    trees = []
    for side, rev in (("base", base), ("head", head)):
        files = {p: head for p in scripts}  # the check code is the head's on both sides
        for p in scripts:
            if p.endswith(DATA_SUFFIXES) and side == "base":
                files[p] = base if p in base_data else head  # each side's own baselines
        for p in CONTEXT:
            files[p] = rev
        for p in CHECK_CODE if trusted_scripts is None else ():
            files[p] = head  # a hook run reads the installed copy's, beside the checks (below)
        for p in changed:
            files[p] = rev
        dest = work / side
        write_tree(repo, dest, files, index)
        if trusted_scripts:
            # The hook never takes check code from the push: an install without the masker the push's head has
            # refuses, never falls back to the pushed scripts/swift_source_mask.py.
            missing = [p for p in CHECK_CODE if not (trusted_scripts / Path(p).name).is_file()
                       and blob_at(repo, head, p) is not None]
            if missing:
                raise SystemExit(f"prepush-gate: {STALE_INSTALL} (it has no {', '.join(Path(p).name for p in missing)}).")
            shutil.copytree(trusted_scripts, dest / SCRIPTS, dirs_exist_ok=True)
            lowered = lower_ratchet_baselines(repo, rev, dest / SCRIPTS)
            if lowered and side == "head":
                log("prepush-gate: these ratchet rows read the push's own lower values:\n  " + "\n  ".join(lowered))
            if side == "head":
                taken = apply_reviewed_crash_data(repo, base, head, dest / SCRIPTS)
                if taken:
                    log("prepush-gate: Crash safety reads these reviewed raises of the pushed crash data:\n  "
                        + "\n  ".join(taken))
        trees.append(dest)
    return trees[0], trees[1]



def _literal(node: ast.AST, names: dict[str, str] | None = None):
    """The value of IMPORT_BASELINE's expression, read without running it: strings, tuples, `+`, frozenset()/tuple()
    and a generator of f-strings over a literal tuple (how the checker writes CmuxNextAppTests' rows)."""
    names = names or {}
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, (ast.Tuple, ast.List, ast.Set)):
        return tuple(_literal(e, names) for e in node.elts)
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        return _literal(node.left, names) + _literal(node.right, names)
    if isinstance(node, ast.Name) and node.id in names:
        return names[node.id]
    if isinstance(node, ast.JoinedStr):
        return "".join(_literal(v.value if isinstance(v, ast.FormattedValue) else v, names) for v in node.values)
    if (isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in ("frozenset", "tuple")
            and len(node.args) == 1 and not node.keywords):
        return tuple(_literal(node.args[0], names))
    if (isinstance(node, ast.GeneratorExp) and len(node.generators) == 1 and not node.generators[0].ifs
            and isinstance(node.generators[0].target, ast.Name)):
        var = node.generators[0].target.id
        return tuple(_literal(node.elt, names | {var: item}) for item in _literal(node.generators[0].iter, names))
    raise ValueError(ast.dump(node))


def import_baseline(source: bytes) -> frozenset[str] | None:
    """The IMPORT_BASELINE of the dependency check's SOURCE, parsed and never executed; None when unreadable."""
    try:
        for node in ast.parse(source.decode("utf-8")).body:
            # `IMPORT_BASELINE = ...` or, annotated, `IMPORT_BASELINE: frozenset[str] = ...` (review of c9beb1af)
            targets = node.targets if isinstance(node, ast.Assign) else [node.target] if (
                isinstance(node, ast.AnnAssign) and node.value is not None) else []
            if len(targets) == 1 and isinstance(targets[0], ast.Name) and targets[0].id == "IMPORT_BASELINE":
                return frozenset(_literal(node.value))
    except (SyntaxError, UnicodeDecodeError, ValueError, TypeError):
        return None
    return None


def pushed_import_baseline(repo: Path, head: str) -> frozenset[str] | None:
    """The pushed head's IMPORT_BASELINE (the dependency check's); None when unreadable.
    The hook runs the installed checker, whose baseline is the one before the push: a push that declares a pair and
    drops its line (the cleanup the checker asks for) would be told to drop a line it already dropped. A head without
    the checker reads as None, not a failed push (review of 3f01de17: `git()` exits on a failed `git show`)."""
    return import_baseline(git(repo, "show", f"{head}:{DEPS_CHECKER}", check=False))


def dropped_baseline_pairs(repo: Path, head: str, trusted_scripts: Path | None) -> frozenset[str]:
    """Pairs the installed checker's IMPORT_BASELINE lists and the pushed head's no longer does. The installed checker
    still excuses them, so it would report neither a missing import nor a stale line for them: deps_findings judges
    them itself, over the whole package (gate() gives the check full trees when this is not empty)."""
    if trusted_scripts is None:
        return frozenset()  # the trees run the head's own checker, with the head's own baseline
    try:
        installed = import_baseline((trusted_scripts / Path(DEPS_CHECKER).name).read_bytes())
    except OSError:
        return frozenset()
    pushed = pushed_import_baseline(repo, head)
    return installed - pushed if installed is not None and pushed is not None else frozenset()


def stale_pairs(output: str) -> set[str]:
    """The `Target: Module` pairs the dependency check calls stale IMPORT_BASELINE lines in OUTPUT."""
    return {m.group(1) for r in records(output) for m in [STALE_PAIR.search(r)] if m}


def deps_findings(repo: Path, base: str, head: str, base_out: str, head_out: str, head_code: int, *,
                  full_package: bool, cmd: list[str], work: Path,
                  trusted_scripts: Path | None) -> tuple[str, int]:
    """The dependency check's head output with its "IMPORT_BASELINE lists ...: drop its line" findings judged.

    Missing imports always come from the installed checker (a push cannot weaken it). Which baseline lines are stale
    is the pushed head's call: its IMPORT_BASELINE may already have dropped a line the installed one still lists, and
    dropping a pair there never hides a missing import, which the installed checker still reports.
    With FULL_PACKAGE (the push changed the manifest) the trees hold every Swift file, so a stale finding is true.
    Without it the trees hold only the changed files: a module no file there imports may still be imported by an
    untouched one. So a stale line is kept only when this push made it stale (not stale in the base tree, which holds
    the same files at the base) and the whole package at the head confirms it (WORK gets that tree, only then)."""
    pushed = pushed_import_baseline(repo, head)
    head_stale = stale_pairs(head_out)
    # A pair the push dropped from IMPORT_BASELINE that the installed checker (which still excuses it) does not call
    # stale is still imported and undeclared: CI's pushed checker fails on it. The trees hold the whole package then.
    dropped = dropped_baseline_pairs(repo, head, trusted_scripts) if full_package else frozenset()
    missing = [f"{MANIFEST}: {target}: imports {module} but does not declare it in its dependencies, and this push "
               f"drops its IMPORT_BASELINE line. Fix: add \"{module}\" to the dependencies of {target}, or keep the line"
               for target, module in (p.split(": ", 1) for p in sorted(dropped - head_stale))]
    if missing:
        head_out, head_code = "\n".join(missing + records(head_out)), head_code or 1
    if not head_stale:
        return head_out, head_code
    if full_package:
        keep = {p for p in head_stale if pushed is None or p in pushed}
    else:
        candidates = {p for p in head_stale - stale_pairs(base_out) if pushed is None or p in pushed}
        keep = set()
        if candidates:
            package = sorted({p for prefix in MANIFEST_SOURCES for p in ls_tree(repo, head, prefix)
                              if p.endswith(".swift")} | {MANIFEST})
            _, full_head = build_trees(repo, base, head, package, work, trusted_scripts, index=False)
            keep = candidates & stale_pairs(run(fill(cmd, full_head), full_head)[1])
    kept = [r for r in records(head_out)
            if not (m := STALE_PAIR.search(r)) or m.group(1) in keep]
    if len(kept) == len(records(head_out)):
        return head_out, head_code
    return "\n".join(kept), (0 if all(r.startswith(DEPS_HINT) for r in kept) else head_code)

# ---------------------------------------------------------------- findings

def source_line(tree: Path, roots: list[Path], rel: str, number: int) -> str | None:
    for root in roots:
        path = root / rel
        if path.is_file():
            try:
                lines = path.read_text(encoding="utf-8", errors="replace").split("\n")
            except OSError:
                return None
            return lines[number - 1].strip() if 0 < number <= len(lines) else None
    return None


def normalize(text: str, tree: Path) -> str:
    """A finding's identity: file, rule and source text; no tree path, no line or count numbers."""
    text = text.replace(str(tree.resolve()) + "/", "").replace(str(tree) + "/", "")
    roots = [tree, tree / PKG, tree / PKG / "Sources", tree / PKG / "Tests", tree / "Packages"]

    def keyed(match: re.Match) -> str:
        line = source_line(tree, roots, match.group("path"), int(match.group("line")))
        return f"{match.group('path')}:«{line}»" if line is not None else match.group("path")
    parts = []
    last = 0
    for match in LOCATION.finditer(text):
        parts.append(NUMBER.sub("N", text[last:match.start()]))
        parts.append(keyed(match))
        last = match.end()
    parts.append(NUMBER.sub("N", text[last:]))
    return "".join(parts).strip()


def records(output: str) -> list[str]:
    """Output lines, an indented line joined to the finding above it."""
    out: list[str] = []
    for line in output.splitlines():
        if not line.strip():
            continue
        if line[:1].isspace() and out and LOCATION.search(out[-1]):
            out[-1] += "\n" + line
        else:
            out.append(line)
    return out


class Finding(str):
    """A finding as printed, plus KEY: its identity across runs (normalize(): file, rule and source text, no tree
    path, line or count numbers). gate_own matches a merge's runs by KEY: their trees and line numbers differ."""

    key: str

    def __new__(cls, text: str, key: str) -> "Finding":
        finding = super().__new__(cls, text)
        finding.key = key
        return finding


class NoVerdict(str):
    """A check that ran but gave no verdict (it crashed, timed out, or printed output of the wrong shape). It is
    never subtracted as old debt: not by a base run that gave no verdict alike (both sides crash the same way, so
    the diff would hide it), and not by gate_own's runs over a merge's upstream ranges. Its key is its own object,
    so push_range.less never matches it."""

    @property
    def key(self) -> str:
        return f"no-verdict:{id(self)}"


# Output that says a check stopped instead of judging: a Python traceback, or run()'s timeout line.
NO_VERDICT = re.compile(r"Traceback \(most recent call last\)|^timed out after \d+s$|^ast-grep failed: ", re.M)


def no_verdict(code: int, out: str, codes: tuple[int, ...] | None = None) -> str | None:
    """Why a check's run gave no verdict, or None when it gave one: it timed out (run()'s 124), was killed by a signal
    (a negative code), crashed (a traceback), or exited with a code outside CODES (the codes its verdicts use)."""
    if code == 124:
        return "timed out"
    if code < 0:
        return f"was killed by signal {-code}"
    if NO_VERDICT.search(out):
        return "crashed"
    if codes is not None and code not in codes:
        return f"exited {code}"
    return None


def new_records(base_out: str, head_out: str, base_tree: Path, head_tree: Path) -> list[str]:
    seen = collections.Counter(normalize(r, base_tree) for r in records(base_out))
    fresh = []
    for record in records(head_out):
        key = normalize(record, head_tree)
        if seen[key] > 0:
            seen[key] -= 1
        elif not re.search(r": ok\b|^All |passed|^ok\b", record) and not INFO.match(record):
            # Both spellings of the temporary tree (macOS: /var is /private/var).
            text = record.replace(str(head_tree.resolve()) + "/", "").replace(str(head_tree) + "/", "")
            fresh.append(Finding(text, key))
    return fresh


def run(cmd: list[str], cwd: Path, timeout: int = 120) -> tuple[int, str]:
    """CMD's exit code and output, or 124 and "timed out" past TIMEOUT seconds.

    A timed-out command is stopped with stop(), not subprocess.run's SIGKILL, so a `git` under it clears
    the lock it holds (see stop())."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")} | CI_ENV
    with subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
                          stdin=subprocess.DEVNULL) as process:
        try:
            out, err = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            stop([process.pid, *_descendants(process.pid)])
            try:
                process.communicate(timeout=GRACE_SECONDS + 5)
            except subprocess.TimeoutExpired:  # not even SIGKILL got it reaped (an unkillable disk wait)
                process.kill()
            return 124, f"timed out after {timeout}s"
    return process.returncode, out + err


def fill(cmd: list[str], tree: Path) -> list[str]:
    return [c.format(root=tree, pkg=tree / PKG, s=tree / SCRIPTS) for c in cmd]


def escaped(tree: Path, rel: str, index: int, rule: str) -> bool:
    pattern = ESCAPES.get(rule)
    if pattern is None:
        return False
    try:
        lines = (tree / rel).read_text(encoding="utf-8", errors="replace").split("\n")
    except OSError:
        return False
    if index < len(lines) and pattern.search(lines[index]):
        return True
    j = index - 1
    while j >= 0 and COMMENT_LINE.match(lines[j]):
        if pattern.search(lines[j]):
            return True
        j -= 1
    return False


def ast_grep(binary: Path, config: Path, tree: Path, swift: list[str]) -> str:
    present = [p for p in swift if (tree / p).is_file()]
    if not present:
        return ""
    result = subprocess.run([str(binary), "scan", "-c", str(config), "--json=compact", *present],
                            cwd=tree, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    try:
        matches = json.loads(result.stdout or "[]")
    except json.JSONDecodeError:
        return f"ast-grep failed: {result.stderr.strip()}"
    lines = []
    for m in matches:
        rel, index = m["file"], m["range"]["start"]["line"]
        if escaped(tree, rel, index, m["ruleId"]):
            continue
        lines.append(f"{rel}:{index + 1}: [{m['ruleId']}] {m['message']}")
    return "\n".join(sorted(lines))


# A SwiftFormat --lint finding line (0.64): `/abs/path/A.swift:3:1: error: (consecutiveBlankLines) Remove ...`.
SWIFTFORMAT_FINDING = re.compile(r"^\S.*\.swift:\d+:\d+: (?:error|warning): \([A-Za-z]+\) ")


def swiftformat(binary: Path, config: Path, tree: Path, swift: list[str]) -> str:
    present = [p for p in swift if (tree / p).is_file()]
    if not present:
        return ""
    # No cache: the trees are fresh temporary folders on every run and SwiftFormat keys its cache by absolute path,
    # so a persistent one never hits. It only grew (335 MB on a busy machine) and every call spent ~50 s reading and
    # rewriting it, even for one file. Linting the changed files takes milliseconds without it.
    # No --quiet: with it SwiftFormat 0.64 prints only "Source input did not pass lint check." and no finding, so this
    # layer never refused anything. Its findings are `<path>:<line>:<col>: error: (<rule>) <message>` lines.
    _, out = run([str(binary), "--lint", "--config", str(config), "--cache", "ignore", *present], tree)
    return "\n".join(l for l in out.splitlines() if SWIFTFORMAT_FINDING.match(l))


RUST_SCOPE = "cmux-tui/"


EDITION = re.compile(r'^\s*edition\s*=\s*"(\d{4})"', re.M)


def rust_edition(repo: Path) -> str:
    """The cmux-tui workspace's Rust edition (`[workspace.package] edition`), else 2024."""
    try:
        text = (repo / RUST_SCOPE / "Cargo.toml").read_text()
    except OSError:
        return "2024"
    found = EDITION.search(text)
    return found.group(1) if found else "2024"


def _manifest_text(repo: Path, tree: Path, rel: str) -> str | None:
    """REL's text in the judged tree, else in the checkout, else None."""
    for root in (tree, repo):
        try:
            return (root / rel).read_text()
        except OSError:
            continue
    return None


def rustfmt_edition(repo: Path, tree: Path, path: str) -> str | None:
    """The edition `cargo fmt --all` in cmux-tui/ formats PATH with, or None when it does not format PATH at all.

    The nearest Cargo.toml above PATH names its crate. A crate with its own `[workspace]`, or one the cmux-tui
    workspace lists under `exclude`, is outside that check (cmux-rd-host: own workspace, edition 2021), so the
    layer leaves its files alone rather than judge them by another crate's edition. A crate's literal `edition`
    wins; `edition.workspace = true` (or none) is the workspace's."""
    root_text = _manifest_text(repo, tree, RUST_SCOPE + "Cargo.toml") or ""
    excluded = set()
    found = re.search(r"^\s*exclude\s*=\s*\[(.*?)\]", root_text, re.M | re.S)
    if found:
        excluded = {RUST_SCOPE + e for e in re.findall(r'"([^"]+)"', found.group(1))}
    crate = Path(path).parent
    while str(crate).startswith(RUST_SCOPE.rstrip("/")) and str(crate) != RUST_SCOPE.rstrip("/"):
        text = _manifest_text(repo, tree, f"{crate}/Cargo.toml")
        if text is not None:
            if str(crate) in excluded or re.search(r"^\s*\[workspace\]", text, re.M):
                return None
            own = EDITION.search(text)
            return own.group(1) if own else rust_edition(repo)
        crate = crate.parent
    return rust_edition(repo)


def rustfmt(repo: Path, config: Path, tree: Path, rust: list[str]) -> str:
    """One finding per changed cmux-tui Rust file that rustfmt would change: `<path>: not rustfmt-clean ...`.

    Each file goes through rustfmt's stdin mode, so only that file is judged (a path argument would also format the
    files its `mod` lines name). The rustfmt is the one the cmux-tui checkout pins (rust-toolchain.toml, run in
    cmux-tui/), never installed for this check; with no such rustfmt the layer warns and finds nothing. The tip's
    `cargo fmt --all --check` (cmux-tui-rust-check.sh fmt) stays the backstop."""
    present = [p for p in rust if (tree / p).is_file()]
    if not present or not config.is_file():
        return ""
    env = {**os.environ, "RUSTUP_AUTO_INSTALL": "0"}
    findings = []
    for path in present:
        edition = rustfmt_edition(repo, tree, path)
        if edition is None:
            continue  # outside the cmux-tui workspace's `cargo fmt --all`: not this layer's to judge
        args = ["rustfmt", "--edition", edition, "--config-path", str(config), "--emit", "stdout"]
        source = (tree / path).read_bytes()
        try:
            done = subprocess.run(args, cwd=repo / RUST_SCOPE, input=source, env=env, capture_output=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired) as error:
            log(f"prepush-gate: WARNING: rustfmt did not run ({type(error).__name__}); Rust formatting NOT checked")
            return ""
        if done.returncode != 0:
            if b"error[" in done.stderr or (b"error:" in done.stderr and b"toolchain" not in done.stderr and b"not installed" not in done.stderr):
                findings.append(f"{path}: rustfmt cannot parse it: "
                                f"{done.stderr.decode(errors='replace').strip().splitlines()[0][:200]}")
                continue
            log("prepush-gate: WARNING: the pinned rustfmt is not available here (rustup component add rustfmt in "
                f"cmux-tui/); Rust formatting NOT checked: {done.stderr.decode(errors='replace').strip()[:200]}")
            return ""
        if done.stdout != source:
            findings.append(f"{path}: not rustfmt-clean; run `cargo fmt` in cmux-tui/ (the pre-commit hook does this)")
    return "\n".join(findings)


def swiftlint(binary: Path, config: Path, tree: Path, swift: list[str]) -> str:
    present = [p for p in swift if (tree / p).is_file()]
    if not present:
        return ""
    _, out = run([str(binary), "lint", "--config", str(config), "--quiet", "--no-cache", "--reporter", "xcode",
                  *present], tree)
    return "\n".join(l for l in out.splitlines() if LOCATION.search(l))


# ---------------------------------------------------------------- gate

def _json_at(repo: Path, rev: str, path: str) -> dict:
    result = subprocess.run(["git", "-C", str(repo), "show", f"{rev}:{path}"], capture_output=True)
    try:
        value = json.loads(result.stdout) if result.returncode == 0 else {}
    except ValueError:
        value = {}
    return value if isinstance(value, dict) else {}


def _allow_entries(data: dict) -> dict[tuple, dict]:
    return {(e.get("path"), e.get("class")): e for e in data.get("allow") or [] if isinstance(e, dict)}


def _rows(data: object, prefix: tuple = ()) -> dict[tuple, int]:
    """The baseline's leaves {(section, ..., module): hits}."""
    if isinstance(data, dict):
        out = {}
        for key, value in data.items():
            if not str(key).startswith("_"):
                out.update(_rows(value, prefix + (str(key),)))
        return out
    return {prefix: data} if isinstance(data, int) and not isinstance(data, bool) else {}


def crash_raises(repo: Path, base: str, head: str) -> list[tuple[str, str, str | None, dict, dict]]:
    """Per non-merge commit of BASE..HEAD that changes the crash data: (sha, subject, its Crash-allow-OK trailer or
    None, {allowlist key: entry added or raised}, {baseline row: value raised}), against the commit's own parent."""
    out = git(repo, "log", "--reverse", "--no-merges", "--format=%x1e%H%x1f%B", f"{base}..{head}", "--",
              CRASH_ALLOWLIST, CRASH_BASELINE, check=False).decode(errors="replace")
    found = []
    for record in out.split("\x1e")[1:]:
        sha, _, message = record.partition("\x1f")
        sha = sha.strip()
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            continue
        old, new = _allow_entries(_json_at(repo, sha + "^", CRASH_ALLOWLIST)), _allow_entries(_json_at(repo, sha, CRASH_ALLOWLIST))
        allow = {k: e for k, e in new.items() if k not in old or (e.get("count") or 0) > (old[k].get("count") or 0)}
        old_rows, new_rows = _rows(_json_at(repo, sha + "^", CRASH_BASELINE)), _rows(_json_at(repo, sha, CRASH_BASELINE))
        rows = {k: v for k, v in new_rows.items() if v > old_rows.get(k, 0)}
        if allow or rows:
            trailer = CRASH_OK.search(message)
            subject = message.strip().splitlines()[0] if message.strip() else ""
            found.append((sha, subject, trailer.group(1).strip() if trailer else None, allow, rows))
    return found


def _ratchet_rows(text: str, keys: tuple[int, ...], count: int) -> dict[tuple[str, ...], int]:
    """{key: count} of a ratchet baseline's rows; comments, blank and malformed lines are not rows."""
    rows = {}
    for line in text.splitlines():
        parts = line.split("\t")
        if line.startswith("#") or len(parts) <= max(*keys, count) or not parts[count].isdigit():
            continue
        rows[tuple(parts[i] for i in keys)] = int(parts[count])
    return rows


def lower_ratchet_baselines(repo: Path, rev: str, scripts_dir: Path) -> list[str]:
    """Rewrite each RATCHET_BASELINES file in SCRIPTS_DIR (a tree's copy of the installed scripts) so a row reads REV's
    own count where that is lower (a row REV deleted reads 0 and is dropped); every other line stays the installed
    one, so a raise or a new row is never taken. REV without the file changes nothing. Returns what was lowered."""
    taken: list[str] = []
    for name, (keys, count) in RATCHET_BASELINES.items():
        path = scripts_dir / name
        own = git_batch.run(repo, ["show", f"{rev}:{SCRIPTS}/{name}"])
        if not path.is_file() or own.returncode != 0:
            continue
        pushed = _ratchet_rows(own.stdout.decode(errors="replace"), keys, count)
        lines, changed = [], False
        for line in path.read_text(encoding="utf-8").splitlines(keepends=True):
            row = _ratchet_rows(line, keys, count)
            if not row:
                lines.append(line)
                continue
            (key, installed), = row.items()
            now = pushed.get(key, 0)
            if now >= installed:
                lines.append(line)
                continue
            changed = True
            if now == 0:
                taken.append(f"{name}: {' '.join(key)} {installed} -> 0 (row deleted)")
                continue
            parts = line.rstrip("\n").split("\t")
            parts[count] = str(now)
            lines.append("\t".join(parts) + ("\n" if line.endswith("\n") else ""))
            taken.append(f"{name}: {' '.join(key)} {installed} -> {now}")
        if changed:
            path.write_text("".join(lines), encoding="utf-8")
    return taken


def apply_reviewed_crash_data(repo: Path, base: str, head: str, scripts_dir: Path) -> list[str]:
    """Write into SCRIPTS_DIR (the head tree's installed scripts) the crash data raises of the pushed commits that
    carry a Crash-allow-OK trailer, over the installed files; a raise without one stays out, so it is still refused.
    Returns what was taken, one line each, for the gate to print."""
    taken: list[str] = []
    allow_path, baseline_path = scripts_dir / Path(CRASH_ALLOWLIST).name, scripts_dir / Path(CRASH_BASELINE).name
    try:
        allow_data = json.loads(allow_path.read_text()) if allow_path.is_file() else {"banned": [], "allow": []}
        baseline = json.loads(baseline_path.read_text()) if baseline_path.is_file() else {}
    except (OSError, ValueError):
        return taken
    changed = False
    for sha, subject, trailer, allow, rows in crash_raises(repo, base, head):
        if trailer is None:
            continue
        entries = [e for e in allow_data.setdefault("allow", []) if isinstance(e, dict)]
        for key, entry in allow.items():
            entries = [e for e in entries if (e.get("path"), e.get("class")) != key] + [entry]
            taken.append(f"{sha[:11]} (Crash-allow-OK: {trailer[:60]}): allow {key[1]} in {key[0]} count {entry.get('count')}")
        allow_data["allow"] = entries
        for row, value in rows.items():
            node = baseline
            for part in row[:-1]:
                node = node.setdefault(part, {}) if isinstance(node, dict) else None
            if isinstance(node, dict) and value > (node.get(row[-1]) or 0):
                node[row[-1]] = value
                taken.append(f"{sha[:11]} (Crash-allow-OK: {trailer[:60]}): baseline {'.'.join(row)} -> {value}")
        changed = changed or bool(allow or rows)
    if changed:
        allow_path.write_text(json.dumps(allow_data, indent=1) + "\n")
        baseline_path.write_text(json.dumps(baseline, indent=1, sort_keys=True) + "\n")
    return taken


def crash_allow_unreviewed(repo: Path, base: str, head: str) -> list[str]:
    """Each commit of BASE..HEAD that adds or raises a crash allowlist entry without a Crash-allow-OK trailer."""
    return [f"{sha[:11]} {subject[:70]}: adds {', '.join(f'{k[1]} in {k[0]}' for k in list(allow)[:3])}"
            f"{f' and {len(allow) - 3} more' if len(allow) > 3 else ''} to {CRASH_ALLOWLIST} without a "
            "`Crash-allow-OK: <reviewer or review id>` trailer"
            for sha, subject, trailer, allow, _ in crash_raises(repo, base, head) if allow and trailer is None]


STALE_INSTALL = "the installed hook is older than the checks this push needs: rerun scripts/install-git-hooks.sh"


def main_based(repo: Path, head: str, head_tree: Path) -> bool:
    """True for a push cut from main: HEAD's tree has no CmuxNext app entry, or the commit where HEAD left origin/main
    is not on origin/feat-cmux-next (HEAD_TREE holds HEAD's copy of the entry when HEAD has one)."""
    if not (head_tree / APP_ENTRY).is_file():
        return True
    feat = DEFAULT_BASE_REFS[0]
    if not (rev_ok(repo, MAIN_REF) and rev_ok(repo, feat)):
        return False
    fork = git(repo, "merge-base", head, MAIN_REF, check=False).decode().strip()
    return bool(fork) and subprocess.run(["git", "-C", str(repo), "merge-base", "--is-ancestor", fork, feat],
                                         capture_output=True).returncode == 1


def load_crash_ratchet(repo: Path, head_tree: Path, trusted_scripts: Path | None, on_main: bool, work: Path):
    """CI's crash ratchet (crash_ratchet.py) as a module, never the pushed copy on a hook run: origin/main's for a
    main-based push when main has one, else the installed reviewed copy (HEAD_TREE's scripts on a hook run; the head's,
    else this checkout's, on a plain run). A hook install without it refuses."""
    candidates: list[Path] = []
    if on_main:
        source = blob_at(repo, MAIN_REF, f"{SCRIPTS}/{CRASH_RATCHET}")
        if source is not None:
            folder = work / "main-crash-ratchet"
            folder.mkdir(parents=True, exist_ok=True)
            (folder / CRASH_RATCHET).write_bytes(source)
            allowlist = blob_at(repo, MAIN_REF, f"{SCRIPTS}/crash-allowlist.json")
            if allowlist is not None:
                (folder / "crash-allowlist.json").write_bytes(allowlist)
            candidates.append(folder / CRASH_RATCHET)
    candidates.append(head_tree / SCRIPTS / CRASH_RATCHET)
    if trusted_scripts is None:
        candidates.append(Path(__file__).with_name(CRASH_RATCHET))
    for script in candidates:
        if not script.is_file():
            continue
        name = "cmux_crash_ratchet_" + hashlib.sha256(str(script).encode()).hexdigest()[:12]
        spec = importlib.util.spec_from_file_location(name, script)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        if all(hasattr(module, attr) for attr in ("Scan", "scan_rust", "scan_rows", "baseline_rows", "load_baseline",
                                                  "proven_moves", "WAIVED")):
            return module
        log(f"prepush-gate: {script} has no crash ratchet this gate can call; trying the next copy")
    raise SystemExit(f"prepush-gate: {STALE_INSTALL} (it has no {CRASH_RATCHET}).")


def rust_owner_files(path: str) -> list[str]:
    """The files that can declare PATH's module or a folder above it (`#[cfg(test)] mod name;` makes PATH test code):
    for cmux-tui/crates/C/src/a/b.rs, src/a.rs and src/a/mod.rs, then src/lib.rs and src/main.rs."""
    crate, sep, rest = path.partition("/src/")
    if not sep:
        return []
    folders = rest.split("/")[:-1]
    owners = [f"{crate}/src/lib.rs", f"{crate}/src/main.rs"]
    for depth in range(1, len(folders) + 1):
        above = "/".join([crate, "src", *folders[:depth - 1]])
        owners += [f"{above}/{folders[depth - 1]}.rs", f"{above}/{folders[depth - 1]}/mod.rs"]
    return [p for p in owners if p != path]


def add_blobs(repo: Path, tree: Path, rev: str, paths: list[str]) -> None:
    """Write each of PATHS that TREE lacks and REV has into TREE (one `git cat-file --batch`)."""
    wanted = [p for p in paths if not (tree / p).exists()]
    try:
        blobs = git_batch.cat_file(repo, [f"{rev}:{p}" for p in wanted])
    except git_batch.GitError as error:
        raise SystemExit(f"prepush-gate: {error}")
    for path in wanted:
        blob = blobs[f"{rev}:{path}"]
        if blob is not None:
            (tree / path).parent.mkdir(parents=True, exist_ok=True)
            (tree / path).write_bytes(blob)


def prepare_crash_ratchet(repo: Path, base: str, head: str, head_tree: Path, trusted_scripts: Path | None,
                          work: Path) -> tuple[bool, object, list[str], float]:
    """(main-based, the ratchet module, the crate files the push deletes, seconds taken): the git reads of crash_ratchet_findings,
    which touch no tree, so gate() runs them next to the scanners (the merge-base reads take about a second)."""
    started = time.monotonic()
    on_main = main_based(repo, head, head_tree)
    ratchet = load_crash_ratchet(repo, head_tree, trusted_scripts, on_main, work)
    deleted = [p for p in git(repo, "diff", "--name-only", "--no-renames", "--diff-filter=D", "-z", base, head, "--",
                               RUST_CRATES).decode().split("\0") if p.endswith(".rs")]
    return on_main, ratchet, deleted, time.monotonic() - started


def crash_ratchet_findings(repo: Path, base: str, head: str, base_tree: Path, head_tree: Path, crates: list[str],
                           prepared: tuple[bool, object, list[str], float]) -> list["Finding"]:
    """The Rust crash ratchet over what the push adds: per crate and class (and waived hits apart), CI's crash
    ratchet code counts the hits in the changed crate files at BASE and at HEAD, and a count that rises is refused,
    less the rows the head's baseline raises over the base's (a reviewed raise, the same rows CI reads) and the hits
    that moved in from another crate. The trees also get the files that declare each changed file's module (test code
    is told by a `#[cfg(test)] mod name;` line) and, on the base side, the crate files the push deletes (a file moved
    within its crate is no new hit). One finding per added hit line, at its place in HEAD. PREPARED is
    prepare_crash_ratchet's answer."""
    on_main, ratchet, deleted, _ = prepared
    owners = sorted({o for p in crates + deleted for o in rust_owner_files(p)})
    add_blobs(repo, base_tree, base, owners + deleted)
    add_blobs(repo, head_tree, head, owners)
    scans = []
    for tree in (base_tree, head_tree):
        scan = ratchet.Scan()
        ratchet.scan_rust(str(tree), scan, True)
        scans.append(scan)
    old, new = scans
    old_rows, new_rows = ratchet.scan_rows(old), ratchet.scan_rows(new)

    def baseline(tree: Path) -> dict:
        data = ratchet.load_baseline(str(tree / SCRIPTS / "crash-safety-baseline.json"))
        return ratchet.baseline_rows(data) if data else {}
    base_rows, head_rows = baseline(base_tree), baseline(head_tree)
    allowance = {row: n - base_rows.get(row, 0) for row, n in head_rows.items() if n > base_rows.get(row, 0)}
    for (section, lang, kind, _source, target), hits in ratchet.proven_moves(old, new).items():
        row = (section, lang, kind, target)
        allowance[row] = allowance.get(row, 0) + hits
    findings = []
    for row, count in sorted(new_rows.items()):
        section, lang, kind, crate = row
        if lang != "rust" or (on_main and section == ratchet.WAIVED):
            continue
        if count - old_rows.get(row, 0) - allowance.get(row, 0) <= 0:
            continue
        label = f"{kind}{'.waived' if section == ratchet.WAIVED else ''}"
        added = [key[4] for key, hits in new.lines.items()
                 if key[:4] == row and hits > old.lines.get(key, 0)]
        for text in sorted(added):
            places = [f"{p}:{i + 1}" for p in crates if p.split("/")[2] == crate and (head_tree / p).is_file()
                      for i, line in enumerate((head_tree / p).read_text(encoding="utf-8", errors="replace")
                                               .split("\n")) if line.strip() == text]
            where = places[0] if places else f"{RUST_CRATES}{crate}"
            # Keyed without line numbers or counts, so gate_own matches it across a merge's runs.
            findings.append(Finding(f"{where}: [crash-ratchet] rust {crate}: a new non-test {label} hit "
                                    f"({old_rows.get(row, 0)} -> {count} in the files this push changes): {text}",
                                    f"{where.split(':')[0]}: [crash-ratchet] rust {crate} {label}: {text}"))
    return findings


def blob_at(repo: Path, rev: str, path: str) -> bytes | None:
    """PATH's content in commit REV, or None when REV has no such file."""
    result = subprocess.run(["git", "-C", str(repo), "show", f"{rev}:{path}"], capture_output=True)
    return result.stdout if result.returncode == 0 else None


def check_script(repo: Path, head: str, path: str, trusted_scripts: Path | None) -> bytes | None:
    """The check script at PATH to run for a push to HEAD: the installed reviewed copy on a hook run (TRUSTED_SCRIPTS),
    HEAD's own on a manual run; None when HEAD is older than the check. A hook run never falls back to the pushed head's
    copy (the hook never runs code a push controls): an install that lacks a check HEAD has refuses the push."""
    at_head = blob_at(repo, head, path)
    if trusted_scripts is None:
        return at_head
    if at_head is None:
        return None  # a commit older than this check
    installed = trusted_scripts / Path(path).name
    if not installed.is_file():
        raise SystemExit(f"prepush-gate: {STALE_INSTALL} (it has no {Path(path).name}).")
    return installed.read_bytes()


def reserved_keys(repo: Path, base: str, head: str, trusted_scripts: Path | None = None) -> list[str]:
    """What head adds to the Ghostty-default keys check (RESERVED_CHECK) over base."""
    def blob(rev: str, path: str) -> bytes | None:
        result = subprocess.run(["git", "-C", str(repo), "show", f"{rev}:{path}"], capture_output=True)
        return result.stdout if result.returncode == 0 else None

    # The hook runs the installed reviewed checker (as for the scanners); a manual run, the checkout's.
    script = check_script(repo, head, RESERVED_SCRIPT, trusted_scripts)
    if script is None:
        return []  # a commit older than this check
    with tempfile.TemporaryDirectory(prefix="cmux-reserved-") as tmp:
        work = Path(tmp)
        (work / "check.py").write_bytes(script)

        def findings(rev: str, base_list: bytes | None) -> tuple[list[str], str | None] | None:
            reserved, surfaces = blob(rev, RESERVED_LIST), blob(rev, RESERVED_SURFACES)
            if reserved is None or surfaces is None:
                return None
            (work / f"{rev}.reserved.json").write_bytes(reserved)
            (work / f"{rev}.surfaces.json").write_bytes(surfaces)
            cmd = ["python3", "-I", str(work / "check.py"), "--reserved", str(work / f"{rev}.reserved.json"),
                   "--surfaces", str(work / f"{rev}.surfaces.json")]
            if base_list is not None:
                (work / "base-list.json").write_bytes(base_list)
                cmd += ["--base-reserved", str(work / "base-list.json")]
            code, out = run(cmd, work)
            # Its verdicts exit 0 (none) or 1 (findings); anything else, a traceback or a timeout is no verdict.
            return [line for line in out.splitlines() if line.strip()], no_verdict(code, out, (0, 1))

        head_lines, head_stopped = findings(head, blob(base, RESERVED_LIST)) or ([], None)
        base_lines, base_stopped = findings(base, None) or ([], None)
    if head_stopped:
        return [NoVerdict(f"{RESERVED_SCRIPT} {head_stopped} at the pushed head instead of judging it, so the push is "
                          f"refused: {' '.join(head_lines[-2:])[:300]}")]
    fresh = [line for line in head_lines if base_stopped or line not in base_lines]
    if fresh and RESERVED_OK.search(git(repo, "log", "--format=%B", f"{base}..{head}", check=False).decode(errors="replace")):
        log(f"prepush-gate: {RESERVED_CHECK}: allowed by a Ghostty-defaults-OK trailer:\n  " + "\n  ".join(fresh))
        return []
    return fresh


def ui_font_inputs(check: Path) -> tuple[str, ...] | None:
    """The files and folders CHECK (a check-ui-font.py) reads, from its own `--inputs`; None when it cannot say
    (a copy older than --inputs, or any failure), so the caller runs it."""
    try:
        code, out = run(["python3", "-I", str(check), "--inputs"], check.parent, timeout=60)
    except Exception:  # any failure to ask means "unknown": the check runs
        return None
    inputs = tuple(line for line in out.splitlines() if line.strip())
    return inputs if code == 0 and inputs else None


def ui_font(repo: Path, base: str, head: str, trusted_scripts: Path | None = None) -> list[str]:
    """What head adds to the UI font check (UI_FONT_CHECK) over base: findings base does not have, and a
    pin change in base..head with no `Font-order:` trailer.

    A push that changes none of the files the check reads (its `--inputs`) and not the check itself cannot
    change what it finds, so neither pass runs. Each pass reads every webviews/src and Native/OptChat source
    (4268 files on feat-cmux-next, 2026-11-09): 9.6 s of an 18.8 s gate on a push of one Python file, plus one
    on-demand fetch (5-8 s) per source blob a blob:none clone lacks."""
    script = check_script(repo, head, UI_FONT_SCRIPT, trusted_scripts)
    if script is None:
        return []  # a commit older than this check
    with tempfile.TemporaryDirectory(prefix="cmux-ui-font-") as tmp:
        check = Path(tmp) / "check.py"
        check.write_bytes(script)
        inputs = ui_font_inputs(check)
        if inputs is not None:
            names = git(repo, "diff", "--name-only", "--no-renames", "-z", base, head)
            names = names.decode("utf-8", "surrogateescape")
            if not any(path.startswith((*inputs, UI_FONT_SCRIPT)) for path in names.split("\0") if path):
                return []

        def findings(*args: str) -> tuple[list[str], str | None]:
            code, out = run(["python3", "-I", str(check), "--repo", str(repo), *args], Path(tmp), timeout=600)
            lines = [line for line in out.splitlines() if line.strip() and not line.startswith("ui font:")]
            # Its verdicts exit 0 or 1; anything else, a traceback or a timeout is no verdict.
            return lines, no_verdict(code, out, (0, 1))

        head_lines, head_stopped = findings("--rev", head, "--base", base)
        # A guard stop (a read outside the check's INPUTS) prints the same line on both passes, so the diff below
        # would hide it and pass a push the check never judged (review of #39838): it refuses on its own.
        stopped = [line for line in head_lines if UI_FONT_GUARD in line]
        if stopped:
            return stopped
        # A crash or a timeout is the same class: both passes can print it alike, so it refuses on its own too.
        if head_stopped:
            return [NoVerdict(f"{UI_FONT_SCRIPT} {head_stopped} at the pushed head instead of judging it, so the push "
                              f"is refused: {' '.join(head_lines[-2:])[:300]}")]
        base_lines, base_stopped = findings("--rev", base)
        # A base pass with no verdict never subtracts: every head finding counts.
        return [line for line in head_lines if base_stopped or line not in set(base_lines)]


def cargo_lock_drift(repo: Path, base: str, head: str, trusted_scripts: Path | None = None) -> list[str]:
    """Every tracked Cargo.lock that no longer matches its workspace's manifests at head, when the push changes any
    Cargo.toml or Cargo.lock anywhere in the repository (scripts/cmux-next/cargo-locks.py check).

    2026-11-02: #31462 moved fs4 between two crates' Cargo.toml and put it under the wrong crate in Cargo.lock.
    Every --locked cargo step on feat-cmux-next then stopped ("cannot update the lock file"), the NEXT nightly
    included, until #31717. 2026-11-10: eb4f3eb1d94 changed cmux-tui/Cargo.toml and cmux-tui/Cargo.lock only, and
    the cmux-app-ffi and cmux-layout-reducer-ffi workspaces (their own locks, cmux-tui's crates by path) went stale;
    this check then read only the lock of the workspace a changed file sat in, so it passed. Now any Cargo change
    checks every lock: a manifest reaches other workspaces through path dependencies. It reads the pushing
    checkout itself (no tree is exported), so it runs only when head is the checked-out HEAD and no Cargo file has
    uncommitted edits; it refuses only on cargo's own lock error and lets the push through on any other (no cargo,
    an uncached index, a timeout).
    """
    names = git(repo, "diff", "--name-only", "--no-renames", "-z", base, head).decode("utf-8", "surrogateescape")
    if not any(CARGO_FILE.search(p) for p in names.split("\0") if p) or shutil.which("cargo") is None:
        return []
    try:
        checked_out = git(repo, "rev-parse", "HEAD").decode().strip() == git(repo, "rev-parse", head).decode().strip()
    except subprocess.CalledProcessError:
        return []
    # Pathspecs here use git's default matching, where `*` also matches `/`.
    dirty = subprocess.run(["git", "-C", str(repo), "diff", "--quiet", "HEAD", "--", "*Cargo.toml", "*Cargo.lock"],
                           capture_output=True).returncode != 0
    if not checked_out or dirty:
        log("prepush-gate: Cargo.lock check skipped: the pushed head is not this checkout's clean HEAD")
        return []
    script = check_script(repo, head, CARGO_LOCKS_SCRIPT, trusted_scripts)
    if script is None:
        return []  # a commit older than the shared check
    with tempfile.TemporaryDirectory(prefix="cmux-cargo-locks-") as tmp:
        check = Path(tmp) / "cargo-locks.py"
        check.write_bytes(script)
        # 30 workspaces resolve offline in parallel (about 4 s on a warm index); any the cached index cannot answer
        # then resolve with the network one at a time, each with its own 120 s limit, inside a 300 s budget.
        code, out = run(["python3", "-I", str(check), "check", "--repo", str(repo.resolve())], Path(tmp), timeout=300)
    if code == 124:
        log(f"prepush-gate: Cargo.lock check skipped: {out}")
        return []
    return [line.removeprefix("stale: ") for line in out.splitlines() if line.startswith("stale: ")]


def conflict_markers(repo: Path, base: str, head: str) -> list[str]:
    """`file:line` of each conflict marker the push adds, in any file of the repository.

    2026-10-22: c779988d57d landed `<<<<<<< HEAD` in SidebarNowLineTests.swift and CmuxNextAppTests
    stopped compiling; no scanner reads a test file. A file counts only when the push adds both an
    opening and a closing marker to it, so a fixture that mentions one marker never matches.
    """
    # Fixed prefixes: with a user's diff.noprefix the `+++ b/` headers this parse reads would be missing. No
    # inter-hunk context: a user's diff.interHunkContext would put unchanged lines between the added ones.
    diff = git(repo, "diff", "-U0", "--inter-hunk-context=0", "--no-color", "--no-renames", "--no-ext-diff",
               "--src-prefix=a/", "--dst-prefix=b/", base, head).decode("utf-8", "replace")
    found: dict[str, list[tuple[int, str]]] = collections.defaultdict(list)
    name, number = "", 0
    for line in diff.splitlines():
        if line.startswith("+++ "):
            name = line[6:] if line.startswith("+++ b/") else ""
        elif line.startswith("@@"):
            match = re.search(r"\+(\d+)", line)
            number = int(match.group(1)) if match else 0
        elif line.startswith("+") and name:
            text = line[1:]
            if CONFLICT_OPEN.match(text) or CONFLICT_CLOSE.match(text):
                found[name].append((number, text))
            number += 1
        elif line.startswith(" ") and name:  # a context line, should one come, is a head line too
            number += 1
    return [f"{name}:{n}: {text}" for name, marks in sorted(found.items())
            if any(CONFLICT_OPEN.match(t) for _, t in marks) and any(CONFLICT_CLOSE.match(t) for _, t in marks)
            for n, text in marks]


def yaml_problem(text: str) -> tuple[bool, str | None]:
    """(whether TEXT could be parsed here, `line:column: problem` when it does not parse).

    PyYAML when this Python has it (CI's guard venv and most dev Pythons), else Ruby's Psych (macOS ships it).
    Neither: (False, None), and the caller warns; no network is needed either way."""
    try:
        import yaml  # noqa: PLC0415  (optional: the gate runs on Pythons without it)
    except ImportError:
        yaml = None
    if yaml is not None:
        try:
            yaml.safe_load(text)
        except yaml.MarkedYAMLError as error:
            mark = error.problem_mark or error.context_mark
            where = f"{mark.line + 1}:{mark.column + 1}" if mark else "1:1"
            return True, f"{where}: {error.problem or error.context or error}"
        except yaml.YAMLError as error:
            return True, f"1:1: {error}"
        return True, None
    ruby = shutil.which("ruby")
    if ruby is None:
        return False, None
    try:
        result = subprocess.run([ruby, "-e", RUBY_YAML_PARSE], input=text, text=True, capture_output=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return False, None
    if result.returncode == 0:
        return True, None
    first = result.stdout.strip().splitlines()
    # No line printed: Ruby itself failed (no psych), which says nothing about the file.
    return (True, first[0]) if first else (False, None)


def actionlint_syntax(actionlint: str, path: str, text: str) -> set[str] | None:
    """actionlint's [syntax-check] messages for TEXT as PATH, without their line and column; None if it did not run.

    Its external linters are off (-shellcheck= -pyflakes=): syntax is what keeps GitHub from loading a workflow."""
    try:
        result = subprocess.run([actionlint, "-no-color", "-oneline", "-shellcheck=", "-pyflakes=",
                                 "-stdin-filename", path, "-"], input=text, text=True, capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode not in (0, 1):
        return None
    found = set()
    for line in result.stdout.splitlines():
        match = re.match(r"^[^:]+:(\d+):(\d+): (.*\[syntax-check\])$", line)
        if match:
            found.add(f"{match.group(1)}:{match.group(2)}: {match.group(3)}")
    return found


def workflow_problems(repo: Path, base: str, head: str, restrict: set[str] | None = None) -> list[str]:
    """`file:line:column: problem` for each workflow (or composite action) BASE..HEAD changes that HEAD leaves
    unloadable: YAML that does not parse, and the local actionlint's new [syntax-check] findings when it is on PATH.

    Only the head counts: GitHub loads the pushed head's file, so a broken commit fixed later in the push passes, and
    a file the push does not change is never read. Not skippable by CMUX_NEXT_CHECKS_SKIP_REASON (main())."""
    names = git(repo, "diff", "--name-only", "--no-renames", "--diff-filter=ACMRT", "-z", base, head, "--",
                ".github/").decode().split("\0")
    files = sorted(n for n in names if n and WORKFLOW_FILE.match(n) and (restrict is None or n in restrict))
    actionlint = shutil.which("actionlint")
    found, unchecked = [], []
    for path in files:
        data = blob_at(repo, head, path)
        if data is None:
            continue
        text = data.decode("utf-8", "replace")
        checked, problem = yaml_problem(text)
        if problem:
            found.append(f"{path}:{problem} (the YAML does not parse; GitHub will not load this file)")
            continue
        if not checked:
            unchecked.append(path)
        if actionlint and path.startswith(".github/workflows/"):
            now = actionlint_syntax(actionlint, path, text)
            if now:
                before = blob_at(repo, base, path)
                old = actionlint_syntax(actionlint, path, before.decode("utf-8", "replace")) if before else set()
                old_keys = {line.split(": ", 1)[1] for line in old or ()}
                found += [f"{path}:{line} (actionlint)" for line in sorted(now)
                          if line.split(": ", 1)[1] not in old_keys]
    if unchecked and not actionlint:
        log(f"prepush-gate: WARNING: no YAML parser here (PyYAML, ruby or actionlint), so {', '.join(unchecked)} "
            "went unchecked; CI's \"Lint every workflow\" step still checks it. `pip install pyyaml` fixes this.")
    return found


# scripts/ci/guards-local.sh's pin, so the hook and the local guard venv read YAML with the same PyYAML.
PYYAML_PIN = "PyYAML==6.0.3"


def has_pyyaml(python: str) -> bool:
    """Whether PYTHON, run the way the hook runs every layer (`-I`: no user site), can import yaml."""
    try:
        return subprocess.run([python, "-I", "-c", "import yaml"], capture_output=True, timeout=60).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


# Where Debian and Ubuntu's python3-yaml lands: the one place `apt-get install` can put PyYAML for an interpreter.
APT_DIST_PACKAGES = "/usr/lib/python3/dist-packages"


def interpreter_sys_path(python: str) -> list[str]:
    """PYTHON's sys.path as the hook runs it (-I, so no user site and no PYTHONPATH); [] when it does not answer."""
    try:
        done = subprocess.run([python, "-I", "-c", "import json, sys; print(json.dumps(sys.path))"],
                              capture_output=True, text=True, timeout=30)
        listed = json.loads(done.stdout) if done.returncode == 0 else []
    except (OSError, ValueError, subprocess.SubprocessError):
        return []
    return [p for p in listed if isinstance(p, str)] if isinstance(listed, list) else []


# How pip may install into an interpreter (PEP 668), as one line run with `python -I -c PEP668_ROUTE [STDLIB PURELIB]`
# (both paths or neither: the interpreter's own). Externally managed: not a venv (sys.prefix == sys.base_prefix; a
# venv reads its base's stdlib, so it sees the base's marker, yet pip installs into the venv: Codex on #40966) and
# STDLIB holds EXTERNALLY-MANAGED. It prints one route:
#   pip       not externally managed, PURELIB writable: plain pip
#   sudo-pip  not externally managed, PURELIB not writable by this user: pip with sudo
#   break     externally managed, PURELIB writable (Homebrew): pip --break-system-packages (Codex on leo-workspace#4198)
#   refuse    externally managed, PURELIB not writable (a system Python under /usr): no pip; say what to do
# leo-workspace machines/host-baseline.json's PyYAML install runs this same text, and both repos' tests pin its sha256
# (tests/test_ci_single_host_fallbacks.py PEP668_ROUTE_SHA256), so change both sides together.
PEP668_ROUTE = 'import os, sys, sysconfig; p = sysconfig.get_paths(); s, w = sys.argv[1:3] if len(sys.argv) == 3 else (p["stdlib"], p["purelib"]); m = sys.prefix == sys.base_prefix and os.path.exists(os.path.join(s, "EXTERNALLY-MANAGED")); print(("break" if m else "pip") if os.access(w, os.W_OK) else ("refuse" if m else "sudo-pip"))'
PEP668_ROUTES = ("pip", "sudo-pip", "break", "refuse")


def pep668_route(python: str, stdlib: str | None = None, purelib: str | None = None) -> str:
    """PEP668_ROUTE's answer for PYTHON, asked of PYTHON itself with -I. STDLIB and PURELIB override the paths PYTHON
    reports (a missing one of the two is this interpreter's). A PYTHON that does not answer is judged by this
    interpreter, with PYTHON's paths taken as this interpreter's."""
    paths = sysconfig.get_paths()
    given = [] if stdlib is None and purelib is None else [
        paths["stdlib"] if stdlib is None else stdlib, paths["purelib"] if purelib is None else purelib]
    for asked, extra in ((python, given), (sys.executable, given or [paths["stdlib"], paths["purelib"]])):
        try:
            done = subprocess.run([asked, "-I", "-c", PEP668_ROUTE, *extra], capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.SubprocessError):
            continue
        if done.returncode == 0 and done.stdout.strip() in PEP668_ROUTES:
            return done.stdout.strip()
    return "refuse"


def pyyaml_install_command(python: str, purelib: str | None = None, stdlib: str | None = None,
                           apt: bool | None = None, syspath: list[str] | None = None) -> str:
    """The one command that makes PyYAML importable for PYTHON under `-I`, which ignores user site-packages, so
    `pip install --user` never helps the hook. apt's python3-yaml only where it reaches PYTHON: apt-get exists and
    PYTHON's own sys.path (SYSPATH; read from PYTHON when None) holds APT_DIST_PACKAGES (Codex on #40880: a venv or
    a custom Python on an apt host never sees it). Otherwise pip, run as -I so a PyYAML already in the user site does
    not satisfy it, into PYTHON's own prefix, by pep668_route(): plain, with sudo, with --break-system-packages, or
    no pip at all and what to do instead."""
    apt = shutil.which("apt-get") is not None if apt is None else apt
    if apt and APT_DIST_PACKAGES in (interpreter_sys_path(python) if syspath is None else syspath):
        return "sudo apt-get install -y python3-yaml"
    route = pep668_route(python, stdlib, purelib)
    if route == "refuse":
        return (f"{python} is externally managed (PEP 668) and this user cannot write its prefix: install PyYAML "
                "6.0.3 with its own package manager, or rerun scripts/install-git-hooks.sh with a venv's python3 "
                "first on PATH")
    pip = f"{shlex.quote(python)} -I -m pip install {'--break-system-packages ' if route == 'break' else ''}{PYYAML_PIN}"
    return f"sudo {pip}" if route == "sudo-pip" else pip


FALLBACKS_STATUSES = ("found", "incomplete")
FALLBACKS_INCOMPLETE = "incomplete"


def fallback_output_fault(listed: object) -> str | None:
    """What is wrong with the checker's --json output LISTED, or None: it must be a list of objects, each with a string
    key, a string message and a status of FALLBACKS_STATUSES (Codex on #40840: findings were str()-coerced, so
    `[{"key": [], "message": {}}]` read as one equal finding on both sides and was subtracted)."""
    if not isinstance(listed, list):
        return f"a {type(listed).__name__}, not a list"
    for index, item in enumerate(listed):
        if not isinstance(item, dict):
            return f"item {index} is a {type(item).__name__}, not an object"
        for field in ("key", "message"):
            if not isinstance(item.get(field), str):
                return f"item {index}'s {field} is a {type(item.get(field)).__name__}, not a string"
        if item.get("status") not in FALLBACKS_STATUSES:
            return f"item {index}'s status is {item.get('status')!r}, not one of {', '.join(FALLBACKS_STATUSES)}"
    return None


def single_host_fallback_problems(repo: Path, base: str, head: str, trusted_scripts: Path | None = None) -> list[str]:
    """Each runs-on variable or single-host label HEAD reads with no declared fallback that BASE did not already have.

    Runs only when BASE..HEAD changes .github/workflows/ or the declaration. The checker is the installed reviewed copy
    on a hook run (TRUSTED_SCRIPTS), HEAD's own on a plain run. Only two cases pass unchecked: a HEAD without the
    declaration (a branch older than it), and a hook install older than the checker (a warning). A checker that runs
    and crashes, exits non-zero or prints no JSON list REFUSES the push (Codex on #40799: a null `variables` crashed
    the checker and the layer passed), whatever the cause, a missing PyYAML included.

    Codex on #40840. F1: a finding whose status is "incomplete" (the scan did not run: a declaration of the wrong
    shape, a workflow that does not load) refuses at the head whether or not the base had it too; the base's copy was
    subtracted as old debt, so a new vars.NAME passed with no scan. F2: the output must be a list of objects, each
    with a string key, a string message and a known status; anything else (`[{"key": [], "message": {}}]`, which
    str() made equal on both sides) is a checker failure and refuses. A base that gives no verdict, or an incomplete
    one, subtracts nothing."""
    names = git(repo, "diff", "--name-only", "--no-renames", "-z", base, head, "--", ".github/").decode().split("\0")
    if not any(n == FALLBACKS_DECLARATION or n.startswith(".github/workflows/") for n in names if n):
        return []
    if blob_at(repo, head, FALLBACKS_DECLARATION) is None:
        return []  # a branch older than the declaration
    if trusted_scripts is None:
        script = blob_at(repo, head, FALLBACKS_SCRIPT)
    else:
        installed = trusted_scripts / Path(FALLBACKS_SCRIPT).name
        script = installed.read_bytes() if installed.is_file() else None
    if script is None:
        log(f"prepush-gate: WARNING: no {Path(FALLBACKS_SCRIPT).name} in the hook's checks copy yet, so the single-host "
            "fallback check did not run; `scripts/install-git-hooks.sh` from origin/feat-cmux-next adds it.")
        return []
    # The checker runs under this interpreter: the hook's own Python (its python3-path), as every other layer does.
    if not has_pyyaml(sys.executable):
        fix = pyyaml_install_command(sys.executable)
        return [f"PyYAML missing: {fix}" if "externally managed" in fix else f"PyYAML missing: run {fix}"]
    with tempfile.TemporaryDirectory(prefix="cmux-fallbacks-") as tmp:
        work = Path(tmp)
        (work / "check.py").write_bytes(script)

        def keyed(rev: str) -> tuple[dict[str, str], list[str]] | str:
            """(the findings at REV by key, the messages of its incomplete ones), or the reason the checker gave no
            verdict (a crash, an exit, no JSON, output of the wrong shape)."""
            tree = work / rev[:12]
            tree.mkdir()
            paths = [".github/workflows"] + ([FALLBACKS_DECLARATION] if blob_at(repo, rev, FALLBACKS_DECLARATION) else [])
            archive = subprocess.run(["git", "-C", str(repo), "archive", "--format=tar", rev, *paths],
                                     capture_output=True)
            if archive.returncode != 0:
                return f"git archive {rev[:12]} failed: {archive.stderr.decode(errors='replace').strip()[:200]}"
            subprocess.run(["tar", "-x", "-C", str(tree)], input=archive.stdout, check=True)
            if not (tree / FALLBACKS_DECLARATION).is_file():
                return {}, []
            code, out = run([sys.executable, "-I", str(work / "check.py"), "--root", str(tree), "--json"], work)
            tail = " ".join(out.strip().splitlines()[-3:])[:300]
            if code != 0:
                return f"exited {code}: {tail or 'no output'}"
            try:
                listed = json.loads(next(line for line in out.splitlines() if line.startswith("[")))
            except (ValueError, StopIteration) as error:
                return f"printed no JSON list of findings ({error.__class__.__name__}): {tail or 'no output'}"
            bad = fallback_output_fault(listed)
            if bad:
                return f"printed findings of the wrong shape ({bad}): {tail[:200]}"
            return ({f["key"]: f["message"] for f in listed},
                    [f["message"] for f in listed if f["status"] == FALLBACKS_INCOMPLETE])

        now = keyed(head)
        if isinstance(now, str):
            return [NoVerdict(f"the single-host fallback checker did not give a verdict at the pushed head, so the "
                              f"push is refused (fix the declaration or the checker; `python3 {FALLBACKS_SCRIPT}` "
                              f"shows it): {now}")]
        found, incomplete = now
        if incomplete:
            return [NoVerdict(f"the single-host fallback scan did not run at the pushed head, so the push is refused "
                              f"whatever the base had (fix the declaration or the workflow): {message}")
                    for message in incomplete]
        before = keyed(base)
        # No verdict at the base, or an incomplete one: subtract nothing, every head finding is new.
        before = before[0] if isinstance(before, tuple) and not before[1] else {}
        return [message for key, message in sorted(found.items()) if key not in before]


def highlight_problems(repo: Path, base: str, head: str, trusted_scripts: Path | None = None,
                       restrict: set[str] | None = None) -> list[str]:
    """`<highlight file>: <validator problem>` for each problem of each What's New highlight BASE..HEAD adds or changes.

    The validator is the release-notary test's (HIGHLIGHTS_CODE): for the hook (TRUSTED_SCRIPTS) the one at this
    clone's origin/feat-cmux-next, so a pushed edit to it cannot pass its own highlight; for a plain run the head's.
    It fails open: no validator at that ref, or one that does not run, prints a warning and refuses nothing."""
    names = git(repo, "diff", "--name-only", "--no-renames", "--diff-filter=ACMRT", "-z", base, head, "--",
                HIGHLIGHTS_DIR).decode()
    files = sorted(n for n in names.split("\0") if n.endswith(".md") and "/" not in n[len(HIGHLIGHTS_DIR):]
                   and (restrict is None or n in restrict))
    if not files:
        return []
    code_rev = next((ref for ref in DEFAULT_BASE_REFS if rev_ok(repo, ref)), None) if trusted_scripts else head
    try:
        if code_rev is None:
            raise ValueError(f"no {' or '.join(DEFAULT_BASE_REFS)} in this clone to read the validator from")
        blobs = git_batch.cat_file(repo, [f"{code_rev}:{p}" for p in HIGHLIGHTS_CODE] + [f"{head}:{p}" for p in files])
        if any(blobs[f"{code_rev}:{p}"] is None for p in HIGHLIGHTS_CODE):
            return []  # a validator older than the highlights' rules: CI's test is older too
        with tempfile.TemporaryDirectory(prefix="cmux-prepush-highlights-") as tmp:
            work = Path(tmp)
            for p in HIGHLIGHTS_CODE:
                (work / Path(p).name).write_bytes(blobs[f"{code_rev}:{p}"])
            args = []
            for index, p in enumerate(files):
                (work / f"{index}.md").write_bytes(blobs[f"{head}:{p}"] or b"")
                args += [Path(p).name, str(work / f"{index}.md")]
            result = work / "result.json"
            code, out = run([sys.executable, "-I", "-c", HIGHLIGHTS_PROGRAM, str(work), str(result), *args], work,
                            timeout=60)
            # The exit code and the result file are the answer; the output is only for the warning below.
            if code != 0 or not result.is_file():
                raise ValueError(f"exit {code}: {out.strip().splitlines()[-1] if out.strip() else 'no output'}")
            problems = json.loads(result.read_text(encoding="utf-8"))
    except (Exception, SystemExit) as error:  # noqa: BLE001 - fail open: CI's release-notary test still runs it
        log(f"prepush-gate: WARNING: the What's New highlights were not validated ({type(error).__name__}: {error}); "
            "run python3 scripts/whats-new/test_digest.py before pushing a highlight.")
        return []
    found = []
    for p in files:
        name = Path(p).name
        for problem in problems.get(name, []):
            problem = HIGHLIGHTS_DOCUMENT.sub("", problem, count=1)
            problem = problem[len(name) + 2:] if problem.startswith(name + ": ") else problem
            found.append(f"{p}: {problem}")
    return found


def picture_problems(repo: Path, base: str, head: str, restrict: set[str] | None = None) -> list[str]:
    """`<highlight file>: ...` for each New or Improved What's New highlight BASE..HEAD adds with no picture source.

    NOW's whats_new line counts the New and Improved highlights of the last ten nightlies that went out with no
    picture; on 2026-11-08, 61 of the 166 in 21 days changed only Swift, where whats-new-gallery.yml finds no state,
    and none named one. A highlight passes with a `clip:` or `gallery:` line, with a clip spec
    (release-notes/next/clips/<id>.json) at HEAD, or when the branch changes a webview *.gallery.ts(x) file since it
    left origin/feat-cmux-next (a gallery change pushed before the highlight counts). An Improved one also needs, in
    each gallery file the branch adds (with a `gallery:` line and no `before:`, the file of its entry), a variant
    marked as the old look (PICTURES_BEFORE_MARK): its before is otherwise the same state at the commit before it,
    where the file is not (agent-file-result-cards and agent-web-result-cards shipped with none, 2026-11-09). Fixed and Security entries need no picture; a highlight
    already on the base is never judged. It fails open, with a warning."""
    names = git(repo, "diff", "--name-only", "--no-renames", "--diff-filter=A", "-z", base, head, "--",
                HIGHLIGHTS_DIR).decode()
    files = sorted(n for n in names.split("\0") if n.endswith(".md") and "/" not in n[len(HIGHLIGHTS_DIR):]
                   and (restrict is None or n in restrict))
    if not files:
        return []
    try:
        since = base
        for ref in DEFAULT_BASE_REFS:
            if rev_ok(repo, ref):
                since = git(repo, "merge-base", ref, head).decode().strip() or base
                break
        changed = [p for p in git(repo, "diff", "--name-only", "--no-renames", "-z", since, head).decode().split("\0")
                   if PICTURES_GALLERY_FILE.fullmatch(p)]
        added = set(git(repo, "diff", "--name-only", "--no-renames", "--diff-filter=A", "-z", since, head, "--",
                        *changed).decode().split("\0")) if changed else set()
        # A gallery file the branch adds has no state at the commit before, so an improvement drawn from it has
        # its before only where that file marks the old look; each new file on its own (one marked never covers another).
        new_files = sorted(added - {""})
        new_blobs = git_batch.cat_file(repo, [f"{head}:{path}" for path in new_files])
        texts = {path: (new_blobs[f"{head}:{path}"] or b"").decode("utf-8", "replace") for path in new_files}
        unmarked = sorted(path for path, text in texts.items() if not PICTURES_BEFORE_MARK.search(text))
        clips = set(git(repo, "ls-tree", "--name-only", "-z", head, "--", PICTURES_CLIPS_DIR).decode().split("\0"))
        blobs = git_batch.cat_file(repo, [f"{head}:{p}" for p in files])
        found = []
        for p in files:
            meta = {}
            for line in (blobs[f"{head}:{p}"] or b"").decode("utf-8", "replace").partition("\n\n")[0].splitlines():
                key, sep, value = line.partition(":")
                if sep:
                    meta[key.strip().lower()] = value.strip()
            highlight_id = Path(p).stem
            category = (meta.get("category") or "new").lower()
            if category not in ("new", "improved") or meta.get("clip") or f"{PICTURES_CLIPS_DIR}{highlight_id}.json" in clips:
                continue
            if meta.get("gallery"):
                # A named state with no `before:` is rendered at the commit before too: its entry's file must exist there.
                entry = meta["gallery"].partition("/")[0]
                new = [path for path in unmarked if re.search(r"""\bid:\s*["']""" + re.escape(entry) + r"""["']""",
                                                              texts[path])]
                if category == "improved" and not meta.get("before") and new:
                    found.append(f"{p}: an improved highlight whose gallery file is new, with no before ({', '.join(new)})")
                continue
            if not changed:
                found.append(f"{p}: a {category} highlight with no picture source")
            elif category == "improved" and unmarked:
                found.append(f"{p}: an improved highlight whose gallery file is new, with no before ({', '.join(unmarked)})")
        return found
    except (Exception, SystemExit) as error:  # noqa: BLE001 - fail open: the NOW count still shows a miss
        log(f"prepush-gate: WARNING: the What's New pictures were not checked ({type(error).__name__}: {error}).")
        return []


def window_freezes(repo: Path, base: str, head: str, window: Path | None = None) -> list[str]:
    """Each pushed commit that changes a path a WINDOW FREEZE line holds without that line's token.

    2026-10-25 (Lawrence): "freeze for all" on cmux.xcodeproj/project.pbxproj; landq honored the FREEZE lines,
    a direct push did not. A commit passes with a `Freeze-Token: <token>` trailer equal to the line's token
    (a slot grant replaces `none` with a token; `none` never matches). No WINDOW file: nothing is checked.
    """
    try:
        text = (window or WINDOW_FILE).read_text()
    except OSError:
        return []
    freezes = FREEZE_LINE.findall(text)
    if not freezes:
        return []
    found: list[str] = []
    out = git(repo, "log", "--reverse", "--no-merges", "--name-only", "--format=%x1e%H%x1f%B%x1f",
              f"{base}..{head}", "--", check=False).decode(errors="replace")
    for record in out.split("\x1e")[1:]:
        sha, message, names = (record.split("\x1f") + ["", ""])[:3]
        files = [f for f in names.split("\n") if f]
        tokens = set(FREEZE_TRAILER.findall(message))
        for prefix, token in freezes:
            hit = sorted(f for f in files if f == prefix or f.startswith(prefix.rstrip("/") + "/"))
            if hit and (token.startswith("none") or token not in tokens):
                found.append(f"{sha[:11]} changes {hit[0]}, frozen in WINDOW (`FREEZE: {prefix} token={token}`). "
                             f"Ask the coordinator for a slot grant, then add `Freeze-Token: <its token>` to the commit.")
    return found


def sidebar_owner(repo: Path, base: str, head: str, ack_rev: str | None = None) -> list[str]:
    """Each pushed commit that changes the sidebar's drawing code without the owner's record (sidebar_owner_by_commit)."""
    return [finding for _, finding in sidebar_owner_by_commit(repo, base, head, ack_rev)]


def sidebar_owner_by_commit(repo: Path, base: str, head: str, ack_rev: str | None = None) -> list[tuple[str, str]]:
    """(sha, finding) for each pushed commit that changes the sidebar's drawing code without the owner's record.

    A commit touching the sidebar package's code (`SIDEBAR_CODE` but `SIDEBAR_EXEMPT`) needs a `Sidebar-Look:` trailer: the user's words that asked for the
    look (a visual change, which must also edit `SIDEBAR_NOTE` in that commit) or `no visual change` (a
    behavior or performance change; the sidebar look contract tests hold the look). Checked per commit, so a
    later commit cannot launder an earlier one.

    A commit the owner has logged passes too: its 11-character sha in `SIDEBAR_NOTE` at `ack_rev` (default
    `head`). That is how a commit that reached the branch without a trailer (an old hook, a cancelled CI
    run; dcd4316ef5c, 2026-10-23) is reviewed once instead of failing every later sweep.
    """
    found: list[tuple[str, str]] = []
    note = subprocess.run(["git", "-C", str(repo), "show", f"{ack_rev or head}:{SIDEBAR_NOTE}"], capture_output=True)
    logged = note.stdout.decode(errors="replace") if note.returncode == 0 else ""
    # One `git log` for the whole range (a CI sweep reads every commit since the check landed): per commit a
    # record separator, the sha, the message, then the files it changes.
    out = git(repo, "log", "--reverse", "--no-merges", "--name-only", "--format=%x1e%H%x1f%B%x1f",
              f"{base}..{head}", "--", check=False).decode(errors="replace")
    for record in out.split("\x1e")[1:]:
        sha, message, names = (record.split("\x1f") + ["", ""])[:3]
        files = [f for f in names.split("\n") if f]
        views = sorted(f for f in files if f.startswith(SIDEBAR_CODE) and not f.startswith(SIDEBAR_EXEMPT))
        if not views or sha[:11] in logged:
            continue
        subject = message.strip().splitlines()[0] if message.strip() else ""
        trailer = SIDEBAR_TRAILER.search(message)
        where = f"{sha[:11]} {subject[:70]} ({views[0]}{f' and {len(views) - 1} more' if len(views) > 1 else ''})"
        if trailer is None:
            found.append((sha, f"{where}: no `Sidebar-Look:` trailer. Add `Sidebar-Look: <the user's words>` (and edit "
                               f"{SIDEBAR_NOTE}) or `Sidebar-Look: no visual change`."))
        elif not SIDEBAR_NO_VISUAL.match(trailer.group(1).strip()) and SIDEBAR_NOTE not in files:
            found.append((sha, f"{where}: a visual change (`Sidebar-Look: {trailer.group(1).strip()[:60]}`) must update "
                               f"{SIDEBAR_NOTE} in the same commit: the target look and the commit log."))
    return found


def chrome_hunks(repo: Path, sha: str, sources: list[str]) -> list[str]:
    """The chrome-layer token sources among SOURCES whose change in SHA touches a hunk naming a chrome token
    (`CHROME_TOKENS`, in a changed line or its three lines of context)."""
    out = git(repo, "show", "--format=", "--no-color", "-U3", sha, "--", *sources, check=False).decode(errors="replace")
    named: list[str] = []
    path, hunk, changed = "", [], False

    def close() -> None:
        if changed and path and path not in named and any(CHROME_TOKENS.search(line) for line in hunk):
            named.append(path)

    for line in out.split("\n"):
        if line.startswith("diff --git "):
            close()
            path, hunk, changed = line.split(" b/", 1)[-1], [], False
        elif line.startswith("@@"):
            close()
            hunk, changed = [], False
        elif line.startswith(("+++", "---")):
            continue
        elif line[:1] in ("+", "-", " "):
            hunk.append(line[1:])
            changed = changed or line[:1] != " "
    close()
    return named


def chrome_look(repo: Path, base: str, head: str) -> list[str]:
    """Each pushed commit that changes the chrome layer's recorded colours (`CHROME_VECTORS`) or a chrome token in
    its sources (`CHROME_SOURCES`) without a `Chrome-Look-OK:` trailer quoting Leo (his name and quoted words).

    Checked per commit, like the sidebar owner, so a later commit cannot launder an earlier one. Leo's ask
    (2026-11-11, after #39984 dimmed the sidebar for a non-Leo issue): a chrome-layer token change fails unless
    the pull request quotes him. ChromeLayerColorTests fails on any change to what those regions paint until the
    file is rewritten, so a colour change reaches this rule through the file even from an unlisted source."""
    found: list[str] = []
    watched = [CHROME_VECTORS, *CHROME_SOURCES]
    out = git(repo, "log", "--reverse", "--no-merges", "--name-only", "--format=%x1e%H%x1f%B%x1f",
              f"{base}..{head}", "--", *watched, check=False).decode(errors="replace")
    for record in out.split("\x1e")[1:]:
        sha, message, names = (record.split("\x1f") + ["", ""])[:3]
        files = [f for f in names.split("\n") if f in watched]
        if not files:
            continue
        touched = ([CHROME_VECTORS] if CHROME_VECTORS in files else []) + chrome_hunks(
            repo, sha, [f for f in files if f != CHROME_VECTORS])
        if not touched:
            continue
        trailer = CHROME_TRAILER.search(message)
        words = trailer.group(1).strip() if trailer else ""
        if CHROME_LEO.search(words) and CHROME_QUOTE.search(words):
            continue
        subject = message.strip().splitlines()[0] if message.strip() else ""
        where = f"{sha[:11]} {subject[:70]} ({touched[0]}{f' and {len(touched) - 1} more' if len(touched) > 1 else ''})"
        why = ("no `Chrome-Look-OK:` trailer" if trailer is None else
               f"`Chrome-Look-OK: {words[:60]}` does not quote Leo (his name and his words in quotes)")
        found.append(f"{where}: changes the chrome layer's colour (sidebar, footer, titlebar) with {why}. The chrome "
                     "keeps its colour unless Leo asks: add `Chrome-Look-OK: Leo <date> \"<his words>\"`, or leave "
                     f"the chrome tokens and {CHROME_VECTORS} as they are.")
    return found


def gate(repo: Path, base: str, head: str, only: set[str] | None, timings: bool,
         trusted_scripts: Path | None = None, ack_rev: str | None = None,
         restrict: set[str] | None = None, swiftformat_layer: bool = False,
         highlights_layer: bool = False) -> list[tuple[str, list[str]]]:
    """[(check, new findings)] that head adds over base; the tree checks read only RESTRICT's files when given.

    SWIFTFORMAT_LAYER: run SwiftFormat (main() sets it for the local pre-push hook and a plain local run only), or
    when `--only` names swiftformat. HIGHLIGHTS_LAYER: validate the What's New highlights the push changes (set
    like SWIFTFORMAT_LAYER), or when `--only` names highlights."""
    reserved: list[tuple[str, list[str]]] = []
    if only is None or "reserved" in only:
        fresh = reserved_keys(repo, base, head, trusted_scripts)
        reserved = [(RESERVED_CHECK, fresh)] if fresh else []
    if only is None or "ui-font" in only:
        fresh = ui_font(repo, base, head, trusted_scripts)
        reserved += [(UI_FONT_CHECK, fresh)] if fresh else []
    if only is None or "conflicts" in only:
        markers = conflict_markers(repo, base, head)
        if markers:
            reserved.append((CONFLICT_CHECK, markers))
    # Local only, like the highlights (CLAUDE.md: no new CI gates): CI's "Lint every workflow" step (actionlint, on
    # every pull request and every feat-cmux-next and main push) is the backstop. Here it meets a direct commit first.
    if highlights_layer if only is None else "workflows" in only:
        broken = workflow_problems(repo, base, head, restrict)
        if broken:
            reserved.append((WORKFLOW_CHECK, broken))
    # Local only, like the workflow parse (CLAUDE.md: no new CI gates): ci-guards.yml runs the checker --advisory.
    if (highlights_layer if only is None else "single-host-fallbacks" in only) and restrict is None:
        undeclared = single_host_fallback_problems(repo, base, head, trusted_scripts)
        if undeclared:
            reserved.append((FALLBACKS_CHECK, undeclared))
    # Local only, like SwiftFormat: CI's own --locked cargo steps stay the backstop. Not in gate_own's runs over the
    # ranges a merge does not own (RESTRICT): the check reads only the checkout, never those ranges' heads.
    if (highlights_layer if only is None else "cargo-lock" in only) and restrict is None:
        drift = cargo_lock_drift(repo, base, head, trusted_scripts)
        if drift:
            reserved.append((CARGO_LOCK_CHECK, drift))
    if only is None or "sidebar" in only:
        owner = sidebar_owner(repo, base, head, ack_rev)
        if owner:
            reserved.append((SIDEBAR_CHECK, owner))
    if only is None or "chrome" in only:
        chrome = chrome_look(repo, base, head)
        if chrome:
            reserved.append((CHROME_CHECK, chrome))
    if only is None or "freeze" in only:
        frozen = window_freezes(repo, base, head)
        if frozen:
            reserved.append((FREEZE_CHECK, frozen))
    if only is None or "crash-allow" in only:
        unreviewed = crash_allow_unreviewed(repo, base, head)
        if unreviewed:
            reserved.append((CRASH_ALLOW_CHECK, unreviewed))
    # Local only, like SwiftFormat (CLAUDE.md: no new CI gates): CI's release-notary test stays the backstop.
    if highlights_layer if only is None else "highlights" in only:
        t0 = time.monotonic()
        bad = highlight_problems(repo, base, head, trusted_scripts, restrict)
        if timings:
            log(f"  {time.monotonic() - t0:5.2f}s  {HIGHLIGHTS_CHECK}")
        if bad:
            reserved.append((HIGHLIGHTS_CHECK, bad))
    # Local only, like the highlights (CLAUDE.md: no new CI gates): NOW's whats_new count is the backstop.
    if highlights_layer if only is None else "pictures" in only:
        missing = picture_problems(repo, base, head, restrict)
        if missing:
            reserved.append((PICTURES_CHECK, missing))
    # The git-only checks above need no trees: a run of only those (CI's sidebar sweep) stops here.
    if only is not None and not only & {"scanners", "ast-grep", "swiftformat", "swiftlint", "rustfmt", "crash-ratchet"}:
        return reserved
    changed = sorted(set(changed_files(repo, base, head)) | set(ratchet_row_files(repo, base, head)))
    deleted = deleted_package_swift(repo, base, head) if only is None or "scanners" in only else []
    if restrict is not None:
        changed = [p for p in changed if p in restrict]
        deleted = [p for p in deleted if p in restrict]
    # The checker lies outside SCOPES: a push that only drops IMPORT_BASELINE lines still needs the dependency check.
    dropped = dropped_baseline_pairs(repo, head, trusted_scripts) if only is None or "scanners" in only else ()
    # The surface materials manifest lies outside SCOPES too: a push that only edits it, or only deletes a file the
    # check judges (an entry then goes stale), still runs its check.
    materials_data = [n for n in git(repo, "diff", "--name-only", "--no-renames", "-z", base, head, "--",
                                     SURFACE_MATERIALS_DATA).decode().split("\0") if n]
    materials_data += [n for n in git(repo, "diff", "--name-only", "--no-renames", "--diff-filter=D", "-z", base, head,
                                      "--", *SURFACE_MATERIALS_SOURCES).decode().split("\0")
                       if n.endswith((".swift", ".tsx"))]
    if not changed and not dropped and not deleted and not materials_data:
        return reserved
    swift = [p for p in changed if p.startswith(SWIFT_SCOPE) and p.endswith(".swift")]
    sources = [p for p in swift if p.startswith(PKG + "/Sources/")]
    started = time.monotonic()
    found: list[tuple[str, list[str]]] = list(reserved)
    with tempfile.TemporaryDirectory(prefix="cmux-prepush-") as tmp:
        base_tree, head_tree = build_trees(repo, base, head, changed + deleted, Path(tmp), trusted_scripts)
        # The tool rules and pins: on a hook run, only the installed reviewed copy's (head_tree/SCRIPTS is that copy);
        # a pin names a binary the gate downloads and runs, and its sha256 proves nothing when the same file names it.
        # An install without them refuses. A manual run reads the head's, else (a commit older than the gate) the
        # checkout's.
        if trusted_scripts is not None and not (trusted_scripts / "lint-tools.lock").is_file():
            raise SystemExit(f"prepush-gate: {STALE_INSTALL} (it has no lint-tools.lock).")
        config_root = head_tree if (head_tree / SCRIPTS / "lint-tools.lock").is_file() else repo
        lint = config_root / SCRIPTS / "lint"
        lock = config_root / SCRIPTS / "lint-tools.lock"
        jobs: dict[str, tuple] = {}
        trees_for: dict[str, tuple[Path, Path]] = {}
        for name, cmd, prefixes in SCANNERS:
            script = next(Path(c) for c in fill(cmd, head_tree) if c.startswith(str(head_tree / SCRIPTS)))
            if not script.is_file():
                continue  # a commit older than this check
            if name == CRASH_SAFETY_CHECK and not (head_tree / APP_ENTRY).is_file():
                continue  # a main-based push: its crash rule is the crash ratchet below
            runs = any(p.startswith(prefixes) for p in changed) or (name == SURFACE_MATERIALS_CHECK and materials_data)
            if runs and (only is None or "scanners" in only):
                jobs[name] = ("cmd", cmd)
        if (dropped or deleted) and DEPS_CHECK not in jobs:
            jobs[DEPS_CHECK] = ("cmd", next(cmd for name, cmd, _ in SCANNERS if name == DEPS_CHECK))
        if DEPS_CHECK in jobs and (MANIFEST in changed or dropped):
            # Each side's own Swift files, so a finding both sides have still cancels out. Its own list: `sources` is
            # ast-grep's, the changed production files only.
            package = sorted({p for rev in (base, head) for prefix in MANIFEST_SOURCES
                              for p in ls_tree(repo, rev, prefix) if p.endswith(".swift")} | {MANIFEST})
            # Not indexed: the check reads files, never ls-files, and indexing 9,000 files twice was most of the cost.
            trees_for[DEPS_CHECK] = build_trees(repo, base, head, package, Path(tmp) / "deps", trusted_scripts,
                                                index=False)
        if SURFACE_MATERIALS_CHECK in jobs:
            # Each side's manifest and every file the check judges, so a finding both sides have cancels out and an
            # entry for an untouched file never reads as stale.
            judged = sorted({p for rev in (base, head) for prefix in SURFACE_MATERIALS_SOURCES
                             for p in ls_tree(repo, rev, prefix) if p.endswith((".swift", ".tsx"))}
                            | {p for rev in (base, head) for p in ls_tree(repo, rev, SURFACE_MATERIALS_DATA)})
            trees_for[SURFACE_MATERIALS_CHECK] = build_trees(repo, base, head, judged, Path(tmp) / "materials",
                                                             trusted_scripts, index=False)
        if not lock.is_file():
            sources, swift = [], []  # a checkout older than the pinned tools: scanners only
        if sources and (only is None or "ast-grep" in only):
            jobs["ast-grep (scripts/cmux-next/lint/ast-grep-rules)"] = ("fn", ast_grep, ensure_tool(lock, "ast-grep"),
                                                                       lint / "sgconfig.yml", sources)
        # Local only (lead 2026-10-27): CI and the merge-time gates (fast gates, car guards: --base/--head; pushes:
        # --commits) never refused a SwiftFormat finding, and must not start to (CLAUDE.md: no new CI gates).
        if swift and (swiftformat_layer if only is None else "swiftformat" in only):
            jobs["SwiftFormat --lint"] = ("fn", swiftformat, ensure_tool(lock, "swiftformat"),
                                          lint / "swiftformat.conf", swift)
        # Local only, like SwiftFormat (lead 2026-11-05: PRs merge before CI's fmt check ends; no new CI gate).
        rust = [p for p in changed if p.startswith(RUST_SCOPE) and p.endswith(".rs")]
        if rust and (swiftformat_layer if only is None else "rustfmt" in only):
            jobs["rustfmt (cmux-tui)"] = ("fn", rustfmt, repo, repo / RUST_SCOPE / "rustfmt.toml", rust)
        if swift and (only is None or "swiftlint" in only):
            jobs["SwiftLint (syntax rules)"] = ("fn", swiftlint, ensure_tool(lock, "swiftlint"),
                                                lint / "swiftlint.yml", swift)

        def side(job, tree):
            t0 = time.monotonic()
            if job[0] == "cmd":
                code, out = run(fill(job[1], tree), tree)
            else:
                _, fn, binary, config, files = job
                out = fn(binary, config, tree, files)
                code = 1 if out else 0
            return code, out, time.monotonic() - t0

        crates = [p for p in changed if p.startswith(RUST_CRATES) and p.endswith(".rs")]
        crash_layer = bool(crates) and (highlights_layer if only is None else "crash-ratchet" in only)
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(16, (os.cpu_count() or 4))) as pool:
            futures = {(name, i): pool.submit(side, job, tree)
                       for name, job in jobs.items()
                       for i, tree in enumerate(trees_for.get(name, (base_tree, head_tree)))}
            prepared = (pool.submit(prepare_crash_ratchet, repo, base, head, head_tree, trusted_scripts, Path(tmp))
                        if crash_layer else None)
            for name in jobs:
                name_base, name_head = trees_for.get(name, (base_tree, head_tree))
                base_code, base_out, base_s = futures[(name, 0)].result()
                head_code, head_out, head_s = futures[(name, 1)].result()
                if timings:
                    log(f"  {max(base_s, head_s):5.2f}s  {name}")
                if BROKEN.search(head_out):
                    log(f"prepush-gate: WARNING: {name} did not run cleanly in the push's tree; CI still runs it:\n"
                        + "\n".join(head_out.splitlines()[-5:]))
                if os.environ.get("CMUX_PREPUSH_GATE_DEBUG"):
                    log(f"--- {name} (head exit {head_code})\n{head_out}")
                # One rule for every scanner, before any subtraction (Codex on #40880): a run outside the scanner's
                # verdict codes, a signal, a crash or a timeout is no verdict. At the head it refuses; at the base it
                # subtracts nothing, here or in the dependency check's stale-line diff.
                codes = SCANNER_VERDICT_CODES.get(name, DEFAULT_VERDICT_CODES) if jobs[name][0] == "cmd" else None
                stopped = no_verdict(head_code, head_out, codes)
                if stopped:
                    found.append((name, [NoVerdict(f"{name} {stopped} at the pushed head instead of judging it, so the "
                                                   f"push is refused: "
                                                   f"{' '.join(head_out.strip().splitlines()[-2:])[:300]}")]))
                    continue
                if no_verdict(base_code, base_out, codes):
                    base_out = ""
                if name == DEPS_CHECK:
                    head_out, head_code = deps_findings(repo, base, head, base_out, head_out, head_code,
                                                        full_package=name in trees_for, cmd=jobs[name][1],
                                                        work=Path(tmp) / "deps-head", trusted_scripts=trusted_scripts)
                if head_code == 0:
                    continue  # passing on the head: what it prints is a warning tier, as in CI
                fresh = new_records(base_out, head_out, name_base, name_head)
                if fresh:
                    found.append((name, fresh))
        # Its scan after the scanners: it adds files to the trees (the modules that declare a changed file, deleted
        # files). Its git reads ran next to them.
        if prepared is not None:
            ready = prepared.result()
            t0 = time.monotonic()
            fresh = crash_ratchet_findings(repo, base, head, base_tree, head_tree, crates, ready)
            if timings:
                log(f"  {time.monotonic() - t0:5.2f}s  {CRASH_RATCHET_CHECK} (after the scanners; its git reads, "
                    f"{ready[3]:.2f}s, ran next to them)")
            if fresh:
                found.append((CRASH_RATCHET_CHECK, fresh))
    if timings:
        log(f"prepush-gate: {len(changed)} changed file(s), {time.monotonic() - started:.1f}s")
    return found


COMPILE_REMOTE = re.compile(r"github\.com[:/]+manaflow-ai/cmux(\.git)?/?$")
COMPILE_REF = "refs/heads/feat-cmux-next"


def compile_ranges(repo: Path, pushed_lines: list[str], push_range=None,
                   remote: str | None = "origin") -> list[tuple[str, str]]:
    """The pushed ranges the compile trailer rule applies to: those that update manaflow-ai/cmux's feat-cmux-next (the
    hook passes the remote's URL in CMUX_PREPUSH_REMOTE_URL), as (base, head) of the push's own commits
    (PUSH_RANGE.pushed_ranges over REMOTE; PUSH_RANGE is the push_range.py next to this file when None; a merge's base
    is the merged upstream). A row whose own range cannot be told is left out: main() refuses the push for it. A side
    branch is where an agent pushes a commit to compile it (cmux-ci compile-check needs it pushed), so a side-branch
    push needs no trailer."""
    if not COMPILE_REMOTE.search(os.environ.get("CMUX_PREPUSH_REMOTE_URL", "")):
        return []
    lines = [line for line in pushed_lines if len(line.split()) == 4 and line.split()[2] == COMPILE_REF]
    if not lines:
        return []
    push_range = push_range or load_push_range(repo, Path(__file__).resolve().parent)
    ranges, _errors = push_range.pushed_ranges(repo, lines, remote)
    return [(own.base, own.head) for own in ranges]


def compile_trailer(repo: Path, ranges: list[tuple[str, str]], trusted_scripts: Path | None) -> bool:
    """The compile trailer rule (compile_trailer.py, lead 2026-10-24): a push that changes Swift names a passing compile
    job (`Compiled: <cmux-ci job id>`) of its Swift. Local only (like the guardrails), from the installed copy for the
    hook; any error or a controller that does not answer in 5 s lets the push through with a loud
    `!!! COMPILE TRAILER NOT CHECKED` line naming the reason. True: refused."""
    script = (trusted_scripts / "compile_trailer.py") if trusted_scripts else (repo / SCRIPTS / "compile_trailer.py")
    if not ranges or not script.is_file():
        return False
    try:
        spec = importlib.util.spec_from_file_location("cmux_next_compile_trailer", script)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        refused, lines = module.check(repo, ranges)
    except Exception as error:  # noqa: BLE001 - fail open: a bug here must not block every push
        log(f"!!! COMPILE TRAILER NOT CHECKED: compile_trailer.py failed ({type(error).__name__}: {error}). The push "
            "goes through UNCHECKED; the tip may not build. Say so in your report. !!!")
        return False
    for line in lines:
        log(line)
    return bool(refused)


def finding_key(record: str) -> str:
    """What gate_own matches a finding by: a scanner's normalized key, else (a git-only check) its text."""
    return getattr(record, "key", record)


def gate_own(repo: Path, own, only: set[str] | None, timings: bool,
             trusted_scripts: Path | None = None, swiftformat_layer: bool = False,
             highlights_layer: bool = False) -> list[tuple[str, list[str]]]:
    """[(check, findings)] the push's own range OWN (push_range.OwnRange) adds.

    gate() over own.base..own.head; for a merge (own.before), less what gate() finds over each range the push
    does not own (push_range.less): the old remote head's delta over the upstream it started from. Findings are
    matched by finding_key (a scanner's by file, rule and source text with no line or count numbers; a git-only
    check's by its text). Those runs read only the files the push's own range changes (a finding elsewhere
    cannot take one off), so a merge costs the branch's delta, never the files upstream changed. A scanner whose
    text depends on other files in its tree can word one finding differently in the two runs; it is then not
    taken off and refuses (fails closed). A record without a file location in a check that also printed located
    ones describes them (`check-crash-safety: 1 violation(s)`): it is kept only when one of that check's located
    findings is."""
    found = gate(repo, own.base, own.head, only, timings, trusted_scripts, swiftformat_layer=swiftformat_layer,
                 highlights_layer=highlights_layer)
    if not own.before or not found:
        return found
    changed = set(changed_files(repo, own.base, own.head)) | set(deleted_package_swift(repo, own.base, own.head))
    changed |= {p for p in git(repo, "diff", "--name-only", "--no-renames", "-z", own.base, own.head, "--",
                               HIGHLIGHTS_DIR).decode().split("\0") if p}
    before = [dict(gate(repo, b, a, only, timings, trusted_scripts, restrict=changed, swiftformat_layer=swiftformat_layer,
                        highlights_layer=highlights_layer))
              for b, a in own.before]
    push_range = sys.modules[PUSH_RANGE_MODULE]
    kept = []
    for name, fresh in found:
        # A run of the check that gave no verdict over an upstream range takes nothing off: what it printed is not
        # its findings. A NoVerdict of the push's own range is never taken off (its key matches nothing).
        sides = [run.get(name, []) for run in before]
        mine = push_range.less(fresh, [[] if any(isinstance(r, NoVerdict) for r in side) else side for side in sides],
                               key=finding_key)
        if (any(LOCATION.search(r) for r in fresh) and not any(LOCATION.search(r) for r in mine)
                and not any(isinstance(r, NoVerdict) for r in mine)):
            mine = []
        if mine:
            kept.append((name, mine))
    return kept


CHECKS_IN_USE = ".in-use"


def claim_trusted_scripts(link: Path):
    """(the checks copy LINK points at, an open handle that holds it in use until this process exits).

    install-git-hooks.sh removes a copy only when it can take an exclusive flock on the copy's .in-use, and
    renames it away first while holding that lock; this takes a shared one. A copy removed between resolving
    the link and taking the lock is seen (open fails, or the file has no link left) and the link resolved
    again: a link only ever moves to a newer copy. A copy without .in-use is from an install before the lock
    (handle None), as is a link that points at nothing (the caller refuses it).
    """
    target = link.resolve()
    while True:
        try:
            handle = open(target / CHECKS_IN_USE, "rb")
        except FileNotFoundError:
            again = link.resolve()
            if again == target:
                return target, None
            target = again
            continue
        fcntl.flock(handle, fcntl.LOCK_SH)
        if os.fstat(handle.fileno()).st_nlink > 0:
            return target, handle
        handle.close()
        target = link.resolve()


def load_guardrails(repo: Path, trusted_scripts: Path | None):
    """The guardrails module: the installed reviewed copy for the hook, else this checkout's."""
    script = (trusted_scripts / "guardrails.py") if trusted_scripts else (repo / SCRIPTS / "guardrails.py")
    if not script.is_file():
        return None
    spec = importlib.util.spec_from_file_location("cmux_next_guardrails", script)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


def start_guardrails(repo: Path, ranges: list, trusted_scripts: Path | None):
    """(module, ratchet, error): guardrails.py loaded, and its arch ratchet started on a thread at once.

    The ratchet runs next to the scanners, so the push pays what is left of it when the gate reaches the
    guardrails (its cost is the Swift files it reads and analyzes; guardrails.Ratchet). A load error is
    reported there (fail open).
    """
    try:
        module = load_guardrails(repo, trusted_scripts)
        if module is None:
            return None, None, ("guardrails.py is not installed; rerun scripts/install-git-hooks.sh"
                                if trusted_scripts else None)
        start = getattr(module, "start_ratchet", None)
        return module, (start(repo, ranges) if start is not None else None), None
    except (Exception, SystemExit) as error:  # SystemExit: guardrails.git() exits on a failed git call
        return None, None, (f"WARNING: guardrails.py failed ({type(error).__name__}: {error}); not applied to this "
                            "push. Tell the Performance Lead (PL-guardrails) with this line.")


def guardrails(repo: Path, ranges: list, started) -> bool:
    """Print the guardrail warnings and refusals (line rules and arch ratchet) for RANGES; True when they refuse.

    STARTED is start_guardrails()'s result. The rules are advisory debt checks in every agent's hook: a bug in
    one rule turns off only that rule (guardrails.check warns and runs the rest); a bug outside the rules (a
    failed load or git call, a parse edge) prints a warning and lets the push through instead of blocking
    every push with a traceback. RANGES are the gate's push_range.OwnRange values, so the guardrails judge the
    same own commits as the scanners: what a push only brings in from origin/feat-cmux-next (a merge of it, or a
    rebase onto it and a force push) never counts, because CI never runs these rules and that base can carry
    debt.
    """
    module, ratchet, error = started
    if error:
        log(f"prepush-gate: {error}")
        return False
    if module is None:
        return False
    try:
        return bool(module.run_push(repo, ranges, ratchet))
    except (Exception, SystemExit) as error:  # SystemExit: guardrails.git() exits on a failed git call
        log(f"prepush-gate: WARNING: guardrails.py failed ({type(error).__name__}: {error}); not applied to "
            "this push. Tell the Performance Lead (PL-guardrails) with this line.")
        return False


# The perf cron's unit tests (scripts/cmux-next/perf-cron.py) never run on CI (Lawrence 2026-10-23: no new CI tests;
# the owner runs them), and the hook never runs them either: they are the push's own code. When a push changes the
# cron or its tests, the gate names them and the command to run them (perf_cron_tests).
PERF_CRON_PATHS = ("scripts/cmux-next/perf-cron", "scripts/cmux-next/tests/test_perf_cron")


def perf_cron_tests(repo: Path, ranges: list) -> None:
    """Name the perf cron's unit tests when a pushed head's own changes touch the perf cron; never run them.

    They are that head's own code, and the hook never runs code the push controls (docs/contributor-verification.md,
    trust boundary: a pushed branch may be a contributor's). Running the reviewed copy of the tests would still import
    the pushed perf-cron.py. CI does not run them either (no new CI tests), so the person runs them on code they
    trust, with the command printed here. RANGES are push_range.OwnRange values: a path counts when it changes over
    the base and since the head of every range the push does not own. Never refuses the push."""
    for own in ranges:
        head = own.head
        try:
            # changed_files keeps only the app's source scopes; the cron is under scripts/.
            changed = [{p for p in git(repo, "diff", "--name-only", "--no-renames", "-z", base, head).decode().split("\0") if p}
                       for base in [own.base, *(a for _, a in own.before)]]
        except (Exception, SystemExit) as error:  # SystemExit: git() exits on a failed git call
            log(f"prepush-gate: WARNING: could not tell whether {head[:12]} changes the perf cron "
                f"({type(error).__name__}: {error}).")
            continue
        touched = sorted(p for p in set.intersection(*changed) if p.startswith(PERF_CRON_PATHS))
        if touched:
            log(f"prepush-gate: {head[:12]} changes the perf cron ({', '.join(touched[:3])}"
                f"{' ...' if len(touched) > 3 else ''}). The hook does not run its unit tests: they are this push's own "
                "code. Run them yourself on code you trust: python3 -I -m unittest discover -s scripts/cmux-next/tests "
                "-p 'test_perf_cron*.py'.")


# guardrails.py loads count-swift-code-lines.py (CI's lexer) from the installed copy: an old one counts
# source lines unlike CI's check-app-size.sh. push_range.py decides which commits are the push's own, for the
# gate, guardrails.py and arch-ratchet.py alike. The arch_rules/*.py modules are compared as a folder
# (_stale_rules), so a rule module added upstream needs no entry here.
TRUSTED_COPIES = ("prepush-gate.py", "guardrails.py", "count-swift-code-lines.py", "arch-ratchet.py", "arch_counts.py",
                  "push_range.py", "git_batch.py")
RULES_SUBDIR = "arch_rules"


def _blob_id(data: bytes, hex_len: int) -> str:
    """The git object id of a blob with DATA (sha1, or sha256 in a sha256 repository)."""
    digest = hashlib.sha256 if hex_len == 64 else hashlib.sha1
    return digest(b"blob %d\0" % len(data) + data).hexdigest()


def _stale_rules(tree: bytes, hex_len: int, installed: Path) -> list[str]:
    """The arch_rules/*.py files whose installed copy differs from TREE's (a raw git tree object)."""
    want: dict[str, str] = {}
    raw_len = hex_len // 2
    i = 0
    while i < len(tree):
        nul = tree.find(b"\0", i)
        if nul < 0:
            break
        mode, _, name = tree[i:nul].partition(b" ")
        oid = tree[nul + 1:nul + 1 + raw_len].hex()
        i = nul + 1 + raw_len
        if mode.startswith(b"100") and name.endswith(b".py"):
            want[name.decode(errors="replace")] = oid
    have = {p.name: p for p in installed.glob("*.py")} if installed.is_dir() else {}
    stale = [f"{RULES_SUBDIR}/{n}" for n, oid in sorted(want.items())
             if n not in have or _blob_id(have[n].read_bytes(), hex_len) != oid]
    stale += [f"{RULES_SUBDIR}/{n} (removed upstream)" for n in sorted(set(have) - set(want))]
    return stale


def stale_hook_warning(repo: Path, trusted_scripts: Path) -> None:
    """Warn when the installed checker copies differ from origin/feat-cmux-next's (a rebase never refreshes them).

    The copies: TRUSTED_COPIES and every arch_rules/*.py module (a rule the install missed never runs).
    """
    for ref in DEFAULT_BASE_REFS:
        if not rev_ok(repo, ref):
            continue
        stale = []
        # One `git cat-file --batch` for every copy and the arch_rules tree (a `git show` each cost a process).
        names = [f"{SCRIPTS}/{name}" for name in TRUSTED_COPIES] + [f"{SCRIPTS}/{RULES_SUBDIR}"]
        batch = "".join(f"{ref}:{name}\n" for name in names).encode()
        out = git_batch.run(repo, ["cat-file", "--batch"], batch).stdout
        i = 0
        for index, name in enumerate(names):
            nl = out.find(b"\n", i)
            if nl < 0:
                break
            header = out[i:nl].split()
            i = nl + 1
            if len(header) < 3 or header[1] not in (b"blob", b"tree"):
                continue
            size = int(header[2])
            theirs = out[i:i + size]
            i += size + 1
            if header[1] == b"tree":
                stale += _stale_rules(theirs, len(header[0]), trusted_scripts / RULES_SUBDIR)
                continue
            mine = trusted_scripts / TRUSTED_COPIES[index]
            if not mine.is_file() or mine.read_bytes() != theirs:
                stale.append(TRUSTED_COPIES[index])
        # The pre-push hook itself (it passes the remote's URL to the compile trailer rule, 7ea27860336): the
        # installed hook sits next to the checks folder.
        hook = trusted_scripts.parent / "pre-push"
        tracked = subprocess.run(["git", "-C", str(repo), "show", f"{ref}:scripts/git-hooks/pre-push"], capture_output=True)
        if tracked.returncode == 0 and hook.is_file() and hook.read_bytes() != tracked.stdout:
            stale.append("pre-push (the hook)")
        if stale:
            log(f"prepush-gate: WARNING: this clone's installed hook copy of {', '.join(stale)} is not {ref}'s, so its "
                f"rules may be old: run scripts/install-git-hooks.sh from a checkout at {ref} (rebase and fetch do not).")
        return


def print_findings(found: list[tuple[str, list[str]]], header: str) -> None:
    print(header)
    for name, fresh in found:
        print(f"  {name}:")
        for record in fresh:
            for line in record.splitlines():
                print(f"    {line}")


HOW_TO_FIX = """\
Fix them before pushing (AGENTS.md, "Before every push"): background APIs instead of blocking calls,
typed errors instead of try!, TypeScale/Typography fonts, CmuxDialogSpec / CmuxDialogActionButton for
dialogs, translucent theme tints on glass. A reviewed escape comment (`// concurrency-allow: <why>`,
`// crash-allow: <why>`, `dialog-keys-exempt: <why>`, `// glass-opaque-allow: <why>`) is allowed only when the code is provably safe.
Never --no-verify: CI names every commit that adds a violation (step "Pushed commits add no violations")."""


# ---------------------------------------------------------------- advisory (CI: named, never a gate)

# The pull request's fast gates pass --advisory (scripts/ci/cmux_next_fast_gates.py, its existing "prepush gate").
# The four layers below never run on CI otherwise, so a push that skipped the hook landed what they would have
# refused and nobody saw it. Here they run on the same range and each finding is a `::warning file=,line=` annotation
# plus a row in the step summary. They never change the exit code: the step passes or fails exactly as it did
# without them. AGENTS.md / CLAUDE.md: "Never add CI gates, perf-gate rows or budgets, CI jobs or steps, or CI
# tests" (Lawrence 2026-10-23: "not to add gates/tests in CI, but you have to run them yourself"): this is no gate,
# no job and no step; it is advisory, as fleet-test-compile.yml is ("It gates nothing"). The hook stays the gate.
ADVISORY_ARCH = "arch ratchet"
ADVISORY_GUARDRAILS = "guardrails line rules"
ADVISORY_SWIFTFORMAT = "SwiftFormat"
ADVISORY_PICTURES = "What's New pictures"
ADVISORY_LAYERS = (ADVISORY_ARCH, ADVISORY_GUARDRAILS, ADVISORY_SWIFTFORMAT, ADVISORY_PICTURES)
# The whole advisory pass, in its own process group (advisory_supervise): past it the group is killed and one
# "timed out" warning is printed. CMUX_PREPUSH_ADVISORY_SECONDS sets it (a test's short deadline); it skips nothing.
ADVISORY_SECONDS = 240.0
ADVISORY_SECONDS_ENV = "CMUX_PREPUSH_ADVISORY_SECONDS"
ADVISORY_ANNOTATIONS = 50  # GitHub shows at most this many annotations of a job; the summary has every count
# A site under an arch ratchet refusal: `  path:line: text` (a count row) or `  path: text` (an escape site).
ARCH_SITE = re.compile(r"^\s+(?P<path>[\w.+@/-]+\.\w+)(?::(?P<line>\d+))?: (?P<text>.*)$")


class AdvisoryFinding:
    __slots__ = ("layer", "path", "line", "title", "message")

    def __init__(self, layer: str, path: str | None, line: int | None, title: str, message: str) -> None:
        self.layer, self.path, self.line, self.title, self.message = layer, path, line, title, message


def _workflow_data(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def _workflow_property(text: str) -> str:
    return _workflow_data(text).replace(":", "%3A").replace(",", "%2C")


def advisory_annotation(finding: AdvisoryFinding) -> str:
    """The `::warning` workflow command for FINDING: file and line when it has them, the layer in its title."""
    props = []
    if finding.path:
        props.append(f"file={_workflow_property(finding.path)}")
        if finding.line:
            props.append(f"line={finding.line}")
    props.append(f"title={_workflow_property(f'prepush advisory ({finding.layer}) {finding.title}')}")
    return f"::warning {','.join(props)}::{_workflow_data(finding.message)}"


def _repo_path(repo: Path, path: str) -> str:
    """PATH as a repository path (an annotation's file=): as given, or under the package when it is relative to it."""
    for prefix in ("", PKG + "/", PKG + "/Sources/"):
        if (repo / (prefix + path)).exists():
            return prefix + path
    return path


def _load_script(repo: Path, name: str, filename: str):
    script = repo / SCRIPTS / filename
    spec = importlib.util.spec_from_file_location(name, script)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


# An arch ratchet note that says part of the push was not judged (a rule module or the ratchet failed, a row's map did
# not parse): the layer is incomplete, never clean.
ARCH_DIAGNOSTIC = re.compile(r"^arch-ratchet: (WARNING: |.*\bnot judged\b)")


def advisory_arch(repo: Path, ranges: list) -> tuple[list[AdvisoryFinding], list[str]]:
    """(findings, diagnostics): the arch ratchet's refusals for RANGES, one finding per named site (or one for a
    refusal that names none), and its notes that say something was not judged."""
    module = _load_script(repo, "cmux_next_arch_ratchet", "arch-ratchet.py")
    refusals, notes = module.push_refusals(repo, ranges)
    diagnostics = [str(note) for note in notes if ARCH_DIAGNOSTIC.match(str(note))]
    found = []
    for row, text in refusals:
        lines = text.splitlines()
        title = re.sub(r"^arch-ratchet: ", "", lines[0]).strip() if lines else f"[{row}]"
        sites = [m for m in (ARCH_SITE.match(line) for line in lines[1:]) if m]
        for m in sites:
            found.append(AdvisoryFinding(ADVISORY_ARCH, _repo_path(repo, m.group("path")),
                                         int(m.group("line")) if m.group("line") else None, f"[{row}]",
                                         f"{title}: {m.group('text').strip()}"))
        if not sites:
            found.append(AdvisoryFinding(ADVISORY_ARCH, None, None, f"[{row}]", text))
    return found, diagnostics


def advisory_guardrails(repo: Path, ranges: list) -> tuple[list[AdvisoryFinding], list[str]]:
    """(findings, diagnostics): guardrails.py's line rules (and its Ghostty pin) for RANGES, one finding per refused
    line, and check_own's own failure warnings (kind "guardrails": a rule that raised and was not applied)."""
    module = load_guardrails(repo, None)
    if module is None:
        raise RuntimeError(f"{SCRIPTS}/guardrails.py is missing")
    found, diagnostics = [], []
    for own in module.load_push_range().as_own_ranges(repo, ranges):
        refusals, warnings = module.check_own(repo, own.base, own.head, own.before)
        diagnostics += [text for kind, text in warnings if kind == "guardrails" and text not in diagnostics]
        for rule, hits in refusals:
            for hit in hits:
                found.append(AdvisoryFinding(ADVISORY_GUARDRAILS, hit.path, hit.number or None, f"[{rule.id}]",
                                             f"{rule.title}: {hit.text.strip()[:140]}. Do: {rule.fix}"))
        try:
            pin = module.ghostty_pin_problem(repo, own.base, own.head, own.before)
        except Exception as error:  # noqa: BLE001 - as run_push: the pin check failing is a diagnostic
            diagnostics.append(module.check_failure("ghostty-pin", error))
            pin = None
        if pin:
            found.append(AdvisoryFinding(ADVISORY_GUARDRAILS, None, None, "[ghostty-pin]", pin))
    return found, diagnostics


def _record_findings(layer: str, repo: Path, found: list[tuple[str, list[str]]]) -> list[AdvisoryFinding]:
    out = []
    for name, records_ in found:
        for record in records_:
            first = str(record).splitlines()[0] if str(record) else ""
            at = LOCATION.match(first)
            if at:
                path, line = at.group("path"), int(at.group("line"))
            else:
                path, line = (first.partition(": ")[0] or None), None
            out.append(AdvisoryFinding(layer, _repo_path(repo, path) if path else None, line, name, str(record)))
    return out


def advisory_swiftformat(repo: Path, ranges: list) -> tuple[list[AdvisoryFinding], list[str], str | None]:
    """(findings, the reason the layer was skipped or None). Skipped, not installed, when the runner has no binary:
    the rule above forbids an install step."""
    if not any(p.startswith(SWIFT_SCOPE) and p.endswith(".swift")
               for own in ranges for p in changed_files(repo, own.base, own.head)):
        return [], [], "no Swift file changed"
    lock = repo / SCRIPTS / "lint-tools.lock"
    try:
        binary = ensure_tool(lock, "swiftformat")
        probe = subprocess.run([str(binary), "--version"], capture_output=True, text=True, timeout=30,
                               stdin=subprocess.DEVNULL)
    except (Exception, SystemExit) as error:  # noqa: BLE001 - no binary for this runner: say so, never fail
        return [], [], f"no SwiftFormat binary on this runner ({type(error).__name__}: {error})"
    if probe.returncode != 0:
        return [], [], f"the pinned SwiftFormat does not run on this runner: {(probe.stderr or probe.stdout).strip()[:200]}"
    found = []
    for own in ranges:
        found += gate_own(repo, own, {"swiftformat"}, False, None, swiftformat_layer=True)
    return _record_findings(ADVISORY_SWIFTFORMAT, repo, found), [], None


def advisory_pictures(repo: Path, ranges: list) -> tuple[list[AdvisoryFinding], list[str]]:
    found = []
    for own in ranges:
        found += gate_own(repo, own, {"pictures"}, False, None)
    return _record_findings(ADVISORY_PICTURES, repo, found), []


def _summary(summary: str | None, rows: list[tuple[str, str]]) -> None:
    if not summary:
        return
    lines = ["### prepush advisory (hook-only checks, never a gate)", "",
             "Run on CI only to show what a push that skipped the pre-push hook adds; the step's result is "
             "unchanged by them.", "", "| check | result |", "| --- | --- |"]
    lines += [f"| {name} | {result.replace('|', '/')} |" for name, result in rows]
    try:
        with open(summary, "a", encoding="utf-8") as stream:
            stream.write("\n".join(lines) + "\n\n")
    except OSError as error:
        print(f"prepush-gate: advisory: could not write the step summary ({error})", flush=True)


def advisory_run(repo: Path, ranges: list, summary: str | None) -> None:
    """The advisory child (--advisory-only): run the hook-only layers on RANGES one after the other, print each
    finding as a `::warning`, each internal failure diagnostic as a `::warning` too, and the summary table.

    A layer whose checker reports it did not judge everything (a rule that raised, a ratchet note that says "not
    judged") or that raised itself is "incomplete", never "clean"."""
    rows: list[tuple[str, str]] = []
    findings: list[AdvisoryFinding] = []
    diagnostics: list[tuple[str, str]] = []
    layers = ((ADVISORY_ARCH, advisory_arch), (ADVISORY_GUARDRAILS, advisory_guardrails),
              (ADVISORY_SWIFTFORMAT, advisory_swiftformat), (ADVISORY_PICTURES, advisory_pictures))
    for name, fn in layers:
        t0 = time.monotonic()
        try:
            got = fn(repo, ranges)
        except (Exception, SystemExit) as error:  # noqa: BLE001 - advisory: report it, never fail the gate
            text = f"did not run ({type(error).__name__}: {str(error)[:300]})"
            diagnostics.append((name, text))
            rows.append((name, f"incomplete: {text}"))
            continue
        found, notes, skipped = (got + (None,))[:3]
        if skipped:
            rows.append((name, f"skipped: {skipped}"))
            continue
        findings.extend(found)
        diagnostics += [(name, note) for note in notes]
        took = f" ({time.monotonic() - t0:.1f}s)"
        if notes:
            rows.append((name, f"incomplete: {len(found)} finding(s), {len(notes)} check(s) did not run{took}"))
        else:
            rows.append((name, (f"{len(found)} finding(s)" if found else "clean") + took))
    print("prepush-gate: advisory, hook-only checks on this range (they never fail this step): "
          + "; ".join(f"{name}: {result}" for name, result in rows), flush=True)
    for name, text in diagnostics:
        print(f"::warning title={_workflow_property(f'prepush advisory ({name}) incomplete')}::{_workflow_data(text)}",
              flush=True)
    for finding in findings[:ADVISORY_ANNOTATIONS]:
        print(advisory_annotation(finding), flush=True)
    if len(findings) > ADVISORY_ANNOTATIONS:
        print(f"prepush-gate: advisory: {len(findings) - ADVISORY_ANNOTATIONS} more finding(s) not annotated", flush=True)
    _summary(summary, rows)


def advisory_seconds() -> float:
    raw = os.environ.get(ADVISORY_SECONDS_ENV, "").strip()
    try:
        return float(raw) if raw else ADVISORY_SECONDS
    except ValueError:
        return ADVISORY_SECONDS


def advisory_start(repo: Path, base: str | None, head: str):
    """Start the advisory child (this script, --advisory-only) in its own process group, or None when it cannot
    start. Its own session, so advisory_finish can kill everything it started (git, the arch checks' workers)."""
    cmd = [sys.executable, "-I", str(Path(__file__).resolve()), "--advisory-only", "--repo", str(repo), "--head", head]
    if base:
        cmd += ["--base", base]
    sys.stdout.flush()
    try:
        return subprocess.Popen(cmd, cwd=repo, start_new_session=True, stdin=subprocess.DEVNULL), time.monotonic()
    except OSError as error:
        print(f"::warning title=prepush advisory did not start::{_workflow_data(str(error))}", flush=True)
        return None


def advisory_finish(started, summary: str | None, seconds: float) -> None:
    """Wait for the advisory child until SECONDS after it started. Past that: SIGTERM then SIGKILL to its whole
    process group, reap it, and print one "timed out" warning. Returns nothing: the gate's exit code never depends
    on the child (Codex review of #40811: a stalled child joined at interpreter exit ran into the gate's watchdog)."""
    if started is None:
        return
    process, t0 = started
    try:
        code = process.wait(timeout=max(0.0, seconds - (time.monotonic() - t0)))
    except subprocess.TimeoutExpired:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(process.pid, sig)
            except (ProcessLookupError, PermissionError):
                break
            try:
                process.wait(timeout=GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                pass
        try:
            os.killpg(process.pid, signal.SIGKILL)  # members that outlived the leader
        except (ProcessLookupError, PermissionError):
            pass
        try:
            process.wait(timeout=GRACE_SECONDS + 5)
        except subprocess.TimeoutExpired:
            pass
        print(f"::warning title=prepush advisory timed out::the hook-only checks gave no result in {seconds:g}s and "
              "were stopped; this step's result is unchanged. Run the pre-push hook (or prepush-gate.py) locally.",
              flush=True)
        _summary(summary, [(name, f"incomplete: timed out after {seconds:g}s") for name in ADVISORY_LAYERS])
        return
    if code != 0:
        print(f"::warning title=prepush advisory incomplete::the advisory pass exited {code}; this step's result is "
              "unchanged.", flush=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=None)
    parser.add_argument("--base")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--pre-push", action="store_true", help="read pre-push stdin (the hook)")
    parser.add_argument("--trusted-scripts-dir", help="installed reviewed checker snapshot (required with --pre-push)")
    parser.add_argument("--remote", default="origin",
                        help="the pushed remote's name (the hook's first argument; a URL for a push to a URL)")
    parser.add_argument("--commits", help="CI: check each non-merge commit of RANGE against its first parent")
    parser.add_argument("--own-range", help="sidebar sweep on a pull request: the PR's own commits (BASE..HEAD). A "
                                            "finding on a commit outside it (on the base) is a warning that names the "
                                            "commit and the owner file; one inside it is an error")
    parser.add_argument("--only", help="comma list of layers: scanners,ast-grep,swiftformat,rustfmt,swiftlint,reserved,ui-font,conflicts,"
                                       "cargo-lock,sidebar,crash-allow,crash-ratchet,freeze,highlights,pictures,workflows,"
                                       "single-host-fallbacks")
    parser.add_argument("--timings", action="store_true")
    parser.add_argument("--no-guardrails", action="store_true", help="skip guardrails.py and its arch ratchet (they never run on CI)")
    parser.add_argument("--advisory-only", action="store_true", help=argparse.SUPPRESS)  # advisory_start's child
    parser.add_argument("--advisory", action="store_true",
                        help="CI (the fast gates): also run the hook-only layers (arch ratchet, guardrails line rules, "
                             "SwiftFormat, What's New pictures) and print each finding as a ::warning; never changes "
                             "the exit code")
    args = parser.parse_args(argv)
    repo = Path(args.repo or git(Path.cwd(), "rev-parse", "--show-toplevel").decode().strip())
    only = set(args.only.split(",")) if args.only else None
    started = time.monotonic()
    # The handle keeps the installed checks copy this run reads in use until main returns (claim_trusted_scripts).
    trusted_scripts, _in_use = (claim_trusted_scripts(Path(args.trusted_scripts_dir)) if args.trusted_scripts_dir
                                else (None, None))
    if args.pre_push and (trusted_scripts is None or not trusted_scripts.is_dir()):
        raise SystemExit("prepush-gate: --pre-push requires the installed --trusted-scripts-dir snapshot")

    if args.commits and only == {"sidebar"}:
        # The sidebar sweep: one pass over the range (per commit already: each commit is judged on its own).
        tip = git(repo, "rev-parse", args.commits.split("..")[-1] or "HEAD").decode().strip()
        base = args.commits.split("..")[0]
        found = sidebar_owner_by_commit(repo, base, tip)
        # A pull request is judged on its own commits: a base commit without the owner's record is the base's
        # debt, named as a warning here and still an error on every push sweep of the branch (2026-10-29: two
        # base commits put an error on every feat-cmux-next pull request's checks, #27454).
        own = (set(git(repo, "rev-list", "--no-merges", args.own_range).decode().split())
               if args.own_range else None)
        fresh = [finding for sha, finding in found if own is None or sha in own]
        inherited = [(sha, finding) for sha, finding in found if own is not None and sha not in own]
        if fresh:
            print_findings([(SIDEBAR_CHECK, fresh)], "prepush-gate: sidebar commits without the owner's record:")
            print(f"::error title=Sidebar look owner::{len(fresh)} commit(s) change the sidebar's drawing code without "
                  "a Sidebar-Look: trailer or an entry in plans/cmux-next/sidebar-owner.md")
        for sha, finding in inherited:
            # The whole finding (one line); % escaped, as a workflow command reads %0A as a new line.
            text = (f"{finding} This commit is on the base, not in this pull request: the owner logs {sha[:11]} in "
                    f"{SIDEBAR_NOTE}.").replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print(f"::warning title=Sidebar look owner (base commit)::{text}")
        print(f"prepush-gate: sidebar sweep {base[:11]}..{tip[:11]}, {len(fresh)} finding(s)"
              + (f", {len(inherited)} on base commits (warnings)" if inherited else "")
              + f" ({time.monotonic() - started:.1f}s)")
        return 1 if fresh else 0

    if args.commits:
        commits = git(repo, "rev-list", "--reverse", "--no-merges", args.commits).decode().split()
        bad = 0
        for sha in commits:
            parent = f"{sha}^"
            if not rev_ok(repo, parent):
                continue
            # The owner's log is read at the tip of the range: a later commit may log an earlier one.
            found = gate(repo, parent, sha, only, args.timings, trusted_scripts, ack_rev=commits[-1])
            if found:
                bad += 1
                subject = git(repo, "log", "-1", "--format=%h %an: %s", sha).decode().strip()
                print_findings(found, f"commit {subject} adds violations:")
                for name, fresh in found:
                    print(f"::error title=commit {sha[:11]} adds violations::{name}: {len(fresh)} new finding(s)")
        print(f"prepush-gate: {len(commits)} commit(s) checked, {bad} add violations "
              f"({time.monotonic() - started:.1f}s)")
        return 1 if bad else 0

    push_range = load_push_range(repo, trusted_scripts)
    pushed_lines: list[str] = []
    try:
        if args.pre_push:
            pushed_lines = sys.stdin.read().splitlines()
            ranges, errors = push_range.pushed_ranges(repo, pushed_lines, args.remote)
        else:
            # A run by hand fetches the shared base first, as a push does (push_range.manual_range); an installed
            # copy older than it has only own_range.
            manual = getattr(push_range, "manual_range", None) or push_range.own_range
            ranges, errors = [push_range.given_range(repo, args.base, args.head) if args.base
                              else manual(repo, args.head)], []
    except ValueError as error:  # a git call failed (a commit gone between two reads)
        ranges, errors = [], [str(error)]
    if errors:
        # Refused on purpose: with no bound on the pushed commits the gate cannot tell what the push adds.
        for error in errors:
            print(f"prepush-gate: cannot tell which commits are this push's own: {error}")
        print("prepush-gate: push refused; nothing was checked. Fix the clone as said above and push again.")
        return 1
    if args.advisory_only:
        advisory_run(repo, ranges, os.environ.get("GITHUB_STEP_SUMMARY"))
        return 0
    for own in ranges:
        log(f"prepush-gate: judging {own.describe()}")
    # Next to the gate, in its own process group; joined (or killed at its deadline) after the gate's own checks.
    advised = (advisory_start(repo, args.base, args.head) if args.advisory and only is None and not args.pre_push
               else None)
    # Local only: CI runs this script too (--commits, and --base/--head on pull requests), and must gain no gate.
    local_only = not args.no_guardrails and not os.environ.get("GITHUB_ACTIONS") and only is None
    started_guardrails = start_guardrails(repo, ranges, trusted_scripts) if local_only else None
    # SwiftFormat only for the pre-push hook and a plain local run (no --base: CI's pull request run, the fast gates
    # and the car guards name one), never on GitHub Actions.
    swiftformat_layer = not args.base and not os.environ.get("GITHUB_ACTIONS")
    found_any = []
    for own in ranges:
        # The highlights run where SwiftFormat runs: the hook and a plain local run, never CI or a merge-time gate.
        found_any += gate_own(repo, own, only, args.timings, trusted_scripts, swiftformat_layer,
                              highlights_layer=swiftformat_layer)
    advisory_finish(advised, os.environ.get("GITHUB_STEP_SUMMARY"), advisory_seconds())
    if args.pre_push and trusted_scripts:
        stale_hook_warning(repo, trusted_scripts)
    guarded = False
    if local_only:
        t0 = time.monotonic()
        guarded = guardrails(repo, ranges, started_guardrails)
        if args.timings:
            ratchet = started_guardrails[1]
            waited = getattr(ratchet, "waited", None)
            log(f"  {time.monotonic() - t0:5.2f}s  guardrails (line rules, and the arch ratchet's wait left: it "
                "ran next to the scanners)"
                + (f"; of it {waited:.2f}s waiting for the arch ratchet" if isinstance(waited, float) else ""))
        t0 = time.monotonic()
        perf_cron_tests(repo, ranges)  # names the perf cron tests a push changes; never refuses
        if args.timings:
            log(f"  {time.monotonic() - t0:5.2f}s  perf cron (named, not run)")
        t0 = time.monotonic()
        guarded = compile_trailer(repo, compile_ranges(repo, pushed_lines, push_range, args.remote), trusted_scripts) or guarded
        if args.timings:
            log(f"  {time.monotonic() - t0:5.2f}s  compile trailer")
    elapsed = time.monotonic() - started
    if not found_any:
        if guarded:
            print(f"prepush-gate: push refused by the guardrails or the compile trailer ({elapsed:.1f}s)")
            return 1
        print(f"prepush-gate: no new violations ({elapsed:.1f}s)")
        return 0
    skip = os.environ.get("CMUX_NEXT_CHECKS_SKIP_REASON", "").strip()
    print_findings(found_any, "prepush-gate: this push adds violations:")
    if skip and any(name == CONFLICT_CHECK for name, _ in found_any):
        print(f"prepush-gate: CMUX_NEXT_CHECKS_SKIP_REASON does not skip {CONFLICT_CHECK}: finish the merge "
              "(keep one side of each hunk), then push.")
    elif skip and any(name == WORKFLOW_CHECK for name, _ in found_any):
        # A workflow GitHub cannot load stops every run of it (all its jobs, on every push), not one check.
        print(f"prepush-gate: CMUX_NEXT_CHECKS_SKIP_REASON does not skip {WORKFLOW_CHECK}. {WORKFLOW_HINT}")
    elif skip and any(name == SIDEBAR_CHECK for name, _ in found_any):
        print(f"prepush-gate: CMUX_NEXT_CHECKS_SKIP_REASON does not skip {SIDEBAR_CHECK}. Amend the commit with a "
              "`Sidebar-Look:` trailer (and the note for a visual change); the sidebar owner keeps the look.")
    elif skip and any(name == CHROME_CHECK for name, _ in found_any):
        print(f"prepush-gate: CMUX_NEXT_CHECKS_SKIP_REASON does not skip {CHROME_CHECK}. The chrome layer keeps its "
              "colour unless Leo asks, quoted in a `Chrome-Look-OK: Leo <date> \"<his words>\"` commit trailer.")
    elif skip and any(name == RESERVED_CHECK for name, _ in found_any):
        print(f"prepush-gate: CMUX_NEXT_CHECKS_SKIP_REASON does not skip {RESERVED_CHECK}. Changing a Ghostty-default "
              "shortcut needs the user's explicit OK, quoted in a `Ghostty-defaults-OK: <the user's words>` commit trailer.")
    elif skip and any(name == UI_FONT_CHECK for name, _ in found_any):
        print(f"prepush-gate: CMUX_NEXT_CHECKS_SKIP_REASON does not skip {UI_FONT_CHECK}. The UI font changes only "
              "on the user's order, quoted in a `Font-order: <the user's words>` commit trailer.")
    elif skip:
        print(f"prepush-gate: SKIPPED by CMUX_NEXT_CHECKS_SKIP_REASON={skip!r}. Say so in your report; "
              "CI still names the commit.")
        if guarded:
            print("prepush-gate: push refused by the guardrails (CMUX_NEXT_CHECKS_SKIP_REASON does not skip them)")
            return 1
        return 0
    if any(name == HIGHLIGHTS_CHECK for name, _ in found_any):
        print(HIGHLIGHTS_HINT)
    if any(name == PICTURES_CHECK for name, _ in found_any):
        lines = [line for name, found in found_any if name == PICTURES_CHECK for line in found]
        if any("no picture source" in line for line in lines):
            print(PICTURES_HINT)
        if any("with no before" in line for line in lines):
            print(PICTURES_BEFORE_HINT)
    if any(name == CARGO_LOCK_CHECK for name, _ in found_any):
        print(CARGO_HINT)
    if any(name == FALLBACKS_CHECK for name, _ in found_any):
        print(FALLBACKS_HINT)
    if any(name == CRASH_RATCHET_CHECK for name, _ in found_any):
        print(CRASH_RATCHET_HINT)
    if any(name == WORKFLOW_CHECK for name, _ in found_any):
        print(WORKFLOW_HINT)
    print(HOW_TO_FIX)
    print(f"prepush-gate: push refused ({elapsed:.1f}s)")
    return 1


GATE_LIMIT_SECONDS = 600.0  # a whole gate takes under a minute; a hang (a786, a796, a808: 28-30 min) refuses here


def _descendants(pid: int) -> list[int]:
    """Every live process this gate started, children first (from `ps`; the gate is not a process-group leader)."""
    try:
        rows = subprocess.run(["ps", "-A", "-o", "pid=,ppid="], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    kids: dict[int, list[int]] = collections.defaultdict(list)
    for row in rows.splitlines():
        parts = row.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            kids[int(parts[1])].append(int(parts[0]))
    out, todo = [], [pid]
    while todo:
        for kid in kids.get(todo.pop(), []):
            out.append(kid)
            todo.append(kid)
    return out


GRACE_SECONDS = 2.0  # how long a stopped process has to clean up before it is killed outright


def stop(pids: list[int], grace: float = GRACE_SECONDS) -> None:
    """Stop PIDS: SIGTERM, then SIGKILL whatever is still alive GRACE seconds later.

    Not SIGKILL first. A `git` that reads the working tree (`git diff --quiet HEAD`) takes `.git/index.lock`
    to write back the index it refreshed, and on SIGKILL that lock stays behind with no process left to blame,
    so the developer's next git command refuses ("Another git process seems to be running"). On SIGTERM git
    removes its own lock files. Measured on a checkout with stale index times (which is what a fresh checkout
    or a fetch leaves): SIGKILL left the lock in 3 of 3 runs, SIGTERM in 0 of 3 (live-apply-nightly saw this
    three times, 2026-11-04)."""
    def alive(pid: int) -> bool:
        try:
            os.kill(pid, 0)
        except OSError:
            return False
        return True

    for signum in (signal.SIGTERM, signal.SIGKILL):
        for pid in pids:
            try:
                os.kill(pid, signum)
            except OSError:
                pass
        if signum is signal.SIGKILL:
            return
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline:
            if not any(alive(pid) for pid in pids):
                return
            time.sleep(0.02)


def start_watchdog(limit: float) -> None:
    """Past LIMIT seconds, print every thread's stack, stop the processes this gate started, and refuse the push.

    A hung gate blocks the push anyway, so refusing loosens no check; the stacks say where it hung."""
    import faulthandler
    import threading

    def fire() -> None:
        sys.stderr.write(f"prepush-gate: the gate ran past its {limit:g}s limit (CMUX_NEXT_GATE_LIMIT_SECONDS); "
                         "push refused. A Mac too loaded to finish it pushes through an idle one: "
                         "scripts/cmux-next/push-from-host.sh <branch>. Where each thread was:\n")
        sys.stderr.flush()
        faulthandler.dump_traceback(file=sys.stderr, all_threads=True)
        stop(_descendants(os.getpid()))
        sys.stdout.flush()
        os._exit(1)

    timer = threading.Timer(limit, fire)
    timer.daemon = True
    timer.start()


GATE_LIMIT_MAX_SECONDS = 3600.0  # the most a loaded Mac's gate gets; past it the push goes through another Mac


def loaded_limit(base: float, load: float, cpus: int) -> float:
    """BASE on a Mac with a free core, and BASE times the runnable processes per core on a loaded one, up to
    GATE_LIMIT_MAX_SECONDS. The limit is there to refuse a hang, and a check that shares each core with LOAD/CPUS
    others is slow, not hung: on 2026-11-10 (load average 300-770 on 18 cores) every push's gate ran to 600 s and
    was refused with nothing wrong in it, while the same push's gate took 8 s on an idle Mac."""
    if cpus <= 0 or load <= cpus:
        return base
    return max(base, min(base * load / cpus, GATE_LIMIT_MAX_SECONDS))


def gate_limit() -> float:
    """CMUX_NEXT_GATE_LIMIT_SECONDS as given (a set limit is never scaled), else GATE_LIMIT_SECONDS for this load."""
    raw = os.environ.get("CMUX_NEXT_GATE_LIMIT_SECONDS", "").strip()
    try:
        if raw:
            return float(raw)
    except ValueError:
        pass
    try:
        load = os.getloadavg()[0]
    except OSError:
        return GATE_LIMIT_SECONDS
    return loaded_limit(GATE_LIMIT_SECONDS, load, os.cpu_count() or 1)


if __name__ == "__main__":
    start_watchdog(gate_limit())
    sys.exit(main())
