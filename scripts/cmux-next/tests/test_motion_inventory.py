"""motion_inventory.py: what counts as an animation, a tokened one, a slow one, and a raw colour."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import motion_inventory as mi  # noqa: E402

SCALE = {
    "steps": [{"name": "quick", "ms": 80, "for": ""}, {"name": "micro", "ms": 120, "for": ""},
              {"name": "standard", "ms": 180, "for": ""}, {"name": "large", "ms": 200, "for": ""}],
    "spinner": {"ms": 2000, "for": ""},
    "send": {"ms": 180, "ease": [0, 0, 1, 1], "for": ""},
    "settle": {"ms": 180, "bezier": [0, 0, 1, 1], "for": ""},
}


def tree(files: dict[str, str]) -> Path:
    root = Path(tempfile.mkdtemp())
    files = {"schemas/motion-scale/motion-scale.json": json.dumps(SCALE), **files}
    for rel, text in files.items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text(text)
    return root


def web_sites(css: str, name: str = "a.css") -> list[mi.Site]:
    root = tree({f"webviews/src/{name}": css})
    return [s for s in mi.inventory(root).sites if s.surface == "webviews"]


class WebSites(unittest.TestCase):
    def test_a_step_token_is_tokened_and_a_literal_is_not(self):
        sites = web_sites(".a { transition: opacity var(--cmux-motion-quick, 80ms) ease-out, translate 120ms; }")
        self.assertEqual([(s.tokened, s.ms) for s in sites], [(True, 80), (False, 120)])

    def test_an_alias_of_a_step_is_tokened_and_a_zero_switch_does_not_break_it(self):
        css = (":root { --agent-motion-in: var(--cmux-motion-micro, 120ms); }\n"
               ".off { --agent-motion-in: 0s; }\n.a { animation: in var(--agent-motion-in) both; }")
        site = [s for s in web_sites(css) if s.kind == "site"][0]
        self.assertTrue(site.tokened)
        self.assertEqual(site.ms, 120)

    def test_a_token_multiplied_off_the_scale_is_not_the_token(self):
        site = web_sites(".a { transition: opacity calc(var(--cmux-motion-micro) * 1.25); }")[0]
        self.assertFalse(site.tokened)
        self.assertEqual(site.ms, 150)
        on = web_sites(".a { transition: opacity calc(var(--cmux-motion-micro) * 1.5); }")[0]
        self.assertTrue(on.tokened)  # 180 ms, the standard step

    def test_slow_is_a_state_change_past_200_ms(self):
        css = (".a { transition: transform 240ms; }\n.b { animation: spin 1s linear infinite; }\n"
               ".c { transition: opacity var(--cmux-hover-reveal-in); }\n:root { --cmux-hover-reveal-in: 400ms; }")
        slow = [(s.line, s.ms) for s in web_sites(css) if s.slow]
        self.assertEqual(slow, [(1, 240)])

    def test_scripts_read_template_tokens_waapi_and_constants(self):
        ts = ("import { MOTION_MS } from './scale';\nconst FADE_MS = 160;\n"
              "el.animate(f, { duration: MOTION_MS.micro });\nel.animate(f, { duration: 250 });\n"
              "const css = `.x { transition: opacity ${MOTION_MS.quick}ms; }`;\n// transition: opacity 999ms\n")
        sites = web_sites(ts, "a.ts")
        got = sorted((s.line, s.kind, s.tokened, s.ms) for s in sites)
        self.assertEqual(got, [(2, "def", False, 160), (3, "site", True, None), (4, "site", False, 250),
                               (5, "site", True, None)])

    def test_scripts_read_style_assignments_and_set_property(self):
        ts = ('el.style.transition = "opacity 300ms";\nel.style.transitionDuration = "250ms";\n'
              'el.style.setProperty("transition", "transform 220ms ease");\nconst transition = useTransition();\n')
        got = sorted((s.line, s.tokened, s.ms) for s in web_sites(ts, "a.ts"))
        self.assertEqual(got, [(1, False, 300), (2, False, 250), (3, False, 220)])

    def test_marked_lines_are_allowed(self):
        site = web_sites(".a { transition: width 1s linear; } /* motion-allow: playback progress */")[0]
        self.assertTrue(site.allowed)


class Native(unittest.TestCase):
    def test_gate_calls_are_tokened_and_marked_raw_animations_are_not(self):
        swift = ("Motion.sidebar.animate(.move, in: row) { row.animator().frame = f }\n"
                 "// motion: allow a measured one-off that obeys the switches\n"
                 "let a = CABasicAnimation(keyPath: \"opacity\")\n")
        root = tree({"Packages/macOS/CmuxNext/Sources/A/A.swift": swift})
        sites = [s for s in mi.inventory(root).sites if s.surface == "native" and s.kind == "site"]
        self.assertEqual([(s.line, s.tokened) for s in sites], [(1, True), (3, False)])

    def test_spring_visible_end_matches_the_swift_simulation(self):
        # MotionTunables' comments: response 0.2 critically damped ends visibly at 235 ms, 0.15 at 177 ms.
        self.assertAlmostEqual(mi.spring_visible_end(0.2, 1) * 1000, 235, delta=1)
        self.assertAlmostEqual(mi.spring_visible_end(0.15, 1) * 1000, 177, delta=1)


class Colours(unittest.TestCase):
    def test_raw_colours_outside_token_files(self):
        root = tree({
            "webviews/src/a.css": ":root { --x: #ff0000; }\n.a { color: #00ff00; }\n.b { --y: var(--z, #fff); }",
            "webviews/src/b.ts": "const c = 'rgb(1, 2, 3)';\nconst d = 5; // #abc\n"
                                 "const e = '#123456'; // colour-allow: a brand mark\n",
            "webviews/src/theme/t.ts": "const c = '#ffffff';",
            "Packages/macOS/CmuxNext/Sources/A/A.swift": "let c = NSColor(red: 1, green: 0, blue: 0, alpha: 1)\n"
                                                         "let d = Palette.accent\n",
        })
        hits = {path: [line for line, _ in found] for path, found in mi.raw_colours(root).items()}
        self.assertEqual(hits, {"webviews/src/a.css": [1], "webviews/src/b.ts": [1],
                                "Packages/macOS/CmuxNext/Sources/A/A.swift": [1]})


class Coverage(unittest.TestCase):
    def test_the_figure_is_tokened_over_all_per_surface(self):
        root = tree({"webviews/src/a.css": ".a { transition: opacity var(--cmux-motion-quick); }\n"
                                           ".b { transition: opacity 120ms; }"})
        report = mi.coverage(mi.inventory(root))
        self.assertEqual(report["surfaces"]["webviews"]["animations"], 2)
        self.assertEqual(report["surfaces"]["webviews"]["coverage"], 0.5)


class Ratchet(unittest.TestCase):
    def run_check(self, root: Path, baseline: Path, *extra: str) -> tuple[int, str]:
        import subprocess
        script = Path(__file__).resolve().parent.parent / "check-motion-tokens.py"
        done = subprocess.run([sys.executable, "-I", str(script), "--root", str(root), "--baseline", str(baseline),
                               *extra], capture_output=True, text=True)
        return done.returncode, done.stdout

    def test_growth_fails_shrink_passes_and_update_never_raises(self):
        root = tree({"webviews/src/a.ts": "const css = `.x { transition: opacity 150ms; }`;\n"})
        baseline = root / "baseline.tsv"
        baseline.write_text("duration\twebviews/src/a.ts\t1\n")
        self.assertEqual(self.run_check(root, baseline)[0], 0)
        (root / "webviews/src/a.ts").write_text("const css = `.x { transition: opacity 150ms, color 90ms; }`;\n")
        code, out = self.run_check(root, baseline)
        self.assertEqual(code, 1)
        self.assertIn("webviews/src/a.ts: 2 (baseline 1)", out)
        self.run_check(root, baseline, "--update-baseline")
        self.assertIn("\t1", baseline.read_text())  # never raised
        (root / "webviews/src/a.ts").write_text("const css = `.x { transition: opacity ${MOTION_MS.micro}ms; }`;\n")
        code, out = self.run_check(root, baseline)
        self.assertEqual(code, 0)
        self.assertIn("lower it", out)
        self.run_check(root, baseline, "--update-baseline")
        self.assertNotIn("a.ts", baseline.read_text())


if __name__ == "__main__":
    unittest.main()
