//! A host that runs Claude Code's translator says so in its record (`HostRecord::claude_translator`),
//! and the agent over it counts as one that gates its own tools on the repository sync
//! (`ChildAgent::runs_claude_translator`, `hub/repo_sync.rs`). Before, a hosted Claude never did:
//! every Cloud chat (agents run under hosts there) waited in `session/new` for the whole folder
//! copy instead of its top level.

use super::*;

const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");

async fn spawned(dir: &Path, spec: &SpawnSpec) -> (HostRecord, bool) {
    let record = link::spawn(&launcher(), spec).await.expect("spawn");
    let lock = live_lock(dir, &record);
    let agent = hosted_agent(&record, true).await;
    let runs = agent.runs_claude_translator();
    agent.terminate(Duration::from_millis(500)).await;
    wait_dead(lock).await;
    (record, runs)
}

#[tokio::test]
async fn a_hosted_claude_gates_its_tools_and_a_hosted_acp_agent_does_not() {
    let dir = scratch("claude-record");
    let mut claude = spec(&dir, "s-claude");
    claude.args = vec![FAKE_CLAUDE.into()];
    claude
        .env
        .push(("CLAUDE_CONFIG_DIR".into(), dir.join("claude").to_string_lossy().into_owned()));
    claude.translator = Some(agent_host::TranslatorSpec {
        acp_session_id: "acp-1".into(),
        mode: "default".into(),
        model: "haiku".into(),
        effort: "default".into(),
        fast: false,
        prompt_suggestions: false,
        recap: None,
        claude_session_id: None,
        resumes_cut_turn: false,
    });
    let (record, runs) = spawned(&dir, &claude).await;
    assert!(record.claude_translator, "the host's record names its translator");
    assert!(runs, "a hosted Claude counts as one that gates its tools");

    let (record, runs) = spawned(&dir, &spec(&dir, "s-acp")).await;
    assert!(!record.claude_translator);
    assert!(!runs, "an ACP agent under a host waits for the whole checkout");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A record an older host wrote has no `claude_translator`: its agent waits for the whole
/// checkout, as before.
#[test]
fn an_older_hosts_record_reads_as_no_translator() {
    let old = json!({
        "record_version": acpmux::agent_host::RECORD_VERSION,
        "session_id": "s", "incarnation": "i", "host_pid": 1, "start_nonce": "00",
        "harness_pid": null, "owner_token": "o", "protocol_min": 1, "protocol_max": 1,
        "host_build": "old", "socket": "/nonexistent.sock"
    });
    let record: HostRecord = serde_json::from_value(old).unwrap();
    assert!(!record.claude_translator);
}
