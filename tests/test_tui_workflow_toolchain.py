from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui.yml"
RUST_JOBS = (
    "valgrind-leak-check",
    "test",
    "bindings-e2e",
    "windows-experimental",
)


def job_block(workflow: str, job: str) -> str:
    marker = f"\n  {job}:\n"
    remainder = workflow.split(marker, 1)[1]
    next_job = re.search(r"\n  [a-zA-Z0-9_-]+:\n", remainder)
    return remainder[: next_job.start()] if next_job else remainder


def test_tui_rust_jobs_install_the_release_toolchain() -> None:
    workflow = WORKFLOW.read_text()
    assert '\nenv:\n  RUST_TOOLCHAIN: "1.95.0"\n' in workflow

    for job in RUST_JOBS:
        block = job_block(workflow, job)
        assert "rustup toolchain install \"$RUST_TOOLCHAIN\" --profile minimal" in block
        assert "rustup default \"$RUST_TOOLCHAIN\"" in block
        assert "if ! command -v cargo" not in block

    test_job = job_block(workflow, "test")
    assert "--component clippy,rustfmt" in test_job
