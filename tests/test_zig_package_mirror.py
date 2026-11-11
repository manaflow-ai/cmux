#!/usr/bin/env python3
"""scripts/ci/zig_package_mirror.py: the detector that no Zig build fetches from
a third-party host, and the lock reader the seeds share.

codeberg.org's outage on 2026-11-11 failed every cold libghostty-vt build:
translate_c's own build.zig.zon fetches aro from git+https://codeberg.org. The
detector must catch such a dependency in the tree and in the packages it pulls
in, and the lock must keep a git+ URL's #commit."""

from __future__ import annotations

import importlib.util
import io
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("zig_package_mirror", ROOT / "scripts/ci/zig_package_mirror.py")
zpm = importlib.util.module_from_spec(spec)
sys.modules["zig_package_mirror"] = zpm
spec.loader.exec_module(zpm)

MIRROR = "https://github.com/manaflow-ai/ghostty-next/releases/download/zig-packages/"
SHA = "0" * 64


def tarball(files: dict[str, str]) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for name, text in files.items():
            data = text.encode()
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


class ParseDeps(unittest.TestCase):
    def test_reads_url_path_lazy_and_skips_comments(self):
        text = """.{
    .name = .x,
    .dependencies = .{
        // .gone = .{ .url = "https://example.invalid/gone.tar.gz", .hash = "N-gone" },
        .aro = .{
            .url = "git+https://codeberg.org/ziglang/arocc#d0c8", // pinned
            .hash = "aro-0.0.0-A",
        },
        .local = .{ .path = "./pkg/local", .lazy = true },
        .@"odd-name" = .{ .url = "https://deps.example/a.tar.gz", .hash = "N-a", .lazy = true },
    },
    .paths = .{ "" },
}
"""
        deps = {d.name: d for d in zpm.parse_deps(text)}
        self.assertEqual(sorted(deps), ["aro", "local", "odd-name"])
        self.assertEqual(deps["aro"].url, "git+https://codeberg.org/ziglang/arocc#d0c8")
        self.assertEqual(deps["aro"].hash, "aro-0.0.0-A")
        self.assertTrue(deps["local"].lazy)
        self.assertEqual(deps["local"].path, "./pkg/local")
        self.assertTrue(deps["odd-name"].lazy)

    def test_no_dependencies(self):
        self.assertEqual(zpm.parse_deps('.{ .name = .x, .version = "1.0.0" }'), [])

    def test_archive_zon_under_a_root_dir(self):
        data = tarball({"arocc-d0c8/build.zig.zon": '.{ .dependencies = .{ .x = .{ .url = "https://h/x.tar.gz", .hash = "N-x" } } }',
                        "arocc-d0c8/src/a.zig": ""})
        self.assertIn("N-x", zpm.archive_zon(data))
        self.assertIsNone(zpm.archive_zon(tarball({"pkg/README": "no manifest"})))


