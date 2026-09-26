from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_claude_hook_settings_include_agent_pane_middleware() -> None:
    source = (ROOT / "CLI/CMUXCLI+ClaudeHookSettings.swift").read_text(encoding="utf-8")
    assert 'matcher: "Task|Agent"' in source
    assert 'hooks claude agent-pane' in source


if __name__ == "__main__":
    test_claude_hook_settings_include_agent_pane_middleware()
    print("PASS: Claude agent-pane hook contract")
