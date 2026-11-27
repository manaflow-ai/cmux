use super::*;
use crate::workspace_registry::WorkspaceRegistry;
use crate::{Mux, SurfaceOptions};

/// W3-H: the last reply stays after its banner dropped it, folded and cut for
/// `extra.last_reply`, and only the agent value of its terminal carries it.
#[test]
fn w3h_last_reply_outlives_the_banner_and_rides_on_the_agent_value() {
    let root = std::env::temp_dir()
        .join(format!("cmux-last-reply-{}", crate::workspace_registry::new_uuid_v4()));
    let registry = WorkspaceRegistry::open(&root, "last-reply").unwrap();
    let mux = Mux::from_workspace_registry(
        "last-reply".to_owned(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal = surface.terminal_public_id().cloned().unwrap();
    assert!(mux.agent_last_replies().is_empty());

    assert!(mux.note_agent_reply(&terminal, "Done.\n\n  ALPHA_OK").is_some());
    // The append ends: whatever the banner did not take is dropped.
    mux.forget_agent_reply(&terminal);
    let replies = mux.agent_last_replies();
    assert_eq!(replies.get(terminal.as_str()).map(String::as_str), Some("Done. ALPHA_OK"));

    let long = "word ".repeat(200);
    assert!(mux.note_agent_reply(&terminal, &long).is_some());
    let kept = mux.agent_last_replies().remove(terminal.as_str()).unwrap();
    assert!(kept.chars().count() <= crate::agent_hooks::LIVE_PROMPT_CHARS, "{kept}");

    let agent = serde_json::json!({"terminal_id": terminal.as_str(), "extra": {"agent": "claude"}});
    let shown = with_last_reply(agent, &mux.agent_last_replies());
    assert_eq!(shown["extra"]["last_reply"], kept);
    let other = serde_json::json!({"terminal_id": "term_other", "extra": {}});
    assert!(with_last_reply(other, &replies)["extra"].get("last_reply").is_none());
    let _ = std::fs::remove_dir_all(root);
}