class Detector(unittest.TestCase):
    """check() on a scratch repo: one Ghostty source and a lock."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / "src").mkdir()
        self.saved = (zpm.ROOT, zpm.LOCK, zpm.SOURCES)
        zpm.ROOT = self.root
        zpm.LOCK = self.root / "zig-packages.lock"
        zpm.SOURCES = ("src",)

    def tearDown(self):
        zpm.ROOT, zpm.LOCK, zpm.SOURCES = self.saved
        self.tmp.cleanup()

    def write(self, zon: str, lock_lines: list[str], mirror: str = MIRROR):
        (self.root / "src/build.zig.zon").write_text(zon)
        zpm.LOCK.write_text("# comment\n" + f"mirror {mirror}\n" + "\n".join(lock_lines) + "\n")

    def run_check(self) -> tuple[int, str]:
        err = io.StringIO()
        old = sys.stderr
        sys.stderr = err
        try:
            code = zpm.check(False, ["src"])
        finally:
            sys.stderr = old
        return code, err.getvalue()

    ZON = """.{ .dependencies = .{
        .translate_c = .{ .url = "https://deps.files.ghostty.org/tc.tar.gz", .hash = "translate_c-2.0.0-T" },
        .own = .{ .url = "https://github.com/manaflow-ai/itijah/archive/abc.tar.gz", .hash = "itijah-0.2.1-I" },
    } }"""

    def test_a_tree_wholly_mirrored_passes(self):
        self.write(self.ZON, [
            f"translate_c-2.0.0-T {SHA} src,vt https://deps.files.ghostty.org/tc.tar.gz aro-0.0.0-A",
            f"aro-0.0.0-A {SHA} src,vt git+https://codeberg.org/ziglang/arocc#d0c8 -",
            f"itijah-0.2.1-I {SHA} src https://github.com/manaflow-ai/itijah/archive/abc.tar.gz -",
        ])
        code, err = self.run_check()
        self.assertEqual(code, 0, err)

    def test_a_third_party_url_not_mirrored_fails(self):
        self.write(self.ZON, [])
        code, err = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn("deps.files.ghostty.org/tc.tar.gz (a third-party host)", err)
        self.assertNotIn("itijah-0.2.1-I is not mirrored", err)  # on a host we control, reported as unchecked
        self.assertIn("next:", err)

    def test_a_transitive_third_party_dependency_not_mirrored_fails(self):
        # The 2026-11-11 outage: translate_c is mirrored, the aro it names is not.
        self.write(self.ZON, [
            f"translate_c-2.0.0-T {SHA} src,vt https://deps.files.ghostty.org/tc.tar.gz aro-0.0.0-A",
        ])
        code, err = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn("depends on aro-0.0.0-A, which is not mirrored", err)

    def test_a_package_on_our_host_missing_from_the_lock_fails(self):
        # Its own build.zig.zon could name a third-party package nobody checks.
        self.write(self.ZON, [
            f"translate_c-2.0.0-T {SHA} src,vt https://deps.files.ghostty.org/tc.tar.gz aro-0.0.0-A",
            f"aro-0.0.0-A {SHA} src,vt git+https://codeberg.org/ziglang/arocc#d0c8 -",
        ])
        code, err = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn("is on a host we control but itijah-0.2.1-I is not in", err)

    def test_a_package_on_our_host_naming_an_unmirrored_dependency_fails(self):
        self.write(self.ZON, [
            f"translate_c-2.0.0-T {SHA} src,vt https://deps.files.ghostty.org/tc.tar.gz aro-0.0.0-A",
            f"aro-0.0.0-A {SHA} src,vt git+https://codeberg.org/ziglang/arocc#d0c8 -",
            f"itijah-0.2.1-I {SHA} src https://github.com/manaflow-ai/itijah/archive/abc.tar.gz N-thirdparty",
        ])
        code, err = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn("itijah-0.2.1-I (mirrored) depends on N-thirdparty, which is not mirrored", err)

    def test_vt_set_must_be_closed(self):
        self.write(self.ZON, [
            f"translate_c-2.0.0-T {SHA} src,vt https://deps.files.ghostty.org/tc.tar.gz aro-0.0.0-A",
            f"aro-0.0.0-A {SHA} src git+https://codeberg.org/ziglang/arocc#d0c8 -",
        ])
        code, err = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn("is not tagged vt", err)

    def test_a_mirror_on_another_host_fails(self):
        self.write(self.ZON, [
            f"translate_c-2.0.0-T {SHA} src https://deps.files.ghostty.org/tc.tar.gz -",
        ], mirror="https://deps.files.ghostty.org/")
        code, err = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn("not on a host we control", err)

    def test_a_url_without_hash_fails(self):
        self.write('.{ .dependencies = .{ .x = .{ .url = "https://deps.example/x.tar.gz" } } }', [])
        code, err = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn("has no .hash", err)

    def test_a_missing_source_checkout_fails(self):
        self.write(self.ZON, [])
        (self.root / "src/build.zig.zon").unlink()
        code, err = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn("git submodule update --init --depth 1 src", err)

    def test_lock_keeps_a_git_url_fragment(self):
        self.write(self.ZON, [f"aro-0.0.0-A {SHA} src git+https://codeberg.org/ziglang/arocc#d0c8 -"])
        lock = zpm.read_lock(zpm.LOCK)
        self.assertEqual(lock.entries["aro-0.0.0-A"].upstream, "git+https://codeberg.org/ziglang/arocc#d0c8")
        self.assertEqual(lock.mirror, MIRROR)


class CheckedInLock(unittest.TestCase):
    def test_the_lock_mirrors_on_our_host_and_names_aro(self):
        lock = zpm.read_lock()
        self.assertTrue(zpm.allowed(lock.mirror), lock.mirror)
        vt = {h for h, e in lock.entries.items() if "vt" in e.tags}
        # The package whose codeberg fetch failed every cold build.
        self.assertIn("aro-0.0.0-JSD1QtuBNwCASyBtNF3pqTl_W3oAJQGEVyFAtrBSE_Pa", vt)
        for h in vt:
            for dep in lock.entries[h].deps:
                self.assertIn(dep, vt)

    def test_the_lock_round_trips(self):
        lock = zpm.read_lock()
        text = zpm.write_lock(lock)
        with tempfile.NamedTemporaryFile("w", suffix=".lock", delete=False) as f:
            f.write(text)
        again = zpm.read_lock(Path(f.name))
        Path(f.name).unlink()
        self.assertEqual({h: (e.sha256, e.tags, e.upstream, e.deps) for h, e in lock.entries.items()},
                         {h: (e.sha256, e.tags, e.upstream, e.deps) for h, e in again.entries.items()})


class FetchScriptMirrorOnly(unittest.TestCase):
    """fetch-ghostty-zig-packages.sh runs Zig with no route out in mirror-only mode."""

    def run_fetch(self, env_extra: dict[str, str]) -> str:
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            (t / "src").mkdir()
            (t / "src/build.zig.zon").write_text(".{ .dependencies = .{} }\n")
            (t / "bin").mkdir()
            fake = t / "bin/zig"
            fake.write_text('#!/usr/bin/env bash\nif [[ "$1" == env ]]; then exit 1; fi\n'
                            'echo "proxy=${https_proxy:-none} no_proxy=${NO_PROXY-unset},${no_proxy-unset}" >> "$FAKE_ZIG_LOG"\n')
            fake.chmod(0o755)
            log = t / "log"
            env = {"PATH": f"{t / 'bin'}:/usr/bin:/bin", "HOME": tmp, "FAKE_ZIG_LOG": str(log),
                   "CMUX_ZIG_SEED": "0", "ZIG_GLOBAL_CACHE_DIR": str(t / "cache"), **env_extra}
            subprocess.run(["bash", str(ROOT / "scripts/ci/fetch-ghostty-zig-packages.sh"), str(t / "src")],
                           env=env, check=True, capture_output=True)
            return log.read_text()

    def test_ci_runs_zig_with_no_route_out(self):
        self.assertEqual(self.run_fetch({"CI": "true"}).strip(), "proxy=http://127.0.0.1:9 no_proxy=unset,unset")

    def test_an_inherited_bypass_list_cannot_route_around_the_proxy(self):
        # NO_PROXY=* (or a host) would send Zig straight to the third-party host.
        got = self.run_fetch({"CI": "true", "NO_PROXY": "*", "no_proxy": "codeberg.org"}).strip()
        self.assertEqual(got, "proxy=http://127.0.0.1:9 no_proxy=unset,unset")

    def test_off_ci_and_turned_off_zig_keeps_its_network(self):
        self.assertEqual(self.run_fetch({}).strip(), "proxy=none no_proxy=unset,unset")
        self.assertEqual(self.run_fetch({"CI": "true", "CMUX_ZIG_MIRROR_ONLY": "0", "NO_PROXY": "*"}).strip(),
                         "proxy=none no_proxy=*,unset")


if __name__ == "__main__":
    unittest.main()
