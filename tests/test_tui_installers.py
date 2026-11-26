from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
UNIX_INSTALLER = ROOT / "web/public/tui/install-static.sh"
WINDOWS_INSTALLER = ROOT / "web/public/tui/install-static.ps1"
COMMIT = "a" * 40
PAYLOAD = b"real cmux binary fixture\n"


def write_executable(path: Path, contents: str) -> None:
    path.write_text(contents)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def run_unix_installer(
    tmp_path: Path,
    base_url: str,
    commit: str | None = COMMIT,
    payload: bytes = PAYLOAD,
    args: list[str] | None = None,
    env: dict[str, str] | None = None,
    binary: bytes | None = None,
    script: str | None = None,
) -> tuple[subprocess.CompletedProcess[str], Path, list[str]]:
    """`binary`, when given, is published and served as the verified build.
    `script`, when given, goes to `sh -s` on stdin (as `curl | sh` and the
    ssh:// install send it) instead of the installer file."""
    if binary is not None:
        payload = binary
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    manifest = {
        "binaries": {
            "cmux-tui-aarch64-apple-darwin": hashlib.sha256(binary or PAYLOAD).hexdigest(),
        },
    }
    if commit is not None:
        manifest["commit"] = commit
    (tmp_path / "manifest.json").write_text(json.dumps(manifest, indent=2))
    (tmp_path / "binary").write_bytes(payload)
    downloads = tmp_path / "downloads"

    write_executable(
        fake_bin / "uname",
        """#!/bin/sh
if [ "$1" = "-s" ]; then printf 'Darwin\\n'; else printf 'arm64\\n'; fi
""",
    )
    write_executable(
        fake_bin / "curl",
        """#!/bin/sh
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\\n' "$url" >>"$FIXTURES/downloads"
case "$url" in
  *appcast*.xml)
    if [ -f "$FIXTURES/feed.xml" ]; then cat "$FIXTURES/feed.xml"; else exit 22; fi
    ;;
  */manifest.json)
    cp "$FIXTURES/manifest.json" "$out"
    ;;
  */cmux-tui-aarch64-apple-darwin)
    case "$url" in
      */latest/*) printf 'stale cmux binary fixture\\n' >"$out" ;;
      *) cp "$FIXTURES/binary" "$out" ;;
    esac
    ;;
  *) exit 22 ;;
esac
""",
    )

    install_root = tmp_path / "install"
    argv = ["/bin/sh", str(UNIX_INSTALLER), *(args or [])]
    if script is not None:
        argv = ["/bin/sh", "-s", "--", *(args or [])]
    result = subprocess.run(
        argv,
        cwd=ROOT,
        env={
            **os.environ,
            "CMUX_DOWNLOAD_BASE_URL": base_url,
            "CMUX_INSTALL": str(install_root),
            "FIXTURES": str(tmp_path),
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "SHELL": "/bin/sh",
            **(env or {}),
        },
        check=False,
        capture_output=True,
        **({"input": script} if script is not None else {"stdin": subprocess.DEVNULL}),
        text=True,
    )
    downloaded = downloads.read_text().splitlines() if downloads.exists() else []
    return result, install_root / "bin/cmux", downloaded


def test_unix_installer_selects_verifies_and_installs_native_binary(
    tmp_path: Path,
) -> None:
    result, installed, downloads = run_unix_installer(
        tmp_path, "",
    )

    assert result.returncode == 0, result.stderr
    assert installed.read_bytes() == PAYLOAD
    assert installed.stat().st_mode & stat.S_IXUSR
    assert f"Installed cmux to {installed}" in result.stdout
    assert downloads[:2] == [
        "https://files.cmux.com/cmux-tui/latest/manifest.json",
        f"https://files.cmux.com/cmux-tui/{COMMIT}/cmux-tui-aarch64-apple-darwin",
    ]
    assert sum(url.endswith("/manifest.json") for url in downloads) == 1


