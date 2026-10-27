#!/usr/bin/env python3
"""scripts/ensure-ghosttykit.sh --variant safe (chrome-parity p10-stability-165).

The ReleaseSafe lab libghostty: the ghostty-next gitlink built with the pinned
flavor's flags from next/build-xcframework.sh, -Doptimize=ReleaseSafe in place of
ReleaseFast, cached under a key that names the variant and linked at
Packages/Shared/CmuxGhosttyKit/Variants/safe. Zig is a stub that records its
arguments, so this runs on Linux.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import git_fixture_env  # noqa: F401  (disables git auto maintenance)


ROOT = Path(__file__).resolve().parents[1]
FLAGS = """flags=(
  -Demit-xcframework=true
  -Demit-macos-app=false
  -Dxcframework-target=ios
  -Doptimize={optimize}
  -Dsentry=false
  -Di18n=false
)
"""


class EnsureGhosttyKitSafeVariantTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copyfile(ROOT / "scripts/ensure-ghosttykit.sh", scripts / "ensure-ghosttykit.sh")
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("CMUX_GHOSTTYKIT_", "GIT_"))}
        self.env.update(HOME=str(self.root), LC_ALL="C", GIT_CONFIG_NOSYSTEM="1",
                        GIT_CONFIG_GLOBAL=os.devnull, CMUX_GHOSTTYKIT_CACHE_DIR=str(self.root / "cache"),
                        TEST_ROOT=str(self.root))
        self.next = self.root / "ghostty-next"
        tools = self.next / "next"
        tools.mkdir(parents=True)
        (self.next / "build.zig").write_text("// fixture\n")
        (self.next / ".gitignore").write_text("/macos/\n")
        (tools / "toolchain.env").write_text("ZIG_VERSION=0.16.0\nGHOSTTYKIT_FLAVOR=apple-v6\n")
        self.write_build_script("ReleaseFast")
        # The pinned-Zig installer prints a stub Zig that records its arguments and makes the xcframework.
        zig = self.root / "zig-bin" / "zig"
        zig.parent.mkdir()
        zig.write_text(
            '#!/usr/bin/env bash\nset -eu\n'
            'if [[ "$1" == version ]]; then echo 0.16.0; exit 0; fi\n'
            'printf "%s\\n" "$*" >> "$TEST_ROOT/zig-calls"\n'
            'mkdir -p macos/GhosttyNextKit.xcframework/macos-arm64_x86_64\n'
            'printf "%s\\n" "$*" > macos/GhosttyNextKit.xcframework/flags\n'
        )
        zig.chmod(0o755)
        installer = tools / "install-zig.sh"
        installer.write_text(f'#!/usr/bin/env bash\necho "{zig}"\n')
        installer.chmod(0o755)
        self.git("init", "-q")
        self.commit()

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.next), *args], env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self):
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")

    def write_build_script(self, optimize):
        (self.next / "next/build-xcframework.sh").write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\n" + FLAGS.format(optimize=optimize)
            + 'zig build "${flags[@]}" --summary failures\n')

    def run_script(self, *args):
        return subprocess.run(["bash", str(self.root / "scripts/ensure-ghosttykit.sh"), *args],
                              cwd=self.root, env=self.env, capture_output=True, text=True)

    def zig_calls(self):
        path = self.root / "zig-calls"
        return path.read_text().splitlines() if path.exists() else []

    def link(self):
        return self.root / "Packages/Shared/CmuxGhosttyKit/Variants/safe/GhosttyNextKit.xcframework"

    def test_builds_release_safe_under_its_own_key_and_links_it(self):
        result = self.run_script("--variant", "safe")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.zig_calls()
        self.assertEqual(len(calls), 1, calls)
        self.assertIn("-Doptimize=ReleaseSafe", calls[0])
        self.assertNotIn("ReleaseFast", calls[0])
        for flag in ("-Demit-xcframework=true", "-Dxcframework-target=ios", "-Dsentry=false", "-Di18n=false"):
            self.assertIn(flag, calls[0])
        sha = self.git("rev-parse", "HEAD")
        key = f"next-{sha}-apple-v6-releasesafe-v1"
        self.assertIn(f"build key: {key}", result.stdout)
        cached = self.root / "cache" / key / "GhosttyNextKit.xcframework"
        self.assertTrue(cached.is_dir())
        self.assertTrue(self.link().is_symlink())
        self.assertEqual(self.link().resolve(), cached.resolve())
        self.assertFalse((self.next / "macos/GhosttyNextKit.xcframework").exists(),
                         "the build output stays in the cache, not in the submodule")

        again = self.run_script("--variant=safe")
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertEqual(len(self.zig_calls()), 1, "a cached safe variant is not rebuilt")
        self.assertIn("Reusing cached ReleaseSafe", again.stdout)

    def test_dirty_submodule_gets_its_own_key(self):
        self.assertEqual(self.run_script("--variant", "safe").returncode, 0)
        (self.next / "src.zig").write_text("// local change\n")
        result = self.run_script("--variant", "safe")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.zig_calls()), 2, "a dirty tree is not the clean commit's build")
        self.assertRegex(result.stdout, r"releasesafe-v1-dirty-[0-9a-f]{64}")

    def test_refuses_a_build_script_without_release_fast(self):
        self.write_build_script("Debug")
        self.commit()
        result = self.run_script("--variant", "safe")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("-Doptimize=Debug", result.stderr)
        self.assertEqual(self.zig_calls(), [])

    def test_refuses_an_unknown_variant(self):
        result = self.run_script("--variant", "debug")
        self.assertEqual(result.returncode, 2)
        self.assertIn("fast or safe", result.stderr)

    def test_refuses_a_missing_submodule(self):
        shutil.rmtree(self.next)
        result = self.run_script("--variant", "safe")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("git submodule update --init ghostty-next", result.stderr)


if __name__ == "__main__":
    unittest.main()
