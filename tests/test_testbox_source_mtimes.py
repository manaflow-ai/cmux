#!/usr/bin/env python3
"""The warm Testbox target dir is only correct if restore never makes a
changed source look old: Cargo would then skip rebuilding it."""

import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "blacksmith-testbox-source-mtimes.py"
OLD = 1_000_000_000 * 10**9


def run(*args: str) -> None:
    subprocess.run([sys.executable, "-I", str(SCRIPT), *args], check=True, capture_output=True)


class SourceMtimesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.box1 = tempfile.TemporaryDirectory()
        self.box2 = tempfile.TemporaryDirectory()
        self.manifest = os.path.join(self.box1.name, "manifest.tsv")
        for box in (self.box1.name, self.box2.name):
            os.makedirs(os.path.join(box, "cmux-tui", "src"))
            os.makedirs(os.path.join(box, "ghostty", "src"))
            os.makedirs(os.path.join(box, "web"))
        self.write(self.box1.name, "cmux-tui/src/same.rs", "fn same() {}\n")
        self.write(self.box1.name, "cmux-tui/src/changed.rs", "fn old() {}\n")
        self.write(self.box1.name, "ghostty/src/vt.zig", "const a = 1;\n")
        self.write(self.box1.name, "web/page.ts", "x\n")
        os.makedirs(os.path.join(self.box1.name, "web", "node_modules"))
        self.write(self.box1.name, "web/node_modules/dep.js", "d\n")
        os.makedirs(os.path.join(self.box1.name, "ghostty", "include"))
        os.makedirs(os.path.join(self.box2.name, "ghostty", "include"))
        self.write(self.box1.name, "ghostty/include/a.h", "a\n")
        self.write(self.box2.name, "ghostty/include/a.h", "a\n")
        self.write(self.box2.name, "ghostty/include/b.h", "b\n")
        for path in pathlib.Path(self.box1.name).rglob("*"):
            os.utime(path, ns=(OLD, OLD))
        for top in ("cmux-tui", "ghostty"):
            os.utime(os.path.join(self.box1.name, top), ns=(OLD, OLD))
        run("record", self.box1.name, self.manifest)

        self.write(self.box2.name, "cmux-tui/src/same.rs", "fn same() {}\n")
        self.write(self.box2.name, "cmux-tui/src/changed.rs", "fn new() {}\n")
        self.write(self.box2.name, "cmux-tui/src/added.rs", "fn added() {}\n")
        self.write(self.box2.name, "ghostty/src/vt.zig", "const a = 1;\n")
        self.write(self.box2.name, "web/page.ts", "x\n")
        os.makedirs(os.path.join(self.box2.name, "web", "node_modules"))
        self.write(self.box2.name, "web/node_modules/dep.js", "d\n")

    def tearDown(self) -> None:
        self.box1.cleanup()
        self.box2.cleanup()

    @staticmethod
    def write(box: str, relative: str, text: str) -> None:
        pathlib.Path(box, relative).write_text(text, encoding="utf-8")

    def mtime(self, relative: str) -> int:
        return os.lstat(os.path.join(self.box2.name, relative)).st_mtime_ns

    def test_only_identical_sources_get_their_recorded_mtime(self) -> None:
        run("restore", self.box2.name, self.manifest)
        self.assertEqual(self.mtime("cmux-tui/src/same.rs"), OLD)
        self.assertEqual(self.mtime("ghostty/src/vt.zig"), OLD)
        self.assertGreater(self.mtime("cmux-tui/src/changed.rs"), OLD)
        self.assertGreater(self.mtime("cmux-tui/src/added.rs"), OLD)
        # Files outside cmux-tui/ are Cargo inputs too (include_str! of
        # schemas/); dependency stores are never recorded.
        self.assertEqual(self.mtime("web/page.ts"), OLD)
        self.assertGreater(self.mtime("web/node_modules/dep.js"), OLD)
        # Cargo's rerun-if-changed on a directory also compares directory
        # mtimes: a directory with the same entries gets its mtime back, a
        # directory that gained or lost an entry stays fresh.
        self.assertEqual(self.mtime("ghostty/src"), OLD)
        self.assertEqual(self.mtime("ghostty"), OLD)
        self.assertGreater(self.mtime("ghostty/include"), OLD)
        self.assertGreater(self.mtime("cmux-tui/src"), OLD)

    def test_restore_never_dates_a_file_into_the_future(self) -> None:
        path = os.path.join(self.box2.name, "cmux-tui", "src", "same.rs")
        os.utime(path, ns=(OLD - 10**9, OLD - 10**9))
        run("restore", self.box2.name, self.manifest)
        self.assertEqual(self.mtime("cmux-tui/src/same.rs"), OLD - 10**9)

    def test_changed_bytes_with_preserved_mtime_become_dirty(self) -> None:
        path = os.path.join(self.box2.name, "cmux-tui/src/changed.rs")
        os.utime(path, ns=(OLD, OLD))
        run("restore", self.box2.name, self.manifest)
        self.assertGreater(self.mtime("cmux-tui/src/changed.rs"), OLD)
        self.assertEqual(self.mtime("cmux-tui/src/same.rs"), OLD)

    def test_changed_directory_with_preserved_mtime_becomes_dirty(self) -> None:
        path = os.path.join(self.box2.name, "ghostty/include")
        os.utime(path, ns=(OLD, OLD))
        run("restore", self.box2.name, self.manifest)
        self.assertGreater(self.mtime("ghostty/include"), OLD)

    def test_changed_input_with_future_mtime_is_not_backdated(self) -> None:
        future = 4_000_000_000 * 10**9
        path = os.path.join(self.box2.name, "cmux-tui/src/changed.rs")
        os.utime(path, ns=(future, future))
        run("restore", self.box2.name, self.manifest)
        self.assertEqual(self.mtime("cmux-tui/src/changed.rs"), future)

    def test_a_hostile_manifest_cannot_leave_the_repository_or_follow_links(self) -> None:
        outside = os.path.join(self.box1.name, "outside.txt")
        pathlib.Path(outside).write_text("fn same() {}\n", encoding="utf-8")
        os.symlink(outside, os.path.join(self.box2.name, "cmux-tui", "src", "link.rs"))
        before = os.lstat(outside).st_mtime_ns
        with open(self.manifest, "a", encoding="utf-8") as handle:
            data = b"fn same() {}\n"
            blob = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
            handle.write(f"F\t{blob}\t1\t../outside.txt\n")
            handle.write(f"F\t{blob}\t1\tcmux-tui/../../outside.txt\n")
            handle.write(f"F\t{blob}\t1\tcmux-tui/src/link.rs\n")
            handle.write("garbage line\n")
        run("restore", self.box2.name, self.manifest)
        self.assertEqual(os.lstat(outside).st_mtime_ns, before)

    def test_a_missing_manifest_is_a_cold_build(self) -> None:
        run("restore", self.box2.name, os.path.join(self.box2.name, "absent.tsv"))
        self.assertGreater(self.mtime("cmux-tui/src/same.rs"), OLD)


