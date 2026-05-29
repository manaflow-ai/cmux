#!/usr/bin/env python3
"""
Regression: cmux bash integration must not remove user-stopped jobs from the
interactive shell job table when its prompt hook launches background telemetry.

Previously the integration used bare `disown`, which in bash 3.2 removes all
active jobs. After Ctrl-Z stopped a foreground process, the next prompt hook
could delete that job while detaching cmux's own async git probe, breaking `fg`.
"""

from __future__ import annotations

import os
import pty
import select
import subprocess
import tempfile
import textwrap
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Resources" / "shell-integration" / "cmux-bash-integration.bash"


def _write_executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


def _read_until(fd: int, needles: list[str], timeout: float) -> str:
    deadline = time.time() + timeout
    chunks: list[str] = []
    while time.time() < deadline:
        remaining = deadline - time.time()
        ready, _, _ = select.select([fd], [], [], max(0.05, remaining))
        if not ready:
            continue
        data = os.read(fd, 4096).decode("utf-8", errors="replace")
        if not data:
            break
        chunks.append(data)
        joined = "".join(chunks)
        if any(needle in joined for needle in needles):
            return joined
    return "".join(chunks)


def main() -> int:
    failures: list[str] = []

    with tempfile.TemporaryDirectory(prefix="cmux-bash-ctrlz-job-control-") as td:
        tmp = Path(td)
        bindir = tmp / "bin"
        repo = tmp / "repo"
        repo_git = repo / ".git"
        socket_path = tmp / "cmux.sock"
        send_log = tmp / "send.log"
        bindir.mkdir(parents=True, exist_ok=True)
        repo_git.mkdir(parents=True, exist_ok=True)
        (repo_git / "HEAD").write_text("ref: refs/heads/main\n", encoding="utf-8")

        _write_executable(
            bindir / "git",
            textwrap.dedent(
                """\
                #!/bin/sh
                if [ "$1" = "rev-parse" ] && [ "$2" = "--git-dir" ]; then
                  printf '%s/.git\\n' "$PWD"
                  exit 0
                fi
                if [ "$1" = "branch" ] && [ "$2" = "--show-current" ]; then
                  printf 'main\\n'
                  exit 0
                fi
                if [ "$1" = "status" ] && [ "$2" = "--porcelain" ] && [ "$3" = "-uno" ]; then
                  exit 0
                fi
                printf 'unexpected git args: %s\\n' "$*" >&2
                exit 1
                """
            ),
        )

        env = dict(os.environ)
        env.update(
            {
                "PATH": f"{bindir}:/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": str(socket_path),
                "CMUX_TAB_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_TEST_SEND_LOG": str(send_log),
                "PS1": "cmux-test$ ",
            }
        )

        server = subprocess.Popen(
            [
                "/usr/bin/python3",
                "-c",
                textwrap.dedent(
                    """\
                    import os, socket
                    path = os.environ["CMUX_SOCKET_PATH"]
                    try:
                        os.unlink(path)
                    except FileNotFoundError:
                        pass
                    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    sock.bind(path)
                    sock.listen(8)
                    try:
                        while True:
                            conn, _ = sock.accept()
                            conn.recv(4096)
                            conn.close()
                    except KeyboardInterrupt:
                        pass
                    finally:
                        sock.close()
                    """
                ),
            ],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        try:
            time.sleep(0.2)
            master_fd, slave_fd = pty.openpty()
            proc = subprocess.Popen(
                ["/bin/bash", "--noprofile", "--norc", "-i"],
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                cwd=repo,
                env=env,
                close_fds=True,
            )
            os.close(slave_fd)

            try:
                bootstrap = textwrap.dedent(
                    f"""\
                    source "{SCRIPT}"
                    _cmux_send() {{ printf '%s\\n' "$1" >> "$CMUX_TEST_SEND_LOG"; }}
                    cd "{repo}"
                    export PS1='cmux-test$ '
                    """
                )
                os.write(master_fd, bootstrap.encode("utf-8"))
                initial = _read_until(master_fd, ["cmux-test$ "], 5.0)
                if "cmux-test$ " not in initial:
                    failures.append(f"bash shell did not reach prompt after bootstrap: {initial!r}")
                else:
                    os.write(master_fd, b"sleep 30\n")
                    running = _read_until(master_fd, ["sleep 30"], 2.0)
                    if "sleep 30" not in running:
                        failures.append(f"sleep command did not start as expected: {running!r}")

                    os.write(master_fd, b"\x1a")
                    stopped = _read_until(master_fd, ["Stopped", "cmux-test$ "], 5.0)
                    os.write(master_fd, b"jobs\n")
                    jobs_output = _read_until(master_fd, ["cmux-test$ "], 5.0)

                    combined = stopped + jobs_output
                    if "Stopped" not in combined:
                        failures.append(f"expected Ctrl-Z to stop foreground job, got: {combined!r}")
                    if "sleep 30" not in combined:
                        failures.append(f"expected stopped job to remain in job table, got: {combined!r}")
                    if "deleting stopped job" in combined:
                        failures.append(f"prompt hook deleted stopped job: {combined!r}")

                os.write(master_fd, b"exit\n")
                proc.wait(timeout=5)
            finally:
                os.close(master_fd)
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait(timeout=3)
        finally:
            server.terminate()
            try:
                server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=3)

    if failures:
        print("FAIL: bash shell integration Ctrl-Z regression")
        for failure in failures:
            print(failure)
        return 1

    print("PASS: bash shell integration preserves stopped jobs across prompt telemetry")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