def test_install_scripts_are_public_and_checksum_verified() -> None:
    unix = UNIX_INSTALLER.read_text()
    windows = WINDOWS_INSTALLER.read_text()

    assert "checksum verification failed" in unix
    assert '"commit"' in unix
    assert "artifact_base_url" in unix
    assert "release manifest" not in unix
    assert "cmux-tui-x86_64-pc-windows-gnu.exe" in windows
    assert "Get-FileHash" in windows
    assert "$Manifest.commit" in windows
    assert "$ArtifactBaseUrl" in windows
    assert "SetEnvironmentVariable" in windows
    assert "SecurityProtocolType]::Tls12" in windows
    assert "release manifest" not in windows


def test_unix_installer_has_valid_shell_syntax() -> None:
    subprocess.run(["/bin/sh", "-n", str(UNIX_INSTALLER)], check=True)


def test_unix_installer_preserves_overrides_and_trims_trailing_slashes() -> None:
    for suffix in (COMMIT, "mirror", "latest/"):
        with tempfile.TemporaryDirectory() as directory:
            base_url = f"https://fixtures.invalid/cmux-tui/{suffix}"
            result, installed, downloads = run_unix_installer(Path(directory), base_url)
            assert result.returncode == 0, result.stderr
            assert installed.read_bytes() == PAYLOAD
            artifact_base = base_url.rstrip("/")
            if suffix == "latest/":
                artifact_base = f"https://fixtures.invalid/cmux-tui/{COMMIT}"
            assert downloads[1] == f"{artifact_base}/cmux-tui-aarch64-apple-darwin"


def test_unix_installer_rejects_missing_or_invalid_commit_before_binary_download() -> None:
    for commit in (None, "", "b" * 39, "g" * 40, "../escape"):
        with tempfile.TemporaryDirectory() as directory:
            result, installed, downloads = run_unix_installer(
                Path(directory), "https://fixtures.invalid/cmux-tui/latest", commit,
            )
            assert result.returncode != 0
            assert "manifest has no commit" in result.stderr
            assert not installed.exists()
            assert len(downloads) == 1


def test_unix_installer_rejects_wrong_commit_binary_checksum() -> None:
    with tempfile.TemporaryDirectory() as directory:
        result, installed, _ = run_unix_installer(
            Path(directory), "https://fixtures.invalid/cmux-tui/latest", payload=b"wrong binary\n",
        )
        assert result.returncode != 0
        assert "checksum verification failed" in result.stderr
        assert not installed.exists()


# A cmux that records how it was run, one line per run in each log: its
# arguments, its stdin, and whether CMUX_JOIN_TICKET reached its environment.
RECORDING_CMUX = b"""#!/bin/sh
printf '%s\\n' "$*" >>"$FIXTURES/cmux-runs"
printf '%s\\n' "$(cat)" >>"$FIXTURES/cmux-stdin"
printf '%s\\n' "${CMUX_JOIN_TICKET-unset}" >>"$FIXTURES/cmux-env"
"""
TICKET = "cmxt1.eyJ2IjoxfQ"


def runs(directory: Path, log: str = "cmux-runs") -> list[str]:
    path = directory / log
    return path.read_text().splitlines() if path.exists() else []


