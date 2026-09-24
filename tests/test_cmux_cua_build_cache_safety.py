#!/usr/bin/env python3
"""Regression checks for non-destructive cmux-cua cache handling."""

from __future__ import annotations

import os
import platform
import re
import stat
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "scripts" / "build-cmux-cua.sh"


def pinned_sha() -> str:
    match = re.search(
        r'^CMUX_CUA_PINNED_SHA="([0-9a-f]{40})"$',
        BUILD_SCRIPT.read_text(),
        re.MULTILINE,
    )
    assert match is not None
    return match.group(1)


def write_executable(path: Path, contents: str) -> None:
    path.write_text(contents)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def fake_tool_environment(root: Path, sha: str) -> dict[str, str]:
    bin_dir = root / "bin"
    bin_dir.mkdir()
    write_executable(
        bin_dir / "git",
        f"""#!/bin/bash
set -eu
if [[ "${{1:-}}" == "clone" ]]; then
  target="${{@: -1}}"
  mkdir -p "$target/.git" "$target/libs/cmux-cua/rust"
  : > "$target/libs/cmux-cua/rust/Cargo.toml"
  : > "$target/LICENSE.md"
  exit 0
fi
if [[ "${{1:-}}" == "-C" ]]; then
  shift 2
  case "${{1:-}}" in
    cat-file|checkout|clean|fetch) exit 0 ;;
    remote)
      echo "fake://cmux-cua"
      exit 0
      ;;
    rev-parse)
      echo "{sha}"
      exit 0
      ;;
    status) exit 0 ;;
  esac
fi
exit 1
""",
    )
    write_executable(bin_dir / "cargo", "#!/bin/bash\nexit 42\n")
    environment = os.environ.copy()
    environment["PATH"] = f"{bin_dir}:{environment['PATH']}"
    environment["CMUX_CUA_REPO_URL"] = "fake://cmux-cua"
    return environment


def run_until_compile(root: Path, cache_dir: Path, sha: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            str(BUILD_SCRIPT),
            "--output",
            str(root / "output"),
            "--archs",
            "arm64",
            "--cache-dir",
            str(cache_dir),
        ],
        env=fake_tool_environment(root, sha),
        capture_output=True,
        text=True,
    )


def successful_build_environment(root: Path, sha: str) -> dict[str, str]:
    environment = fake_tool_environment(root, sha)
    bin_dir = root / "bin"
    write_executable(
        bin_dir / "rustup",
        """#!/bin/bash
set -eu
if [[ "${1:-}" == "target" && "${2:-}" == "list" ]]; then
  printf '%s\n' aarch64-apple-darwin x86_64-apple-darwin
  exit 0
fi
exit 1
""",
    )
    write_executable(
        bin_dir / "cargo",
        """#!/bin/bash
set -eu
target=""
while (($#)); do
  if [[ "$1" == "--target" ]]; then
    target="$2"
    shift 2
  else
    shift
  fi
done
[[ -n "$target" ]]
mkdir -p "$CARGO_TARGET_DIR/$target/release"
cp /usr/bin/true "$CARGO_TARGET_DIR/$target/release/cmux-cua"
""",
    )
    environment["PRODUCT_BUNDLE_IDENTIFIER"] = "com.cmuxterm.app.debug.cua-safety-test"
    return environment


def test_unmanaged_current_source_is_preserved(sha: str) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-cua-cache-current-") as tmp:
        root = Path(tmp)
        cache_dir = root / "cache"
        source_dir = cache_dir / f"src-{sha}"
        source_dir.mkdir(parents=True)
        sentinel = source_dir / "user-data.txt"
        sentinel.write_text("keep me")

        result = run_until_compile(root, cache_dir, sha)

        assert result.returncode != 0
        assert sentinel.read_text() == "keep me", result.stderr


def test_stale_sibling_source_is_preserved(sha: str) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-cua-cache-sibling-") as tmp:
        root = Path(tmp)
        cache_dir = root / "cache"
        stale_source = cache_dir / f"src-{'0' * 40}"
        stale_source.mkdir(parents=True)
        sentinel = stale_source / "user-data.txt"
        sentinel.write_text("keep me")
        stamp = stale_source / ".cmux-last-used"
        stamp.touch()
        old_time = time.time() - (9 * 24 * 60 * 60)
        os.utime(stamp, (old_time, old_time))

        result = run_until_compile(root, cache_dir, sha)

        assert result.returncode != 0
        assert sentinel.read_text() == "keep me", result.stderr


