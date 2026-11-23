//! The agent turn cap is a loop guard between agents: it applies only where
//! two or more agents share a conversation. The person's own Chief chat (one
//! person, one Chief) has no cap, and keeps the 2 s gap between agent texts
//! (2026-11-20: the cap refused 25 Chief status messages in a row there).

use cmux_conversation::{
    ConversationHead, CreateRequest, MAX_AGENT_TURNS, MIN_AGENT_GAP_MS, Part, Participant, Reject,
    check_agent_streak, create, parse_rfc3339_millis,
};
use serde_json::json;

const NOW: &str = "2026-11-20T12:00:00.000Z";

fn participant(id: &str, kind: &str) -> Participant {
    serde_json::from_value(json!({"id": id, "kind": kind, "display_name": id})).unwrap()
}

fn head(agents: &[&str]) -> ConversationHead {
    let mut participants = vec![participant("user_local", "human")];
    participants.extend(agents.iter().map(|id| participant(id, "agent")));
    create(&CreateRequest {
        id: "conv_TEST",
        actor: "user_local",
        title: "mux",
        participants: &participants,
        now: NOW,
    })
    .unwrap()
}

fn text() -> Vec<Part> {
    serde_json::from_value(json!([{"type": "text", "text": "status"}])).unwrap()
}

/// The head after `streak` agent texts at the top level, the last at NOW.
fn spent(mut head: ConversationHead, streak: usize) -> ConversationHead {
    head.agent_text_streak = streak as u32;
    head.last_agent_text_at = Some(NOW.to_owned());
    head
}

fn now_ms() -> u64 {
    parse_rfc3339_millis(NOW).unwrap()
}

#[test]
fn a_lone_agent_is_not_capped_after_many_texts() {
    let head = spent(head(&["agent_mux"]), MAX_AGENT_TURNS * 4);
    let later = now_ms() + MIN_AGENT_GAP_MS;
    assert_eq!(check_agent_streak(&head, "agent_mux", &text(), later, None), Ok(()));
}

#[test]
fn a_lone_agent_still_waits_the_gap() {
    let head = spent(head(&["agent_mux"]), MAX_AGENT_TURNS * 4);
    let soon = now_ms() + MIN_AGENT_GAP_MS - 1;
    assert_eq!(check_agent_streak(&head, "agent_mux", &text(), soon, None), Err(Reject::AgentRate));
}

#[test]
fn two_agents_keep_the_cap() {
    let head = spent(head(&["agent_mux", "agent_two"]), MAX_AGENT_TURNS);
    let later = now_ms() + MIN_AGENT_GAP_MS;
    assert_eq!(
        check_agent_streak(&head, "agent_mux", &text(), later, None),
        Err(Reject::AgentBudget)
    );
}