@unittest.skipUnless(os.environ.get("CMUX_TEST_SOURCE_MTIMES_CARGO") == "1",
                     "opt in on the Rust fleet with CMUX_TEST_SOURCE_MTIMES_CARGO=1")
class CargoFreshnessTests(unittest.TestCase):
    """Exercise the pinned compiler, build-script inputs and the resulting binary.

    Timings describe this disposable fixture, not full application CI savings.
    """

    def test_restored_target_reuses_identical_inputs_and_rebuilds_edits(self) -> None:
        pin = (SCRIPT.parent.parent / "cmux-tui/rust-toolchain.toml").read_text()
        toolchain = re.search(r'channel\s*=\s*"([^"]+)"', pin).group(1)
        env = {**os.environ, "RUSTUP_TOOLCHAIN": toolchain, "RUSTC_WRAPPER": "",
               "RUSTC_WORKSPACE_WRAPPER": "", "CARGO_INCREMENTAL": "1"}
        rustc = subprocess.check_output(["rustc", "-vV"], env=env, text=True, timeout=30)
        host = re.search(r"^host: (.+)$", rustc, re.MULTILINE).group(1)
        env["CARGO_BUILD_TARGET"] = host
        print(json.dumps({"rustc": rustc, "cargo": subprocess.check_output(
            ["cargo", "--version"], env=env, text=True, timeout=30).strip(),
            "target": host, "profile": "dev", "incremental": True,
            "wrappers": {key: env[key] for key in ("RUSTC_WRAPPER", "RUSTC_WORKSPACE_WRAPPER")}}), flush=True)
        with tempfile.TemporaryDirectory(prefix="cargo-freshness-") as td:
            root = pathlib.Path(td)
            repo = root / "repo"
            (repo / "src").mkdir(parents=True)
            (repo / "Cargo.toml").write_text(
                '[package]\nname="freshness_probe"\nversion="0.1.0"\nedition="2021"\n')
            source = repo / "src/main.rs"
            source.write_text('fn main(){println!("11:{}",env!("BUILD_VALUE"));}\n')
            (repo / "build.rs").write_text(
                'fn main(){println!("cargo:rerun-if-changed=input.txt");'
                'println!("cargo:rustc-env=BUILD_VALUE={}",'
                'std::fs::read_to_string("input.txt").unwrap().trim());}\n')
            build_input = repo / "input.txt"
            build_input.write_text("7\n")
            target = repo / "target"
            manifest = target / "source-mtimes.tsv"

            def build(label, expected, target_dir=target):
                start = time.monotonic()
                result = subprocess.run(
                    ["cargo", "build", "--offline", "--message-format=json"], cwd=repo,
                    env={**env, "CARGO_TARGET_DIR": str(target_dir)},
                    capture_output=True, text=True, timeout=120)
                self.assertEqual(result.returncode, 0, result.stderr)
                rows = [json.loads(line) for line in result.stdout.splitlines()]
                artifacts = [row for row in rows if row.get("reason") == "compiler-artifact"]
                executable = next(row["executable"] for row in artifacts if row.get("executable"))
                output = subprocess.check_output([executable], text=True, timeout=10).strip()
                counts = {"case": label, "cargo_and_link_ms": round((time.monotonic() - start) * 1000, 2),
                          "fresh": sum(row["fresh"] for row in artifacts),
                          "compiled": sum(not row["fresh"] for row in artifacts), "output": output}
                print(json.dumps(counts), flush=True)
                self.assertEqual(output, expected, counts)
                return counts

            build("cold", "11:7")
            run("record", str(repo), str(manifest))
            snapshot = root / "saved-target"
            shutil.copytree(target, snapshot)
            source_stat = source.stat()
            os.utime(source, None)
            self.assertGreater(build("new_mtime_without_restore", "11:7")["compiled"], 0)

            # Round-trip the whole target, including its source manifest.
            start = time.monotonic()
            shutil.rmtree(target)
            shutil.copytree(snapshot, target)
            print(json.dumps({"target_restore_ms": round((time.monotonic() - start) * 1000, 2)}), flush=True)
            start = time.monotonic()
            run("restore", str(repo), str(manifest))
            print(json.dumps({"source_restore_ms": round((time.monotonic() - start) * 1000, 2)}), flush=True)
            self.assertEqual(source.stat().st_mtime_ns, source_stat.st_mtime_ns)
            self.assertEqual(build("identical_bytes_restored", "11:7")["compiled"], 0)

            for path, contents, expected in (
                (source, 'fn main(){println!("22:{}",env!("BUILD_VALUE"));}\n', "22:7"),
                (build_input, "8\n", "22:8"),
            ):
                stat = path.stat()
                path.write_text(contents)
                os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
                run("restore", str(repo), str(manifest))
                self.assertGreater(build("changed_old_mtime_" + path.name, expected)["compiled"], 0)
                build("clean_reference_" + path.name, expected, root / ("clean-" + path.name))
                run("record", str(repo), str(manifest))
                self.assertEqual(build("warm_after_edit_" + path.name, expected)["compiled"], 0)


