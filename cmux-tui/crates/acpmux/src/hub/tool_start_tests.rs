use super::*;

fn event(dir: &str, kind: &str, update: Value) -> HubEvent {
    HubEvent {
        session_id: "s1".into(),
        record: Arc::new(crate::store::EventRecord {
            seq: 1,
            at: 42,
            dir: dir.into(),
            kind: kind.into(),
            msg: json!({"jsonrpc": "2.0", "method": "session/update",
                "params": {"sessionId": "own", "update": update}}),
            host_seq: None,
        }),
        remote: None,
        update_line: Default::default(),
    }
}

/// Claude's call named as its block starts (pending, input still streaming) is a start, with
/// its tool's name; so is another harness's call with no status.
#[test]
fn a_call_named_before_it_runs_is_a_start() {
    let early = json!({"sessionUpdate": "tool_call", "toolCallId": "toolu_1", "status": "pending",
        "kind": "edit", "_meta": {"claude": {"tool": "Edit"}}});
    assert_eq!(
        tool_start(&event("in", "tool_call", early)),
        Some(ToolStart {
            session_id: "s1".into(),
            tool_call_id: "toolu_1".into(),
            tool: "Edit".into(),
            at: 42
        })
    );
    let plain = json!({"sessionUpdate": "tool_call", "toolCallId": "c2", "kind": "execute"});
    assert_eq!(tool_start(&event("in", "tool_call", plain)).unwrap().tool, "execute");
}

/// A call that already runs, its later updates, acpmux's own records and a peer's mirror are
/// no start.
#[test]
fn a_running_call_an_update_or_a_peers_record_is_no_start() {
    let running = json!({"sessionUpdate": "tool_call", "toolCallId": "c", "status": "in_progress"});
    assert!(tool_start(&event("in", "tool_call", running)).is_none());
    let update =
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "c", "status": "pending"});
    assert!(tool_start(&event("in", "tool_call_update", update)).is_none());
    let pending = json!({"sessionUpdate": "tool_call", "toolCallId": "c", "status": "pending"});
    assert!(tool_start(&event("mux", "tool_call", pending.clone())).is_none());
    assert!(tool_start(&event("in", "tool_call", json!({"status": "pending"}))).is_none(), "no id");
    let mut remote = event("in", "tool_call", pending);
    remote.remote = Some(RemoteRef { peer: "p".into(), summary: json!({}) });
    assert!(tool_start(&remote).is_none());
}
