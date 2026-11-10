//! W6-A (bench round 5, orchestration row 4): an agent's last reply after a
//! daemon restart. The daemon keeps the reply in memory only, and the journal
//! keeps only the harness transcript's path; a restarted daemon reads the last
//! assistant text from that transcript, so `terminal list --agents` does not
//! show `last_reply: null` for an agent that answered before the restart.

use super::*;

fn transcript_hook(transcript: &std::path::Path) -> Value {
    serde_json::json!({
        "session_id": "w6a-reply-session",
        "transcript_path": transcript.to_str().unwrap(),
        "last_assistant_message": "BETA_BACK",
    })
}

fn append_hook(mux: &Arc<Mux>, terminal: &TerminalPublicId, event: &str, native: Value) {
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        event,
        Some(terminal.as_str()),
        native,
    )
    .unwrap();
    let key = format!("w6a-reply-{}", crate::workspace_registry::new_uuid_v4());
    mux.append_journal_ingress(&ingress, "test", &key).unwrap();
}

fn listed_reply(mux: &Arc<Mux>, terminal: &TerminalPublicId) -> Value {
    let listed = public_request(
        mux,
        "agents",
        "agent.list",
        serde_json::json!({"machine": "current", "session": "current"}),
        None,
    );
    listed["result"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|agent| agent["terminal_id"] == terminal.as_str())
        .map(|agent| agent["extra"]["last_reply"].clone())
        .unwrap_or_else(|| panic!("no agent row of {terminal}: {listed}"))
}

#[test]
fn w6a_the_last_reply_survives_a_daemon_restart_from_the_transcript() {
    let session = "w6a-reply-restart";
    let root = std::env::temp_dir()
        .join(format!("cmux-w6a-reply-restart-{}", crate::workspace_registry::new_uuid_v4()));
    let transcripts = std::env::temp_dir()
        .join(format!("cmux-w6a-transcripts-{}", crate::workspace_registry::new_uuid_v4()));
    std::fs::create_dir_all(&transcripts).unwrap();
    let transcript = transcripts.join("w6a-transcript.jsonl");
    std::fs::write(
        &transcript,
        concat!(
            r#"{"type":"user","message":{"role":"user","content":"Reply with BETA_BACK"}}"#,
            "\n",
            r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"BETA_BACK"}]}}"#,
            "\n",
        ),
    )
    .unwrap();
    let mux = open_persistent_test_mux(session, &root);
    let terminal = mux.new_workspace(None, None).unwrap().terminal_public_id().cloned().unwrap();
    append_hook(&mux, &terminal, "SessionStart", transcript_hook(&transcript));
    append_hook(&mux, &terminal, "Stop", transcript_hook(&transcript));
    // The hook helper sends the reply beside the append (`live_reply`).
    let _ = mux.note_agent_reply(&terminal, "BETA_BACK");
    let _ = settled(&mux);
    assert_eq!(listed_reply(&mux, &terminal), "BETA_BACK");
    mux.shutdown();
    drop(mux);

    let reopened = open_persistent_test_mux(session, &root);
    let _ = settled(&reopened);
    assert_eq!(
        listed_reply(&reopened, &terminal),
        "BETA_BACK",
        "the restarted daemon reads the reply from the transcript the hook named"
    );
    reopened.shutdown();
    drop(reopened);
    let _ = std::fs::remove_dir_all(root);
    let _ = std::fs::remove_dir_all(transcripts);
}
