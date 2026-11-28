#!/usr/bin/env python3
"""design-system-census.py and check-design-scale-parity.py on tiny fixtures
(Leo, 2026-11-22: "the shifting projects and sizing of stuff ... we need to prevent this once and for all")."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import re
import os
import tempfile
import unittest
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
REPO = os.path.abspath(os.path.join(SCRIPTS, "..", ".."))


def load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, os.path.join(SCRIPTS, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


census = load("design_system_census", "design-system-census.py")
parity = load("check_design_scale_parity", "check-design-scale-parity.py")
SCALE = {0.0, 4.0, 6.0, 8.0, 12.0, 14.0, 16.0, 18.0}


def css(text: str):
    counts, sets = Counter(), {"custom_properties": set(), "radius.raw_values": set(), "shadow.literals": set()}
    census.css_counts(text, SCALE, counts, sets)
    return counts, sets


def write(root: str, rel: str, text: str) -> None:
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


class CensusCss(unittest.TestCase):
    def test_radius_classes(self):
        counts, sets = css("""
            .a { border-radius: var(--ds-radius-md); }
            .b { border-radius: 8px; }
            .c { border-radius: 5px 5px 0 0; }
            .d { border-radius: 999px; }
            .e { border-top-left-radius: 50%; }
            .f { border-radius: calc(var(--ds-radius-control) + 4px); }
            .g { border-radius: calc(var(--h) / 2); }
            .h { border-radius: 0; }
            .i { border-radius: inherit; }
            /* .j { border-radius: 3px; } */
        """)
        self.assertEqual(counts["radius.total"], 9)
        self.assertEqual(counts["radius.token"], 2)   # .a and .g (a bare factor is not a radius)
        self.assertEqual(counts["radius.mixed"], 1)   # .f
        self.assertEqual(counts["radius.raw"], 2)     # .b .c
        self.assertEqual(counts["radius.off_scale"], 1)
        self.assertEqual(counts["radius.capsule"], 2)
        self.assertEqual(counts["radius.zero"], 2)
        self.assertEqual(sets["radius.raw_values"], {"8px", "5px 5px 0 0"})

    def test_custom_properties_are_definitions_not_uses(self):
        _, sets = css(":root { --ds-radius-md: 6px; --acpmux-glass-blur: 4px; --x-shadow:\n 0 1px red; }"
                      ".a { color: var(--y); }")
        self.assertEqual(sets["custom_properties"], {"--ds-radius-md", "--acpmux-glass-blur", "--x-shadow"})

    def test_box_shadow_kinds(self):
        counts, sets = css("""
            .a { box-shadow: none; }
            .b { box-shadow: var(--elevation-2); }
            .c { box-shadow: inset 0 0 0 var(--cmux-hairline, 0.5px) var(--edge); }
            .d { box-shadow: 0 1px 2px rgba(0, 0, 0, 0.1); }
            .e { box-shadow: inset 0 0 0 1px var(--accent); }
            .f { box-shadow: 0 0 0 0 color-mix(in srgb, var(--x) 30%, transparent); }
        """)
        self.assertEqual((counts["shadow.none"], counts["shadow.token"], counts["shadow.literal"]), (1, 3, 2))
        self.assertEqual(len(sets["shadow.literals"]), 2)

    def test_backdrop_z_spacing_and_colour(self):
        counts, _ = css("""
            .a { backdrop-filter: var(--glass-blur); -webkit-backdrop-filter: blur(12px); }
            .b { z-index: 10; } .c { z-index: var(--layer-menu); } .d { z-index: auto; }
            .e { padding: 6px 8px; margin: 4px; gap: calc(3 * var(--grid-base)); }
            .f { color: #fff; background: var(--x, #000); border-color: rgb(var(--rgb) / 0.5); }
            .g { --tint: #123456; fill: rgba(1, 2, 3, 0.4); content: "#abc"; }
        """)
        self.assertEqual((counts["backdrop.token"], counts["backdrop.literal"]), (1, 1))
        self.assertEqual((counts["z.literal"], counts["z.var"], counts["z.other"]), (1, 1, 1))
        self.assertEqual(counts["spacing.off_grid"], 1)
        self.assertEqual(counts["color.css"], 2)  # #fff and rgba(); not the fallback, the token rgb(), the definition

    def test_a_declaration_in_a_comment_or_an_at_rule_prelude_is_not_counted(self):
        counts, _ = css("/* .a { box-shadow: 0 1px red; } */ @media (min-width: 4px) { .b { z-index: 1; } }")
        self.assertEqual(counts["shadow.total"], 0)
        self.assertEqual(counts["z.literal"], 1)


class CensusScripts(unittest.TestCase):
    def test_colour_literals_in_strings_only(self):
        strings, code = census.js_strings_and_code(
            'const a = "#fff"; // "#000"\nconst b = `rgba(0, 0, 0, ${x})`; const c = "PR #441"; /* "#abcdef" */\n'
            'const d = "rgb(var(--x) / 0.5)"; const e = "#a1b2c3";')
        self.assertEqual(census.js_color_literals(strings), 2)
        self.assertNotIn("#000", code.replace('"', ""))

    def test_primitives(self):
        _, code = census.js_strings_and_code(
            '<button title="x" /> <Button /> <Tooltip label="y"><input /></Tooltip> <textarea /> <Input />'
            ' // <button')
        found = {key: len(pattern.findall(code)) for key, pattern in census.PRIMITIVES.items()}
        self.assertEqual(found, {"button.raw": 1, "button.component": 1, "title.attribute": 1,
                                 "tooltip.component": 1, "input.raw": 2, "input.component": 1})

    def test_buckets(self):
        self.assertEqual(census.web_bucket("agent-session/acpmux/Composer.tsx"), "main")
        self.assertEqual(census.web_bucket("ui/Button.gallery.tsx"), "other")
        self.assertEqual(census.web_bucket("prototypes/x/styles.css"), "other")
        self.assertEqual(census.web_bucket("agent-session/acpmux/prototype/Shell.tsx"), "other")
        self.assertEqual(census.web_bucket("protocol/test/fixture.ts"), "other")


class CensusSwift(unittest.TestCase):
    def test_swift_counters(self):
        found = census.swift_counts("""
            layer.cornerRadius = 8
            layer?.cornerRadius = 0
            let card = Card(cornerRadius: 12, inset: 4)
            var panelCornerRadius: CGFloat = 10
            let r = on ? radius : 0
            layer.cornerRadius = Metrics.surfaceCornerRadius
            // layer.cornerRadius = 4
            let s = "cornerRadius = 7"
            view.layer?.zPosition = 1
            if layer.zPosition != 2 { layer.zPosition = -1 }
            let v = NSVisualEffectView(); let g = NSGlassEffectView()
            struct PopupGlassLook {}
            enum Material {}
            let h = DesignTokens.space1 + DesignTokens.controlRow
        """)
        self.assertEqual(found["corner"], 3)
        self.assertEqual(found["zposition"], 2)
        self.assertEqual(found["effect_views"], 2)
        self.assertEqual(found["glass_types"], ["Material", "PopupGlassLook"])
        self.assertEqual(found["tokens_refs"], 2)

    def test_census_runs_on_a_small_tree_with_json(self):
        with tempfile.TemporaryDirectory() as root:
            write(root, census.SCALE, json.dumps({"radii": [{"name": "md", "px": 6}],
                                                  "namedRadii": [{"name": "menu", "var": "var(--m)"}]}))
            write(root, "webviews/src/a.css", ".a { border-radius: 7px; }")
            write(root, "webviews/src/a.generated.css", ".a { border-radius: 7px; }")
            write(root, "webviews/src/node_modules/x.css", ".a { border-radius: 7px; }")
            write(root, "webviews/src/A.gallery.tsx", "<button />")
            write(root, f"{census.SWIFT}/CmuxNextApp/A.swift", "layer.cornerRadius = 3\n")
            write(root, f"{census.SWIFT}/CmuxNextDesign/B.swift", "layer.cornerRadius = 3\n")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(census.main(["--root", root, "--json"]), 0)
            data = json.loads(out.getvalue())
            self.assertEqual(data["web"]["all"]["radius"]["raw"], 1)
            self.assertEqual(data["web"]["main"]["radius"]["off_scale"], 1)
            self.assertEqual(data["web"]["other"]["primitives"]["button_raw"], 1)
            self.assertEqual(data["web"]["other"]["primitives"]["gallery_files"], 1)
            self.assertEqual(data["swift"]["design"]["corner_radius_literals"], 1)
            self.assertEqual(data["swift"]["other"]["corner_radius_literals"], 1)


TOKENS = """public struct DesignTokens {
    public static let space1: CGFloat = 4
    public nonisolated static let radiusPopup: CGFloat = {popup}
    public static let radiusControl: CGFloat = 6
}
"""
POPUP = """public struct PopupStyle {
    public let padding: CGFloat = DesignTokens.space1
    public static let elevation1 = Elevation(offset: 1, blur: 2, alpha: 0.07)
}
"""


class Parity(unittest.TestCase):
    def tree(self, root: str, popup_swift: int = 8, popup_schema: int = 8, extra_constant: str = "",
             control_fallback: int = 8) -> str:
        write(root, parity.SCALE, json.dumps({
            "spacing": {"steps": [{"name": "1", "px": 4}]},
            "namedRadii": [{"name": "popup", "px": popup_schema},
                           {"name": "control", "var": f"var(--cmux-button-radius, {control_fallback}px)"}],
            "elevation": [{"name": "1", "geometry": "0 1px 2px", "light": 7}],
        }))
        write(root, "src/CmuxNextDesignTokens/DesignTokens.swift",
              TOKENS.replace("{popup}", str(popup_swift)).replace("}\n", extra_constant + "}\n", 1)
              if extra_constant else TOKENS.replace("{popup}", str(popup_swift)))
        write(root, "src/CmuxNextDesign/PopupStyle.swift", POPUP)
        table = {
            "swiftRoot": "src",
            "pairs": [
                {"schema": "spacing.steps[name=1].px", "read": "px", "swift": "CmuxNextDesignTokens/DesignTokens.swift:space1"},
                {"schema": "namedRadii[name=popup].px", "read": "px", "swift": "CmuxNextDesignTokens/DesignTokens.swift:radiusPopup"},
                {"schema": "namedRadii[name=control].var", "read": "fallbackPx", "swift": "CmuxNextDesignTokens/DesignTokens.swift:radiusControl"},
                {"schema": "spacing.steps[name=1].px", "read": "px", "swift": "CmuxNextDesign/PopupStyle.swift:padding"},
                {"schema": "elevation[name=1].geometry", "read": "nth:2", "swift": "CmuxNextDesign/PopupStyle.swift:elevation1.blur"},
                {"schema": "elevation[name=1].light", "read": "percent", "swift": "CmuxNextDesign/PopupStyle.swift:elevation1.alpha"},
                {"schema": "dialog.padding", "read": "px", "swift": "CmuxNextDesignTokens/DesignTokens.swift:dialogPadding", "optional": True},
            ],
            "drift": [{"swift": "CmuxNextDesignTokens/DesignTokens.swift:radiusControl", "schemaValue": 8,
                       "swiftValue": 6, "reason": "fixture"}],
            "unmapped": [{"swift": "x", "reason": "computed"}],
        }
        path = os.path.join(root, "parity.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(table, handle)
        return path

    def test_equal_pairs_and_recorded_drift_pass(self):
        with tempfile.TemporaryDirectory() as root:
            errors, summary = parity.check(root, self.tree(root))
            self.assertEqual(errors, [])
            self.assertEqual(summary, "6 mapped, 5 equal, 1 drifting, 1 unmapped")

    def test_a_pair_moved_together_passes_and_one_moved_alone_fails(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertEqual(parity.check(root, self.tree(root, popup_swift=18, popup_schema=18))[0], [])
            errors, _ = parity.check(root, self.tree(root, popup_swift=18, popup_schema=8))
            self.assertEqual(len(errors), 1)
            self.assertIn("differs: namedRadii[name=popup].px", errors[0])

    def test_a_fixed_or_changed_drift_entry_fails(self):
        with tempfile.TemporaryDirectory() as root:
            errors, _ = parity.check(root, self.tree(root, control_fallback=6))
            self.assertEqual(len(errors), 1)
            self.assertIn("drift fixed", errors[0])
            errors, _ = parity.check(root, self.tree(root, control_fallback=10))
            self.assertIn("drift changed", errors[0])

    def test_a_new_tokens_constant_needs_a_pair_and_an_optional_pair_needs_both_sides(self):
        with tempfile.TemporaryDirectory() as root:
            errors, _ = parity.check(root, self.tree(root, extra_constant="    public static let radiusSheet: CGFloat = 20\n"))
            self.assertEqual(errors, ["unmapped DesignTokens.radiusSheet: add its design-scale pair to "
                                      "schemas/design-scale/swift-parity.json"])
            errors, _ = parity.check(root, self.tree(root, extra_constant="    public static let dialogPadding: CGFloat = 12\n"))
            self.assertEqual(len(errors), 1)
            self.assertIn("missing: dialog.padding", errors[0])

    def test_an_unreadable_symbol_fails(self):
        with tempfile.TemporaryDirectory() as root:
            table = self.tree(root)
            write(root, "src/CmuxNextDesign/PopupStyle.swift", POPUP.replace("DesignTokens.space1", "Metrics.scale(4)"))
            errors, _ = parity.check(root, table)
            self.assertEqual(len(errors), 1)
            self.assertIn("unreadable", errors[0])

    def test_a_design_scale_alias_reads_the_generated_value_and_a_native_override_is_recorded_drift(self):
        # DesignTokens forwards to DesignScale, which gen-design-scale-swift.py writes at build time; the
        # checker runs the generator and reads it. A NativeOverride is drift the generator records.
        with tempfile.TemporaryDirectory() as root:
            table = self.tree(root)
            tokens = os.path.join(root, "src/CmuxNextDesignTokens/DesignTokens.swift")
            with open(tokens, encoding="utf-8") as handle:
                text = handle.read()
            text = re.sub(r"(space1: CGFloat = )\S+", r"\1DesignScale.space1", text)
            text = re.sub(r"(radiusControl: CGFloat = )\S+", r"\1DesignScale.NativeOverride.radiusControl", text)
            write(root, "src/CmuxNextDesignTokens/DesignTokens.swift", text)
            with open(table, encoding="utf-8") as handle:
                data = json.load(handle)
            data["drift"] = []
            with open(table, "w", encoding="utf-8") as handle:
                json.dump(data, handle)
            generated = ("public enum DesignScale {\n    public static let space1: CGFloat = {space}\n"
                         "    public static let radiusControl: CGFloat = 8\n"
                         "    public nonisolated enum NativeOverride {\n"
                         "        public static let radiusControl: CGFloat = 6\n    }\n}\n")
            for space, want in ((4, []), (5, ["differs: spacing.steps[name=1].px"])):
                parity._GENERATED.pop(root, None)
                write(root, parity.GENERATOR, "import sys, os\nout = sys.argv[sys.argv.index('--swift-out') + 1]\n"
                      f"open(os.path.join(out, {parity.GENERATED_FILE!r}), 'w').write({generated.replace('{space}', str(space))!r})\n")
                errors, summary = parity.check(root, table)
                self.assertEqual([e.split(" <->")[0] for e in errors if "space1" in e], want, errors)
            self.assertNotIn("radiusControl", " ".join(errors))

    def test_the_repository_table_passes(self):
        errors, summary = parity.check(REPO, os.path.join(REPO, parity.TABLE))
        self.assertEqual(errors, [], summary)


if __name__ == "__main__":
    unittest.main()
