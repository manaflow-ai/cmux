#!/usr/bin/env python3
"""Keep the trusted complexity workflow isolated from candidate Bun config."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "web-complexity-trusted.yml"


def main() -> None:
    text = WORKFLOW.read_text(encoding="utf-8")
    assert "  merge_group:" in text
    assert ".bunfig-empty.toml" in text
    assert text.count("--no-env-file") == 3
    assert text.count("--config \"$GITHUB_WORKSPACE/trusted/.bunfig-empty.toml\"") == 3

    marker = "      - name: Check pull-request or merge-group source with trusted policy"
    start = text.index(marker)
    end = text.index("\n      - name:", start + len(marker))
    step = text[start:end]
    assert "        working-directory: trusted/web" in step
    run = step
    assert "candidate/web" not in run
    assert "trusted/web/scripts/check-complexity.mjs" not in run
    assert "--repo-root \"$GITHUB_WORKSPACE/candidate\"" in run


if __name__ == "__main__":
    main()
    print("PASS: trusted web complexity runs with an explicit empty Bun config")