def test_unix_installer_joins_with_a_pasted_ticket() -> None:
    # `sh -s -- <ticket>`, `--join <ticket>` and CMUX_JOIN_TICKET all join,
    # with --serve unless CMUX_HOST already turned hosting on, and pass
    # `--advertise` / CMUX_JOIN_ADVERTISE through. The ticket reaches
    # `cmux host join` on stdin: never in a cmux's argv (`ps`), never in
    # its environment. The argv forms warn once, without the ticket.
    cases = [
        ([TICKET], {}, ["host join --serve"]),
        (["--join", TICKET], {}, ["host join --serve"]),
        ([f"--join={TICKET}"], {}, ["host join --serve"]),
        ([], {"CMUX_JOIN_TICKET": TICKET}, ["host join --serve"]),
        ([], {"CMUX_JOIN_TICKET": TICKET, "CMUX_HOST": "1"}, ["host enable", "host join"]),
        ([TICKET], {"CMUX_HOST": "1"}, ["host enable", "host join"]),
        ([TICKET], {"CMUX_HOST": "0"}, ["host join"]),
        # A daemon-role ticket: the address the other machine dials this one at.
        (
            [TICKET, "--advertise", "wss://new.example/acp"],
            {},
            ["host join --serve --advertise wss://new.example/acp"],
        ),
        (
            ["--advertise=wss://new.example/acp", TICKET],
            {"CMUX_HOST": "0"},
            ["host join --advertise wss://new.example/acp"],
        ),
        (
            [TICKET],
            {"CMUX_JOIN_ADVERTISE": "wss://new.example/acp"},
            ["host join --serve --advertise wss://new.example/acp"],
        ),
        ([], {}, []),
    ]
    warning = "a ticket on the command line is readable by other users"
    for args, env, expected in cases:
        with tempfile.TemporaryDirectory() as directory:
            result, installed, _ = run_unix_installer(
                Path(directory), "https://fixtures.invalid/cmux-tui/latest",
                args=args, env=env, binary=RECORDING_CMUX,
            )
            assert result.returncode == 0, (args, env, result.stderr)
            assert installed.exists()
            argv = runs(Path(directory))
            assert argv == expected, (args, env, argv)
            assert not any(TICKET in line for line in argv), (args, env, argv)
            stdins = runs(Path(directory), "cmux-stdin")
            joined = [i for i, line in enumerate(argv) if line.startswith("host join")]
            assert [stdins[i] for i in joined] == [TICKET] * len(joined), (args, env, stdins)
            assert all(stdins[i] == "" for i in range(len(argv)) if i not in joined), stdins
            assert set(runs(Path(directory), "cmux-env")) <= {"unset"}, (args, env)
            in_argv = any(a == TICKET or a.endswith(TICKET) for a in args)
            assert result.stderr.count(warning) == (1 if in_argv else 0), (args, result.stderr)
            assert TICKET not in result.stderr + result.stdout, (args, env)


def test_unix_installer_refuses_an_unknown_argument_before_downloading() -> None:
    with tempfile.TemporaryDirectory() as directory:
        result, installed, downloads = run_unix_installer(
            Path(directory), "https://fixtures.invalid/cmux-tui/latest",
            args=["not-a-ticket"],
        )
        assert result.returncode == 2
        assert "unknown argument" in result.stderr
        assert not installed.exists()
        assert downloads == []


def test_unix_installer_fails_when_the_join_fails() -> None:
    failing = b"#!/bin/sh\ncase \"$*\" in *join*) exit 1 ;; esac\n"
    with tempfile.TemporaryDirectory() as directory:
        result, installed, _ = run_unix_installer(
            Path(directory), "https://fixtures.invalid/cmux-tui/latest",
            args=[TICKET], binary=failing,
        )
        assert result.returncode == 1
        assert installed.exists()
        assert "did not join" in result.stderr


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as directory:
        test_unix_installer_selects_verifies_and_installs_native_binary(Path(directory))
    test_install_scripts_are_public_and_checksum_verified()
    test_unix_installer_has_valid_shell_syntax()
    test_unix_installer_preserves_overrides_and_trims_trailing_slashes()
    test_unix_installer_rejects_missing_or_invalid_commit_before_binary_download()
    test_unix_installer_rejects_wrong_commit_binary_checksum()
    test_unix_installer_joins_with_a_pasted_ticket()
    test_unix_installer_refuses_an_unknown_argument_before_downloading()
    test_unix_installer_fails_when_the_join_fails()
    print("cmux-tui installer tests passed")


# cmux server (`--server`): the service step after the verified install.
NIGHTLY = "c" * 40
FEED = f"""<?xml version="1.0"?><rss xmlns:cmux="https://cmux.com/xml-namespaces/cmux"><channel>
<item><cmux:sourceCommit xmlns:cmux="https://cmux.com/xml-namespaces/cmux">{NIGHTLY}</cmux:sourceCommit></item>
<item><cmux:sourceCommit>{"d" * 40}</cmux:sourceCommit></item>
</channel></rss>
"""


