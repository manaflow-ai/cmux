#!/usr/bin/env python3
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "Resources" / "bin" / "cmux-claude-wrapper"


def claude_project_dir_name(path: Path) -> str:
    return str(path).replace("/", "-").replace(".", "-")


def claude_project_dir_names_for_path(path: Path) -> set[str]:
    slash_and_dot = claude_project_dir_name(path)
    slash_only = str(path).replace("/", "-")
    return {slash_and_dot, slash_only}


def cwd_project_dir_names(path: Path) -> set[str]:
    names = set(claude_project_dir_names_for_path(path))
    raw = str(path)
    if raw.startswith("/private/"):
        names.update(claude_project_dir_names_for_path(Path(raw.removeprefix("/private"))))
    elif raw.startswith("/") and Path(f"/private{raw}").exists():
        names.update(claude_project_dir_names_for_path(Path(f"/private{raw}")))
    return names


def write_executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


def test_resume_from_different_cwd_seeds_transcript_copy(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-resume-cwd-seed-") as td:
        root = Path(td)
        wrapper_bin = root / "wrapper-bin"
        real_bin = root / "real-bin"
        config = root / "claude-config"
        origin_cwd = root / "repo.main"
        target_cwd = root / "worktrees" / "feature.v2"
        sid = "39c1eb84-1111-2222-3333-444444444444"
        for directory in (wrapper_bin, real_bin, origin_cwd, target_cwd):
            directory.mkdir(parents=True, exist_ok=True)

        wrapper = wrapper_bin / "cmux-claude-wrapper"
        shutil.copy2(WRAPPER, wrapper)
        wrapper.chmod(0o755)

        origin_project = config / "projects" / claude_project_dir_name(origin_cwd)
        target_project = config / "projects" / claude_project_dir_name(target_cwd)
        slash_only_target_project = config / "projects" / str(target_cwd).replace("/", "-")
        origin_sidecar = origin_project / sid
        origin_sidecar.mkdir(parents=True, exist_ok=True)
        (origin_project / f"{sid}.jsonl").write_text("origin transcript\n", encoding="utf-8")
        (origin_sidecar / "attachment.txt").write_text("sidecar payload\n", encoding="utf-8")

        real_seen_transcript = root / "real-seen-transcript.log"
        write_executable(
            real_bin / "claude",
            f"""#!/usr/bin/env bash
set -euo pipefail
sid=""
while (($#)); do
  case "$1" in
    --resume|-r)
      shift
      sid="${{1:-}}"
      ;;
    --resume=*)
      sid="${{1#--resume=}}"
      ;;
  esac
  shift || true
done
project="$(printf '%s' "$PWD" | sed 's#[/.]#-#g')"
transcript="${{CLAUDE_CONFIG_DIR}}/projects/${{project}}/${{sid}}.jsonl"
if [[ ! -f "$transcript" ]]; then
  echo "No conversation found with session ID: $sid" >&2
  exit 42
fi
cat "$transcript" > {str(real_seen_transcript)!r}
""",
        )

        env = dict(os.environ)
        env["PATH"] = f"{wrapper_bin}:{real_bin}:/usr/bin:/bin"
        env["HOME"] = str(root)
        env["CLAUDE_CONFIG_DIR"] = str(config)
        env["CMUX_SURFACE_ID"] = "surface:test"
        env["CMUX_CLAUDE_HOOKS_DISABLED"] = "1"
        env.pop("CMUX_SOCKET_PATH", None)

        result = subprocess.run(
            [str(wrapper), "--resume", sid, "--fork-session"],
            cwd=target_cwd,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

        target_transcript = target_project / f"{sid}.jsonl"
        target_sidecar_file = target_project / sid / "attachment.txt"
        slash_only_target_transcript = slash_only_target_project / f"{sid}.jsonl"
        if result.returncode != 0:
            failures.append(
                f"wrapper exited {result.returncode}: stdout={result.stdout!r} stderr={result.stderr!r}"
            )
        if not target_transcript.exists():
            failures.append("target cwd transcript was not seeded")
        elif target_transcript.read_text(encoding="utf-8") != "origin transcript\n":
            failures.append("target cwd transcript did not preserve origin content")
        if not target_sidecar_file.exists():
            failures.append("target cwd sidecar directory was not copied")
        elif target_sidecar_file.read_text(encoding="utf-8") != "sidecar payload\n":
            failures.append("target cwd sidecar did not preserve origin content")
        if not real_seen_transcript.exists():
            failures.append("real claude did not observe the target cwd transcript")
        elif real_seen_transcript.read_text(encoding="utf-8") != "origin transcript\n":
            failures.append("real claude observed unexpected transcript content")
        if not slash_only_target_transcript.exists():
            failures.append("slash-only dotted cwd transcript variant was not seeded")
        elif slash_only_target_transcript.read_text(encoding="utf-8") != "origin transcript\n":
            failures.append("slash-only dotted cwd transcript variant did not preserve origin content")
        if target_transcript.exists() and target_transcript.samefile(origin_project / f"{sid}.jsonl"):
            failures.append("target transcript must be a copy, not a hardlink")


def test_copy_failure_in_current_root_allows_fallback_root(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-resume-cwd-fallback-") as td:
        root = Path(td)
        wrapper_bin = root / "wrapper-bin"
        real_bin = root / "real-bin"
        inherited_config = root / "bad-config"
        fallback_config = root / ".claude"
        origin_cwd = root / "repo-main"
        target_cwd = root / "worktrees" / "feature"
        sid = "39c1eb84-5555-6666-7777-888888888888"
        for directory in (wrapper_bin, real_bin, origin_cwd, target_cwd):
            directory.mkdir(parents=True, exist_ok=True)

        wrapper = wrapper_bin / "cmux-claude-wrapper"
        shutil.copy2(WRAPPER, wrapper)
        wrapper.chmod(0o755)

        for config_root, content in (
            (inherited_config, "inherited transcript\n"),
            (fallback_config, "fallback transcript\n"),
        ):
            origin_project = config_root / "projects" / claude_project_dir_name(origin_cwd)
            origin_project.mkdir(parents=True, exist_ok=True)
            (origin_project / f"{sid}.jsonl").write_text(content, encoding="utf-8")

        for project_dir_name in cwd_project_dir_names(target_cwd):
            blocked_target_project = inherited_config / "projects" / project_dir_name
            blocked_target_project.write_text("not a directory\n", encoding="utf-8")

        real_seen_transcript = root / "real-seen-transcript.log"
        write_executable(
            real_bin / "claude",
            f"""#!/usr/bin/env bash
set -euo pipefail
sid=""
while (($#)); do
  case "$1" in
    --resume|-r)
      shift
      sid="${{1:-}}"
      ;;
    --resume=*)
      sid="${{1#--resume=}}"
      ;;
  esac
  shift || true
done
project="$(printf '%s' "$PWD" | sed 's#[/.]#-#g')"
transcript="${{CLAUDE_CONFIG_DIR}}/projects/${{project}}/${{sid}}.jsonl"
if [[ ! -f "$transcript" ]]; then
  echo "No conversation found with session ID: $sid" >&2
  exit 42
fi
cat "$transcript" > {str(real_seen_transcript)!r}
""",
        )

        env = dict(os.environ)
        env["PATH"] = f"{wrapper_bin}:{real_bin}:/usr/bin:/bin"
        env["HOME"] = str(root)
        env["CLAUDE_CONFIG_DIR"] = str(inherited_config)
        env["CMUX_SURFACE_ID"] = "surface:test"
        env["CMUX_CLAUDE_HOOKS_DISABLED"] = "1"
        env.pop("CMUX_SOCKET_PATH", None)

        result = subprocess.run(
            [str(wrapper), "--resume", sid, "--fork-session"],
            cwd=target_cwd,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

        fallback_targets = [
            fallback_config / "projects" / project_dir_name / f"{sid}.jsonl"
            for project_dir_name in cwd_project_dir_names(target_cwd)
        ]
        if result.returncode != 0:
            failures.append(
                f"fallback wrapper exited {result.returncode}: stdout={result.stdout!r} stderr={result.stderr!r}"
            )
        if not any(target.exists() for target in fallback_targets):
            failures.append("fallback root target transcript was not seeded")
        for fallback_target in fallback_targets:
            if fallback_target.exists() and fallback_target.read_text(encoding="utf-8") != "fallback transcript\n":
                failures.append("fallback root target transcript did not preserve fallback content")
        if not real_seen_transcript.exists():
            failures.append("real claude did not observe fallback root transcript")
        elif real_seen_transcript.read_text(encoding="utf-8") != "fallback transcript\n":
            failures.append("real claude did not run from the fallback config root")


def main() -> int:
    failures: list[str] = []
    test_resume_from_different_cwd_seeds_transcript_copy(failures)
    test_copy_failure_in_current_root_allows_fallback_root(failures)
    if failures:
        print("FAIL: claude wrapper resume cwd seeding checks failed")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: claude wrapper seeds resume transcripts for different cwd forks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
