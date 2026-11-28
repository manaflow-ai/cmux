#!/usr/bin/env python3
"""Regression coverage for lossless cmux-settings JSONC writes."""

from __future__ import annotations

import fcntl
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "skills" / "cmux-settings" / "scripts" / "cmux-settings"
sys.path.insert(0, str(HELPER.parent))
LOADER = importlib.machinery.SourceFileLoader("cmux_settings_helper", str(HELPER))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None
helper = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(helper)


class CmuxSettingsJSONCTests(unittest.TestCase):
    def run_helper(
        self,
        config: Path,
        *args: str,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        env = dict(os.environ)
        # This suite owns JSONC editing and publication behavior. Semantic
        # validation is covered by the config-validator/doctor suites; the
        # skill-contract runner intentionally has no built cmux CLI.
        env["CMUX_CLI_BIN"] = "/usr/bin/true"
        result = subprocess.run(
            [sys.executable, str(HELPER), "--file", str(config), *args],
            text=True,
            capture_output=True,
            check=False,
            env=env,
        )
        if check and result.returncode != 0:
            self.fail(
                f"helper failed ({result.returncode}): {result.stderr}\n{result.stdout}"
            )
        return result

    def test_unset_removes_values_under_all_duplicate_ancestors(self) -> None:
        cases = [
            ('{"app":{"appearance":"hidden","keep":1},"app":{"appearance":"dark"}}', "app.appearance"),
            ('{"app":1,"app":{"appearance":"dark","keep":1}}', "app.appearance"),
            ('{"app":{"nested":{"appearance":"hidden","keep":1},"nested":{"appearance":"dark"}}}', "app.nested.appearance"),
        ]
        for source, key in cases:
            with self.subTest(source=source), tempfile.TemporaryDirectory() as tmp:
                config = Path(tmp) / "cmux.json"
                config.write_text(source, encoding="utf-8")
                self.run_helper(config, "unset", key)
                appearances = []
                kept = []

                def inspect_object(pairs):
                    appearances.extend(value for name, value in pairs if name == "appearance")
                    kept.extend(value for name, value in pairs if name == "keep")
                    return dict(pairs)

                json.loads(self.strip_jsonc_for_test(config.read_text(encoding="utf-8")), object_pairs_hook=inspect_object)
                self.assertEqual(appearances, [])
                self.assertEqual(kept, [1])

    def test_set_preserves_comments_whitespace_order_and_trailing_commas(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            source = """{
  // root documentation
  "zeta": { "keep": true },
  "app": {
    // before appearance
    "before": 1,
    "appearance": "light", // inline appearance documentation
    // after appearance
    "after": 2,
  },
  "alpha": 1,
}
"""
            config.write_text(source, encoding="utf-8")

            self.run_helper(config, "set", "app.appearance", "dark")

            self.assertEqual(
                config.read_text(encoding="utf-8"),
                source.replace('"appearance": "light"', '"appearance": "dark"'),
            )

    def test_set_preserves_crlf_line_endings(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            source = (
                b"{\r\n"
                b'  "app": {\r\n'
                b'    "appearance": "light",\r\n'
                b'    "menuBarOnly": false,\r\n'
                b"  },\r\n"
                b"}\r\n"
            )
            config.write_bytes(source)

            self.run_helper(config, "set", "app.appearance", "dark")

            self.assertEqual(
                config.read_bytes(),
                source.replace(b'"appearance": "light"', b'"appearance": "dark"'),
            )

    def test_nested_creation_inherits_trailing_comma_style(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            config.write_text(
                """{
  "app": {
    "appearance": "dark",
  },
  "other": 1,
}
""",
                encoding="utf-8",
            )

            self.run_helper(config, "set", "app.nested.leaf", "true")

            updated = config.read_text(encoding="utf-8")
            self.assertIn(
                '"nested": {\n      "leaf": true\n    },',
                updated,
            )
            parsed = json.loads(self.strip_jsonc_for_test(updated))
            self.assertIs(parsed["app"]["nested"]["leaf"], True)

    def test_unset_prunes_plain_empty_parents_and_keeps_unrelated_text(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            config.write_text(
                """{
  "automation": {
    "nested": {
      "leaf": true,
    },
  },
  "keep": 1,
}
""",
                encoding="utf-8",
            )

            self.run_helper(config, "unset", "automation.nested.leaf")

            self.assertEqual(
                config.read_text(encoding="utf-8"),
                """{
  "keep": 1,
}
""",
            )

    def test_symlinked_config_writes_target_and_keeps_link(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "target.json"
            config = root / "cmux.json"
            source = """{
  // target docs
  "app": {
    "appearance": "light",
  },
}
"""
            target.write_text(source, encoding="utf-8")
            config.symlink_to(target)

            self.run_helper(config, "set", "app.appearance", "dark")

            self.assertTrue(config.is_symlink())
            self.assertEqual(config.resolve(), target.resolve())
            self.assertEqual(
                target.read_text(encoding="utf-8"),
                source.replace('"appearance": "light"', '"appearance": "dark"'),
            )

    def test_malformed_input_is_refused_without_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            before = b'{\n  // truncated\n  "app": {\n'
            config.write_bytes(before)

            result = self.run_helper(
                config,
                "set",
                "app.appearance",
                "dark",
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not valid JSONC", result.stderr)
            self.assertEqual(config.read_bytes(), before)

    def test_semantic_noops_are_byte_stable_and_skip_replace(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            source = """{
  // preserve every byte on no-op
  "app": {
    "appearance": "dark",
  },
}
"""
            config.write_text(source, encoding="utf-8")
            before = config.stat()

            self.run_helper(config, "set", "app.appearance", "dark")
            self.run_helper(config, "unset", "app.missing")

            after = config.stat()
            self.assertEqual(config.read_text(encoding="utf-8"), source)
            self.assertEqual(after.st_ino, before.st_ino)
            self.assertEqual(after.st_mtime_ns, before.st_mtime_ns)

    def test_set_targets_effective_last_duplicate_key(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            source = """{
  "app": {
    "appearance": "shadowed",
    "appearance": "system",
  },
}
"""
            config.write_text(source, encoding="utf-8")

            self.run_helper(config, "set", "app.appearance", "dark")

            updated = config.read_text(encoding="utf-8")
            self.assertIn('"appearance": "shadowed"', updated)
            self.assertIn('"appearance": "dark"', updated)
            parsed = json.loads(self.strip_jsonc_for_test(updated))
            self.assertEqual(parsed["app"]["appearance"], "dark")

    def test_unset_duplicate_keys_does_not_expose_shadowed_value(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            source = """{
  "app": {
    "appearance": "shadowed",
    "keep": "authored",
  },
  "app": {
    "appearance": "system",
    "appearance": "light",
  },
  "other": 1,
}
"""
            config.write_text(source, encoding="utf-8")

            self.run_helper(config, "unset", "app.appearance")

            updated = config.read_text(encoding="utf-8")
            self.assertIn('"keep": "authored"', updated)
            self.assertIn('"other": 1', updated)
            parsed = json.loads(self.strip_jsonc_for_test(updated))
            self.assertNotIn("appearance", parsed["app"])

    def test_scalar_intermediate_rejection_remains_byte_stable(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            source = '{"app":"manual"}\n'
            config.write_text(source, encoding="utf-8")

            result = self.run_helper(
                config,
                "set",
                "app.appearance",
                "dark",
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("intermediate key 'app' is not an object", result.stderr)
            self.assertEqual(config.read_text(encoding="utf-8"), source)

    def test_project_scope_follows_the_config_the_cwd_would_load(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            project = root / "project"
            other = root / "other"
            project.mkdir()
            other.mkdir()
            config = project / "cmux.json"
            config.write_text('{"app":{"appearance":"dark"}}\n', encoding="utf-8")

            # Discovered from inside the project: this is the project config.
            with mock.patch.object(helper.Path, "cwd", return_value=project):
                self.assertEqual(helper.semantic_scope_for(config), "project")

            # A cmux.json the current project would never load is a custom
            # global config, not a project-local one. Inferring scope from the
            # target's own directory would make it match itself here and reject
            # global-only keys such as `$.app`.
            with mock.patch.object(helper.Path, "cwd", return_value=other):
                self.assertEqual(helper.semantic_scope_for(config), "global")

    def test_custom_global_config_outside_any_project_is_global(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            workspace = home / "workspace" / "child"
            workspace.mkdir(parents=True)
            # A user-level cmux.json must not turn its whole home into a project.
            (home / "cmux.json").write_text("{}\n", encoding="utf-8")
            config = home / "custom-global" / "cmux.json"
            config.parent.mkdir()
            config.write_text('{"app":{"appearance":"dark"}}\n', encoding="utf-8")

            with (
                mock.patch.object(helper.Path, "home", return_value=home),
                mock.patch.object(helper.Path, "cwd", return_value=workspace),
            ):
                self.assertEqual(helper.semantic_scope_for(config), "global")
                self.assertEqual(helper.semantic_scope_for(home / "cmux.json"), "global")

    def test_dot_cmux_directory_is_always_project_scoped(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config = root / "project" / ".cmux" / "cmux.json"
            config.parent.mkdir(parents=True)
            config.write_text("{}\n", encoding="utf-8")
            other = root / "other"
            other.mkdir()

            with mock.patch.object(helper.Path, "cwd", return_value=other):
                self.assertEqual(helper.semantic_scope_for(config), "project")

    def test_explicit_scope_still_overrides_target_inference(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            config.write_text("{}\n", encoding="utf-8")
            self.assertEqual(
                helper.semantic_scope_for(config, explicit_scope="global"),
                "global",
            )

    def test_atomic_commit_refuses_stale_external_revision(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            config.write_text('{"app":{"appearance":"dark"}}\n', encoding="utf-8")
            original = helper.current_revision(config)
            external = '{"app":{"appearance":"external"}}\n'
            config.write_text(external, encoding="utf-8")

            with self.assertRaisesRegex(
                SystemExit,
                "cmux config changed while preparing the edit",
            ):
                helper.atomic_write_text(
                    config,
                    '{"app":{"appearance":"light"}}\n',
                    expected_revision=original,
                )

            self.assertEqual(config.read_text(encoding="utf-8"), external)

    def test_atomic_commit_retains_recovery_when_writer_wins_exchange_race(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            original_text = '{"app":{"appearance":"dark"}}\n'
            external_text = '{"app":{"appearance":"external"}}\n'
            candidate_text = '{"app":{"appearance":"light"}}\n'
            config.write_text(original_text, encoding="utf-8")
            original = helper.current_revision(config)
            real_exchange = helper.exchange_paths
            exchanges = 0

            def exchange_after_external_edit(left: Path, right: Path) -> None:
                nonlocal exchanges
                exchanges += 1
                if exchanges == 1:
                    right.write_text(external_text, encoding="utf-8")
                real_exchange(left, right)

            with mock.patch.object(
                helper,
                "exchange_paths",
                side_effect=exchange_after_external_edit,
            ):
                with self.assertRaisesRegex(
                    SystemExit,
                    "cmux config changed during publication; recovery retained at",
                ) as raised:
                    helper.atomic_write_text(
                        config,
                        candidate_text,
                        expected_revision=original,
                    )

            self.assertEqual(exchanges, 1)
            self.assertEqual(config.read_text(encoding="utf-8"), candidate_text)
            recovery_path = Path(
                str(raised.exception).split("recovery retained at ", 1)[1]
            )
            self.assertEqual(
                recovery_path.read_text(encoding="utf-8"),
                external_text,
            )
            recovery_path.unlink()

    def test_atomic_recovery_never_attempts_a_second_exchange(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            original_text = '{"app":{"appearance":"dark"}}\n'
            external_text = '{"app":{"appearance":"external"}}\n'
            candidate_text = '{"app":{"appearance":"light"}}\n'
            config.write_text(original_text, encoding="utf-8")
            original = helper.current_revision(config)
            real_exchange = helper.exchange_paths
            exchanges = 0

            def count_exchange(left: Path, right: Path) -> None:
                nonlocal exchanges
                exchanges += 1
                if exchanges == 1:
                    right.write_text(external_text, encoding="utf-8")
                real_exchange(left, right)

            with mock.patch.object(helper, "exchange_paths", side_effect=count_exchange):
                with self.assertRaisesRegex(
                    SystemExit,
                    "recovery retained at",
                ) as raised:
                    helper.atomic_write_text(
                        config,
                        candidate_text,
                        expected_revision=original,
                    )

            self.assertEqual(exchanges, 1)
            recovery_path = Path(
                str(raised.exception).split("recovery retained at ", 1)[1]
            )
            self.assertEqual(
                recovery_path.read_text(encoding="utf-8"),
                external_text,
            )
            recovery_path.unlink()

    def test_helper_applies_after_shared_writer_lock_release(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            config.write_text('{"app":{"appearance":"dark"}}\n', encoding="utf-8")
            lock_path = Path(str(config.resolve()) + ".cmux-write.lock")
            ready = Path(tmp) / "ready"
            holder = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    (
                        "import fcntl,os,pathlib,sys;"
                        "fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o600);"
                        "fcntl.flock(fd,fcntl.LOCK_EX);"
                        "pathlib.Path(sys.argv[2]).write_text('ready');"
                        "sys.stdin.buffer.read(1);"
                        "fcntl.flock(fd,fcntl.LOCK_UN);"
                        "os.close(fd)"
                    ),
                    str(lock_path),
                    str(ready),
                ],
                stdin=subprocess.PIPE,
            )
            helper_process = None
            try:
                for _ in range(200):
                    if ready.exists():
                        break
                    time.sleep(0.01)
                self.assertTrue(ready.exists())

                env = dict(os.environ)
                env["CMUX_CLI_BIN"] = "/usr/bin/true"
                helper_process = subprocess.Popen(
                    [
                        sys.executable,
                        str(HELPER),
                        "--file",
                        str(config),
                        "set",
                        "app.appearance",
                        "light",
                    ],
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=env,
                )
                assert holder.stdin is not None
                holder.stdin.write(b"x")
                holder.stdin.close()
                stdout, stderr = helper_process.communicate(timeout=5)
                self.assertEqual(helper_process.returncode, 0, stderr + stdout)
            finally:
                if helper_process is not None and helper_process.poll() is None:
                    helper_process.terminate()
                    helper_process.wait(timeout=5)
                if holder.poll() is None:
                    holder.terminate()
                holder.wait(timeout=5)

            self.assertIn('"light"', config.read_text(encoding="utf-8"))

    def test_helper_refuses_while_shared_writer_lock_is_held(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux.json"
            source = '{"app":{"appearance":"dark"}}\n'
            config.write_text(source, encoding="utf-8")
            lock_path = Path(str(config.resolve()) + ".cmux-write.lock")
            fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                result = self.run_helper(
                    config,
                    "set",
                    "app.appearance",
                    "light",
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0)
                conflict = json.loads(result.stderr)
                self.assertEqual(conflict["status"], "conflict")
                self.assertEqual(conflict["code"], "writer_busy")
                self.assertEqual(config.read_text(encoding="utf-8"), source)
            finally:
                fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)

    @staticmethod
    def strip_jsonc_for_test(text: str) -> str:
        # This fixture only needs line-comment and trailing-comma handling.
        lines = []
        for line in text.splitlines():
            quoted = False
            escaped = False
            cut = len(line)
            for index, character in enumerate(line):
                if quoted:
                    if escaped:
                        escaped = False
                    elif character == "\\":
                        escaped = True
                    elif character == '"':
                        quoted = False
                elif character == '"':
                    quoted = True
                elif line[index : index + 2] == "//":
                    cut = index
                    break
            lines.append(line[:cut])
        import re

        return re.sub(r",(\s*[}\]])", r"\1", "\n".join(lines))


if __name__ == "__main__":
    unittest.main()
