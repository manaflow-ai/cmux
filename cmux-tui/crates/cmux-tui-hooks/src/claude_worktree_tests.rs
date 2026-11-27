//! Claude Code runs a `WorktreeCreate` hook instead of `git worktree add` and
//! reads the new path from its stdout, and skips its own `git worktree remove`
//! when a `WorktreeRemove` hook exits 0, so cmux-tui installs neither.

use super::tests::context;
use super::*;

#[cfg(unix)]
#[test]
fn cmux_next_claude_hooks_leave_worktree_handling_to_claude_code() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let config = context.home.join(".claude/settings.json");
    let journal = |event: &str| {
        json!({"hooks": [{
            "type": "command",
            "command": hook_command("claude", event),
            "timeout": COMMAND_HOOK_TIMEOUT_SECONDS,
            "async": true,
        }]})
    };
    let own = json!({"hooks": [{"type": "command", "command": "jj-worktree-create"}]});
    let settings = json!({"hooks": {
        "WorktreeCreate": [journal("WorktreeCreate"), own],
        "WorktreeRemove": [journal("WorktreeRemove")],
    }});
    atomic_write(&config, &serde_json::to_vec(&settings).unwrap(), Some(0o600)).unwrap();

    let install = Plan { action: Action::Install, providers: vec!["claude".into()] };
    let result = run_with_context(&install, &context);
    assert!(!result.failed, "{}", result.value);

    let installed: Value = serde_json::from_slice(&fs::read(&config).unwrap()).unwrap();
    assert_eq!(installed["hooks"]["WorktreeCreate"], json!([own]));
    assert!(installed["hooks"].get("WorktreeRemove").is_none(), "{}", installed["hooks"]);
    let session = claude_session_hook_settings(None).unwrap();
    for event in ["WorktreeCreate", "WorktreeRemove"] {
        assert!(session["hooks"].get(event).is_none(), "{event}: {:?}", session["hooks"]);
    }
}
