#!/usr/bin/env python3
"""layer_gate.py (arch-ratchet rule `layer-gate`): a push may not add a Package.swift edge that breaks
plans/cmux-next/architecture-layers.json, or a target the map does not place. Each case builds a temp git
repo with a base and a head commit and runs the rule on the push from one to the other.

  python3 scripts/cmux-next/tests/test_layer_gate.py
"""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
# The review fields every arch-ratchet.json exception needs (reward-hacking audit 2026-10-30): an author, an
# owner, an independent receipt and an expiry.
RATCHET_REVIEW = {"author": "agent-a", "owner": "PL-arch", "expiry": "2026-11-06",
                  "receipt": "Review (reviewer-b): SHIP at " + "a" * 40}
SOURCES = "Packages/macOS/CmuxNext/Sources"
SCRIPT = HERE.parent / "arch_rules" / "layer_gate.py"
RATCHET = HERE.parent / "arch-ratchet.py"
SPEC = importlib.util.spec_from_file_location("layer_gate", SCRIPT)
assert SPEC and SPEC.loader
gate = importlib.util.module_from_spec(SPEC)
sys.modules["layer_gate"] = gate
SPEC.loader.exec_module(gate)

LAYERS = {
    "CmuxNextCore": "core",
    "CmuxNextOtherCore": "core",
    "CmuxNextService": "service",
    "CmuxNextOtherService": "service",
    "CmuxNextDomain": "domain",
    "CmuxNextUI": "ui",
    "CmuxNextApp": "app",
    "CCmuxAppFFI": "core",
}

BASE_DEPS = {
    "CmuxNextCore": [],
    "CmuxNextOtherCore": ['"CmuxNextCore"'],
    "CmuxNextService": ['"CmuxNextCore"'],
    "CmuxNextOtherService": ['"CmuxNextCore"', '"CmuxNextUI"'],  # an existing hard edge
    "CmuxNextDomain": ['"CmuxNextCore"', '"CmuxNextService"'],
    "CmuxNextUI": ['"CmuxNextDomain"'],
    "CmuxNextApp": ['"CmuxNextUI"', '"CmuxNextDomain"', '.product(name: "Sparkle", package: "Sparkle")'],
}


def manifest(deps: dict[str, list[str]], extra: str = "", prologue: str = "", epilogue: str = "") -> str:
    blocks = []
    for name, entries in deps.items():
        listed = ", ".join(entries)
        blocks.append(
            "        // A comment that names .target(name: \"CmuxNextNotATarget\") is not a target.\n"
            f"        .target(\n            name: \"{name}\",\n            dependencies: [{listed}],\n"
            "            swiftSettings: uiSwiftSettings\n        ),\n")
    return (
        "// swift-tools-version: 6.2\nimport PackageDescription\n\n"
        "let uiSwiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]\n"
        'let appFFI: Target = .binaryTarget(\n    name: "CCmuxAppFFI",\n    url: "https://example.invalid/a.zip",\n'
        '    checksum: "00"\n)\n'
        f"{prologue}"
        'let package = Package(\n    name: "CmuxNext",\n    targets: [\n'
        + "".join(blocks) + extra +
        "    ] + [appFFI]\n)\n" + epilogue)


def layers(targets: dict[str, str], exceptions: list[dict] | None = None,
           relayered: list[dict] | None = None) -> str:
    spec = {"order": ["core", "service", "domain", "ui", "app"],
            "targets": {name: {"layer": layer} for name, layer in targets.items()}}
    if exceptions is not None:
        spec["exceptions"] = exceptions
    if relayered is not None:
        spec["relayered"] = relayered
    return json.dumps(spec, indent=2) + "\n"


# A helper that builds a target from a name it is passed: the static reader cannot see the name.
HELPER = 'func feature(_ n: String, _ d: [Target.Dependency]) -> Target { .target(name: n, dependencies: d) }\n'



class Repo:
    def __init__(self, root: Path):
        self.root = root
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "gate@example.invalid")
        self.git("config", "user.name", "gate")

    def git(self, *args: str) -> str:
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        return subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True, text=True,
                              env=env).stdout.strip()

    def commit(self, files: dict[str, str]) -> str:
        for path, text in files.items():
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", "c")
        return self.git("rev-parse", "HEAD")



class Changes:
    """What arch-ratchet.py hands a rule (arch_rules/__init__.py): repo, files [(status, path)], read()."""

    def __init__(self, repo: Repo, base: str, head: str):
        self.repo, self.base, self.head = repo.root, base, head
        self.files = [tuple(line.split("\t", 1)) for line in
                      repo.git("diff", "--name-status", "--no-renames", base, head).splitlines()]

    def read(self, items):
        return dict(zip(items, gate.blobs(self.repo, items)))


class LayerGateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(Path(self.tmp.name))
        self.base = self.repo.commit({gate.PACKAGE_SWIFT: manifest(BASE_DEPS), gate.LAYERS_JSON: layers(LAYERS)})

    def tearDown(self):
        self.tmp.cleanup()

    def push(self, files: dict[str, str]) -> list[str]:
        head = self.repo.commit(files)
        refusals, notes = gate.check(self.base, head, Changes(self.repo, self.base, head))
        self.assertEqual(notes, [])
        for rule, text, row in refusals:
            self.assertEqual(rule, "layer-gate")
            self.assertIn('"row": "layer-gate", "allow": 1', text)
            self.assertNotIn("ARCH_RATCHET_SKIP_REASON", text)
            self.assertIn(row, (None, "layer_hard", "layer_soft", "layer_upward", "layer_unplaced"), text)
        return [text for _, text, _ in refusals]

    def with_deps(self, **changes: list[str]) -> dict[str, list[str]]:
        deps = {name: list(entries) for name, entries in BASE_DEPS.items()}
        for name, entries in changes.items():
            deps[name] = deps.get(name, []) + entries
        return deps

    def test_base_is_clean(self):
        self.assertEqual(self.push({"README.md": "x\n"}), [])

    def test_new_hard_edge_is_refused(self):
        found = self.push({gate.PACKAGE_SWIFT: manifest(self.with_deps(CmuxNextService=['"CmuxNextUI"']))})
        self.assertEqual(len(found), 1, found)
        self.assertIn("new edge CmuxNextService (service) -> CmuxNextUI (ui)", found[0])
        self.assertIn("protocol seam", found[0])
        self.assertIn("lift the shared type to a core target", found[0])
        self.assertIn("a service target may not depend on a ui target", found[0])

    def test_new_edge_to_app_written_as_target_call_is_refused(self):
        found = self.push({gate.PACKAGE_SWIFT: manifest(self.with_deps(
            CmuxNextDomain=['.target(name: "CmuxNextApp", condition: .when(platforms: [.macOS]))']))})
        self.assertEqual(len(found), 1, found)
        self.assertIn("CmuxNextDomain (domain) -> CmuxNextApp (app)", found[0])
        self.assertIn("a domain target may not depend on an app target", found[0])

    def test_new_soft_edge_is_refused(self):
        found = self.push({gate.PACKAGE_SWIFT: manifest(self.with_deps(CmuxNextService=['"CmuxNextDomain"']))})
        self.assertEqual(len(found), 1, found)
        self.assertIn("new edge CmuxNextService (service) -> CmuxNextDomain (domain)", found[0])
        self.assertIn("exceptions", found[0])

    def test_soft_edge_listed_in_exceptions_passes(self):
        exception = {"from": "CmuxNextService", "to": "CmuxNextDomain", "date": "2026-10-23",
                     "reason": "the schema moves to core in the Settings split"}
        found = self.push({gate.PACKAGE_SWIFT: manifest(self.with_deps(CmuxNextService=['"CmuxNextDomain"'])),
                           gate.LAYERS_JSON: layers(LAYERS, [exception])})
        self.assertEqual(found, [])

    def test_exception_without_date_or_reason_does_not_count(self):
        exception = {"from": "CmuxNextService", "to": "CmuxNextDomain", "reason": ""}
        found = self.push({gate.PACKAGE_SWIFT: manifest(self.with_deps(CmuxNextService=['"CmuxNextDomain"'])),
                           gate.LAYERS_JSON: layers(LAYERS, [exception])})
        self.assertEqual(len(found), 1, found)
        self.assertIn("needs a YYYY-MM-DD `date` and a `reason`", found[0])

    def test_exceptions_do_not_cover_hard_edges(self):
        exception = {"from": "CmuxNextService", "to": "CmuxNextUI", "date": "2026-10-23", "reason": "no"}
        found = self.push({gate.PACKAGE_SWIFT: manifest(self.with_deps(CmuxNextService=['"CmuxNextUI"'])),
                           gate.LAYERS_JSON: layers(LAYERS, [exception])})
        self.assertEqual(len(found), 1, found)

    def test_existing_edge_passes(self):
        # CmuxNextOtherService -> CmuxNextUI is in the base; the push edits Package.swift around it.
        deps = self.with_deps(CmuxNextUI=['"CmuxNextCore"'])
        deps["CmuxNextOtherService"] = ['"CmuxNextUI"', '"CmuxNextCore"']
        self.assertEqual(self.push({gate.PACKAGE_SWIFT: manifest(deps)}), [])

    def test_allowed_new_edge_passes(self):
        self.assertEqual(self.push({gate.PACKAGE_SWIFT: manifest(self.with_deps(
            CmuxNextUI=['"CmuxNextService"'], CmuxNextApp=['"CmuxNextCore"']))}), [])

    def test_new_unmapped_target_is_refused(self):
        deps = self.with_deps(CmuxNextNew=['"CmuxNextCore"'])
        found = self.push({gate.PACKAGE_SWIFT: manifest(deps)})
        self.assertEqual(len(found), 1, found)
        self.assertIn("target CmuxNextNew (target) has no layer", found[0])

    def test_new_target_mapped_in_the_same_push_passes(self):
        deps = self.with_deps(CmuxNextNew=['"CmuxNextCore"'])
        found = self.push({gate.PACKAGE_SWIFT: manifest(deps),
                           gate.LAYERS_JSON: layers({**LAYERS, "CmuxNextNew": "service"})})
        self.assertEqual(found, [])

    def test_new_unmapped_executable_and_binary_targets_are_refused(self):
        extra = ('        .executableTarget(name: "CmuxNextTool", dependencies: ["CmuxNextCore"]),\n'
                 '        .binaryTarget(name: "CNewFFI", path: "CNewFFI.xcframework"),\n')
        found = self.push({gate.PACKAGE_SWIFT: manifest(BASE_DEPS, extra=extra)})
        self.assertEqual(len(found), 2, found)
        self.assertIn("target CNewFFI (binaryTarget) has no layer", found[0])
        self.assertIn("target CmuxNextTool (executableTarget) has no layer", found[1])

    def test_unmapping_an_existing_target_is_refused(self):
        found = self.push({gate.LAYERS_JSON: layers({k: v for k, v in LAYERS.items() if k != "CmuxNextDomain"})})
        self.assertEqual(len(found), 1, found)
        self.assertIn("CmuxNextDomain", found[0])

    def test_test_target_is_ignored(self):
        extra = ('        .testTarget(\n            name: "CmuxNextServiceTests",\n'
                 '            dependencies: ["CmuxNextService", "CmuxNextUI", "CmuxNextApp", .target(name: "CmuxNextDomain")]\n'
                 '        ),\n')
        self.assertEqual(self.push({gate.PACKAGE_SWIFT: manifest(BASE_DEPS, extra=extra)}), [])

    def test_dependency_variable_is_read(self):
        prologue = 'let serviceDeps: [Target.Dependency] = [\n    "CmuxNextCore",\n    "CmuxNextUI",\n]\n'
        text = manifest(BASE_DEPS, prologue=prologue).replace(
            'name: "CmuxNextService",\n            dependencies: ["CmuxNextCore"]',
            'name: "CmuxNextService",\n            dependencies: ["CmuxNextCore"] + serviceDeps')
        found = self.push({gate.PACKAGE_SWIFT: text})
        self.assertEqual(len(found), 1, found)
        self.assertIn("CmuxNextService (service) -> CmuxNextUI (ui)", found[0])

    def test_unreadable_dependency_expression_is_refused(self):
        text = manifest(BASE_DEPS).replace('name: "CmuxNextService",\n            dependencies: ["CmuxNextCore"]',
                                           'name: "CmuxNextService",\n            dependencies: flag ? ["CmuxNextUI"] : []')
        found = self.push({gate.PACKAGE_SWIFT: text})
        self.assertEqual(len(found), 1, found)
        self.assertIn("cannot read", found[0])

    def test_relabel_and_a_new_edge_in_one_push_are_refused(self):
        # The review's case: a new service -> ui edge, with the service relabelled ui in the same push.
        found = self.push({gate.PACKAGE_SWIFT: manifest(self.with_deps(CmuxNextService=['"CmuxNextUI"'])),
                           gate.LAYERS_JSON: layers({**LAYERS, "CmuxNextService": "ui"})})
        self.assertEqual(len(found), 2, found)
        self.assertIn("target CmuxNextService moves from service to ui", found[0])
        self.assertIn("CmuxNextService -> CmuxNextUI hard -> allowed", found[0])
        self.assertIn("CmuxNextDomain -> CmuxNextService allowed -> hard", found[0])
        self.assertIn("new edge CmuxNextService (service) -> CmuxNextUI (ui)", found[1])
        self.assertIn("the gate takes the stricter of the two", found[1])

    def test_relabel_alone_that_clears_an_existing_hard_edge_is_refused(self):
        found = self.push({gate.LAYERS_JSON: layers({**LAYERS, "CmuxNextOtherService": "ui"})})
        self.assertEqual(len(found), 1, found)
        self.assertIn("target CmuxNextOtherService moves from service to ui", found[0])
        self.assertIn("CmuxNextOtherService -> CmuxNextUI hard -> allowed", found[0])
        self.assertIn("`relayered`", found[0])

    def test_moving_the_dependency_down_does_not_clear_a_new_edge(self):
        found = self.push({gate.PACKAGE_SWIFT: manifest(self.with_deps(CmuxNextDomain=['"CmuxNextUI"'])),
                           gate.LAYERS_JSON: layers({**LAYERS, "CmuxNextUI": "domain"})})
        self.assertEqual(len(found), 2, found)
        self.assertIn("target CmuxNextUI moves from ui to domain", found[0])
        self.assertIn("CmuxNextOtherService -> CmuxNextUI hard -> soft", found[0])
        self.assertIn("new edge CmuxNextDomain (domain) -> CmuxNextUI (ui)", found[1])

    def test_relabel_with_a_dated_entry_and_its_code_change_passes(self):
        entry = {"target": "CmuxNextUI", "from": "ui", "to": "domain", "date": "2026-10-23",
                 "reason": "its views moved to CmuxNextUIViews"}
        found = self.push({f"{SOURCES}/CmuxNextUI/Model.swift": "public struct Model {}\n",
                           gate.LAYERS_JSON: layers({**LAYERS, "CmuxNextUI": "domain"}, relayered=[entry])})
        self.assertEqual(found, [])

    def test_justified_relabel_and_a_new_edge_cannot_ride_together(self):
        # Even with its code change and a valid entry, the relabel does not clear a new edge in the same push:
        # under the base layers CmuxNextDomain -> CmuxNextUI is hard.
        entry = {"target": "CmuxNextUI", "from": "ui", "to": "domain", "date": "2026-10-23",
                 "reason": "its views moved to CmuxNextUIViews"}
        found = self.push({gate.PACKAGE_SWIFT: manifest(self.with_deps(CmuxNextDomain=['"CmuxNextUI"'])),
                           f"{SOURCES}/CmuxNextUI/Model.swift": "public struct Model {}\n",
                           gate.LAYERS_JSON: layers({**LAYERS, "CmuxNextUI": "domain"}, relayered=[entry])})
        self.assertEqual(len(found), 1, found)
        self.assertIn("new edge CmuxNextDomain (domain) -> CmuxNextUI (ui)", found[0])
        self.assertIn("land the relabel with the code change that moves CmuxNextUI in its own push first", found[0])

    def test_relabel_with_an_entry_but_no_code_change_is_refused(self):
        # The review's case: one push adds HangReports -> HomeEngine (service -> ui), relabels HangReports ui and
        # adds a dated `relayered` entry; no source of the relabelled target changes. A file in a target whose
        # name only starts with the same letters does not count.
        entry = {"target": "CmuxNextService", "from": "service", "to": "ui", "date": "2026-10-23",
                 "reason": "needs home engine"}
        found = self.push({gate.PACKAGE_SWIFT: manifest(self.with_deps(CmuxNextService=['"CmuxNextUI"'])),
                           f"{SOURCES}/CmuxNextServiceKit/Other.swift": "struct Other {}\n",
                           gate.LAYERS_JSON: layers({**LAYERS, "CmuxNextService": "ui"}, relayered=[entry])})
        self.assertEqual(len(found), 2, found)
        self.assertIn("target CmuxNextService moves from service to ui", found[0])
        self.assertIn(f"the push changes no file under {SOURCES}/CmuxNextService/", found[0])
        self.assertIn("new edge CmuxNextService (service) -> CmuxNextUI (ui)", found[1])

    def test_a_relabel_that_only_clears_an_edge_is_refused_even_when_justified(self):
        # The review's case: a dated `relayered` entry and a comment-only edit under the target's sources let a
        # relabel clear the standing hard edge CmuxNextOtherService -> CmuxNextUI (service -> ui raised to ui). The
        # code holds the same layer as before, so the relabel is that debt renamed.
        self.base = self.repo.commit({f"{SOURCES}/CmuxNextOtherService/Client.swift": "struct Client {}\n"})
        entry = {"target": "CmuxNextOtherService", "from": "service", "to": "ui", "date": "2026-10-23",
                 "reason": "it shows views now"}
        found = self.push({f"{SOURCES}/CmuxNextOtherService/Client.swift": "// a comment\nstruct Client {}\n",
                           gate.LAYERS_JSON: layers({**LAYERS, "CmuxNextOtherService": "ui"}, relayered=[entry])})
        self.assertEqual(len(found), 1, found)
        self.assertIn("target CmuxNextOtherService moves from service to ui", found[0])
        self.assertIn("CmuxNextOtherService -> CmuxNextUI hard -> allowed", found[0])
        self.assertIn("raises", found[0])

    def lowered_ui(self, source: str) -> list[str]:
        """A base where CmuxNextDomain depends on CmuxNextUI (a standing hard edge) and CmuxNextUI's view imports
        SwiftUI; the push replaces that file with SOURCE and relabels CmuxNextUI ui -> domain with a dated entry."""
        deps = {**BASE_DEPS, "CmuxNextDomain": BASE_DEPS["CmuxNextDomain"] + ['"CmuxNextUI"'],
                "CmuxNextUI": ['"CmuxNextCore"']}
        view = f"{SOURCES}/CmuxNextUI/Panel.swift"
        self.base = self.repo.commit({gate.PACKAGE_SWIFT: manifest(deps),
                                      view: "import SwiftUI\nstruct Panel: View {\n    var body: some View { Text(\"a\") }\n}\n"})
        entry = {"target": "CmuxNextUI", "from": "ui", "to": "domain", "date": "2026-10-23",
                 "reason": "its views moved to CmuxNextPanelUI; it holds the panel model only"}
        return self.push({view: source, gate.LAYERS_JSON: layers({**LAYERS, "CmuxNextUI": "domain"}, relayered=[entry])})

    def test_a_relabel_down_whose_code_holds_no_ui_clears_its_edge(self):
        # The legitimate case: the push moves every view out of CmuxNextUI (its sources import no AppKit, SwiftUI,
        # WebKit or Cocoa and no ui or app target) and relabels it domain: CmuxNextDomain -> CmuxNextUI is allowed.
        found = self.lowered_ui("import Foundation\n// import SwiftUI: a comment is no import\n"
                                "public struct PanelModel {\n    public var title = \"\"\n}\n")
        self.assertEqual(found, [])

    def test_a_relabel_down_whose_code_still_imports_ui_is_refused(self):
        found = self.lowered_ui("import Foundation\n@preconcurrency import SwiftUI\npublic struct PanelModel {}\n")
        self.assertEqual(len(found), 1, found)
        self.assertIn("CmuxNextDomain -> CmuxNextUI hard -> allowed", found[0])
        self.assertIn("Panel.swift:2: @preconcurrency import SwiftUI", found[0])

    def rename_base(self):
        """A base with a source file in CmuxNextOtherService (service, hard edge to CmuxNextUI)."""
        self.base = self.repo.commit({f"{SOURCES}/CmuxNextOtherService/Client.swift":
                                      "public struct Client {\n    public let id: Int\n    public init(id: Int) { self.id = id }\n}\n"})

    def renamed_deps(self) -> dict[str, list[str]]:
        return {k if k != "CmuxNextOtherService" else "CmuxNextOtherServiceKit": v for k, v in BASE_DEPS.items()}

    def test_a_target_renamed_onto_the_same_sources_keeps_its_base_layer(self):
        # The review's case: CmuxNextOtherService (service, hard edge to CmuxNextUI) becomes CmuxNextOtherServiceKit
        # with `path:` to the old directory, mapped ui: the gate saw no relabel and the edge came back allowed.
        self.rename_base()
        text = manifest(self.renamed_deps()).replace(
            'name: "CmuxNextOtherServiceKit",\n', 'name: "CmuxNextOtherServiceKit",\n            path: "Sources/CmuxNextOtherService",\n')
        mapped = {k: v for k, v in LAYERS.items() if k != "CmuxNextOtherService"}
        found = self.push({gate.PACKAGE_SWIFT: text, gate.LAYERS_JSON: layers({**mapped, "CmuxNextOtherServiceKit": "ui"})})
        self.assertEqual(len(found), 1, found)
        self.assertIn("target CmuxNextOtherServiceKit (CmuxNextOtherService in the base) moves from service to ui", found[0])
        self.assertIn("CmuxNextOtherServiceKit -> CmuxNextUI hard -> allowed", found[0])

    def test_a_target_renamed_with_its_directory_keeps_its_base_layer(self):
        # The same through `git mv Sources/CmuxNextOtherService Sources/CmuxNextOtherServiceKit` (no `path:`).
        self.rename_base()
        (self.repo.root / SOURCES / "CmuxNextOtherService" / "Client.swift").unlink()
        mapped = {k: v for k, v in LAYERS.items() if k != "CmuxNextOtherService"}
        found = self.push({gate.PACKAGE_SWIFT: manifest(self.renamed_deps()),
                           f"{SOURCES}/CmuxNextOtherServiceKit/Client.swift":
                           "public struct Client {\n    public let id: Int\n    public init(id: Int) { self.id = id }\n}\n",
                           gate.LAYERS_JSON: layers({**mapped, "CmuxNextOtherServiceKit": "ui"})})
        self.assertEqual(len(found), 1, found)
        self.assertIn("target CmuxNextOtherServiceKit (CmuxNextOtherService in the base) moves from service to ui", found[0])

    def test_a_plain_rename_moves_its_standing_edge_and_passes(self):
        # A rename at the same layer carries its standing hard edge over: it is not a new edge.
        self.rename_base()
        (self.repo.root / SOURCES / "CmuxNextOtherService" / "Client.swift").unlink()
        mapped = {k: v for k, v in LAYERS.items() if k != "CmuxNextOtherService"}
        found = self.push({gate.PACKAGE_SWIFT: manifest(self.renamed_deps()),
                           f"{SOURCES}/CmuxNextOtherServiceKit/Client.swift":
                           "public struct Client {\n    public let id: Int\n    public init(id: Int) { self.id = id }\n}\n",
                           gate.LAYERS_JSON: layers({**mapped, "CmuxNextOtherServiceKit": "service"})})
        self.assertEqual(found, [])

    def test_relabel_reads_a_target_path_argument(self):
        entry = {"target": "CmuxNextUI", "from": "ui", "to": "domain", "date": "2026-10-23",
                 "reason": "its views moved to CmuxNextUIViews"}
        text = manifest(BASE_DEPS).replace('name: "CmuxNextUI",\n', 'name: "CmuxNextUI",\n            path: "Kit/UI",\n')
        self.base = self.repo.commit({gate.PACKAGE_SWIFT: text})
        relabel = layers({**LAYERS, "CmuxNextUI": "domain"}, relayered=[entry])
        found = self.push({f"{SOURCES}/CmuxNextUI/Model.swift": "x\n", gate.LAYERS_JSON: relabel})
        self.assertEqual(len(found), 1, found)
        self.assertIn("Packages/macOS/CmuxNext/Kit/UI/", found[0])
        self.base = self.repo.git("rev-parse", "HEAD~1")
        self.assertEqual(self.push({"Packages/macOS/CmuxNext/Kit/UI/Model.swift": "x\n", gate.LAYERS_JSON: relabel}), [])

    def test_new_upward_edges_from_core_are_refused(self):
        # Neither hard nor soft, but edges only point down: core -> domain and core -> service.
        found = self.push({gate.PACKAGE_SWIFT: manifest(self.with_deps(
            CmuxNextOtherCore=['"CmuxNextDomain"', '"CmuxNextService"']))})
        self.assertEqual(len(found), 2, found)
        self.assertIn("new edge CmuxNextOtherCore (core) -> CmuxNextDomain (domain)", found[0])
        self.assertIn("new edge CmuxNextOtherCore (core) -> CmuxNextService (service)", found[1])
        self.assertIn("edges only point down", found[0])

    def test_exceptions_do_not_cover_upward_edges(self):
        exception = {"from": "CmuxNextOtherCore", "to": "CmuxNextDomain", "date": "2026-10-23", "reason": "no"}
        found = self.push({gate.PACKAGE_SWIFT: manifest(self.with_deps(CmuxNextOtherCore=['"CmuxNextDomain"'])),
                           gate.LAYERS_JSON: layers(LAYERS, [exception])})
        self.assertEqual(len(found), 1, found)

    def test_map_entry_without_a_layer_is_unmapped_not_a_crash(self):
        # The review's case: one typo (`layr`) used to raise KeyError, and the ratchet then let three new hard
        # edges through.
        spec = json.loads(layers(LAYERS))
        for bad in ({"layr": "domain"}, "domain", {"layer": ["domain"]}):
            spec["targets"]["CmuxNextDomain"] = bad
            found = self.push({gate.PACKAGE_SWIFT: manifest(self.with_deps(CmuxNextService=['"CmuxNextUI"'])),
                               gate.LAYERS_JSON: json.dumps(spec)})
            self.assertEqual(len(found), 2, (bad, found))
            self.assertIn("target CmuxNextDomain (target) has no layer", found[0])
            self.assertIn("new edge CmuxNextService (service) -> CmuxNextUI (ui)", found[1])

    def test_map_that_does_not_parse_is_refused(self):
        for broken in ("{not json", "[]", '{"targets": {}}', '{"order": "core", "targets": {}}'):
            found = self.push({gate.PACKAGE_SWIFT: manifest(self.with_deps(CmuxNextService=['"CmuxNextUI"'])),
                               gate.LAYERS_JSON: broken})
            self.assertEqual(len(found), 1, (broken, found))
            self.assertIn(f"{gate.LAYERS_JSON} does not parse", found[0])

    def test_base_map_that_does_not_parse_judges_the_push_by_the_head(self):
        self.base = self.repo.commit({gate.LAYERS_JSON: "{not json"})
        found = self.push({gate.PACKAGE_SWIFT: manifest(self.with_deps(CmuxNextService=['"CmuxNextUI"'])),
                           gate.LAYERS_JSON: layers(LAYERS)})
        self.assertEqual(len(found), 1, found)
        self.assertIn("new edge CmuxNextService (service) -> CmuxNextUI (ui)", found[0])

    def test_relayered_entry_with_an_impossible_date_or_wrong_layers_does_not_count(self):
        for bad in ({"date": "2026-02-30"}, {"date": "2026-13-45"}, {"from": "service"}, {"reason": " "}):
            entry = {"target": "CmuxNextUI", "from": "ui", "to": "domain", "date": "2026-10-23",
                     "reason": "its views moved to CmuxNextUIViews", **bad}
            found = self.push({gate.PACKAGE_SWIFT: manifest(self.with_deps(CmuxNextDomain=['"CmuxNextUI"'])),
                               gate.LAYERS_JSON: layers({**LAYERS, "CmuxNextUI": "domain"}, relayered=[entry])})
            self.assertEqual(len(found), 2, (bad, found))
            self.assertIn("its `relayered` entry does not count", found[0])

    def test_new_target_placed_as_app_is_refused(self):
        found = self.push({gate.PACKAGE_SWIFT: manifest(self.with_deps(CmuxNextLeaf=['"CmuxNextUI"'])),
                           gate.LAYERS_JSON: layers({**LAYERS, "CmuxNextLeaf": "app"})})
        self.assertEqual(len(found), 1, found)
        self.assertIn("target CmuxNextLeaf is placed as app", found[0])
        self.assertIn("only CmuxNextApp, the composition root, is app", found[0])

    def test_layer_outside_the_order_is_unmapped(self):
        found = self.push({gate.LAYERS_JSON: layers({**LAYERS, "CmuxNextDomain": "middle"})})
        self.assertEqual(len(found), 1, found)
        self.assertIn("target CmuxNextDomain (target) has layer 'middle', which is not in `order`", found[0])

    def test_exception_with_an_impossible_date_does_not_count(self):
        for date in ("2026-02-30", "2026-13-45", "20261023"):
            exception = {"from": "CmuxNextService", "to": "CmuxNextDomain", "date": date, "reason": "why"}
            found = self.push({gate.PACKAGE_SWIFT: manifest(self.with_deps(CmuxNextService=['"CmuxNextDomain"'])),
                               gate.LAYERS_JSON: layers(LAYERS, [exception])})
            self.assertEqual(len(found), 1, (date, found))
            self.assertIn("needs a YYYY-MM-DD `date` and a `reason`", found[0])

    def test_target_from_a_helper_appended_after_the_package_is_refused(self):
        found = self.push({gate.PACKAGE_SWIFT: manifest(
            BASE_DEPS, prologue=HELPER,
            epilogue='package.targets.append(feature("CmuxNextSneaky", ["CmuxNextUI"]))\n')})
        self.assertEqual(len(found), 2, found)
        self.assertIn("`.target(name: n, dependencies: d)`", found[0])
        self.assertIn("`name:` is not a string literal", found[0])
        self.assertIn("`package.targets.append(", found[1])
        self.assertIn("after it is built", found[1])

    def test_target_from_a_helper_in_the_targets_list_is_refused(self):
        found = self.push({gate.PACKAGE_SWIFT: manifest(
            BASE_DEPS, prologue=HELPER, extra='        feature("CmuxNextSneaky", ["CmuxNextUI"]),\n')})
        self.assertEqual(len(found), 2, found)
        self.assertIn("`name:` is not a string literal", found[0])
        self.assertIn('`feature("CmuxNextSneaky", ["CmuxNextUI"])`', found[1])
        self.assertIn("not a target constructor", found[1])

    def test_dependency_appended_after_the_package_is_refused(self):
        epilogue = ('package.targets.first { $0.name == "CmuxNextService" }!'
                    '.dependencies.append(.target(name: "CmuxNextUI"))\n')
        found = self.push({gate.PACKAGE_SWIFT: manifest(BASE_DEPS, epilogue=epilogue)})
        self.assertEqual(len(found), 1, found)
        self.assertIn("after it is built", found[0])

    def test_dependencies_changed_in_a_loop_are_refused(self):
        epilogue = ('for t in package.targets where t.name == "CmuxNextService" {\n'
                    '    t.dependencies += ["CmuxNextUI"]\n}\n')
        found = self.push({gate.PACKAGE_SWIFT: manifest(BASE_DEPS, epilogue=epilogue)})
        self.assertEqual(len(found), 2, found)
        self.assertIn("for t in package.targets", found[0])
        self.assertIn("t.dependencies +=", found[1])

    def test_var_dependency_variable_is_not_read(self):
        prologue = ('var serviceDeps: [Target.Dependency] = ["CmuxNextCore"]\n'
                    'serviceDeps.append("CmuxNextUI")\n')
        text = manifest(BASE_DEPS, prologue=prologue).replace(
            'name: "CmuxNextService",\n            dependencies: ["CmuxNextCore"]',
            'name: "CmuxNextService",\n            dependencies: ["CmuxNextCore"] + serviceDeps')
        found = self.push({gate.PACKAGE_SWIFT: text})
        self.assertEqual(len(found), 1, found)
        self.assertIn("hold `serviceDeps`, which the gate cannot read", found[0])

    def test_commented_out_targets_and_edges_are_not_read(self):
        extra = ('        // .target(name: "CmuxNextGhost", dependencies: ["CmuxNextUI"]),\n'
                 '        /* .target(name: "CmuxNextCore", dependencies: ["CmuxNextApp"]), */\n')
        self.assertEqual(self.push({gate.PACKAGE_SWIFT: manifest(BASE_DEPS, extra=extra)}), [])

    def test_other_files_do_not_run_the_rule(self):
        broken = {gate.PACKAGE_SWIFT: manifest(self.with_deps(CmuxNextService=['"CmuxNextUI"']))}
        head = self.repo.commit(broken)
        self.assertEqual(gate.check(self.base, head, [("M", "README.md")], self.repo.root), ([], []))

    def test_refusal_points_at_the_target_line(self):
        head = self.repo.commit({gate.PACKAGE_SWIFT: manifest(self.with_deps(CmuxNextService=['"CmuxNextUI"']))})
        [refusal] = gate.check_repo(self.repo.root, self.base, head, [gate.PACKAGE_SWIFT])
        lines = (self.repo.root / gate.PACKAGE_SWIFT).read_text().splitlines()
        self.assertEqual((refusal.path, refusal.rule, lines[refusal.number - 1].strip()),
                         (gate.PACKAGE_SWIFT, "layer-gate", ".target("))
        self.assertIn('name: "CmuxNextService"', lines[refusal.number])

    def test_changes_read_from_git_when_none(self):
        head = self.repo.commit({gate.PACKAGE_SWIFT: manifest(self.with_deps(CmuxNextService=['"CmuxNextUI"']))})
        refusals, _ = gate.check(self.base, head, None, self.repo.root)
        self.assertEqual(len(refusals), 1, refusals)

    def test_cli_refuses_and_no_environment_variable_skips_it(self):
        self.repo.commit({gate.PACKAGE_SWIFT: manifest(self.with_deps(CmuxNextService=['"CmuxNextUI"']))})
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        run = [sys.executable, str(SCRIPT), "--repo", str(self.repo.root), "--base", self.base]
        refused = subprocess.run(run, capture_output=True, text=True, env=env)
        self.assertEqual(refused.returncode, 1, refused.stdout + refused.stderr)
        self.assertIn("CmuxNextService (service) -> CmuxNextUI (ui)", refused.stdout)
        self.assertIn('"row": "layer-gate"', refused.stdout)
        # The old escape variable is gone: it no longer passes the push.
        skipped = subprocess.run(run, capture_output=True, text=True,
                                 env={**env, "ARCH_RATCHET_SKIP_REASON": "layer-gate: moving the type in the next push"})
        self.assertEqual(skipped.returncode, 1, skipped.stdout + skipped.stderr)


