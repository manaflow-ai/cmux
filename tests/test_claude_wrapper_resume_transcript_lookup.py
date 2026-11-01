#!/usr/bin/env python3
"""The wrapper's `--resume` config-dir check must not expand every folder under projects/.

Bash expands every word of a `for` list before the loop tests the first one, so
five glob words walk five levels of `projects/` even when the transcript sits at
the first. On a long history that held `claude --resume` for over a minute
(https://github.com/manaflow-ai/cmux/issues/26908).

These cases run the real wrapper under `bash -x` against a fake claude. The
trace shows which lookups ran, which needs no timing: a glob word that matches
nothing stays literal in the trace, and a `find` call shows up by name. The fake
claude's CLAUDE_CONFIG_DIR shows which config root the lookup picked.
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from node_runtime import ensure_node_on_path  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "cmux-claude-wrapper"
SESSION_ID = "0198f073-0a5b-7000-8000-000000026908"
TRANSCRIPT = f"{SESSION_ID}.jsonl"
GENERATED_CLAUDE_HOOK_SETTINGS = '{"preferredNotifChannel":"notifications_disabled","hooks":{}}'
DEEP_GLOB_WORD = "projects/*/*/"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def write_transcript(root: Path, *folders: str, body: str = '{"type":"user"}\n') -> Path:
    directory = root.joinpath("projects", *folders)
    directory.mkdir(parents=True, exist_ok=True)
    transcript = directory / TRANSCRIPT
    transcript.write_text(body, encoding="utf-8")
    return transcript


class Run:
    def __init__(self, home: Path, config_dir: str | None, trace: str) -> None:
        self.home = home
        self.config_dir = config_dir
        self.trace = trace

    @property
    def find_calls(self) -> list[str]:
        return [
            line
            for line in self.trace.splitlines()
            if "/usr/bin/find " in line and TRANSCRIPT in line
        ]

    @property
    def expanded_deep_glob(self) -> bool:
        return any(DEEP_GLOB_WORD in line for line in self.trace.splitlines())


def run_wrapper(arrange, current_root: str | None = "foreign", session_id: str = SESSION_ID) -> Run:
    """Lay out a home with `arrange(home)` and resume a session through the wrapper.

    `current_root` names the inherited CLAUDE_CONFIG_DIR under the home, and is
    created with an empty projects/ folder. None leaves it unset, so the current
    root is `~/.claude`.
    """
    with tempfile.TemporaryDirectory(prefix="cmux-resume-lookup-") as td:
        # The trace and CLAUDE_CONFIG_DIR hold resolved paths; /var is a symlink on macOS.
        tmp = Path(td).resolve()
        wrapper_dir = tmp / "cmux.app" / "Contents" / "Resources" / "bin"
        real_dir = tmp / "real-bin"
        bundled_dir = tmp / "bundled cli"
        home = tmp / "home"
        tmpdir = tmp / "tmp"
        for directory in (wrapper_dir, real_dir, bundled_dir, home, tmpdir):
            directory.mkdir(parents=True, exist_ok=True)

        wrapper = wrapper_dir / "cmux-claude-wrapper"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        config_log = tmp / "claude-config-dir.log"
        socket_path = str(tmp / "cmux.sock")
        make_executable(
            real_dir / "claude",
            """#!/usr/bin/env bash
if [[ "${1:-}" == "--help" ]]; then
  printf 'Usage: claude [options] [command] [prompt]\\n'
  exit 0
fi
printf '%s' "${CLAUDE_CONFIG_DIR:-}" > "$FAKE_CLAUDE_CONFIG_LOG"
exit 0
""",
        )
        make_executable(wrapper_dir / "cmux", "#!/usr/bin/env bash\nexit 0\n")
        make_executable(
            bundled_dir / "cmux",
            """#!/usr/bin/env bash
if [[ "${1:-}" == "hooks" && "${2:-}" == "claude" && "${3:-}" == "inject-settings" ]]; then
  printf '%s' "$FAKE_GENERATED_CLAUDE_HOOK_SETTINGS"
