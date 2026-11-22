#!/usr/bin/env python3
"""scripts/ci/cargo_affected.py selects the changed cmux-tui crates and every crate that depends on them.

The fixture is a fake repository on disk plus fake `cargo metadata` output whose
workspace_root is a different absolute path (the metadata of a build host), so
no test runs cargo.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import cargo_affected  # noqa: E402

HOST_WS = "/work/lanes/x/src/cmux-tui"  # where the fake metadata says the workspace is


def package(name: str, rel_dir: str, deps: dict[str, str] | None = None, *, build: str | None = None,
            targets: list[tuple[str, str]] | None = None) -> dict:
    """deps: name -> kind (None for normal, "dev", "build"); all are path deps inside the workspace."""
    base = f"{HOST_WS}/{rel_dir}" if rel_dir != "." else HOST_WS
    kinds = targets or [("lib", "src/lib.rs")]
    out_targets = [{"name": name, "kind": [kind], "src_path": f"{base}/{src}"} for kind, src in kinds]
    if build:
        out_targets.append({"name": "build-script-build", "kind": ["custom-build"], "src_path": f"{base}/{build}"})
    return {
        "name": name,
        "id": f"path+file://{base}#{name}@0.0.0",
        "manifest_path": f"{base}/Cargo.toml",
        "targets": out_targets,
        "dependencies": [
            {"name": dep, "kind": kind, "path": f"{HOST_WS}/{dirs[dep]}" if dirs[dep] != "." else HOST_WS,
             "source": None}
            for dep, kind in (deps or {}).items()
        ] + [{"name": "serde", "kind": None, "source": "registry+https://github.com/rust-lang/crates.io-index"}],
    }


dirs = {
    "base": "crates/base",
    "mid": "crates/mid",
    "top": "crates/top",
    "testkit": "crates/testkit",
    "lonely": "crates/lonely",
    "wire-protocol": "crates/wire-protocol",
    "sys": "crates/sys",
    "root-watch": ".",
}


def metadata() -> dict:
    packages = [
        package("base", dirs["base"]),
        package("mid", dirs["mid"], {"base": None, "wire-protocol": None}),
        package("top", dirs["top"], {"mid": None, "testkit": "dev"}, targets=[("lib", "src/lib.rs"), ("test", "tests/vectors.rs")]),
        package("testkit", dirs["testkit"]),
        package("lonely", dirs["lonely"], {"root-watch": "build"}),
        package("wire-protocol", dirs["wire-protocol"]),
        package("sys", dirs["sys"], build="build.rs"),
        package("root-watch", ".", build="build-support/watch-build.rs",
                targets=[("lib", "build-support/watch.rs")]),
    ]
    return {
        "packages": packages,
        "workspace_members": [p["id"] for p in packages],
        "workspace_root": HOST_WS,
        "version": 1,
    }


FILES = {
    "cmux-tui/Cargo.toml": "[package]\nname = \"root-watch\"\n\n[workspace]\nmembers = []\n\n"
                           "[patch.crates-io]\npatched = { path = \"vendor/patched\" }\n",
    "cmux-tui/Cargo.lock": "",
    "cmux-tui/rust-toolchain.toml": "",
    "cmux-tui/README.md": "",
    "cmux-tui/build-support/watch.rs": "",
    "cmux-tui/build-support/watch-build.rs": "",
    "cmux-tui/crates/base/Cargo.toml": "",
    "cmux-tui/crates/base/src/lib.rs": "",
    "cmux-tui/crates/mid/Cargo.toml": "",
    "cmux-tui/crates/mid/src/lib.rs": "",
    "cmux-tui/crates/top/Cargo.toml": "",
    "cmux-tui/crates/top/src/lib.rs": "",
    "cmux-tui/crates/top/tests/vectors.rs":
        'let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../schemas/top/vectors.json");\n'
        'assert!(validate("../evil").is_err());\n',
    "cmux-tui/crates/testkit/Cargo.toml": "",
    "cmux-tui/crates/testkit/src/lib.rs": 'pub const DATA: &str = include_str!("../../base/fixtures/data.json");\n',
    "cmux-tui/crates/testkit/src/more.rs": "",
    "cmux-tui/crates/lonely/Cargo.toml": "",
    "cmux-tui/crates/lonely/src/lib.rs": 'const DOC: &str = include_str!("../../../../docs/lonely.txt");\n',
    "cmux-tui/crates/wire-protocol/Cargo.toml": "",
    "cmux-tui/crates/wire-protocol/src/lib.rs": "",
    "cmux-tui/crates/sys/Cargo.toml": "",
    "cmux-tui/crates/sys/build.rs": "",
    "cmux-tui/crates/sys/src/lib.rs": 'for entry in walk(manifest_dir.join("../../crates")) {}\n',
    "cmux-tui/crates/base/fixtures/data.json": "{}",
    "cmux-tui/crates/ffi/Cargo.toml": "[package]\nname = \"ffi\"\n\n[workspace]\n\n[dependencies]\n"
                                      "base = { path = \"../base\" }\n",
    "cmux-tui/crates/ffi/src/lib.rs": "",
    "cmux-tui/vendor/patched/Cargo.toml": "[package]\nname = \"patched\"\n",
    "cmux-tui/vendor/patched/src/lib.rs": "",
    "cmux-tui/spec/protocol.json": "",
    "cmux-tui/bindings/rust/src/lib.rs": "",
    "cmux-tui/frontends/stray.rs": "",
    "schemas/top/vectors.json": "{}",
    "docs/lonely.txt": "",
    "scripts/ci/cross.sh": "",
    "scripts/cmux-next/cmux-tui-tree-inputs.txt":
        "# comment\ntree cmux-tui\ngitlink ghostty-next\nblob scripts/ci/cross.sh\nblob schemas/top/vectors.json\n",
    "Packages/macOS/Foo/Sources/Foo.swift": "",
}


class CargoAffectedTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        for rel, text in FILES.items():
            path = self.root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        self.meta = metadata()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def plan(self, *changed: str) -> cargo_affected.Plan:
        return cargo_affected.plan(self.root, self.meta, list(changed))

    def assert_crates(self, changed: list[str], expected: list[str]) -> None:
        result = self.plan(*changed)
        self.assertFalse(result.workspace, f"{changed} escalated: {result.reasons}")
        self.assertEqual(result.crates, expected, changed)

    def assert_workspace(self, *changed: str) -> None:
        result = self.plan(*changed)
        self.assertTrue(result.workspace, f"{changed} did not escalate to the workspace")
        self.assertTrue(result.reasons, "an escalation must name its reason")
        self.assertEqual(result.cargo_args(), ["--workspace"])

    # --- reverse dependencies -------------------------------------------------

    def test_leaf_change_selects_its_reverse_dependencies(self) -> None:
        self.assert_crates(["cmux-tui/crates/base/src/lib.rs"], ["base", "mid", "top"])

    def test_dev_dependency_counts_as_a_reverse_dependency(self) -> None:
        self.assert_crates(["cmux-tui/crates/testkit/src/lib.rs"], ["testkit", "top"])

    def test_build_dependency_counts_as_a_reverse_dependency(self) -> None:
        self.assert_crates(["cmux-tui/build-support/watch.rs"], ["lonely", "root-watch"])

    def test_crate_without_dependents_selects_itself(self) -> None:
        self.assert_crates(["cmux-tui/crates/lonely/src/lib.rs"], ["lonely"])

    def test_union_of_two_changes(self) -> None:
        self.assert_crates(["cmux-tui/crates/lonely/src/lib.rs", "cmux-tui/crates/testkit/src/lib.rs"],
                           ["lonely", "testkit", "top"])

    def test_cargo_args(self) -> None:
        self.assertEqual(self.plan("cmux-tui/crates/testkit/src/lib.rs").cargo_args(),
                         ["-p", "testkit", "-p", "top"])

    # --- escalation to the full workspace -------------------------------------

    def test_lockfile_and_manifests_escalate(self) -> None:
        self.assert_workspace("cmux-tui/Cargo.lock")
        self.assert_workspace("cmux-tui/Cargo.toml")
        self.assert_workspace("cmux-tui/crates/top/Cargo.toml")

    def test_build_scripts_escalate(self) -> None:
        self.assert_workspace("cmux-tui/crates/sys/build.rs")
        # A custom `build = ...` path is a build script too; metadata names it.
        self.assert_workspace("cmux-tui/build-support/watch-build.rs")

    def test_toolchain_and_cargo_config_escalate(self) -> None:
        self.assert_workspace("cmux-tui/rust-toolchain.toml")
        self.assert_workspace("cmux-tui/rust-toolchain")
        self.assert_workspace("cmux-tui/.cargo/config.toml")
        self.assert_workspace(".cargo/config")

    def test_spec_bindings_and_protocol_crates_escalate(self) -> None:
        self.assert_workspace("cmux-tui/spec/protocol.json")
        self.assert_workspace("cmux-tui/bindings/rust/src/lib.rs")
        self.assert_workspace("cmux-tui/crates/wire-protocol/src/lib.rs")

    def test_patched_vendor_crate_escalates(self) -> None:
        self.assert_workspace("cmux-tui/vendor/patched/src/lib.rs")

    def test_unattributed_build_input_outside_the_workspace_escalates(self) -> None:
        self.assert_workspace("ghostty-next")
        self.assert_workspace("scripts/ci/cross.sh")

    def test_rust_source_outside_every_crate_escalates(self) -> None:
        self.assert_workspace("cmux-tui/frontends/stray.rs")
        # A crate that metadata does not know (deleted or renamed) cannot be mapped either.
        self.assert_workspace("cmux-tui/crates/gone/src/lib.rs")

    def test_one_escalating_path_wins_over_a_leaf_change(self) -> None:
        self.assert_workspace("cmux-tui/crates/lonely/src/lib.rs", "cmux-tui/Cargo.lock")

    # --- files outside crates ---------------------------------------------------

    def test_file_a_test_reads_selects_that_crate(self) -> None:
        # Also a tree-key blob, but a crate reference attributes it, so no escalation.
        self.assert_crates(["schemas/top/vectors.json"], ["top"])

    def test_embedded_file_selects_the_embedding_crate(self) -> None:
        self.assert_crates(["docs/lonely.txt"], ["lonely"])

    def test_files_no_crate_reads_select_nothing(self) -> None:
        result = self.plan("Packages/macOS/Foo/Sources/Foo.swift", "cmux-tui/README.md")
        self.assertFalse(result.workspace)
        self.assertEqual(result.crates, [])
        self.assertEqual(result.cargo_args(), [])
        self.assertIn("cmux-tui/README.md", result.unmapped)

    def test_crate_outside_the_workspace_is_reported_not_selected(self) -> None:
        result = self.plan("cmux-tui/crates/ffi/src/lib.rs")
        self.assertFalse(result.workspace)
        self.assertEqual(result.crates, [])
        self.assertEqual(result.external, ["cmux-tui/crates/ffi/Cargo.toml"])

    def test_external_crate_that_depends_on_a_changed_member_is_reported(self) -> None:
        result = self.plan("cmux-tui/crates/base/src/lib.rs")
        self.assertEqual(result.external, ["cmux-tui/crates/ffi/Cargo.toml"])
        self.assertEqual(self.plan("cmux-tui/crates/lonely/src/lib.rs").external, [])

    def test_file_inside_one_crate_read_by_another_selects_both(self) -> None:
        self.assert_crates(["cmux-tui/crates/base/fixtures/data.json"], ["base", "mid", "testkit", "top"])
        # Other files of base are not what testkit reads.
        self.assert_crates(["cmux-tui/crates/base/src/lib.rs"], ["base", "mid", "top"])

    def test_reference_to_an_ancestor_directory_does_not_pull_into_every_crate_change(self) -> None:
        # sys names cmux-tui/crates; a change inside another crate still selects only that crate.
        self.assert_crates(["cmux-tui/crates/testkit/src/more.rs"], ["testkit", "top"])

    def test_unowned_rust_source_escalates_even_under_a_referenced_directory(self) -> None:
        self.assert_workspace("cmux-tui/crates/new-crate/src/lib.rs")

    # --- command line -------------------------------------------------------------

    def test_exec_inserts_selection_before_test_binary_args(self) -> None:
        self.assertEqual(
            cargo_affected.command_with_selection(["cargo", "test", "--locked", "--", "--test-threads=2"],
                                                  ["-p", "a", "-p", "b"]),
            ["cargo", "test", "--locked", "-p", "a", "-p", "b", "--", "--test-threads=2"])
        self.assertEqual(cargo_affected.command_with_selection(["cargo", "nextest", "run"], ["--workspace"]),
                         ["cargo", "nextest", "run", "--workspace"])

    def run_cli(self, *args: str) -> subprocess.CompletedProcess:
        meta = self.root / "meta.json"
        meta.write_text(json.dumps(self.meta), encoding="utf-8")
        return subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "ci" / "cargo_affected.py"), "--root", str(self.root),
             "--metadata", str(meta), *args],
            capture_output=True, text=True, check=False)

    def test_cli_prints_cargo_args(self) -> None:
        out = self.run_cli("--changed", "cmux-tui/crates/testkit/src/lib.rs")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), "-p testkit -p top")

    def test_cli_exec_skips_when_nothing_is_affected(self) -> None:
        marker = self.root / "ran"
        out = self.run_cli("--changed", "cmux-tui/README.md", "--", "touch", str(marker))
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertFalse(marker.exists(), "an empty selection must not run the command (cargo would pick default members)")
        self.assertIn("no cmux-tui crate", out.stderr)

    def test_cli_exec_runs_with_selection_and_keeps_exit_status(self) -> None:
        out = self.run_cli("--changed", "cmux-tui/crates/lonely/src/lib.rs", "--",
                           sys.executable, "-c", "import sys; print(sys.argv[1:]); sys.exit(7)")
        self.assertEqual(out.returncode, 7)
        self.assertIn("['-p', 'lonely']", out.stdout)

    def test_cli_reads_the_diff_from_git(self) -> None:
        env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
        git = ["git", "-C", str(self.root), "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        subprocess.run([*git, "init", "-q", "-b", "main"], check=True, env=env)
        subprocess.run([*git, "add", "-A"], check=True, env=env)
        subprocess.run([*git, "commit", "-q", "-m", "base"], check=True, env=env)
        subprocess.run([*git, "branch", "base"], check=True, env=env)
        (self.root / "cmux-tui/crates/testkit/src/lib.rs").write_text("pub fn x() {}\n", encoding="utf-8")
        subprocess.run([*git, "commit", "-q", "-am", "edit"], check=True, env=env)
        out = self.run_cli("--base", "base", "--format", "json")
        self.assertEqual(out.returncode, 0, out.stderr)
        data = json.loads(out.stdout)
        self.assertEqual(data["crates"], ["testkit", "top"])
        self.assertEqual(data["changed"], ["cmux-tui/crates/testkit/src/lib.rs"])
        self.assertFalse(data["workspace"])


if __name__ == "__main__":
    unittest.main()