class NativeCpuOutputTests(unittest.TestCase):
    """ghostty-vt-sys builds libghostty-vt for zig's native CPU. A warm target
    dir from a Testbox on another CPU model made every test binary that links
    it die with SIGILL (tbx_01m4gb5w6fhvccqwwjj54emkss, 2026-10-09), so restore
    must drop those outputs when the CPU differs from the recording box."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = os.path.join(self.tmp.name, "repo")
        self.target = os.path.join(self.repo, "cmux-tui", "target")
        os.makedirs(os.path.join(self.repo, "cmux-tui", "src"))
        self.manifest = os.path.join(self.target, ".cmux-testbox-source-mtimes.tsv")
        self.native = [
            os.path.join(self.target, "debug", "build", "ghostty-vt-sys-1a2b"),
            os.path.join(self.target, "debug", ".fingerprint", "ghostty-vt-sys-1a2b"),
            os.path.join(self.target, "x86_64-pc-windows-gnu", "debug", "build", "ghostty-vt-sys-3c4d"),
        ]
        self.portable = os.path.join(self.target, "debug", "build", "serde-5e6f")
        for path in self.native + [self.portable]:
            os.makedirs(path)
            pathlib.Path(path, "output").write_text("x", encoding="utf-8")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def cpuinfo(self, flags: str) -> str:
        path = os.path.join(self.tmp.name, f"cpuinfo-{flags.replace(' ', '-')}")
        pathlib.Path(path).write_text(
            f"processor\t: 0\nmodel name\t: Test CPU\nflags\t\t: {flags}\n\n", encoding="utf-8"
        )
        return path

    def run_with_cpu(self, command: str, flags: str) -> None:
        subprocess.run(
            [sys.executable, "-I", str(SCRIPT), command, self.repo, self.manifest],
            check=True,
            capture_output=True,
            env={**os.environ, "CMUX_TESTBOX_CPUINFO": self.cpuinfo(flags)},
        )

    def test_same_cpu_keeps_native_outputs(self) -> None:
        self.run_with_cpu("record", "sse2 avx2 avx512f")
        self.run_with_cpu("restore", "sse2 avx2 avx512f")
        for path in self.native + [self.portable]:
            self.assertTrue(os.path.isdir(path), path)

    def test_a_different_cpu_drops_only_native_outputs(self) -> None:
        self.run_with_cpu("record", "sse2 avx2 avx512f")
        self.run_with_cpu("restore", "sse2 avx2")
        for path in self.native:
            self.assertFalse(os.path.exists(path), path)
        self.assertTrue(os.path.isdir(self.portable))

    def test_restore_on_a_new_cpu_rewrites_the_cpu_record(self) -> None:
        # A later failed `record` must not leave the old host's record beside
        # output built on this host.
        self.run_with_cpu("record", "sse2 avx2 avx512f")
        self.run_with_cpu("restore", "sse2 avx2")
        os.makedirs(self.native[0])
        self.run_with_cpu("restore", "sse2 avx2 avx512f")
        self.assertFalse(os.path.exists(self.native[0]))

    def write_run(self, fingerprint_dir: str, cpu) -> None:
        os.makedirs(fingerprint_dir, exist_ok=True)
        local = [{"RerunIfEnvChanged": {"var": "CMUX_GHOSTTY_SRC", "val": None}},
                 {"RerunIfEnvChanged": {"var": "CMUX_GHOSTTY_VT_ZIG_CPU", "val": cpu}}]
        pathlib.Path(fingerprint_dir, "run-build-script-build-script-build.json").write_text(
            json.dumps({"rustc": 1, "local": local}), encoding="utf-8")

    def unit(self, kind: str, hash_: str, cpu=None) -> tuple:
        fingerprint = os.path.join(self.target, "debug", ".fingerprint", f"ghostty-vt-sys-{hash_}")
        build = os.path.join(self.target, "debug", "build", f"ghostty-vt-sys-{hash_}")
        os.makedirs(fingerprint)
        os.makedirs(build)
        if kind == "run":
            local = [{"RerunIfEnvChanged": {"var": "CMUX_GHOSTTY_SRC", "val": None}},
                     {"RerunIfEnvChanged": {"var": "CMUX_GHOSTTY_VT_ZIG_CPU", "val": cpu}}]
            name = "run-build-script-build-script-build.json"
        else:
            local, name = [], "build-script-build-script-build.json"
        pathlib.Path(fingerprint, name).write_text(json.dumps({"rustc": 1, "local": local}), encoding="utf-8")
        return fingerprint, build

    def test_baseline_runs_and_compile_units_survive_a_cpu_change(self) -> None:
        # 2026-10-12: 5 of 9 warmups landed on another CPU model and rebuilt
        # ghostty-vt-sys and its dependents. Output for the baseline CPU and
        # rustc's compile units run on every host; only native runs go.
        baseline = self.unit("run", "b0b0", "baseline")
        compile_unit = self.unit("compile", "c0c0")
        native = self.unit("run", "d0d0", None)
        self.run_with_cpu("record", "sse2 avx2 avx512f")
        self.run_with_cpu("restore", "sse2 avx2")
        for path in baseline + compile_unit + (self.portable,):
            self.assertTrue(os.path.isdir(path), path)
        for path in native + tuple(self.native):
            self.assertFalse(os.path.exists(path), path)

    def test_a_snapshot_without_a_cpu_record_drops_native_outputs(self) -> None:
        self.run_with_cpu("restore", "sse2 avx2")
        for path in self.native:
            self.assertFalse(os.path.exists(path), path)
        self.assertTrue(os.path.isdir(self.portable))


if __name__ == "__main__":
    unittest.main()
