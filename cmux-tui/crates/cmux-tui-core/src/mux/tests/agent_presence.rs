//! Live agent presence: hook journal events in, `AgentPresenceChanged` out.

use super::*;

fn hook(
    source: &str,
    terminal_id: &TerminalPublicId,
    event: &str,
    native: Value,
) -> crate::JournalIngress {
    crate::agent_hooks::agent_hook_journal_ingress(
        source,
        event,
        Some(&terminal_id.to_string()),
        native,
    )
    .unwrap()
}

/// The next presence change on `events`, skipping every other event.
fn next_presence(events: &MuxEventReceiver, surface: SurfaceId) -> Option<AgentPresence> {
    loop {
        match events.recv_timeout(Duration::from_millis(500)) {
            Ok(MuxEvent::AgentPresenceChanged { surface: changed, presence })
                if changed == surface =>
            {
                return presence.as_deref().cloned();
            }
            Ok(_) => continue,
            Err(error) => panic!("no agent-presence-changed event: {error:?}"),
        }
    }
}

/// A Claude turn: the edit's file and the read's line reach presence, the
/// post-tool event keeps the target while the agent thinks, and the turn's
/// end clears it. Tool input other than the target stays redacted.
#[test]
fn claude_tool_calls_drive_presence_through_a_turn() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let events = mux.subscribe();
    let append = |event: &str, key: &str, native: Value| {
        mux.append_journal_ingress(&hook("claude", &terminal_id, event, native), "test", key)
            .unwrap();
    };
    let session = serde_json::json!("claude-session-1");

    append(
        "UserPromptSubmit",
        "p-1",
        serde_json::json!({"session_id": session, "prompt": "fix it"}),
    );
    let presence = next_presence(&events, surface.id).unwrap();
    assert_eq!(presence.activity, AgentActivity::Thinking);
    assert_eq!(presence.agent.as_deref(), Some("claude"));
    assert_eq!(presence.session.as_deref(), Some("claude-session-1"));

    append(
        "PreToolUse",
        "p-2",
        serde_json::json!({
            "session_id": session,
            "tool_name": "Edit",
            "tool_input": {"file_path": "/repo/src/app.rs", "old_string": "secret", "new_string": "x"},
        }),
    );
    let presence = next_presence(&events, surface.id).unwrap();
    assert_eq!(presence.activity, AgentActivity::Editing);
    assert_eq!(presence.tool.as_deref(), Some("Edit"));
    assert_eq!(presence.path.as_deref(), Some("/repo/src/app.rs"));
    assert_eq!(presence.line, None);

    append(
        "PostToolUse",
        "p-3",
        serde_json::json!({"session_id": session, "tool_name": "Edit", "tool_input": {"file_path": "/repo/src/app.rs"}}),
    );
    let presence = next_presence(&events, surface.id).unwrap();
    assert_eq!(presence.activity, AgentActivity::Thinking);
    assert_eq!(presence.path.as_deref(), Some("/repo/src/app.rs"));

    append(
        "PreToolUse",
        "p-4",
        serde_json::json!({
            "session_id": session,
            "tool_name": "Read",
            "tool_input": {"file_path": "/repo/src/lib.rs", "offset": 120, "limit": 40},
        }),
    );
    let presence = next_presence(&events, surface.id).unwrap();
    assert_eq!(presence.activity, AgentActivity::Reading);
    assert_eq!(presence.path.as_deref(), Some("/repo/src/lib.rs"));
    assert_eq!(presence.line, Some(120));

    append(
        "PreToolUse",
        "p-5",
        serde_json::json!({"session_id": session, "tool_name": "Bash", "tool_input": {"command": "cargo test"}}),
    );
    let presence = next_presence(&events, surface.id).unwrap();
    assert_eq!(presence.activity, AgentActivity::Running);
    assert_eq!(presence.path, None);

    append("Stop", "p-6", serde_json::json!({"session_id": session}));
    assert_eq!(next_presence(&events, surface.id), None);

    // Only the file target is lifted out of the redacted tool input.
    let journaled = hook(
        "claude",
        &terminal_id,
        "PreToolUse",
        serde_json::json!({"tool_name": "Edit", "tool_input": {"file_path": "/repo/a.rs", "old_string": "secret"}}),
    );
    assert_eq!(journaled.payload["normalized"]["tool_target_path"], "/repo/a.rs");
    assert_eq!(journaled.payload["native"]["tool_input"], "[redacted]");
    assert!(!journaled.payload.to_string().contains("secret"));
}

