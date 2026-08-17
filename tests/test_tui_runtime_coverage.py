from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile

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


def main() -> None:
    test_macos_wheel_selector_covers_both_supported_architectures()
    test_linux_matrix_checks_the_manylinux2014_glibc_floor()
    test_package_workflow_has_fail_closed_macos_wheel_job()
    test_release_callers_enable_the_wheel_runtime_gate()
    test_crossterm_parser_step_removes_no_color_from_child_process()


if __name__ == "__main__":
    main()
