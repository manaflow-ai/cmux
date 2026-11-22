#!/usr/bin/env python3
"""Every option a scripts/cmux-next script reads is one its parser defines.

cmux#44416 dropped `--typing-loads` from agent-engine-bench.py but kept a check of `opts.typing_loads` right after
`parser.parse_args()`, so every run of the bench raised AttributeError before it launched anything. The class: a
script with a module-level `NAME = parser.parse_args()` reads `NAME.attr` that no `add_argument` defines. This reads
each such script (no subparsers, no set_defaults, whose namespaces vary) and names every undefined attribute, so a
removed option cannot leave a reader behind. A script that hands its parser to a module beside it
(`new_surface_screen.add_arguments(parser)` in cmd-n-paint-e2e.py) also has the options that module's
`add_arguments` defines. The detector does not see when that call runs: cmd-n-paint-e2e.py makes it only with
`--screen`, so a read of such an option outside `if opts.screen:` is not found. No app, no fleet; runs on Linux:

    python3 scripts/cmux-next/tests/test_bench_option_refs.py
"""
import ast
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent


def sibling_source(name):
    """The text of the module NAME beside the scripts, or None when there is no such file."""
    path = SCRIPTS / f"{name}.py"
    return path.read_text(encoding="utf-8") if path.is_file() else None


def option_dests(tree, module_source=None, parsers=()):
    """The attribute each add_argument call defines: dest=, else the first long flag, else the first name. A call
    `NAME.add_arguments(PARSER)` adds what the function `add_arguments` of the module NAME defines the same way
    (`module_source(NAME)` is that module's text, or None), when PARSER is one of PARSERS (the script's own)."""
    dests = set()
    for node in ast.walk(tree):
        if (module_source and isinstance(node, ast.Call) and getattr(node.func, "attr", None) == "add_arguments"
                and isinstance(node.func.value, ast.Name)):
            handed = node.args[0] if node.args else None
            text = module_source(node.func.value.id) if getattr(handed, "id", None) in parsers else None
            for inner in ast.parse(text).body if text else []:
                if isinstance(inner, ast.FunctionDef) and inner.name == "add_arguments":
                    dests |= option_dests(inner)
            continue
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


def undefined_option_reads(source, module_source=None):
    """{attr: first line} read from a module-level parse_args() result and defined by no add_argument (pure)."""
    if "add_subparsers" in source or "set_defaults" in source:
        return {}
    tree = ast.parse(source)
    namespaces = {target.id for node in tree.body if isinstance(node, ast.Assign)
                  and isinstance(node.value, ast.Call) and getattr(node.value.func, "attr", None) == "parse_args"
                  for target in node.targets if isinstance(target, ast.Name)}
    if not namespaces:
        return {}
    # The parsers whose parse_args() result is read: a module's options count only on one of these.
    parsers = {node.value.func.value.id for node in tree.body if isinstance(node, ast.Assign)
               and isinstance(node.value, ast.Call) and getattr(node.value.func, "attr", None) == "parse_args"
               and isinstance(node.value.func.value, ast.Name)}
    dests, reads = option_dests(tree, module_source, parsers), {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id in namespaces:
            reads.setdefault(node.attr, node.lineno)
    return {attr: line for attr, line in reads.items() if attr not in dests}


class OptionReadsTest(unittest.TestCase):
    def test_every_script_reads_only_options_it_defines(self):
        bad = {}
        for path in sorted(SCRIPTS.glob("*.py")):
            missing = undefined_option_reads(path.read_text(encoding="utf-8"), sibling_source)
            if missing:
                bad[path.name] = missing
        self.assertEqual(bad, {}, "scripts read options their parser does not define (file: {attr: line})")

    def test_detector_catches_a_removed_option(self):
        source = ("import argparse\nparser = argparse.ArgumentParser()\nparser.add_argument('--keys', type=int)\n"
                  "parser.add_argument('--key-gap-ms', dest='gap')\nopts = parser.parse_args()\n"
                  "if opts.typing_loads and opts.keys and opts.gap:\n    pass\n")
        self.assertEqual(undefined_option_reads(source), {"typing_loads": 6})

    def test_detector_counts_the_options_a_module_adds_to_the_parser(self):
        """cmd-n-paint-e2e.py reads `opts.window_look`, which new_surface_screen.add_arguments(parser) defines: no
        finding. An option that neither defines is still one, and so is one the module defines outside that function."""
        source = ("import argparse, screen_mode\nparser = argparse.ArgumentParser()\nparser.add_argument('--keys')\n"
                  "screen_mode.add_arguments(parser)\nopts = parser.parse_args()\n"
                  "print(opts.keys, opts.window_look,\n      opts.typing_loads,\n      opts.elsewhere)\n")
        module = ("def add_arguments(parser):\n    parser.add_argument('--window-look', default=None)\n"
                  "def other(parser):\n    parser.add_argument('--elsewhere')\n")
        sources = {"screen_mode": module}
        self.assertEqual(undefined_option_reads(source, sources.get), {"typing_loads": 7, "elsewhere": 8})
        self.assertEqual(undefined_option_reads(source, {}.get), {"window_look": 6, "typing_loads": 7, "elsewhere": 8})
        self.assertEqual(undefined_option_reads(source), {"window_look": 6, "typing_loads": 7, "elsewhere": 8})
        # The module's options on a parser that is not the script's are not the script's options.
        other = source.replace("add_arguments(parser)", "add_arguments(argparse.ArgumentParser())")
        self.assertEqual(undefined_option_reads(other, sources.get),
                         {"window_look": 6, "typing_loads": 7, "elsewhere": 8})

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