/// Other harnesses: a Codex `apply_patch` names its file through the patch
/// header, a Gemini tool through `absolute_path`, an MCP computer-use tool
/// and a browser tool by their names, and an approval keeps the target.
#[test]
fn other_harness_tool_calls_map_onto_presence() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let events = mux.subscribe();
    let mut key = 0;
    let mut append = |source: &str, event: &str, native: Value| {
        key += 1;
        mux.append_journal_ingress(
            &hook(source, &terminal_id, event, native),
            "test",
            &format!("k-{key}"),
        )
        .unwrap();
    };

    append(
        "codex",
        "PreToolUse",
        serde_json::json!({
            "session_id": "codex-1",
            "tool_name": "apply_patch",
            "tool_input": {"command": "*** Begin Patch\n*** Update File: src/main.rs\n@@\n-a\n+b\n*** End Patch"},
        }),
    );
    let presence = next_presence(&events, surface.id).unwrap();
    assert_eq!(presence.agent.as_deref(), Some("codex"));
    assert_eq!(presence.activity, AgentActivity::Editing);
    assert_eq!(presence.path.as_deref(), Some("src/main.rs"));

    append("codex", "PermissionRequest", serde_json::json!({"session_id": "codex-1"}));
    let presence = next_presence(&events, surface.id).unwrap();
    assert_eq!(presence.activity, AgentActivity::Waiting);
    assert_eq!(presence.path.as_deref(), Some("src/main.rs"));

    append(
        "gemini",
        "BeforeTool",
        serde_json::json!({"session_id": "gemini-1", "tool_name": "read_file", "tool_input": {"absolute_path": "/g/x.py"}}),
    );
    let presence = next_presence(&events, surface.id).unwrap();
    assert_eq!(presence.activity, AgentActivity::Reading);
    assert_eq!(presence.path.as_deref(), Some("/g/x.py"));

    append(
        "claude",
        "PreToolUse",
        serde_json::json!({"tool_name": "mcp__cmux-cua__click", "tool_input": {"x": 10, "y": 20}}),
    );
    assert_eq!(next_presence(&events, surface.id).unwrap().activity, AgentActivity::ComputerUse);

    append(
        "claude",
        "PreToolUse",
        serde_json::json!({"tool_name": "mcp__playwright__browser_click", "tool_input": {"ref": "e2"}}),
    );
    assert_eq!(next_presence(&events, surface.id).unwrap().activity, AgentActivity::Browsing);
}

/// Presence is live-only: replaying a commit that already happened (same
/// idempotency key) publishes nothing.
#[test]
fn replayed_commits_do_not_publish_presence() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let ingress = hook(
        "claude",
        &terminal_id,
        "PreToolUse",
        serde_json::json!({"tool_name": "Edit", "tool_input": {"file_path": "/repo/a.rs"}}),
    );
    mux.append_journal_ingress(&ingress, "test", "same-key").unwrap();
    let events = mux.subscribe();
    // The same idempotency key replays the earlier commit.
    mux.append_journal_ingress(&ingress, "test", "same-key").unwrap();
    let deadline = Instant::now() + Duration::from_millis(300);
    while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
        match events.recv_timeout(remaining) {
            Ok(MuxEvent::AgentPresenceChanged { .. }) => {
                panic!("a replayed commit published presence")
            }
            Ok(_) => continue,
            Err(_) => break,
        }
    }
}

/// A hook event that finishes committing after a newer one (an older journal
/// sequence) never changes presence, so a late `PreToolUse` cannot resurrect
/// a presence its turn's `Stop` already cleared.
#[test]
fn an_older_hook_event_cannot_resurrect_cleared_presence() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let events = mux.subscribe();
    let pre = hook(
        "claude",
        &terminal_id,
        "PreToolUse",
        serde_json::json!({"tool_name": "Edit", "tool_input": {"file_path": "/repo/a.rs"}}),
    );
    let stop = hook("claude", &terminal_id, "Stop", serde_json::json!({}));
    mux.apply_agent_presence(&pre, 10);
    assert_eq!(next_presence(&events, surface.id).unwrap().activity, AgentActivity::Editing);
    mux.apply_agent_presence(&stop, 12);
    assert_eq!(next_presence(&events, surface.id), None);
    let late = hook(
        "claude",
        &terminal_id,
        "PreToolUse",
        serde_json::json!({"tool_name": "Write", "tool_input": {"file_path": "/repo/b.rs"}}),
    );
    mux.apply_agent_presence(&late, 11);
    let deadline = Instant::now() + Duration::from_millis(300);
    while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
        match events.recv_timeout(remaining) {
            Ok(MuxEvent::AgentPresenceChanged { .. }) => {
                panic!("a late hook event changed presence")
            }
            Ok(_) => continue,
            Err(_) => break,
        }
    }
}

/// An agent that stops without a hook (Ctrl-C, a crash, a socket or
/// screen-detected report) loses its presence when its record goes idle.
#[test]
fn an_idle_agent_report_clears_presence() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let events = mux.subscribe();
    mux.append_journal_ingress(
        &hook(
            "claude",
            &terminal_id,
            "PreToolUse",
            serde_json::json!({"tool_name": "Bash", "tool_input": {"command": "sleep 100"}}),
        ),
        "test",
        "k-1",
    )
    .unwrap();
    assert_eq!(next_presence(&events, surface.id).unwrap().activity, AgentActivity::Running);
    mux.report_agent(surface.id, AgentState::Idle, AgentSource::Socket, None).unwrap();
    assert_eq!(next_presence(&events, surface.id), None);
}
