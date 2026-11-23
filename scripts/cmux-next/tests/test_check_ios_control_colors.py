#!/usr/bin/env python3
"""check-ios-control-colors.py: a literal color inside a control counts, the same color outside one does not, tokens
and allowed lines never do, growth fails (python3 scripts/cmux-next/tests/test_check_ios_control_colors.py)."""
import importlib.util, io, os, tempfile, unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("control", os.path.join(HERE, "..", "check-ios-control-colors.py"))
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def count(source):
    return len(check.control_hits(source))


class Hits(unittest.TestCase):
    def test_send_button_white_glyph_counts(self):
        source = "Button { send() } label: {\n    Image(systemName: \"arrow.up\")\n        .foregroundStyle(.white)\n}\n"
        self.assertEqual(count(source), 1)

    def test_tinted_button_and_press_fill_count(self):
        self.assertEqual(count('Button("Pause") { pause() }.tint(.orange)\n'), 1)
        self.assertEqual(count(".cmuxMobilePressBackground(Color.red, in: .circle)\n"), 1)
        self.assertEqual(count(".glassEffect(.regular.tint(.black.opacity(0.5)).interactive(), in: .circle)\n"), 1)

    def test_button_style_body_counts(self):
        source = ("struct S: ButtonStyle {\n    func makeBody(configuration: Configuration) -> some View {\n"
                  "        configuration.label.background(Color(white: 0.18))\n    }\n}\n")
        self.assertEqual(count(source), 1)

    def test_outside_a_control_does_not_count(self):
        source = "Button { go() } label: { Text(\"Go\") }\nText(\"x\").foregroundStyle(.red)\n"
        self.assertEqual(count(source), 0)

    def test_tokens_allowed_lines_and_comments_do_not(self):
        source = ("Button { send() } label: {\n"
                  "    Image(systemName: \"arrow.up\").foregroundStyle(Color.cmuxMobileOnAccent)\n"
                  "    // was .foregroundStyle(.white)\n"
                  "    Circle().fill(Color.black) // color-literal-allow: mask\n"
                  "}\n.cmuxMobileFloatingGlass(in: .capsule, interactive: true)\n")
        self.assertEqual(count(source), 0)


class Ratchet(unittest.TestCase):
    def run_check(self, source, rows):
        with tempfile.TemporaryDirectory() as root:
            folder = os.path.join(root, check.TREE, "CmuxMobileAgentChat")
            os.makedirs(folder)
            with open(os.path.join(folder, "Send.swift"), "w") as handle:
                handle.write(source)
            baseline = os.path.join(root, "baseline.tsv")
            with open(baseline, "w") as handle:
                handle.writelines(f"{check.TREE}/CmuxMobileAgentChat/Send.swift\t{n}\n" for n in rows)
            with redirect_stdout(io.StringIO()):
                return check.main(["--root", root, "--baseline", baseline])

    def test_growth_fails_and_baseline_passes(self):
        source = 'Button("Stop") { stop() }.tint(.red)\nButton("Go") { go() }.tint(.green)\n'
        self.assertEqual(self.run_check(source, [1]), 1)
        self.assertEqual(self.run_check(source, [2]), 0)
        self.assertEqual(self.run_check('Button("Go") { go() }.tint(Color.cmuxMobileAccent)\n', []), 0)


if __name__ == "__main__":
    unittest.main()
