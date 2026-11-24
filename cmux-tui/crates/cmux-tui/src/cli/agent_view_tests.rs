use super::*;

const ID: &str = "0199f0a2-7c3e-7d41-9b8a-2f6c1d4e5a6b";

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn agent_view_takes_a_chat_key_path_or_id() {
    let none: Option<&Path> = None;
    assert_eq!(chat_key(&format!("codex:{ID}"), none), Some(format!("codex:{ID}")));
    assert_eq!(
        chat_key(&format!("/Users/me/.claude/projects/-src-app/{ID}.jsonl"), none),
        Some(format!("claude-code:{ID}"))
    );
    assert_eq!(
        chat_key(&format!("sessions/2026/10/18/rollout-2026-10-18T09-00-00-{ID}.jsonl"), none),
        Some(format!("codex:{ID}"))
    );
    // A bare id is Claude Code's when its transcript is under ~/.claude/projects.
    let root = std::env::temp_dir().join(format!("cmux-agent-view-{}", std::process::id()));
    std::fs::create_dir_all(root.join("-src-app")).unwrap();
    assert_eq!(chat_key(ID, Some(&root)), Some(format!("codex:{ID}")));
    std::fs::write(root.join(format!("-src-app/{ID}.jsonl")), "").unwrap();
    assert_eq!(chat_key(ID, Some(&root)), Some(format!("claude-code:{ID}")));
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn sidebar_view_verbs_are_not_chats() {
    for verb in ["show", "ensure", "attach", "input", "resize", "reload", "opencode:abc"] {
        assert_eq!(action(&words(&format!("agent view {verb}"))), None, "{verb}");
    }
    assert_eq!(action(&words("agent view --key codex:x")), None);
    assert_eq!(
        action(&words(&format!("agent view codex:{ID} --no-wait"))),
        Some((ACTION.to_owned(), words(&format!("--key codex:{ID} --no-wait"))))
    );
}
