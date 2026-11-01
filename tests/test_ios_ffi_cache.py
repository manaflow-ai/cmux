#!/usr/bin/env python3
"""scripts/ci/ios_ffi_cache.py: the simulator step reuses a verified FFI build instead of rebuilding it.

2026-10-29: every cmux-next-ios-sim.sh step built CmuxMobileLinkFFI.xcframework from a fresh
checkout, 285 s of a ~350 s build phase on an AWS M4 Pro, though the FFI's inputs changed in 6 of
1846 feat-cmux-next commits over three days. Run: python3 -I THIS.
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/ci/ios_ffi_cache.py"
SCRIPT = ROOT / "scripts/ci/cmux-next-ios-sim.sh"
XCF = "cmux-next-ios/CmuxMobileKit/Frameworks/CmuxMobileLinkFFI.xcframework"
SWIFT = "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift"


def sh(cwd, *args):
    return subprocess.run(list(args), cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


class FFICacheTest(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)])
        # The landed repository (feat-cmux-next) and a step's checkout of it.
        self.origin = self.tmp / "origin"
        self.origin.mkdir()
        sh(self.origin, "git", "init", "-q", "-b", "feat-cmux-next")
        sh(self.origin, "git", "config", "uploadpack.allowFilter", "true")
        for d in (self.origin,):
            sh(d, "git", "config", "user.email", "t@example.com")
            sh(d, "git", "config", "user.name", "t")
        write(self.origin / "cmux-next-ios/rust/Cargo.toml", "[workspace]\n")
        write(self.origin / "cmux-next-ios/rust/Cargo.lock", "# lock\n")
        write(self.origin / "cmux-next-ios/rust/.gitignore", "/target\n")
        write(self.origin / "cmux-tui/crates/cmux-wg/src/lib.rs", "pub fn wg() {}\n")
        write(self.origin / "cmux-tui/crates/unrelated/src/lib.rs", "pub fn u() {}\n")
        write(self.origin / SWIFT, "// committed bindings\n")
        self.commit(self.origin, "base")
        self.checkout = self.tmp / "checkout"
        sh(self.tmp, "git", "clone", "-q", str(self.origin), str(self.checkout))
        sh(self.checkout, "git", "config", "user.email", "t@example.com")
        sh(self.checkout, "git", "config", "user.name", "t")
        self.cache = self.tmp / "cache"
        self.work = self.tmp / "work"
        self.work.mkdir()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("CMUX_IOS_FFI_", "CMUX_CI_CACHE_DIR"))}
        self.env.update({
            "CMUX_CI_CACHE_DIR": str(self.cache),
            "CMUX_IOS_FFI_TOOLCHAIN": "rustc 1.91.0\nXcode 26.6",
            "CMUX_IOS_FFI_PATH_PACKAGES": "cmux-next-ios/rust/crates/cmux-mobile-link-ffi\ncmux-tui/crates/cmux-wg",
            "CMUX_IOS_FFI_TRUSTED_URL": "file://" + str(self.origin),
            "CARGO_HOME": str(self.tmp / "cargo-home-default"),  # the host's own config never leaks in
        })

    def commit(self, repo, msg):
        sh(repo, "git", "add", "-A")
        sh(repo, "git", "commit", "-q", "-m", msg)

    def run_helper(self, *args, env=None):
        return subprocess.run([sys.executable, "-I", str(HELPER), *args], env=env or self.env,
                              capture_output=True, text=True)

    def key(self):
        p = self.run_helper("key", str(self.checkout), str(self.work / "inputs.json"))
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout.strip()

    def build(self, marker="built"):
        """What build-xcframework.sh leaves: the xcframework and regenerated bindings."""
        write(self.checkout / XCF / "Info.plist", "<plist/>\n")
        write(self.checkout / XCF / "ios-arm64-simulator/F.framework/F", marker)
        write(self.checkout / SWIFT, "// generated " + marker + "\n")

    def probe_and_store(self):
        p = self.run_helper("probe", str(self.work / "inputs.json"), str(self.work / "tip.json"))
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        return self.run_helper("store", str(self.checkout), str(self.work / "inputs.json"), str(self.work / "tip.json"))

    def test_landed_build_is_stored_then_restored(self):
        key = self.key()
        self.assertEqual(len(key), 64)
        self.assertEqual(self.run_helper("restore", str(self.checkout), key).returncode, 1)  # miss
        self.build()
        p = self.probe_and_store()
        self.assertIn("stored", p.stdout, p.stdout + p.stderr)
        entry = self.cache / "ios-ffi" / key
        manifest = json.loads((entry / "manifest.json").read_text())
        self.assertEqual(manifest["key"], key)
        self.assertEqual(manifest["trusted"]["branch"], "feat-cmux-next")
        # A later step on the same sources: a hit installs exactly the stored build.
        sh(self.checkout, "git", "checkout", "-q", "--", ".")
        sh(self.checkout, "rm", "-rf", "cmux-next-ios/CmuxMobileKit/Frameworks")
        self.assertEqual(self.key(), key)
        p = self.run_helper("restore", str(self.checkout), key)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("hit", p.stdout)
        self.assertEqual((self.checkout / XCF / "ios-arm64-simulator/F.framework/F").read_text(), "built")
        self.assertEqual((self.checkout / SWIFT).read_text(), "// generated built\n")
        self.assertTrue((entry / "used").exists())

    def test_key_follows_inputs_and_toolchain_only(self):
        key = self.key()
        write(self.checkout / "cmux-tui/crates/unrelated/src/lib.rs", "pub fn u2() {}\n")
        self.commit(self.checkout, "unrelated")
        self.assertEqual(self.key(), key)
        write(self.checkout / "cmux-tui/crates/cmux-wg/src/lib.rs", "pub fn wg2() {}\n")
        self.commit(self.checkout, "path package")
        changed = self.key()
        self.assertNotEqual(changed, key)
        env = dict(self.env, CMUX_IOS_FFI_TOOLCHAIN="rustc 1.92.0\nXcode 26.6")
        p = self.run_helper("key", str(self.checkout), str(self.work / "i2.json"), env=env)
        self.assertNotIn(p.stdout.strip(), (key, changed))

    def test_uncommitted_input_has_no_key(self):
        write(self.checkout / "cmux-next-ios/rust/Cargo.lock", "# edited\n")
        p = self.run_helper("key", str(self.checkout), str(self.work / "inputs.json"))
        self.assertEqual(p.returncode, 3)

    def test_pull_request_that_changes_the_ffi_stores_nothing(self):
        write(self.checkout / "cmux-tui/crates/cmux-wg/src/lib.rs", "pub fn evil() {}\n")
        self.commit(self.checkout, "pr")
        key = self.key()
        self.build("pr")
        p = self.probe_and_store()
        self.assertIn("not stored", p.stdout)
        self.assertIn("cmux-tui/crates/cmux-wg", p.stdout)
        self.assertFalse((self.cache / "ios-ffi" / key).exists())

    def test_failed_publish_is_an_error_not_a_quiet_success(self):
        key = self.key()
        self.build()
        p = self.run_helper("probe", str(self.work / "inputs.json"), str(self.work / "tip.json"))
        self.assertEqual(p.returncode, 0, p.stderr)
        # A file holds the key's path: the rename of the new entry onto it fails, and no entry
        # stands there, so this is not the benign "another step published it first" race.
        (self.cache / "ios-ffi").mkdir(parents=True)
        (self.cache / "ios-ffi" / key).write_text("not an entry")
        p = self.run_helper("store", str(self.checkout), str(self.work / "inputs.json"), str(self.work / "tip.json"))
        self.assertEqual(p.returncode, 5, p.stdout + p.stderr)
        self.assertIn("could not publish", p.stderr)

    def test_tampered_entry_is_dropped(self):
        key = self.key()
        self.build()
        self.assertIn("stored", self.probe_and_store().stdout)
        entry = self.cache / "ios-ffi" / key
        (entry / "payload" / XCF / "ios-arm64-simulator/F.framework/F").write_text("other")
        p = self.run_helper("restore", str(self.checkout), key)
        self.assertEqual(p.returncode, 6)
        self.assertIn("dropped", p.stdout)
        self.assertFalse(entry.exists())

    def test_entry_for_another_key_is_dropped(self):
        key = self.key()
        self.build()
        self.probe_and_store()
        other = "0" * 64
        (self.cache / "ios-ffi" / key).rename(self.cache / "ios-ffi" / other)
        p = self.run_helper("restore", str(self.checkout), other)
        self.assertEqual(p.returncode, 6)
        self.assertIn("another key", p.stdout)

    def test_no_cache_dir_builds_as_before(self):
        env = {k: v for k, v in self.env.items() if k != "CMUX_CI_CACHE_DIR"}
        self.assertEqual(self.run_helper("key", str(self.checkout), str(self.work / "i.json"), env=env).returncode, 3)
        self.assertEqual(self.run_helper("restore", str(self.checkout), "a" * 64, env=env).returncode, 1)

    def test_key_follows_build_settings(self):
        key = self.key()
        env = dict(self.env, RUSTFLAGS="-C opt-level=0")
        p = self.run_helper("key", str(self.checkout), str(self.work / "i3.json"), env=env)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotEqual(p.stdout.strip(), key)

    def test_key_follows_every_cargo_and_rust_setting_but_not_locations(self):
        key = self.key()
        def key_with(**extra):
            p = self.run_helper("key", str(self.checkout), str(self.work / "ix.json"), env=dict(self.env, **extra))
            self.assertEqual(p.returncode, 0, p.stderr)
            return p.stdout.strip()
        for name, value in (("CARGO_PROFILE_RELEASE_CODEGEN_UNITS", "1"), ("CARGO_PROFILE_RELEASE_PANIC", "abort"),
                            ("CARGO_TARGET_AARCH64_APPLE_IOS_RUSTFLAGS", "-Copt-level=1"),
                            ("CC_aarch64_apple_ios", "/opt/cc"), ("RUSTUP_TOOLCHAIN", "nightly"),
                            ("RANLIB", "/opt/ranlib"), ("ARFLAGS", "crsD"), ("RANLIB_aarch64-apple-ios", "x"),
                            ("ARFLAGS_aarch64_apple_ios_sim", "x"), ("CRATE_CC_NO_DEFAULTS", "1"),
                            ("TARGET_CFLAGS", "-O0"), ("HOST_CC", "/opt/hcc")):
            self.assertNotEqual(key_with(**{name: value}), key, name)
        self.assertEqual(key_with(CARGO_TARGET_DIR=str(self.tmp / "t"), CARGO_BUILD_JOBS="3"), key)

    def test_key_follows_cargo_home_config_content(self):
        home = self.tmp / "cargo-home"
        home.mkdir()
        key = self.key()
        p = self.run_helper("key", str(self.checkout), str(self.work / "ih.json"), env=dict(self.env, CARGO_HOME=str(home)))
        self.assertEqual(p.stdout.strip(), key)  # where CARGO_HOME is does not matter
        (home / "config.toml").write_text("[profile.release]\nopt-level = 1\n")
        p = self.run_helper("key", str(self.checkout), str(self.work / "ih.json"), env=dict(self.env, CARGO_HOME=str(home)))
        self.assertNotEqual(p.stdout.strip(), key)  # what its config says does

    def test_failed_key_command_is_exit_4_not_a_quiet_no_key(self):
        env = {k: v for k, v in self.env.items() if k != "CMUX_IOS_FFI_PATH_PACKAGES"}
        env["PATH"] = str(self.tmp / "no-cargo")  # cargo metadata cannot run
        p = subprocess.run([sys.executable, "-I", str(HELPER), "key", str(self.checkout), str(self.work / "i.json")],
                           env=env, capture_output=True, text=True)
        self.assertIn(p.returncode, (4, 5), p.stderr)
        self.assertNotEqual(p.returncode, 3)

    def test_prune_waits_for_no_restore_and_skips_while_one_copies(self):
        sys.path.insert(0, str(HELPER.parent))
        try:
            import ios_ffi_cache as m
        finally:
            sys.path.pop(0)
        root = self.tmp / "lockcache"
        old = root / ("a" * 64)
        (old / "payload").mkdir(parents=True)
        (old / "manifest.json").write_text("{}")
        os.utime(old / "manifest.json", (1, 1))  # unused for decades: prunable
        with m.cache_lock(root, exclusive=False):  # a restore is copying
            self.assertEqual(m.prune(root), [])
            self.assertTrue(old.exists())
        self.assertEqual(m.prune(root), [old.name])
        self.assertFalse(old.exists())

    def test_store_keeps_the_cache_bounded(self):
        root = self.cache / "ios-ffi"
        root.mkdir(parents=True)
        now = __import__("time").time()
        ages = {}
        for i in range(9):
            name = ("%x" % (i + 1)) * 64
            entry = root / name[:64]
            (entry / "payload").mkdir(parents=True)
            (entry / "manifest.json").write_text("{}")
            age = 2 * 3600 + i * 3600  # idle two hours and up: none busy
            os.utime(entry / "manifest.json", (now - age, now - age))
            ages[entry.name] = age
        busy = root / ("e" * 64)
        (busy / "payload").mkdir(parents=True)
        (busy / "manifest.json").write_text("{}")
        old_busy = now - 30 * 86400
        os.utime(busy / "manifest.json", (old_busy, old_busy))
        (busy / "used").write_text("1\n")  # restored a minute ago: never pruned mid-copy
        stale = root / ("f" * 64)
        (stale / "payload").mkdir(parents=True)
        (stale / "manifest.json").write_text("{}")
        os.utime(stale / "manifest.json", (now - 8 * 86400, now - 8 * 86400))
        key = self.key()
        self.build()
        p = self.probe_and_store()
        self.assertIn("stored", p.stdout, p.stdout + p.stderr)
        self.assertIn("pruned", p.stdout)
        left = sorted(d.name for d in root.iterdir() if d.is_dir() and not d.name.startswith("."))
        self.assertIn(key, left)
        self.assertIn(busy.name, left)
        self.assertNotIn(stale.name, left)
        # The new entry, the busy one, and the four most recently used of the rest.
        newest = sorted(ages, key=ages.get)[:4]
        self.assertEqual(sorted(left), sorted([key, busy.name] + newest))

    def test_simulator_step_uses_the_cache(self):
        text = SCRIPT.read_text()
        self.assertIn("ffi_cache=(python3 -I scripts/ci/ios_ffi_cache.py)", text)
        for word in ('"${ffi_cache[@]}" key ', '"${ffi_cache[@]}" restore ', '"${ffi_cache[@]}" probe ',
                     '"${ffi_cache[@]}" store ', "build-xcframework.sh", "- FFI: "):
            self.assertTrue(word in text, "cmux-next-ios-sim.sh lacks " + word)
        # A hit is the only path that skips the build.
        hit = text.index('"${ffi_cache[@]}" restore ')
        self.assertLess(hit, text.index("build-xcframework.sh >"))

    def ffi_block(self):
        text = SCRIPT.read_text()
        start = text.index("ffi_cache=(python3 -I scripts/ci/ios_ffi_cache.py)")
        end = text.index('note "- FFI: ', start)
        return text[start:text.index("\n", end) + 1]

    def run_block(self, helper_body, build_body='mkdir -p "$(dirname "$0")/../../CmuxMobileKit/Frameworks"; echo built >> "$OUT"'):
        """The script's FFI section in a fake checkout: a stub helper and a stub build script."""
        fake = pathlib.Path(tempfile.mkdtemp(dir=self.tmp, prefix="fake."))
        write(fake / "scripts/ci/ios_ffi_cache.py", helper_body)
        write(fake / "cmux-next-ios/rust/scripts/build-xcframework.sh", build_body + "\n")
        work = fake / ".build/ios-sim"
        work.mkdir(parents=True)
        out = fake / "calls.txt"
        prog = ("set -euo pipefail\ntrap 'echo ERR line $LINENO >&2' ERR\n"
                'root="$PWD"; work="$PWD/.build/ios-sim"; t0=$SECONDS; summary="$work/SUMMARY.md"\n'
                "note() { printf '%s\\n' \"$*\" | tee -a \"$summary\"; }\n" + self.ffi_block()
                + 'echo "HOW=$ffi_how"\n')
        env = dict(self.env, OUT=str(out))
        p = subprocess.run(["bash", "-c", prog], cwd=fake, env=env, capture_output=True, text=True)
        calls = out.read_text() if out.exists() else ""
        summary = (work / "SUMMARY.md").read_text() if (work / "SUMMARY.md").exists() else ""
        return p, calls, summary

    def test_broken_helper_is_loud_and_the_step_builds(self):
        p, calls, summary = self.run_block("import sys; sys.stderr.write('Traceback: boom\\n'); sys.exit(7)\n")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("built", calls)
        self.assertIn("warning: ios-ffi cache: key failed (exit 7)", p.stderr)
        self.assertIn("Traceback: boom", p.stderr)
        self.assertIn("FFI cache warning: key failed (exit 7)", summary)
        self.assertIn("HOW=built", p.stdout)

    def test_mangled_key_is_refused(self):
        # A key that is not 64 hex characters (a truncated or rewritten sha) is never used.
        p, calls, summary = self.run_block(
            "import sys\nif sys.argv[1] == 'key': print('6bcdfbbe')\nelse: sys.exit(0)\n")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("built", calls)
        self.assertIn("not a sha256", summary)
        self.assertIn("HOW=built", p.stdout)

    def test_hit_without_outputs_builds(self):
        p, calls, summary = self.run_block("import sys\nif sys.argv[1] == 'key': print('a' * 64)\nelse: sys.exit(0)\n")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("built", calls)
        self.assertIn("restore reported a hit but left no", summary)

    def test_failed_probe_is_loud(self):
        helper = ("import sys\nif sys.argv[1] == 'key': print('a' * 64)\n"
                  "elif sys.argv[1] == 'probe': sys.exit(1)\nelse: sys.exit(1)\n")
        p, calls, summary = self.run_block(helper)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("built", calls)
        self.assertIn("probe of the feat-cmux-next tip failed", summary)

    def test_dropped_entry_and_tool_failure_are_loud(self):
        for code, word in ((6, "restore failed (exit 6)"), (4, "key failed (exit 4)")):
            sub = "restore" if code == 6 else "key"
            helper = ("import sys\nif sys.argv[1] == 'key' and %r != 'key': print('a' * 64)\n"
                      "elif sys.argv[1] == %r: sys.exit(%d)\nelse: sys.exit(1)\n") % (sub, sub, code)
            p, calls, summary = self.run_block(helper)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertIn(word, summary)

    def test_no_key_builds_quietly(self):
        p, calls, summary = self.run_block("import sys; sys.exit(3)\n")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("built", calls)
        self.assertNotIn("warning", p.stderr + summary)
        self.assertIn("HOW=built", p.stdout)

    def test_failed_build_fails_the_step(self):
        p, calls, summary = self.run_block("import sys; sys.exit(3)\n", build_body="exit 5")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("CmuxMobileLinkFFI.xcframework build failed", p.stderr)


if __name__ == "__main__":
    unittest.main()
