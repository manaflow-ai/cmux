"""The PR performance-section check: a perf PR records before/after deltas in its description."""
import contextlib
import importlib.util
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/pr_perf_section_check.py"
spec = importlib.util.spec_from_file_location("pr_perf_section_check", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

CODE = ["Packages/macOS/CmuxNext/Sources/CmuxNextApp/Sidebar/SidebarList.swift"]
COMPLETE = """## Summary

Sidebar opens faster.

## Performance

| metric | before | after | delta | harness or run link |
| --- | --- | --- | --- | --- |
| sidebar open p50 | 182 ms | 113 ms | -38% | https://github.com/manaflow-ai/cmux/actions/runs/1 |

## Testing

ran it
"""


def without(column: str) -> str:
    """COMPLETE with one column's cell in the data row blanked."""
    header = ["metric", "before", "after", "delta", "harness or run link"]
    row = ["sidebar open p50", "182 ms", "113 ms", "-38%", "https://github.com/manaflow-ai/cmux/actions/runs/1"]
    row[header.index(column)] = ""
    table = "| " + " | ".join(header) + " |\n| --- | --- | --- | --- | --- |\n| " + " | ".join(row) + " |\n"
    return "## Performance\n\n" + table


class TriggerTests(unittest.TestCase):
    def test_label_triggers(self):
        self.assertTrue(module.trigger("Tidy the sidebar", "", {"perf"}))
        self.assertTrue(module.trigger("Tidy the sidebar", "", {"Performance"}))
        self.assertFalse(module.trigger("Tidy the sidebar", "", {"bug", "sidebar"}))

    def test_each_trigger_word(self):
        for text in ("perf: cache rows", "perf(sidebar): cache rows", "Improve performance of the rail",
                     "Cut input latency", "Lower latencies", "Open tabs faster", "Speed up the composer",
                     "speeds", "2x speedup", "a speed-up for scroll", "PERF"):
            self.assertTrue(module.trigger(text, "", set()), text)
            self.assertTrue(module.trigger("Tidy", text, set()), text)

    def test_near_misses_do_not_trigger(self):
        for text in ("perform the migration", "performed cleanup", "performing a rename", "performer",
                     "a perfect fit", "imperfect", "speedometer", "the fasterxml jar", "superperf",
                     "Fix the composer caret after paste"):
            self.assertFalse(module.trigger(text, text, set()), text)

    def test_comments_code_and_urls_do_not_trigger(self):
        body = ("<!-- Performance change? Add a table: faster, latency -->\n"
                "```\nperf record -g\n```\n"
                "Edited `scripts/perf.sh` and `perf_harness.py`.\n"
                "See https://example.com/perf/latency\n")
        self.assertFalse(module.trigger("Tidy the sidebar", body, set()))

    def test_the_pr_template_does_not_trigger(self):
        template = (ROOT / ".github/pull_request_template.md").read_text()
        self.assertFalse(module.trigger("", template, set()))


class SectionTests(unittest.TestCase):
    def check(self, body, title="Speed up the sidebar", labels=(), paths=CODE):
        return module.check(title, body, set(labels), list(paths))

    def test_complete_section_passes(self):
        code, message = self.check(COMPLETE)
        self.assertEqual(code, 0, message)

    def test_missing_section_fails(self):
        code, message = self.check("## Summary\n\nfaster now\n")
        self.assertEqual(code, 1)
        self.assertIn("no `## Performance` section", message)

    def test_section_without_table_fails(self):
        code, message = self.check("## Performance\n\nIt is 38% faster.\n\n## Testing\n")
        self.assertEqual(code, 1)
        self.assertIn("no before/after table", message)

    def test_each_missing_field_fails(self):
        for column, name in (("metric", "metric"), ("before", "before"), ("after", "after"),
                             ("delta", "delta"), ("harness or run link", "harness")):
            code, message = self.check(without(column))
            self.assertEqual(code, 1, column)
            self.assertIn(name, message, column)

    def test_each_missing_column_fails(self):
        for drop in range(5):
            header = ["metric", "before", "after", "delta", "harness"]
            row = ["open", "1", "2", "+1", "bench"]
            del header[drop], row[drop]
            body = ("## Performance\n\n| " + " | ".join(header) + " |\n|" + " --- |" * 4 + "\n| "
                    + " | ".join(row) + " |\n")
            code, message = self.check(body)
            self.assertEqual(code, 1, header)
            self.assertIn("needs the columns", message)

    def test_placeholders_count_as_empty(self):
        body = COMPLETE.replace("182 ms", "<before>")
        self.assertEqual(self.check(body)[0], 1)
        for placeholder in ("TBD", "-", "?", "n/a", "..."):
            self.assertEqual(self.check(COMPLETE.replace("-38%", placeholder))[0], 1, placeholder)

    def test_url_autolink_is_a_value(self):
        body = COMPLETE.replace("https://github.com/manaflow-ai/cmux/actions/runs/1",
                                "<https://github.com/manaflow-ai/cmux/actions/runs/1>")
        self.assertEqual(self.check(body)[0], 0)

    def test_header_only_table_fails(self):
        body = "## Performance\n\n| metric | before | after | delta | run |\n| --- | --- | --- | --- | --- |\n"
        self.assertIn("no rows", self.check(body)[1])

    def test_run_column_name_and_extra_columns(self):
        body = ("### Performance\n\n| Metric | Before | After | Delta | Run | Notes |\n|---|---|---|---|---|---|\n"
                "| p95 | 40 ms | 31 ms | -22% | https://x.test/r/1 | warm |\n| p50 | 20 ms | 18 ms | -10% | bun bench |  |\n")
        self.assertEqual(self.check(body)[0], 0)

    def test_section_in_a_code_block_does_not_count(self):
        self.assertEqual(self.check("```\n" + COMPLETE + "```\n")[0], 1)

    def test_table_after_the_section_does_not_count(self):
        body = "## Performance\n\nsoon\n\n## Testing\n\n" + COMPLETE.split("## Performance")[1]
        self.assertEqual(self.check(body)[0], 1)

    def test_no_numbers_line_passes_only_in_the_section(self):
        line = "No perf numbers: a rename; the word speed is in a symbol name."
        self.assertEqual(self.check("## Performance\n\n" + line + "\n")[0], 0)
        self.assertEqual(self.check(line)[0], 1)
        self.assertEqual(self.check("## Performance\n\nNo perf numbers:\n")[0], 1)
        for template in ("<why>", "TBD", "<why> ", "**<why>**", "n/a"):
            self.assertEqual(self.check("## Performance\n\nNo perf numbers: " + template + "\n")[0], 1, template)
        self.assertEqual(self.check("## Performance\n\nsoon\n\n## Testing\n\n" + line)[0], 1)

    def test_separator_must_match_the_header(self):
        body = ("## Performance\n\n| metric | before | after | delta | run |\n| --- |\n"
                "| p50 | 20 ms | 18 ms | -10% | bun bench |\n")
        self.assertIn("no before/after table", self.check(body)[1])

    def test_an_unrelated_table_first_does_not_fail_a_good_one(self):
        other = "| file | change |\n| --- | --- |\n| a.swift | cache |\n\n"
        body = COMPLETE.replace("## Performance\n\n", "## Performance\n\n" + other)
        self.assertEqual(self.check(body)[0], 0)
        self.assertEqual(self.check("## Performance\n\n" + other)[0], 1)

    def test_not_perf_passes(self):
        self.assertEqual(self.check("## Summary\n\nFix the caret.", title="Fix the composer caret")[0], 0)

    def test_docs_only_is_exempt(self):
        self.assertEqual(self.check("", paths=["docs/perf.md", "skills/x/SKILL.md"])[0], 0)
        self.assertEqual(self.check("", paths=["docs/perf.md", "scripts/x.py"])[0], 1)
        self.assertEqual(self.check("", paths=[])[0], 1)
        # A rename lists both paths, so code moved under docs/ is not docs-only.
        self.assertEqual(self.check("", paths=["scripts/bench.py", "docs/bench.md"])[0], 1)

    def test_workflow_lists_both_sides_of_a_rename(self):
        workflow = (ROOT / ".github/workflows/pr-perf-section-check.yml").read_text()
        self.assertIn("--no-renames", workflow)
        self.assertIn("previous_filename", workflow)


class LightPathTests(unittest.TestCase):
    """A small change takes the light path: no Performance table (Leo, 2026-10-31)."""

    def test_small_or_removal_diffs_need_no_table(self):
        for added, deleted in ((3, 4), (60, 60), (12, 900)):
            code, message = module.check("Speed up the sidebar", "faster now", {"perf"}, list(CODE), added, deleted)
            self.assertEqual(code, 0, message)
            self.assertIn("light path", message)

    def test_larger_diffs_and_unknown_sizes_still_need_one(self):
        for added, deleted in ((100, 21), (40, 300), (None, None)):
            code, _ = module.check("Speed up the sidebar", "faster now", set(), list(CODE), added, deleted)
            self.assertEqual(code, 1, (added, deleted))

    def test_command_line_reads_the_sizes(self):
        with tempfile.TemporaryDirectory() as tmp:
            body, paths = Path(tmp, "body.md"), Path(tmp, "paths.txt")
            body.write_text("faster now\n", encoding="utf-8")
            paths.write_text("Sources/App.swift\n", encoding="utf-8")
            argv = ["--body-file", str(body), "--paths-file", str(paths), "--title", "Speed up"]
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(module.main(argv + ["--additions", "2", "--deletions", "1"]), 0)
                self.assertEqual(module.main(argv + ["--additions", "", "--deletions", ""]), 1)


class CommandLineTests(unittest.TestCase):
    def run_check(self, body, title, labels="", paths=CODE):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "body.md").write_text(body)
            (Path(tmp) / "paths.txt").write_text("\n".join(paths) + "\n")
            done = subprocess.run([sys.executable, str(SCRIPT), "--body-file", f"{tmp}/body.md", "--paths-file",
                                   f"{tmp}/paths.txt", "--title", title, "--labels", labels],
                                  capture_output=True, text=True)
        return done.returncode, done.stdout

    def test_failure_prints_the_template(self):
        code, out = self.run_check("", "Tidy", labels="perf")
        self.assertEqual(code, 1)
        self.assertIn("::error", out)
        self.assertIn("| metric | before | after | delta | harness or run link |", out)

    def test_complete_passes(self):
        self.assertEqual(self.run_check(COMPLETE, "perf: sidebar")[0], 0)

    def test_missing_body_file_is_bad_input(self):
        done = subprocess.run([sys.executable, str(SCRIPT), "--body-file", "/nonexistent", "--paths-file",
                               "/nonexistent"], capture_output=True, text=True)
        self.assertEqual(done.returncode, 2)


if __name__ == "__main__":
    unittest.main()