def load_ratchet():
    spec = importlib.util.spec_from_file_location("cmux_next_arch_ratchet_for_layer_gate", RATCHET)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ThroughTheRatchetTests(unittest.TestCase):
    """The rule as the pre-push hook runs it: arch-ratchet.py loads arch_rules/ and applies the escape."""

    def setUp(self):
        self.ratchet = load_ratchet()
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(Path(self.tmp.name))
        self.base = self.repo.commit({gate.PACKAGE_SWIFT: manifest(BASE_DEPS), gate.LAYERS_JSON: layers(LAYERS)})

    def tearDown(self):
        self.tmp.cleanup()

    def run_push(self, deps: dict[str, list[str]], exceptions: list[dict] | None = None) -> tuple[list[str], bool]:
        files = {gate.PACKAGE_SWIFT: manifest(deps)}
        if exceptions:
            files["plans/cmux-next/arch-ratchet.json"] = json.dumps({"exceptions": exceptions})
        head = self.repo.commit(files)
        refusals, _ = self.ratchet.check_range(self.repo.root, self.base, head)
        return [row for row, _ in refusals], bool(refusals)

    def test_loader_finds_the_rule(self):
        rules, warnings = self.ratchet.load_rules()
        self.assertIn("layer_gate", [name for name, _ in rules])
        self.assertEqual(warnings, [])

    def test_moved_hard_edge_passes_the_count_but_not_the_gate(self):
        # The push drops CmuxNextOtherService -> CmuxNextUI and adds CmuxNextService -> CmuxNextUI: the
        # hard-edge total stays 31, so only the gate sees the new edge.
        deps = {name: list(entries) for name, entries in BASE_DEPS.items()}
        deps["CmuxNextOtherService"] = ['"CmuxNextCore"']
        deps["CmuxNextService"] = ['"CmuxNextCore"', '"CmuxNextUI"']
        rows, refused = self.run_push(deps)
        self.assertEqual(rows, ["layer-gate"])
        self.assertTrue(refused)

    def test_soft_exception_with_its_count_allowance_passes_the_push(self):
        deps = {name: list(entries) for name, entries in BASE_DEPS.items()}
        deps["CmuxNextService"] = ['"CmuxNextCore"', '"CmuxNextDomain"']
        why = {"date": "2026-10-23", "reason": "the schema moves to core in the Settings split"}
        allowance = {"date": "2026-10-23", "row": "layer_soft", "allow": 1, "why": why["reason"], **RATCHET_REVIEW}
        head = self.repo.commit({
            gate.PACKAGE_SWIFT: manifest(deps),
            gate.LAYERS_JSON: layers(LAYERS, [{"from": "CmuxNextService", "to": "CmuxNextDomain", **why}]),
            "plans/cmux-next/arch-ratchet.json": json.dumps({"exceptions": [allowance]}),
        })
        refusals, _ = self.ratchet.check_range(self.repo.root, self.base, head)
        self.assertEqual(refusals, [])

    def test_escape_is_a_dated_exception_for_the_rule(self):
        deps = {name: list(entries) for name, entries in BASE_DEPS.items()}
        deps["CmuxNextService"] = ['"CmuxNextCore"', '"CmuxNextUI"']
        why = "moving the type next push"
        count_only = [{"date": "2026-10-23", "row": "layer_hard", "allow": 1, "why": why, **RATCHET_REVIEW}]
        rows, refused = self.run_push(deps, count_only)
        self.assertEqual(rows, ["layer-gate"])
        self.assertTrue(refused)
        # One new edge, one escape: the gate's entry alone passes it (the count rule does not refuse the
        # layer_hard rise the gate's refusal answers), and its text asks for no second entry.
        gate_only = [{"date": "2026-10-23", "row": "layer-gate", "allow": 1, "why": why, **RATCHET_REVIEW}]
        rows, refused = self.run_push(deps, gate_only)
        self.assertEqual(rows, [])
        self.assertFalse(refused)
        head = self.repo.commit({gate.PACKAGE_SWIFT: manifest(deps)})
        texts, _ = gate.check(self.base, head, Changes(self.repo, self.base, head))
        self.assertNotIn("layer_hard", texts[0][1])

    def test_an_exception_covers_only_as_many_refusals_as_it_allows(self):
        deps = {name: list(entries) for name, entries in BASE_DEPS.items()}
        deps["CmuxNextService"] = ['"CmuxNextCore"', '"CmuxNextUI"']
        deps["CmuxNextOtherService"] = BASE_DEPS["CmuxNextOtherService"] + ['"CmuxNextApp"']
        why = "moving both types next push"
        exceptions = [{"date": "2026-10-23", "row": "layer_hard", "allow": 2, "why": why, **RATCHET_REVIEW},
                      {"date": "2026-10-23", "row": "layer-gate", "allow": 1, "why": why, **RATCHET_REVIEW}]
        rows, refused = self.run_push(deps, exceptions)
        self.assertEqual(rows, ["layer-gate", "layer-gate"])
        self.assertTrue(refused)

    def test_a_merge_of_upstream_refuses_only_the_push_own_edge(self):
        # origin/feat-cmux-next landed CmuxNextDomain -> CmuxNextUI; the push merges it in and adds its own
        # CmuxNextService -> CmuxNextUI. Only the second is the push's.
        git = self.repo.git
        git("checkout", "-q", "-b", "upstream")
        landed = {name: list(entries) for name, entries in BASE_DEPS.items()}
        landed["CmuxNextDomain"] = landed["CmuxNextDomain"] + ['"CmuxNextUI"']
        self.repo.commit({gate.PACKAGE_SWIFT: manifest(landed)})
        git("checkout", "-q", "main")
        pushed = self.repo.commit({"README.md": "x\n"})
        git("merge", "-q", "--no-edit", "upstream")
        own = {**landed, "CmuxNextService": landed["CmuxNextService"] + ['"CmuxNextUI"']}
        head = self.repo.commit({gate.PACKAGE_SWIFT: manifest(own)})
        # One range, from where HEAD meets upstream: upstream's edge is in its base.
        self.assertEqual(self.ratchet.range_to_count(self.repo.root, pushed, head, "upstream"),
                         (git("rev-parse", "upstream"), head))
        refusals, _ = self.ratchet.check_range(self.repo.root, pushed, head, upstream_ref="upstream")
        gate_texts = [text for row, text in refusals if row == "layer-gate"]
        self.assertEqual(len(gate_texts), 1, gate_texts)
        self.assertIn("new edge CmuxNextService (service) -> CmuxNextUI (ui)", gate_texts[0])

    def test_a_merge_whose_upstream_relabels_the_source_keeps_the_push_own_edge(self):
        # origin/feat-cmux-next relabelled CmuxNextService domain (with its code change and entry); the push merges
        # it in and adds CmuxNextService -> CmuxNextUI. The one range starts where HEAD meets upstream, so the
        # relabel is in the base: the source is domain there, and the push's own edge is refused once.
        git = self.repo.git
        git("checkout", "-q", "-b", "upstream")
        entry = {"target": "CmuxNextService", "from": "service", "to": "domain", "date": "2026-10-23",
                 "reason": "its client became a model"}
        self.repo.commit({f"{SOURCES}/CmuxNextService/Model.swift": "struct Model {}\n",
                          gate.LAYERS_JSON: layers({**LAYERS, "CmuxNextService": "domain"}, relayered=[entry])})
        git("checkout", "-q", "main")
        pushed = self.repo.commit({"README.md": "x\n"})
        git("merge", "-q", "--no-edit", "upstream")
        own = {**BASE_DEPS, "CmuxNextService": BASE_DEPS["CmuxNextService"] + ['"CmuxNextUI"']}
        head = self.repo.commit({gate.PACKAGE_SWIFT: manifest(own)})
        self.assertEqual(self.ratchet.range_to_count(self.repo.root, pushed, head, "upstream"),
                         (git("rev-parse", "upstream"), head))
        refusals, _ = self.ratchet.check_range(self.repo.root, pushed, head, upstream_ref="upstream")
        gate_texts = [text for row, text in refusals if row == "layer-gate"]
        self.assertEqual(len(gate_texts), 1, gate_texts)
        self.assertIn("new edge CmuxNextService (domain) -> CmuxNextUI (ui)", gate_texts[0])


if __name__ == "__main__":
    unittest.main()
