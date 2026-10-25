#!/usr/bin/env python3
"""app-graph.py plans the CmuxNextApp moves (p11-codebase task 000a): groups, SCCs, cuts, order, final deps.

Each case builds a small App in a temp dir (or Facts by hand) with its own package world and destination table,
so the cases do not depend on the live tree; the last cases check the committed app-graph.json and the real
scan's shape.

  python3 -m pytest scripts/cmux-next/tests/test_app_graph.py
"""
from __future__ import annotations

import collections
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "app-graph.py"
REPO = SCRIPT.parents[2]


def load():
    spec = importlib.util.spec_from_file_location("cmux_next_app_graph", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


ag = load()
REQUIRED = ("destination", "host_members", "deps", "cuts", "scc_id", "order")


def world(deps: dict[str, set[str]], layers: dict[str, str]):
    return ag.World(deps={k: set(v) for k, v in deps.items()}, layers=dict(layers),
                    order={n: i for i, n in enumerate(["core", "service", "domain", "ui", "app"])})


def write_app(root: Path, files: dict[str, str]) -> Path:
    for rel, text in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    return root


# Three directories whose types reference each other in a ring, heaviest edge first: Alpha -> Beta (3 uses),
# Beta -> Gamma (2), Gamma -> Alpha (1). Each goes to its own ui target.
RING = {
    "Alpha/AlphaModel.swift": """import Foundation
final class AlphaModel {
    let beta: BetaStore
    init(beta: BetaStore) { self.beta = beta }
    func run() { beta.load(); beta.load() }
}
""",
    "Beta/BetaStore.swift": """import Foundation
final class BetaStore {
    func load() {}
    func gamma(_ g: GammaView) { g.show(); g.show() }
}
""",
    "Gamma/GammaView.swift": """import Foundation
final class GammaView {
    func show() {}
    // AlphaModel in a comment is no reference
    func back(_ a: AlphaModel) {}
}
""",
}
RING_TABLE = {"Alpha": ag.Dest("CmuxNextAlpha"), "Beta": ag.Dest("CmuxNextBeta"), "Gamma": ag.Dest("CmuxNextGamma")}
RING_WORLD = {"CmuxNextAlpha": set(), "CmuxNextBeta": set(), "CmuxNextGamma": set()}
RING_LAYERS = {"CmuxNextAlpha": "ui", "CmuxNextBeta": "ui", "CmuxNextGamma": "ui"}


class CycleTests(unittest.TestCase):
    def ring_graph(self):
        with tempfile.TemporaryDirectory() as tmp:
            facts = ag.regex_facts(write_app(Path(tmp), RING))
        return ag.build(facts, world(RING_WORLD, RING_LAYERS), RING_TABLE)

    def test_three_group_cycle_reports_the_cycle_and_its_cut_edge(self):
        graph = self.ring_graph()
        self.assertEqual(len(graph["cycles"]), 1)
        cycle = graph["cycles"][0]
        self.assertEqual(cycle["groups"], ["Alpha", "Beta", "Gamma"])
        # The lightest edge closes the ring after the two heavier ones became package edges.
        self.assertEqual([(c["from"], c["to"], c["reason"]) for c in cycle["cuts"]], [("Gamma", "Alpha", "cycle")])
        gamma = graph["groups"]["Gamma"]
        self.assertEqual(gamma["host_members"], ["AlphaModel"])
        self.assertEqual(gamma["cuts"][0]["members"], ["AlphaModel"])
        # One SCC before the cuts, three move units after.
        self.assertEqual({graph["groups"][g]["scc_id"] for g in cycle["groups"]}, {cycle["scc_id"]})
        self.assertEqual(graph["summary"]["move_units"], 3)

    def test_order_is_leaf_first_after_the_cut(self):
        graph = self.ring_graph()
        order = {g: graph["groups"][g]["order"] for g in ("Alpha", "Beta", "Gamma")}
        self.assertLess(order["Gamma"], order["Beta"])
        self.assertLess(order["Beta"], order["Alpha"])
        self.assertEqual(graph["order"][order["Alpha"]]["depends_on"], [order["Beta"]])

    def test_final_deps_follow_the_kept_edges(self):
        graph = self.ring_graph()
        d = graph["destinations"]
        self.assertEqual(d["CmuxNextAlpha"]["deps"], ["CmuxNextBeta"])
        self.assertEqual(d["CmuxNextBeta"]["deps"], ["CmuxNextGamma"])
        self.assertEqual(d["CmuxNextGamma"]["deps"], [])
        self.assertEqual(graph["groups"]["Alpha"]["deps"], ["CmuxNextBeta"])

    def test_existing_package_edge_decides_the_cut(self):
        # Gamma's target already depends on Alpha's: the Gamma -> Alpha edge is free and Beta -> Gamma is cut.
        graph = ag.build(self.facts(), world({**RING_WORLD, "CmuxNextGamma": {"CmuxNextAlpha"}}, RING_LAYERS), RING_TABLE)
        cuts = [(c["from"], c["to"]) for c in graph["cycles"][0]["cuts"]]
        self.assertEqual(cuts, [("Beta", "Gamma")])

    def test_features_reach_the_workbench_only_through_a_cut(self):
        # Gamma -> Alpha points into the workbench tier: cut as upward even though both are ui.
        table = {**RING_TABLE, "Alpha": ag.Dest("CmuxNextWorkbenchUI")}
        layers = {**RING_LAYERS, "CmuxNextWorkbenchUI": "ui"}
        deps = {**RING_WORLD, "CmuxNextWorkbenchUI": set()}
        graph = ag.build(self.facts(), world(deps, layers), table)
        self.assertEqual([(c["to"], c["reason"]) for c in graph["groups"]["Gamma"]["cuts"]], [("Alpha", "upward")])
        self.assertEqual(graph["destinations"]["CmuxNextWorkbenchUI"]["deps"], ["CmuxNextBeta"])

    def test_groups_of_one_destination_move_together(self):
        table = {k: ag.Dest("CmuxNextShared") for k in RING_TABLE}
        graph = ag.build(self.facts(), world({"CmuxNextShared": set()}, {"CmuxNextShared": "ui"}), table)
        self.assertEqual(graph["cycles"][0]["cuts"], [])
        self.assertEqual(len(graph["order"]), 1)
        self.assertEqual(graph["order"][0]["groups"], ["Alpha", "Beta", "Gamma"])

    def facts(self):
        with tempfile.TemporaryDirectory() as tmp:
            return ag.regex_facts(write_app(Path(tmp), RING))


class CutTests(unittest.TestCase):
    FILES = {
        "AppServices.swift": """import Foundation
final class AppServices {
    var cloud: CloudStore { CloudStore() }
    var windows: WindowList { WindowList() }
}
final class WindowList { var active: Int { 0 } }
""",
        "Cloud/CloudStore.swift": """import Foundation
import CmuxNextCloud
final class CloudStore {
    let services: AppServices
    init(services: AppServices) { self.services = services }
    func open() { _ = services.windows.active; let v = CloudBadgeView(); v.draw() }
}
""",
        "Cloud/CloudBadgeView.swift": """import SwiftUI
struct CloudBadgeView { func draw() {} }
""",
    }
    TABLE = {"Cloud": ag.Dest("CmuxNextCloudModel", ui="CmuxNextCloudUI"), "top:AppServices": ag.Dest(ag.APP)}
    WORLD = {"CmuxNextCloudModel": set(), "CmuxNextCloudUI": set(), "CmuxNextCloud": set()}
    LAYERS = {"CmuxNextCloudModel": "domain", "CmuxNextCloudUI": "ui", "CmuxNextCloud": "service"}

    def graph(self, world_deps=None, files=None):
        with tempfile.TemporaryDirectory() as tmp:
            facts = ag.regex_facts(write_app(Path(tmp), files or self.FILES))
        return ag.build(facts, world(world_deps or self.WORLD, self.LAYERS), self.TABLE)

    def test_view_files_split_to_the_ui_destination(self):
        graph = self.graph()
        self.assertEqual(graph["groups"]["Cloud"]["destination"], "CmuxNextCloudModel")
        self.assertEqual(graph["groups"]["Cloud:ui"]["destination"], "CmuxNextCloudUI")

    def test_root_and_upward_references_are_host_members(self):
        cloud = self.graph()["groups"]["Cloud"]
        reasons = {c["to"]: c["reason"] for c in cloud["cuts"]}
        self.assertEqual(reasons, {"top:AppServices": "app", "Cloud:ui": "upward"})
        # The property chain `services.windows.active` names each member it walks.
        self.assertIn("AppServices.windows", cloud["host_members"])
        self.assertIn("WindowList.active", cloud["host_members"])
        self.assertIn("CloudBadgeView", cloud["host_members"])
        self.assertEqual(cloud["deps"], ["CmuxNextCloud"])

    def test_root_groups_have_the_last_order_and_no_host(self):
        graph = self.graph()
        root = graph["groups"]["top:AppServices"]
        self.assertEqual(root["order"], len(graph["order"]))
        self.assertEqual(root["host_members"], [])
        self.assertEqual(root["cuts"], [])

    def test_import_that_would_close_a_package_cycle_is_reported(self):
        graph = self.graph({**self.WORLD, "CmuxNextCloud": {"CmuxNextCloudModel"}})
        cloud = graph["groups"]["Cloud"]
        self.assertEqual(cloud["blocked_imports"], ["CmuxNextCloud"])
        self.assertEqual(graph["destinations"]["CmuxNextCloudModel"]["violations"],
                         [{"group": "Cloud", "module": "CmuxNextCloud", "reason": "import-cycle"}])

    def test_host_extension_in_a_feature_dir_stays_in_the_app(self):
        files = dict(self.FILES)
        files["Cloud/AppServices+Cloud.swift"] = "extension AppServices { var cloudStore: CloudStore { cloud } }\n"
        graph = self.graph(files=files)
        host = graph["groups"]["Hosts/Cloud"]
        self.assertEqual((host["destination"], host["app_dir"]), (ag.APP, "Hosts"))


class GroupTests(unittest.TestCase):
    def test_families(self):
        cases = {
            "PaneController+Drag.swift": "top:PaneController",
            "AgentTabStore.swift": "top:AgentTabs",
            "SidebarRows.swift": "top:Sidebar",
            "Handlers/CloudHandlers.swift": "Handlers/Cloud",
            "Handlers/TabCloseGuard.swift": "Handlers/Tab",
            "Handlers/AppActionContext.swift": "Handlers/Infra",
            "Control/DebugSidebarRows.swift": "Control/Sidebar",
            "Control/AppControl+Panes.swift": "Control/Core",
            "Pages/Files/MarkdownShare/X.swift": "Pages/Files",
            "Pages/ChiefUsagePage.swift": "Pages/Chief",
            "Pages/PageFactory.swift": "Pages/Core",
            "Cloud/Deep/Nested.swift": "Cloud",
            "Cloud/AppServices+Cloud.swift": "Hosts/Cloud",
            "Handlers/AppActionContext+Rooms.swift": "Hosts/Handlers/Pane",
        }
        for rel, group in cases.items():
            self.assertEqual(ag.base_group(rel), group, rel)

    def test_every_real_group_has_a_mapped_destination(self):
        facts, _ = ag.scan_files(REPO / ag.APP_DIR)
        groups = {ag.base_group(rel) for rel in facts.files}
        unmapped = sorted(g for g in groups if not g.startswith("Hosts/") and g not in ag.DESTINATIONS)
        self.assertEqual(unmapped, [])

    def test_destinations_exist_or_are_spec_targets(self):
        w = ag.World.read(REPO)
        missing = sorted({d.target for d in ag.DESTINATIONS.values()} - set(w.layers) - {ag.APP})
        self.assertEqual(missing, [])


class IndexStoreTests(unittest.TestCase):
    """index_facts turns occurrences into the same Facts the regex scan gives: a member declared in an
    extension resolves to its type, and the reference keeps the file that declares the member."""

    def test_extension_member_resolves_to_its_type(self):
        S = ag.Sym
        services = S("s:AppServices", "AppServices", ag.KIND_CLASS)
        ext = S("s:e:AppServicesCloud", "AppServices", ag.KIND_EXTENSION)
        member = S("s:AppServices.cloudStore", "cloudStore", 13)
        store = S("s:CloudStore", "CloudStore", ag.KIND_CLASS)
        open_ = S("s:CloudStore.open", "open()", 16)
        records = {
            "AppServices.swift": [ag.Occurrence(services, ag.ROLE_DEFINITION)],
            "Cloud/AppServices+Cloud.swift": [
                ag.Occurrence(ext, ag.ROLE_DEFINITION),
                ag.Occurrence(services, ag.ROLE_REFERENCE, ((ag.REL_EXTENDEDBY, ext),)),
                ag.Occurrence(member, ag.ROLE_DEFINITION, ((ag.REL_CHILDOF, ext),)),
            ],
            "Cloud/CloudStore.swift": [
                ag.Occurrence(store, ag.ROLE_DEFINITION),
                ag.Occurrence(open_, ag.ROLE_DEFINITION, ((ag.REL_CHILDOF, store),)),
                ag.Occurrence(member, ag.ROLE_REFERENCE, ((ag.REL_CONTAINEDBY, open_),)),
            ],
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = write_app(Path(tmp), {k: "\n" for k in records})
            facts = ag.index_facts(root, records)
        self.assertEqual(facts.source, "index-store")
        self.assertEqual(facts.types, {"AppServices": "AppServices.swift", "CloudStore": "Cloud/CloudStore.swift"})
        self.assertIn(("Cloud/CloudStore.swift", "CloudStore", "Cloud/AppServices+Cloud.swift", "AppServices",
                       "cloudStore"), facts.refs)
        self.assertIn(("Cloud/AppServices+Cloud.swift", "", "AppServices.swift", "AppServices", ""), facts.refs)


class OutputTests(unittest.TestCase):
    def test_design_table_replaces_only_the_marked_block(self):
        with tempfile.TemporaryDirectory() as tmp:
            facts = ag.regex_facts(write_app(Path(tmp), RING))
            graph = ag.build(facts, world(RING_WORLD, RING_LAYERS), RING_TABLE)
            doc = Path(tmp) / "DESIGN.md"
            doc.write_text(f"before\n{ag.TABLE_BEGIN}\nold\n{ag.TABLE_END}\nafter\n")
            ag.write_design(doc, ag.design_table(graph))
            text = doc.read_text()
        self.assertTrue(text.startswith("before\n" + ag.TABLE_BEGIN))
        self.assertTrue(text.endswith(ag.TABLE_END + "\nafter\n"))
        self.assertNotIn("\nold\n", text)
        self.assertIn("| CmuxNextGamma | ui |", text)

    def test_committed_graph_has_every_field(self):
        graph = json.loads((REPO / ag.OUT).read_text())
        self.assertTrue(graph["groups"])
        for name, entry in graph["groups"].items():
            for field in REQUIRED:
                self.assertIn(field, entry, f"{name} lacks {field}")
            self.assertIsInstance(entry["host_members"], list)
            self.assertIsInstance(entry["cuts"], list)
            self.assertIsInstance(entry["deps"], list)
        orders = [u["order"] for u in graph["order"]]
        self.assertEqual(orders, list(range(len(orders))))
        for unit in graph["order"]:
            self.assertTrue(all(d < unit["order"] for d in unit["depends_on"]), unit)

    def test_committed_design_table_matches_the_committed_graph(self):
        graph = json.loads((REPO / ag.OUT).read_text())
        text = (REPO / ag.DESIGN).read_text()
        start = text.index(ag.TABLE_BEGIN)
        end = text.index(ag.TABLE_END) + len(ag.TABLE_END)
        self.assertEqual(text[start:end], ag.design_table(graph))


if __name__ == "__main__":
    unittest.main()
