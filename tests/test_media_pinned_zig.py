"""A media tour's local cmux-tui client build uses the tree's pinned Zig, not the Mac's.

Regression: tour 45249031506 built the before app at a644014 with the Mac's PATH zig 0.16
while its ghostty-next pins 0.17; libghostty-vt failed and two What's New befores never recorded.
"""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CI = ROOT / "scripts/ci"


def write(path: Path, text: str, mode: int = 0o755) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    os.chmod(path, mode)


def fake_tree(tmp: Path) -> Path:
    """A git tree with ghostty-next, a stub installer that logs its env, and stub build scripts."""
    tree = tmp / "tree"
    zig = tmp / "pinned" / "zig"
    write(zig, "#!/bin/sh\necho 0.17.0\n")
    write(tree / "scripts/install-zig-ci.sh", f"""#!/bin/bash
env | grep -E '^(GHOSTTY_ZIG_SOURCE|ZIG_FORCE_LOCAL_INSTALL|ZIG_INSTALL_ROOT|ZIG_TARBALL_CACHE_DIR|GITHUB_PATH)=' | sort > {tmp / 'installer-env'}
echo "CMUX_ZIG={zig}" >> "$GITHUB_ENV"
""")
    write(tree / "scripts/cmux-next/pin-cmux-tui.sh", "#!/bin/sh\necho 'tree: waiting'\n")
    write(tree / "scripts/cmux-next/build-cmux-tui-client.sh", f"#!/bin/sh\necho \"$CMUX_ZIG\" > {tmp / 'client-zig'}\necho /client\n")
    write(tree / "scripts/reload.sh", f"#!/bin/sh\nmkdir -p {tmp / 'app.app'}\necho 'App path:'\necho '  {tmp / 'app.app'}'\n")
    git = ["git", "-C", str(tree), "-c", "user.name=t", "-c", "user.email=t@t"]
    subprocess.run(["git", "init", "-q", str(tree)], check=True)
    sub = tmp / "sub"
    subprocess.run(["git", "init", "-q", str(sub)], check=True)
    subprocess.run(["git", "-C", str(sub), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "s"], check=True)
    head = subprocess.run(["git", "-C", str(sub), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    subprocess.run([*git, "update-index", "--add", "--cacheinfo", f"160000,{head},ghostty-next"], check=True)
    subprocess.run([*git, "add", "scripts"], check=True)
    subprocess.run([*git, "commit", "-q", "-m", "t"], check=True)
    return tree


class MediaPinnedZig(unittest.TestCase):
    def test_the_helper_installs_the_trees_zig_job_locally_and_prints_it(self):
        tmp = Path(tempfile.mkdtemp())
        tree = fake_tree(tmp)
        env = dict(os.environ, HOME=str(tmp), RUNNER_NAME="r", GITHUB_PATH=str(tmp / "path"))
        out = subprocess.run([str(CI / "media_pinned_zig.sh"), str(tree)], env=env, capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), str(tmp / "pinned/zig"))
        seen = dict(line.split("=", 1) for line in (tmp / "installer-env").read_text().splitlines())
        self.assertEqual(seen["GHOSTTY_ZIG_SOURCE"], "ghostty-next")
        self.assertEqual(seen["ZIG_FORCE_LOCAL_INSTALL"], "1", "never over the Mac's zig")
        self.assertEqual(seen["GITHUB_PATH"], "", "later steps keep their PATH")
        self.assertTrue(seen["ZIG_INSTALL_ROOT"].startswith(str(tmp / "Library/Caches/cmux-ci-media/zig/r")))

    def test_an_unpublished_trees_client_builds_with_the_pinned_zig(self):
        tmp = Path(tempfile.mkdtemp())
        tree = fake_tree(tmp)
        env = {k: v for k, v in os.environ.items() if k not in ("CMUX_ZIG", "CMUX_TUI_TREE_KEY", "CMUX_NEXT_TUI_BIN", "CMUX_TUI_CLIENT_LOCAL")}
        env.update(HOME=str(tmp), RUNNER_NAME="r", GITHUB_OUTPUT=str(tmp / "output"))
        out = subprocess.run([str(CI / "media_build_app.sh"), str(tree), "ci-media-t", str(tmp / "log"), "app"],
                             env=env, capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertEqual((tmp / "client-zig").read_text().strip(), str(tmp / "pinned/zig"))


if __name__ == "__main__":
    unittest.main()
