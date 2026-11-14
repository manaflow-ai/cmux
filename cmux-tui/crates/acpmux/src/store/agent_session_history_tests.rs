use super::{META_SCHEMA, RETIRED_AGENT_SESSION_IDS, SessionMeta};
use crate::goal::{GoalState, GoalStatus};
use serde_json::json;

fn meta() -> SessionMeta {
    serde_json::from_value(json!({
        "schema": META_SCHEMA,
        "id": "chat",
        "name": "chat",
        "harness": "claude",
        "family": "claude",
        "cwd": "/tmp",
        "status": "idle",
        "createdAt": 1,
        "updatedAt": 1,
    }))
    .unwrap()
}

#[test]
fn replacement_records_each_native_id_once_and_round_trips() {
    let mut m = meta();
    m.set_agent_session_id(Some("s1".into()), "claude");
    m.set_agent_session_id(Some("s2".into()), "claude");
    m.set_agent_session_id(None, "claude");
    m.set_agent_session_id(Some("s2".into()), "claude");
    m.set_agent_session_id(Some("s3".into()), "claude");
    m.set_agent_session_id(Some("s1".into()), "claude");
    assert_eq!(m.claude_session_ids().collect::<Vec<_>>(), ["s1", "s3", "s2"]);
    let encoded = serde_json::to_value(&m).unwrap();
    assert_eq!(encoded["previousAgentSessionIds"], json!(["s2", "s3"]));
    let restored: SessionMeta = serde_json::from_value(encoded).unwrap();
    assert_eq!(restored.claude_session_ids().collect::<Vec<_>>(), ["s1", "s3", "s2"]);
}

#[test]
fn switching_harnesses_never_authorizes_non_claude_history() {
    let mut m = meta();
    m.set_agent_session_id(Some("claude-old".into()), "claude");
    m.set_agent_session_id(Some("codex-id".into()), "codex");
    assert_eq!(m.claude_session_ids().collect::<Vec<_>>(), ["claude-old"]);
    m.set_agent_session_id(Some("claude-new".into()), "claude");
    assert_eq!(m.claude_session_ids().collect::<Vec<_>>(), ["claude-new", "claude-old"]);
}

#[test]
fn unknown_native_provenance_never_inherits_the_creation_family() {
    for next_family in ["claude", "non-claude"] {
        let mut m = meta();
        m.agent_session_id = Some("unrelated-native-id".into());
        m.agent_session_family = None;
        m.set_agent_session_id(Some("new-id".into()), next_family);
        m.set_agent_session_id(Some("confirmed-claude-id".into()), "claude");
        assert!(!m.claude_session_ids().any(|id| id == "unrelated-native-id"));
    }
}

/// Dropping the id (a fresh start) retires it once, but never makes a Claude id transcript
/// authority.
#[test]
fn retiring_the_native_id_keeps_it_out_of_claude_history() {
    let mut m = meta();
    m.set_agent_session_id(Some("claude-root".into()), "claude");
    m.retire_agent_session_id();
    m.retire_agent_session_id();
    assert_eq!(m.agent_session_id, None);
    assert_eq!(m.agent_session_family, None);
    assert_eq!(m.retired_agent_session_ids, ["claude-root"]);
    assert!(m.previous_agent_session_ids.is_empty());
}

#[test]
fn old_metadata_without_history_defaults_to_empty() {
    let m = meta();
    assert!(m.previous_agent_session_ids.is_empty());
    assert!(m.retired_agent_session_ids.is_empty());
}

#[test]
fn goal_persistence_round_trip_keeps_quota_stop_reasons() {
    for status in [GoalStatus::UsageLimited, GoalStatus::BudgetLimited] {
        let mut m = meta();
        m.goal = Some(GoalState {
            objective: "Wait for quota".into(),
            status: status.clone(),
            provider: crate::goal::GoalProvider::Codex,
            token_budget: None,
            tokens_used: None,
            elapsed_seconds: None,
            created_at: None,
            updated_at: None,
            steps: None,
            extra: Default::default(),
        });
        let encoded = serde_json::to_value(&m).unwrap();
        assert_eq!(encoded["goal"]["status"], status.as_str());
        let restored: SessionMeta = serde_json::from_value(encoded).unwrap();
        assert_eq!(restored.goal.unwrap().status, status);
    }
}

/// A Codex chat's earlier native roots stay known after a restart names a new one, so a
/// client folding its older records never reads one as a subagent; bounded, oldest first.
#[test]
fn every_earlier_native_id_is_kept_whatever_its_family() {
    let mut m = meta();
    m.set_agent_session_id(Some("root-1".into()), "non-claude");
    m.set_agent_session_id(Some("root-1".into()), "non-claude");
    m.set_agent_session_id(Some("root-2".into()), "non-claude");
    m.set_agent_session_id(None, "non-claude");
    m.set_agent_session_id(Some("root-3".into()), "non-claude");
    assert_eq!(m.retired_agent_session_ids, ["root-1", "root-2"]);
    // An id that comes back is current again, not retired.
    m.set_agent_session_id(Some("root-1".into()), "non-claude");
    assert_eq!(m.retired_agent_session_ids, ["root-2", "root-3"]);
    let encoded = serde_json::to_value(&m).unwrap();
    assert_eq!(encoded["retiredAgentSessionIds"], json!(["root-2", "root-3"]));
    for n in 0..RETIRED_AGENT_SESSION_IDS + 4 {
        m.set_agent_session_id(Some(format!("r{n}")), "non-claude");
    }
    assert_eq!(m.retired_agent_session_ids.len(), RETIRED_AGENT_SESSION_IDS);
    assert_eq!(m.retired_agent_session_ids.last().map(String::as_str), Some("r34"));
}