def test_unix_installer_server_installs_the_nightly_build_then_the_service() -> None:
    # No base URL and no --commit: --server reads the current NIGHTLY commit
    # from the first cmux:sourceCommit of the feed, installs that published
    # build (checksum-verified), then runs `cmux server install`.
    with tempfile.TemporaryDirectory() as directory:
        tmp = Path(directory)
        (tmp / "feed.xml").write_text(FEED)
        result, installed, downloads = run_unix_installer(
            tmp, "", args=["--server"], binary=RECORDING_CMUX,
            env={"CMUX_DOWNLOAD_BASE_URL": ""},
        )
        assert result.returncode == 0, result.stderr
        assert installed.read_bytes() == RECORDING_CMUX
        assert downloads[0].endswith("appcast-arm64.xml")
        assert downloads[1] == f"https://files.cmux.com/cmux-tui/{NIGHTLY}/manifest.json"
        assert downloads[2] == f"https://files.cmux.com/cmux-tui/{NIGHTLY}/cmux-tui-aarch64-apple-darwin"
        assert runs(tmp) == ["server install"]


def test_unix_installer_server_takes_a_pinned_commit() -> None:
    with tempfile.TemporaryDirectory() as directory:
        tmp = Path(directory)
        result, _, downloads = run_unix_installer(
            tmp, "", args=["--commit", COMMIT, "--server"], binary=RECORDING_CMUX,
            env={"CMUX_DOWNLOAD_BASE_URL": ""},
        )
        assert result.returncode == 0, result.stderr
        assert downloads[0] == f"https://files.cmux.com/cmux-tui/{COMMIT}/manifest.json"
        assert not any("appcast" in url for url in downloads)
        assert runs(tmp) == ["server install"]


def test_unix_installer_without_server_runs_no_service_step() -> None:
    with tempfile.TemporaryDirectory() as directory:
        tmp = Path(directory)
        result, _, _ = run_unix_installer(
            tmp, "https://fixtures.invalid/cmux-tui/latest", binary=RECORDING_CMUX,
        )
        assert result.returncode == 0, result.stderr
        assert runs(tmp) == []


def test_unix_installer_server_failure_names_the_command_to_rerun() -> None:
    failing = RECORDING_CMUX + b"exit 4\n"
    with tempfile.TemporaryDirectory() as directory:
        tmp = Path(directory)
        result, installed, _ = run_unix_installer(
            tmp, f"https://fixtures.invalid/cmux-tui/{COMMIT}", args=["--server"], binary=failing,
        )
        assert result.returncode == 1
        assert installed.exists()
        assert f"then run: {installed} server install" in result.stderr


def test_unix_installer_rejects_bad_commits_and_unreadable_feeds() -> None:
    for args in (["--commit", "abc"], ["--commit", "G" * 40], ["--commit"], ["--commit=../x"]):
        with tempfile.TemporaryDirectory() as directory:
            result, installed, downloads = run_unix_installer(
                Path(directory), "", args=args, env={"CMUX_DOWNLOAD_BASE_URL": ""},
            )
            assert result.returncode == 2, (args, result.stderr)
            assert not installed.exists()
            assert downloads == []
    with tempfile.TemporaryDirectory() as directory:
        result, installed, downloads = run_unix_installer(
            Path(directory), "", args=["--server"], env={"CMUX_DOWNLOAD_BASE_URL": ""},
        )
        assert result.returncode == 1
        assert "--commit <sha>" in result.stderr
        assert not installed.exists()
        assert len(downloads) == 1


def test_unix_installer_dry_run_changes_nothing() -> None:
    with tempfile.TemporaryDirectory() as directory:
        tmp = Path(directory)
        result, installed, downloads = run_unix_installer(
            tmp, f"https://fixtures.invalid/cmux-tui/{COMMIT}", args=["--server", "--dry-run"],
            binary=RECORDING_CMUX,
        )
        assert result.returncode == 0, result.stderr
        assert "Would run:" in result.stdout and "server install" in result.stdout
        assert not installed.exists()
        assert downloads == []
        assert runs(tmp) == []


