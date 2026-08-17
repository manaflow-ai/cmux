from __future__ import annotations

import importlib.util
import os
import pty
import select
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import types

import yaml


ROOT = Path(__file__).resolve().parents[1]
LINUX_SCRIPT = ROOT / "cmux-tui/dist/scripts/test_linux_packages.py"
MACOS_SCRIPT = ROOT / "cmux-tui/dist/scripts/test_macos_packages.py"
PACKAGE_WORKFLOW = ROOT / ".github/workflows/cmux-tui-build-package.yml"
TUI_WORKFLOW = ROOT / ".github/workflows/cmux-tui.yml"
RELEASE_WORKFLOWS = (
    ROOT / ".github/workflows/cmux-tui-nightly.yml",
    ROOT / ".github/workflows/cmux-tui-release.yml",
)


def load_script(path: Path, name: str):
    assert path.is_file(), f"missing runtime coverage script: {path}"
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_macos_wheel_selector_covers_both_supported_architectures() -> None:
    script = load_script(MACOS_SCRIPT, "test_macos_packages")

    assert script.wheel_name("1.2.3", "arm64") == (
        "cmux-1.2.3-py3-none-macosx_11_0_arm64.whl"
    )
    assert script.wheel_name("1.2.3", "x64") == (
        "cmux-1.2.3-py3-none-macosx_10_12_x86_64.whl"
    )


def test_linux_matrix_checks_the_manylinux2014_glibc_floor() -> None:
    script = load_script(LINUX_SCRIPT, "test_linux_packages")

    for architecture, image_prefix in (
        ("x64", "quay.io/pypa/manylinux2014_x86_64"),
        ("arm64", "quay.io/pypa/manylinux2014_aarch64"),
    ):
        image = script.manylinux_image(architecture)[1]
        assert image.startswith(image_prefix)
        assert "@sha256:" in image
    assert script.manylinux_wheel_tag("x64") == (
        "manylinux_2_17_x86_64.manylinux2014_x86_64"
    )
    assert script.manylinux_wheel_tag("arm64") == (
        "manylinux_2_17_aarch64.manylinux2014_aarch64"
    )
    assert "GNU_LIBC_VERSION" in script.MANYLINUX_GLIBC_FLOOR_CHECK
    assert "2.17" in script.MANYLINUX_GLIBC_FLOOR_CHECK


def test_package_workflow_has_fail_closed_macos_wheel_job() -> None:
    document = yaml.safe_load(PACKAGE_WORKFLOW.read_text())
    jobs = document["jobs"]
    job = jobs["verify-macos-wheels"]
    runners = {entry["runner"] for entry in job["strategy"]["matrix"]["include"]}
    architectures = {
        entry["architecture"] for entry in job["strategy"]["matrix"]["include"]
    }
    assert runners == {"macos-14", "macos-15-intel"}
    assert architectures == {"arm64", "x64"}
    assert job["needs"] == "package"
    assert job["if"] == "${{ inputs.package_pypi }}"
    assert "test_macos_packages.py" in str(job)


def test_release_callers_enable_the_wheel_runtime_gate() -> None:
    for path in RELEASE_WORKFLOWS:
        document = yaml.safe_load(path.read_text())
        build = document["jobs"]["build-package"]
        assert build["uses"] == "./.github/workflows/cmux-tui-build-package.yml"
        assert build["with"]["package_pypi"] is True
        assert build["with"].get("verify_linux_arm64", True) is not False