fi
exit 0
""",
        )

        arrange(home)

        test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        test_socket.bind(socket_path)

        node = ensure_node_on_path()
        assert node is not None
        env = {
            "PATH": f"{wrapper_dir}:{real_dir}:{Path(node).parent}:/usr/bin:/bin",
            "HOME": str(home),
            "TMPDIR": str(tmpdir),
            "CMUX_SURFACE_ID": "surface:test",
            "CMUX_SOCKET_PATH": socket_path,
            "CMUX_BUNDLED_CLI_PATH": str(bundled_dir / "cmux"),
            "FAKE_CLAUDE_CONFIG_LOG": str(config_log),
            "FAKE_GENERATED_CLAUDE_HOOK_SETTINGS": GENERATED_CLAUDE_HOOK_SETTINGS,
        }
        if current_root is not None:
            current = home / current_root
            (current / "projects").mkdir(parents=True, exist_ok=True)
            env["CLAUDE_CONFIG_DIR"] = str(current)
        try:
            proc = subprocess.run(
                ["/usr/bin/env", "bash", "-x", str(wrapper), "--resume", session_id],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                check=False,
                timeout=60,
            )
        finally:
            test_socket.close()

        if proc.returncode != 0:
            raise AssertionError(f"wrapper exited {proc.returncode}: {proc.stderr[-2000:]}")
        if not config_log.exists():
            raise AssertionError(f"fake claude never ran: {proc.stderr[-2000:]}")
        return Run(home, config_log.read_text(encoding="utf-8") or None, proc.stderr)


def relative_config_dir(run: Run) -> str | None:
    if run.config_dir is None:
        return None
    return os.path.relpath(run.config_dir, run.home)


def expect(failures: list[str], name: str, condition: bool, detail: object) -> None:
    if not condition:
        failures.append(f"{name}: {detail}")


def check_miss_walks_once_per_root(failures: list[str]) -> None:
    # The case the reconcile exists for: the current root lacks the session.
    def arrange(home: Path) -> None:
        other_session = home / ".claude" / "projects" / "other-cwd" / "abc" / "subagents"
        other_session.mkdir(parents=True)
        (other_session / "other.jsonl").write_text("{}\n", encoding="utf-8")

    run = run_wrapper(arrange)
    expect(failures, "miss", relative_config_dir(run) == "foreign", run.config_dir)
    expect(
        failures,
        "miss expands no deep glob",
        not run.expanded_deep_glob,
        [line for line in run.trace.splitlines() if DEEP_GLOB_WORD in line][:3],
    )
    expect(failures, "miss searches each root once", len(run.find_calls) == 2, run.find_calls)
    expect(
        failures,
        "search stops at the first match",
        all("-quit" in call for call in run.find_calls),
        run.find_calls,
    )


def check_depth_one_needs_no_search(failures: list[str]) -> None:
    run = run_wrapper(lambda home: write_transcript(home / "foreign", "encoded-cwd"))
    expect(failures, "current root hit", relative_config_dir(run) == "foreign", run.config_dir)
    expect(failures, "current root hit expands no deep glob", not run.expanded_deep_glob, "deep glob")
    expect(failures, "current root hit runs no search", not run.find_calls, run.find_calls)

    run = run_wrapper(lambda home: write_transcript(home / ".claude", "encoded-cwd"))
    expect(failures, "other root hit", relative_config_dir(run) == ".claude", run.config_dir)
    expect(failures, "other root hit searches only the current root", len(run.find_calls) == 1, run.find_calls)


def check_current_root_is_never_repointed(failures: list[str]) -> None:
    def deep_here_shallow_there(home: Path) -> None:
        write_transcript(home / "foreign", "a", "b", "c")
        write_transcript(home / ".claude", "a")

    run = run_wrapper(deep_here_shallow_there)
    expect(failures, "deep in the current root wins", relative_config_dir(run) == "foreign", run.config_dir)


def check_depth_is_relative_to_the_root(failures: list[str]) -> None:
    # An ancestor folder named projects must not make a stray file look one level deeper.
    def stray_under_projects_ancestor(home: Path) -> None:
        current = home / "projects" / "config" / "projects"
        current.mkdir(parents=True)
        (current / TRANSCRIPT).write_text("{}\n", encoding="utf-8")
        write_transcript(home / ".claude", "a", "b")

    run = run_wrapper(stray_under_projects_ancestor, current_root="projects/config")
    expect(failures, "stray file under a projects ancestor", relative_config_dir(run) == ".claude", run.config_dir)


def check_every_supported_depth_still_resolves(failures: list[str]) -> None:
    for folders in (
        ("a",),
        ("a", "b"),
        ("a", "b", "c"),
        ("a", "b", "c", "d"),
        ("a", "b", "c", "d", "e"),
    ):
        run = run_wrapper(lambda home, f=folders: write_transcript(home / ".claude", *f))
        expect(failures, f"depth {len(folders)}", relative_config_dir(run) == ".claude", run.config_dir)

    run = run_wrapper(lambda home: write_transcript(home / ".claude", "a", "b", "c", "d", "e", "f"))
    expect(failures, "past the old depth limit", relative_config_dir(run) == "foreign", run.config_dir)


def check_what_counts_as_a_transcript(failures: list[str]) -> None:
    run = run_wrapper(lambda home: write_transcript(home / ".claude", "a", body=""))
    expect(failures, "empty at depth 1", relative_config_dir(run) == "foreign", run.config_dir)

    run = run_wrapper(lambda home: write_transcript(home / ".claude", "a", "b", body=""))
    expect(failures, "empty deeper", relative_config_dir(run) == "foreign", run.config_dir)

    def empty_then_real(home: Path) -> None:
        write_transcript(home / ".claude", "a", body="")
        write_transcript(home / ".claude", "b", "c")

    run = run_wrapper(empty_then_real)
    expect(failures, "empty first, real deeper", relative_config_dir(run) == ".claude", run.config_dir)

    def folder_with_the_name(home: Path) -> None:
        (home / ".claude" / "projects" / "a" / "b" / TRANSCRIPT).mkdir(parents=True)

    run = run_wrapper(folder_with_the_name)
    expect(failures, "folder with the transcript's name", relative_config_dir(run) == "foreign", run.config_dir)

    def directly_under_projects(home: Path) -> None:
        (home / ".claude" / "projects").mkdir(parents=True)
        (home / ".claude" / "projects" / TRANSCRIPT).write_text("{}\n", encoding="utf-8")

    run = run_wrapper(directly_under_projects)
    expect(failures, "directly under projects/", relative_config_dir(run) == "foreign", run.config_dir)

    for folders in ((".hidden",), (".hidden", "a"), ("a", ".hidden"), ("a", "b", "c", "d", ".hidden")):
        run = run_wrapper(lambda home, f=folders: write_transcript(home / ".claude", *f))
        expect(failures, f"hidden folder {folders}", relative_config_dir(run) == "foreign", run.config_dir)


def check_hidden_folders_skip_but_a_dot_led_session_resolves(failures: list[str]) -> None:
    dot_led = ".dot-led-session"

    def deep_dot_led(home: Path) -> None:
        directory = home / ".claude" / "projects" / "a" / "b"
        directory.mkdir(parents=True)
        (directory / f"{dot_led}.jsonl").write_text("{}\n", encoding="utf-8")

    run = run_wrapper(deep_dot_led, session_id=dot_led)
    expect(failures, "dot-led session id", relative_config_dir(run) == ".claude", run.config_dir)


def check_symlinks_resolve_as_the_globs_did(failures: list[str]) -> None:
    def linked_projects(home: Path) -> None:
        write_transcript(home / "elsewhere", "a", "b")
        (home / ".claude").mkdir()
        (home / ".claude" / "projects").symlink_to(home / "elsewhere" / "projects")

    run = run_wrapper(linked_projects)
    expect(failures, "linked projects folder", relative_config_dir(run) == ".claude", run.config_dir)

    def linked_folder(home: Path) -> None:
        write_transcript(home / "elsewhere", "a")
        (home / ".claude" / "projects" / "cwd").mkdir(parents=True)
        (home / ".claude" / "projects" / "cwd" / "link").symlink_to(home / "elsewhere" / "projects" / "a")

    run = run_wrapper(linked_folder)
    expect(failures, "linked folder", relative_config_dir(run) == ".claude", run.config_dir)

    def linked_file(home: Path) -> None:
        real = write_transcript(home / "elsewhere", "a")
        (home / ".claude" / "projects" / "cwd" / "sub").mkdir(parents=True)
        (home / ".claude" / "projects" / "cwd" / "sub" / TRANSCRIPT).symlink_to(real)

    run = run_wrapper(linked_file)
    expect(failures, "linked transcript", relative_config_dir(run) == ".claude", run.config_dir)

    def looped_folder(home: Path) -> None:
        (home / ".claude" / "projects" / "cwd").mkdir(parents=True)
        (home / ".claude" / "projects" / "cwd" / "loop").symlink_to(home / ".claude" / "projects")
        write_transcript(home / ".claude", "real", "sub")

    run = run_wrapper(looped_folder)
    expect(failures, "symlink loop", relative_config_dir(run) == ".claude", run.config_dir)


def main() -> int:
    if ensure_node_on_path() is None:
        print("SKIP: node runtime not found; the wrapper's settings merge needs node")
        return 0

    failures: list[str] = []
    check_miss_walks_once_per_root(failures)
    check_depth_one_needs_no_search(failures)
    check_current_root_is_never_repointed(failures)
    check_depth_is_relative_to_the_root(failures)
    check_every_supported_depth_still_resolves(failures)
    check_what_counts_as_a_transcript(failures)
    check_hidden_folders_skip_but_a_dot_led_session_resolves(failures)
    check_symlinks_resolve_as_the_globs_did(failures)
    if failures:
        print("FAIL:")
        for failure in failures:
            print(f"  {failure}")
        return 1
    print("PASS: --resume transcript lookup stays lazy and resolves the same roots")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
