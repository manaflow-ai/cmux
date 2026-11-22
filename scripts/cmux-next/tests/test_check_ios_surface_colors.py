#!/usr/bin/env python3
"""check-ios-surface-colors.py: literal colors and opaque stock surfaces count, allowed lines and comments do not, growth fails (python3 scripts/cmux-next/tests/test_check_ios_surface_colors.py)."""
import importlib.util, io, os, sys, tempfile, unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("check", os.path.join(HERE, "..", "check-ios-surface-colors.py"))
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class Hits(unittest.TestCase):
    def test_literals_and_stock_surfaces_count(self):
        for line in (
            ".background(Color.cmuxMobileCard, in: .rect(cornerRadius: 20))",
            ".background(.black.opacity(0.4))",
            "let c = UIColor(red: 1, green: 0, blue: 0, alpha: 1)",
            ".fill(Color(white: 0.18))",
            "view.backgroundColor = .secondarySystemBackground",
            ".fill(theme.colors.surfaceRaised)",
            "layer.borderColor = UIColor.gray.cgColor",
        ):
            self.assertEqual(check.hits(line), 1, line)

    def test_tokens_allowed_lines_and_comments_do_not(self):
        for line in (
            ".cmuxMobileContentSurface(.card, in: .rect(cornerRadius: 20))",
            ".foregroundStyle(.secondary)",
            "mask.colors = [UIColor.black.cgColor] // color-literal-allow: mask alpha",
            "// was Color.cmuxMobileCard",
            "/// Never `.black`: Color.black",
            "let x = 1 // Color.white in a trailing comment",
        ):
            self.assertEqual(check.hits(line), 0, line)


class Placeholders(unittest.TestCase):
    def test_placeholder_and_debug_colors_are_found(self):
        for line in (
            ".fill(Color.yellow.opacity(0.28))",
            "background.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.28)",
            ".tint(.orange)",
            ".foregroundStyle(.red)",
            "    case .failed: .red",
            "LinearGradient(colors: [.orange, .pink], startPoint: .top, endPoint: .bottom)",
            ".redacted(reason: .placeholder)",
            ".border(Color.blue)",
            "configuration.baseForegroundColor = .systemRed",
        ):
            self.assertEqual(len(check.placeholder_lines(line)), 1, line)

    def test_tokens_components_cases_and_allowed_lines_are_not(self):
        for line in (
            ".fill(Color.cmuxMobileMatch)",
            ".foregroundStyle(Color.cmuxMobileDanger)",
            "let r = rgb.red + a.red",
            "case .red: return 1",
            "case \"red\": return Color.red // color-literal-allow: the workspace color the person picked",
            "view.layer.borderWidth = 1",
            "// Color.red in a comment",
        ):
            self.assertEqual(check.placeholder_lines(line), [], line)


class Ratchet(unittest.TestCase):
    def run_check(self, source, baseline_rows):
        with tempfile.TemporaryDirectory() as root:
            folder = os.path.join(root, check.TREE, "CmuxMobileAgentChat")
            os.makedirs(folder)
            with open(os.path.join(folder, "Card.swift"), "w") as handle:
                handle.write(source)
            baseline = os.path.join(root, "baseline.tsv")
            with open(baseline, "w") as handle:
                handle.writelines(f"{check.TREE}/CmuxMobileAgentChat/Card.swift\t{n}\n" for n in baseline_rows)
            with redirect_stdout(io.StringIO()):
                return check.main(["--root", root, "--baseline", baseline])

    def test_growth_fails_and_baseline_passes(self):
        source = ".background(Color.cmuxMobileCard)\n.background(Color.black)\n"
        self.assertEqual(self.run_check(source, [1]), 1)
        self.assertEqual(self.run_check(source, [2]), 0)
        self.assertEqual(self.run_check(".cmuxMobileContentSurface(.card, in: Circle())\n", []), 0)

    def test_a_placeholder_color_fails_whatever_the_baseline(self):
        self.assertEqual(self.run_check(".fill(Color.yellow)\n", [5]), 1)
        self.assertEqual(self.run_check(".tint(.red)\n", [5]), 1)


if __name__ == "__main__":
    unittest.main()