def test_crossterm_parser_step_removes_no_color_from_child_process() -> None:
    """Exercise the parser step's shell contract without building Rust."""

    document = yaml.load(TUI_WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    steps = document["jobs"]["test"]["steps"]
    parser_steps = [step for step in steps if step.get("name") == "crossterm parser tests"]
    assert len(parser_steps) == 1
    parser_step = parser_steps[0]
    command = parser_step["run"]
    assert "-- --test-threads=1" in command

    with tempfile.TemporaryDirectory(prefix="tui-no-color-contract-") as directory:
        fake_cargo = Path(directory) / "cargo"
        fake_cargo.write_text(
            "#!/usr/bin/env bash\n"
            "if [[ -v NO_COLOR ]]; then\n"
            "  echo 'NO_COLOR remained in parser child environment' >&2\n"
            "  exit 1\n"
            "fi\n",
            encoding="utf-8",
        )
        fake_cargo.chmod(0o755)
        environment = os.environ.copy()
        environment["NO_COLOR"] = "1"
        environment["PATH"] = f"{directory}:{environment['PATH']}"
        result = subprocess.run(
            ["bash", "-c", command],
            cwd=ROOT / "cmux-tui",
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )

    assert result.returncode == 0, result.stderr


def test_cdp_smoke_step_rejects_a_zero_test_selection() -> None:
    """The full CDP gate must fail before running an empty exact filter."""

    document = yaml.load(TUI_WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    steps = document["jobs"]["cdp-browser-smoke"]["steps"]
    smoke_steps = [
        step for step in steps if step.get("name") == "Run configured Chrome CDP smoke"
    ]
    assert len(smoke_steps) == 1
    command = smoke_steps[0]["run"]
    assert "--list" in command
    assert "grep -Eq ': test$'" in command
    assert "--ignored --exact chrome_smoke_requires_configured_browser" in command


def test_windows_launch_step_rejects_zero_test_filters() -> None:
    """Windows launch coverage must not disappear after a test rename."""

    document = yaml.load(PACKAGE_WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    steps = document["jobs"]["build-windows"]["steps"]
    launch_steps = [step for step in steps if step.get("name") == "Test Windows launch behavior"]
    assert len(launch_steps) == 1
    command = launch_steps[0]["run"]
    assert command.count("-- --list") == 2
    assert "grep -Eq ': test$'" in command
    assert "ghostty-windows-launch.txt" in command
    assert "cmux-windows-launch.txt" in command


def test_conpty_reader_does_not_retain_unbounded_post_startup_output() -> None:
    """The startup marker must survive, while later PTY noise cannot grow memory."""

    smoke_path = ROOT / "cmux-tui/scripts/smoke-windows-conpty-resize.py"
    module_name = "cmux_tui_conpty_resize_smoke_for_contract_test"
    winpty_stub = types.ModuleType("winpty")
    winpty_stub.PtyProcess = object
    previous_winpty = sys.modules.get("winpty")
    sys.modules["winpty"] = winpty_stub
    try:
        spec = importlib.util.spec_from_file_location(module_name, smoke_path)
        assert spec is not None and spec.loader is not None
        smoke = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(smoke)
    finally:
        if previous_winpty is None:
            sys.modules.pop("winpty", None)
        else:
            sys.modules["winpty"] = previous_winpty

    startup = smoke.CONPTY_STARTUP_PREFIX_WITH_VISIBILITY + "\x1b[>1s"

    class NoisyPty:
        def __init__(self) -> None:
            self._startup = True
            self._release_noise = threading.Event()
            self.noise_requested = threading.Event()
            self.eof = threading.Event()
            self.noise_reads = 0

        def read(self, _size: int) -> str:
            if self._startup:
                self._startup = False
                return startup
            self.noise_requested.set()
            self._release_noise.wait()
            self.noise_reads += 1
            if self.noise_reads > 128:
                self.eof.set()
                return ""
            return "N" * 8192

    pty = NoisyPty()
    reader = smoke.start_output_reader(pty)
    assert pty.noise_requested.wait(timeout=2), "reader did not reach post-marker output"
    output = smoke.wait_for_tui_start(reader)
    pty._release_noise.set()

    reader.close()

    assert output == startup
    assert reader.qsize() <= 64, f"pending PTY chunks grew to {reader.qsize()}"
    assert len(reader.tail) <= 8


def test_conpty_reader_close_returns_when_pty_read_is_blocked() -> None:
    """Teardown must not hang the workflow when the PTY read ignores stop."""

    smoke_path = ROOT / "cmux-tui/scripts/smoke-windows-conpty-resize.py"
    module_name = "cmux_tui_conpty_resize_close_contract_test"
    winpty_stub = types.ModuleType("winpty")
    winpty_stub.PtyProcess = object
    previous_winpty = sys.modules.get("winpty")
    sys.modules["winpty"] = winpty_stub
    try:
        spec = importlib.util.spec_from_file_location(module_name, smoke_path)
        assert spec is not None and spec.loader is not None
        smoke = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(smoke)
        smoke.TIMEOUT_SECONDS = 0.1
    finally:
        if previous_winpty is None:
            sys.modules.pop("winpty", None)
        else:
            sys.modules["winpty"] = previous_winpty

    class BlockingPty:
        def __init__(self) -> None:
            self.entered = threading.Event()
            self.release = threading.Event()

        def read(self, _size: int) -> str:
            self.entered.set()
            self.release.wait()
            return ""

    blocked = BlockingPty()
    reader = smoke.start_output_reader(blocked)
    assert blocked.entered.wait(timeout=2), "reader did not enter the blocking PTY read"
    finished = threading.Event()
    closer = threading.Thread(target=lambda: (reader.close(), finished.set()))
    closer.start()
    try:
        assert finished.wait(timeout=1), "reader.close() waited forever for PTY EOF"
    finally:
        blocked.release.set()
        closer.join(timeout=2)


def test_smoke_osc_probe_round_trips_a_terminal_reply() -> None:
    """The OSC probe must run as one command and consume the terminal reply."""

    probe_path = ROOT / "cmux-tui/scripts/smoke_tui_probe.py"
    module = load_script(probe_path, "cmux_tui_smoke_probe_for_contract_test")
    with tempfile.TemporaryDirectory(prefix="tui-osc-probe-contract-") as directory:
        script_path = module.write_osc_probe_script(directory)
        master_fd, slave_fd = pty.openpty()
        environment = os.environ.copy()
        environment["CMUX_TUI_SMOKE_TTY"] = os.ttyname(slave_fd)
        command = module.osc_probe_command(script_path)
        assert "\n" not in command
        process = subprocess.Popen(
            ["/bin/sh", "-c", command],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            readable, _, _ = select.select([master_fd], [], [], 2)
            assert readable, "OSC probe did not query the terminal"
            query = os.read(master_fd, 1024)
            assert b"\x1b]11;?\x1b\\" in query
            os.write(master_fd, b"\x1b]11;rgb:1313/1414/1515\x1b\\")
            stdout, stderr = process.communicate(timeout=2)
            assert process.returncode == 0, stderr
            assert "1313/1414/1515" in stdout
            assert "cmux-tui-osc-probe-complete" in stdout
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=2)
            os.close(slave_fd)
            os.close(master_fd)


def main() -> None:
    test_macos_wheel_selector_covers_both_supported_architectures()
    test_linux_matrix_checks_the_manylinux2014_glibc_floor()
    test_package_workflow_has_fail_closed_macos_wheel_job()
    test_release_callers_enable_the_wheel_runtime_gate()
    test_crossterm_parser_step_removes_no_color_from_child_process()
    test_cdp_smoke_step_rejects_a_zero_test_selection()
    test_windows_launch_step_rejects_zero_test_filters()
    test_conpty_reader_does_not_retain_unbounded_post_startup_output()
    test_smoke_osc_probe_round_trips_a_terminal_reply()


if __name__ == "__main__":
    main()