def test_unix_installer_cut_short_runs_nothing() -> None:
    # A download cut short (curl | sh, or the ssh:// install's stdin) must
    # run no line of the script: no download, no install, no service.
    text = UNIX_INSTALLER.read_text()
    whole_lines = [i + 1 for i, ch in enumerate(text) if ch == "\n"]
    # Every cut drops at least the closing brace (the text ends with "}\n").
    cuts = sorted({len(text) // 4, len(text) // 2, 3 * len(text) // 4, len(text) - 2,
                   *whole_lines[5:-1:7]})
    for cut in cuts:
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            result, installed, downloads = run_unix_installer(
                tmp, f"https://fixtures.invalid/cmux-tui/{COMMIT}", args=["--server"],
                binary=RECORDING_CMUX, script=text[:cut],
            )
            assert result.returncode != 0, (cut, result.stdout)
            assert downloads == [], (cut, downloads)
            assert not installed.exists(), cut
            assert runs(tmp) == [], cut
    # The whole script still runs from stdin.
    with tempfile.TemporaryDirectory() as directory:
        tmp = Path(directory)
        result, installed, _ = run_unix_installer(
            tmp, f"https://fixtures.invalid/cmux-tui/{COMMIT}", args=["--server"],
            binary=RECORDING_CMUX, script=text,
        )
        assert result.returncode == 0, result.stderr
        assert installed.exists()
        assert runs(tmp) == ["server install"]


def test_unix_installer_user_passes_user_to_the_service_step() -> None:
    with tempfile.TemporaryDirectory() as directory:
        tmp = Path(directory)
        result, _, _ = run_unix_installer(
            tmp, f"https://fixtures.invalid/cmux-tui/{COMMIT}", args=["--user"],
            binary=RECORDING_CMUX,
        )
        assert result.returncode == 0, result.stderr
        assert runs(tmp) == ["server install --user"]


def test_unix_installer_channel_picks_stable_or_nightly() -> None:
    with tempfile.TemporaryDirectory() as directory:
        tmp = Path(directory)
        (tmp / "feed.xml").write_text(FEED)
        result, _, downloads = run_unix_installer(
            tmp, "", args=["--channel", "nightly", "--server"], binary=RECORDING_CMUX,
            env={"CMUX_DOWNLOAD_BASE_URL": ""},
        )
        assert result.returncode == 0, result.stderr
        assert downloads[1] == f"https://files.cmux.com/cmux-tui/{NIGHTLY}/manifest.json"
    with tempfile.TemporaryDirectory() as directory:
        tmp = Path(directory)
        (tmp / "feed.xml").write_text(FEED)
        result, _, downloads = run_unix_installer(
            tmp, "", args=["--channel=stable", "--server"], env={"CMUX_DOWNLOAD_BASE_URL": ""},
        )
        assert not any("appcast" in url for url in downloads), downloads
        assert downloads[0] == "https://files.cmux.com/cmux-tui/latest/manifest.json"
    for args in (["--channel", "beta"], ["--channel"], ["--channel", "stable", "--nightly"],
                 ["--channel=stable", "--commit", COMMIT]):
        with tempfile.TemporaryDirectory() as directory:
            result, installed, downloads = run_unix_installer(
                Path(directory), "", args=args, env={"CMUX_DOWNLOAD_BASE_URL": ""},
            )
            assert result.returncode == 2, (args, result.stderr)
            assert downloads == [] and not installed.exists(), args


def test_unix_installer_downloads_stay_on_https_through_redirects() -> None:
    # `--proto =https` alone leaves the redirect protocols to curl's default;
    # every request also pins redirects to HTTPS.
    calls = [line for line in UNIX_INSTALLER.read_text().splitlines()
             if line.strip().startswith("curl ") or "| curl " in line or "$(curl " in line
             or line.strip().startswith("curl --")]
    assert len(calls) >= 4, calls
    for line in calls:
        assert "--proto '=https'" in line and "--proto-redir '=https'" in line, line