def test_clean_legacy_source_is_adopted(sha: str) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-cua-cache-legacy-") as tmp:
        root = Path(tmp)
        cache_dir = root / "cache"
        source_dir = cache_dir / f"src-{sha}"
        (source_dir / ".git").mkdir(parents=True)
        (source_dir / "libs/cmux-cua/rust").mkdir(parents=True)
        (source_dir / "libs/cmux-cua/rust/Cargo.toml").touch()
        (source_dir / ".cmux-last-used").touch()

        result = run_until_compile(root, cache_dir, sha)

        assert result.returncode == 42, result.stderr
        owner = source_dir / ".cmux-cua-managed-source"
        assert owner.read_text() == f"cmux-cua-cache-v2 {sha}\n"


def test_unmanaged_helper_bundle_is_preserved(sha: str) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-cua-helper-unmanaged-") as tmp:
        root = Path(tmp)
        cache_dir = root / "cache"
        contents_dir = root / "cmux DEV.app" / "Contents"
        output = contents_dir / "Resources" / "bin" / "cmux-cua"
        helper = contents_dir / "Library" / "cmux Computer Use.app"
        helper.mkdir(parents=True)
        sentinel = helper / "user-data.txt"
        sentinel.write_text("keep me")
        machine = platform.machine()
        arch = "arm64" if machine in {"arm64", "aarch64"} else "x86_64"

        result = subprocess.run(
            [
                str(BUILD_SCRIPT),
                "--output",
                str(output),
                "--archs",
                arch,
                "--cache-dir",
                str(cache_dir),
            ],
            env=successful_build_environment(root, sha),
            capture_output=True,
            text=True,
        )

        assert result.returncode != 0, result.stdout
        assert sentinel.read_text() == "keep me", result.stderr


def test_prepared_source_compiles_without_git_writes(sha: str) -> None:
    # CI kills the optional prebuild at any moment, so --compile-prepared must
    # take no source lock and run no Git command that writes the checkout.
    with tempfile.TemporaryDirectory(prefix="cmux-cua-prepared-") as tmp:
        root = Path(tmp)
        cache_dir = root / "cache"
        environment = successful_build_environment(root, sha)
        git_log = root / "git.log"
        real_git = root / "bin" / "git"
        (root / "bin" / "git.real").write_text(real_git.read_text())
        (root / "bin" / "git.real").chmod(0o755)
        write_executable(
            real_git,
            f"""#!/bin/bash
printf '%s\\n' "$*" >> {str(git_log)!r}
exec {str(root / "bin" / "git.real")!r} "$@"
""",
        )

        def run(*args: str) -> subprocess.CompletedProcess[str]:
            return subprocess.run(
                [str(BUILD_SCRIPT), *args, "--archs", "arm64 x86_64", "--cache-dir", str(cache_dir)],
                env=environment,
                capture_output=True,
                text=True,
            )

        unprepared = run("--compile-prepared")
        assert unprepared.returncode != 0
        assert "--prepare-source" in unprepared.stderr, unprepared.stderr

        prepared = run("--prepare-source")
        assert prepared.returncode == 0, prepared.stderr
        source_dir = cache_dir / f"src-{sha}"
        assert (source_dir / ".cmux-cua-managed-source").is_file()
        assert not (source_dir / "target").exists()

        git_log.write_text("")
        compiled = run("--compile-prepared")
        assert compiled.returncode == 0, compiled.stderr
        for target in ("aarch64-apple-darwin", "x86_64-apple-darwin"):
            assert (source_dir / ".cmux-cargo-target" / target / "release" / "cmux-cua").is_file()
        git_commands = [line.split()[2] for line in git_log.read_text().splitlines()]
        assert set(git_commands) <= {"rev-parse"}, git_commands
        assert not Path(f"{source_dir}.lock").exists()
        assert not (root / "output").exists()


def main() -> int:
    sha = pinned_sha()
    test_unmanaged_current_source_is_preserved(sha)
    test_stale_sibling_source_is_preserved(sha)
    test_clean_legacy_source_is_adopted(sha)
    test_unmanaged_helper_bundle_is_preserved(sha)
    test_prepared_source_compiles_without_git_writes(sha)
    print("PASS: cmux-cua builds preserve unmanaged cache contents")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
