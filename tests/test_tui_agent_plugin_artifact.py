from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_focused_hosted_build_publishes_the_userland_detector() -> None:
    build = (ROOT / ".github/workflows/cmux-tui-build-package.yml").read_text()
    verification = (ROOT / ".github/workflows/cmux-tui.yml").read_text()
    downloader = (ROOT / "scripts/verify-cmux-tui-hosted.sh").read_text()

    assert "build_agent_plugin:" in build
    assert "Build agent screen-detection plugin" in build
    assert "cmux-agent-screen-detection-${{ matrix.target }}" in build
    assert "Upload agent screen-detection plugin artifact" in build

    build_artifacts = verification.split("  build-artifacts:\n", 1)[1].split(
        "\n  hosted-verification:\n", 1
    )[0]
    assert "build_agent_plugin: true" in build_artifacts

    assert "cmux-agent-screen-detection-aarch64-apple-darwin" in downloader
    assert "Artifact: $artifact_dir/cmux-agent-screen-detection" in downloader

