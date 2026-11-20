#!/usr/bin/env python3
"""Every option a scripts/cmux-next script reads is one its parser defines.

cmux#44416 dropped `--typing-loads` from agent-engine-bench.py but kept a check of `opts.typing_loads` right after
`parser.parse_args()`, so every run of the bench raised AttributeError before it launched anything. The class: a
script with a module-level `NAME = parser.parse_args()` reads `NAME.attr` that no `add_argument` defines. This reads
each such script (no subparsers, no set_defaults, whose namespaces vary) and names every undefined attribute, so a
removed option cannot leave a reader behind. No app, no fleet; runs on Linux:

    python3 scripts/cmux-next/tests/test_bench_option_refs.py
"""
import ast
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent


def option_dests(tree):
    """The attribute each add_argument call defines: dest=, else the first long flag, else the first name."""
    dests = set()
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and getattr(node.func, "attr", None) == "add_argument"):
            continue
        keywords = {k.arg: k.value for k in node.keywords}
        if isinstance(keywords.get("dest"), ast.Constant):
            dests.add(keywords["dest"].value)
            continue
        names = [a.value for a in node.args if isinstance(a, ast.Constant) and isinstance(a.value, str)]
        longs = [n for n in names if n.startswith("--")]
        if longs or names:
            dests.add((longs or names)[0].lstrip("-").replace("-", "_"))
    return dests


def undefined_option_reads(source):
    """{attr: first line} read from a module-level parse_args() result and defined by no add_argument (pure)."""
    if "add_subparsers" in source or "set_defaults" in source:
        return {}
    tree = ast.parse(source)
    namespaces = {target.id for node in tree.body if isinstance(node, ast.Assign)
                  and isinstance(node.value, ast.Call) and getattr(node.value.func, "attr", None) == "parse_args"
                  for target in node.targets if isinstance(target, ast.Name)}
    if not namespaces:
        return {}
    dests, reads = option_dests(tree), {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id in namespaces:
            reads.setdefault(node.attr, node.lineno)
    return {attr: line for attr, line in reads.items() if attr not in dests}


class OptionReadsTest(unittest.TestCase):
    def test_every_script_reads_only_options_it_defines(self):
        bad = {}
        for path in sorted(SCRIPTS.glob("*.py")):
            missing = undefined_option_reads(path.read_text(encoding="utf-8"))
            if missing:
                bad[path.name] = missing
        self.assertEqual(bad, {}, "scripts read options their parser does not define (file: {attr: line})")

    def test_detector_catches_a_removed_option(self):
        source = ("import argparse\nparser = argparse.ArgumentParser()\nparser.add_argument('--keys', type=int)\n"
                  "parser.add_argument('--key-gap-ms', dest='gap')\nopts = parser.parse_args()\n"
                  "if opts.typing_loads and opts.keys and opts.gap:\n    pass\n")
        self.assertEqual(undefined_option_reads(source), {"typing_loads": 6})

    def test_agent_engine_bench_gets_past_its_option_checks(self):
        """A native run's first lines on Linux: the Mac-only modules stubbed, it parses and checks its options and
        stops at bundle_id(), the first call after them (before the fix: AttributeError on opts.typing_loads)."""
        driver = (
            "import runpy, sys, types\n"
            "class Reached(Exception): pass\n"
            "def stop(*a, **k): raise Reached()\n"
            "sys.modules['bench_memory'] = types.ModuleType('bench_memory')\n"
            "launch = types.ModuleType('bench_launch')\n"
            "launch.LaunchError, launch.launch_app, launch.require_no_person_mac = Exception, stop, lambda *a: None\n"
            "launch.bundle_id = stop\n"
            "sys.modules['bench_launch'] = launch\n"
            "sys.argv = [sys.argv[1], '--tag', 'optref', '--app', '/nonexistent/optref.app']\n"
            "try:\n    runpy.run_path(sys.argv[0], run_name='__main__')\n"
            "except Reached:\n    print('reached bundle_id')\n")
        run = subprocess.run([sys.executable, "-c", driver, str(SCRIPTS / "agent-engine-bench.py")],
                             capture_output=True, text=True, timeout=60)
        self.assertEqual((run.returncode, run.stdout.strip()), (0, "reached bundle_id"), run.stderr)


if __name__ == "__main__":
    unittest.main()
