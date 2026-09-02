from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui.yml"


def test_focused_filter_rejects_ignored_only_matches() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")

    assert 'if [[ ! -s "$normal_names" && -s "$ignored_names" ]]; then' in workflow
    assert 'if [[ -s "$normal_names" && -s "$ignored_names" ]] && cmp -s' not in workflow
