#!/usr/bin/env python3
"""Regression guard for public socket capability discovery."""

import importlib.util
import os
import subprocess
import sys
import tempfile


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(ROOT, "scripts", "check-socket-capabilities.py")


def load_guard():
    spec = importlib.util.spec_from_file_location("socket_capability_guard", GUARD)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_public_dispatcher_methods_are_advertised():
    result = subprocess.run(
        [sys.executable, GUARD, "--root", ROOT],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    assert result.returncode == 0, result.stdout
    assert "socket capability parity: ok" in result.stdout
    count = int(result.stdout.split("(", 1)[1].split(" ", 1)[0])
    assert count > 0


def test_compound_case_labels_are_all_checked():
    guard = load_guard()
    methods = guard.switch_cases(
        'switch request.method {\n'
        'case "vm.pause",\n'
        '     "vm.only-second-label": break\n'
        '}'
    )
    assert methods == {"vm.pause", "vm.only-second-label"}


def test_compound_case_reports_missing_second_label():
    with tempfile.TemporaryDirectory() as directory:
        root = os.path.abspath(directory)
        os.makedirs(os.path.join(root, "Sources"))
        with open(os.path.join(root, "Sources", "TerminalController.swift"), "w", encoding="utf-8") as handle:
            handle.write(
                'switch request.method {\n'
                'case "vm.pause",\n'
                '     "vm.only-second-label": break\n'
                '}\n'
            )
        with open(os.path.join(root, "Sources", "TerminalController+Capabilities.swift"), "w", encoding="utf-8") as handle:
            handle.write(
                'var methods: [String] = [\n'
                '        "vm.pause"\n'
                '        ]\n'
            )
        result = subprocess.run(
            [sys.executable, GUARD, "--root", root],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        assert result.returncode != 0
        assert "vm.only-second-label" in result.stdout


if __name__ == "__main__":
    test_public_dispatcher_methods_are_advertised()
    test_compound_case_labels_are_all_checked()
    test_compound_case_reports_missing_second_label()
    print("test_ci_socket_capability_guard: ok (3 tests)")
