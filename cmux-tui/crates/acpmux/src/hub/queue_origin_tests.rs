use super::*;
use serde_json::json;

fn kind(kind: &str) -> Value {
    json!({"kind": kind})
}

#[test]
fn the_persons_prompt_is_the_persons() {
    assert_eq!(of(None, None), QueueOrigin::Person);
    assert_eq!(of(Some(&kind("person_message")), None), QueueOrigin::Person);
    assert_eq!(of(Some(&kind("trigger")), None), QueueOrigin::Person);
}

#[test]
fn acpmux_own_prompts_are_acpmux() {
    for k in [
        "surge_digest",
        "subagent_retry",
        "subagent_resume",
        "auto_resume",
        "turn_cap",
        "offer_result",
        "announcement",
    ] {
        assert_eq!(of(Some(&kind(k)), None), QueueOrigin::Acpmux, "{k}");
    }
}

#[test]
fn other_agents_messages_are_agents() {
    assert_eq!(of(Some(&kind("agent_message")), Some("lane-a")), QueueOrigin::Agent);
    assert_eq!(of(None, Some("lane-a")), QueueOrigin::Agent);
    for k in ["inbox_notice", "agent_digest", "subsession_message", "lane_report", "notice"] {
        assert_eq!(of(Some(&kind(k)), None), QueueOrigin::Agent, "{k}");
    }
}

#[test]
fn serializes_snake_case() {
    assert_eq!(serde_json::to_value(QueueOrigin::Acpmux).unwrap(), json!("acpmux"));
}
