#!/usr/bin/env python3
"""Every bench's `<BenchApp>.launch(...)` call passes only keywords that BenchApp.launch takes.

e85bafbd6f83 (2026-10-23) removed `settle=` from bench_launch.BenchApp.launch, but typing-frame-bench.py and
sidebar-churn-typing.py still passed it, so both benches died with a TypeError right after the app built
(`--suite=typing-frame` step af2c1443198e6ff13d368cd0, 2026-10-31). This reads the signature from bench_launch.py
and every `.launch(` call of a BenchApp from the scripts beside it, with no app and no Mac.
Run: python3 -I scripts/cmux-next/tests/test_bench_launch_calls.py"""
import ast, glob, os, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))


def launch_parameters():
    tree = ast.parse(open(os.path.join(ROOT, "bench_launch.py")).read())
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and node.name == "BenchApp":
            for item in node.body:
                if isinstance(item, ast.FunctionDef) and item.name == "launch":
                    args = item.args
                    return {a.arg for a in args.args + args.kwonlyargs if a.arg != "self"}, args.kwarg is not None
    raise AssertionError("bench_launch.py has no BenchApp.launch")


def bench_app_names(tree):
    """Names bound to a BenchApp(...) in this module (`bench = BenchApp(...)`, `self.app = BenchApp(...)`)."""
    names = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and isinstance(node.value, ast.Call):
            func = node.value.func
            called = func.id if isinstance(func, ast.Name) else func.attr if isinstance(func, ast.Attribute) else ""
            if called == "BenchApp":
                for target in node.targets:
                    names.add(ast.unparse(target))
    return names


def launch_calls():
    """(path, line, receiver, keywords) for each .launch(...) on a name bound to a BenchApp."""
    out = []
    for path in sorted(glob.glob(os.path.join(ROOT, "*.py"))):
        try:
            tree = ast.parse(open(path).read())
        except SyntaxError:
            continue
        apps = bench_app_names(tree)
        if not apps:
            continue
        for node in ast.walk(tree):
            if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "launch"
                    and ast.unparse(node.func.value) in apps):
                out.append((os.path.basename(path), node.lineno, ast.unparse(node.func.value),
                            [k.arg for k in node.keywords if k.arg]))
    return out


class BenchLaunchCalls(unittest.TestCase):
    def test_every_launch_keyword_exists(self):
        params, takes_any = launch_parameters()
        calls = launch_calls()
        self.assertTrue(calls, "found no BenchApp launch call: the scan is broken")
        if takes_any:
            return
        bad = [f"{path}:{line} {recv}.launch({kw}=...)" for path, line, recv, kws in calls for kw in kws if kw not in params]
        self.assertEqual(bad, [], f"BenchApp.launch takes {sorted(params)}")

    def test_the_two_typing_benches_are_scanned(self):
        scanned = {path for path, *_ in launch_calls()}
        for name in ("typing-frame-bench.py", "sidebar-churn-typing.py"):
            self.assertIn(name, scanned)


if __name__ == "__main__":
    unittest.main()
