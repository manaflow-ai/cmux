//! W5-Q: `agent.list` for one terminal carries the agent's whole last reply
//! (bench round 4 orchestration friction 6). `extra.last_reply` stays the
//! folded 200-character line every list shows; a one-terminal list adds
//! `extra.last_reply_text`, the reply whole with its line breaks, and
//! `extra.last_reply_at_ms`, when the daemon kept it, so `cmux terminal NAME
//! send` can answer the reply of its own turn without reading the screen.

use super::*;

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or_default()
}

fn agents(mux: &Arc<Mux>, params: Value) -> Vec<Value> {
    let listed = public_request(mux, "agents", "agent.list", params, None);
    listed["result"].as_array().cloned().unwrap_or_else(|| panic!("agent.list: {listed}"))
}

#[test]
fn w5q_one_terminal_agent_list_carries_the_whole_last_reply() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal = surface.terminal_public_id().cloned().unwrap();
    mux.report_agent(surface.id, AgentState::Idle, AgentSource::Hook, Some("native-1".into()))
        .unwrap();
    let whole = format!(
        "Canberra is the capital of Australia.\n\n```text\n{}\n```",
        "a long line of the reply ".repeat(20).trim_end()
    );
    let before = now_ms();
    assert!(mux.note_agent_reply(&terminal, &whole).is_some());
    // The append ends; the banner took or dropped its copy.
    mux.forget_agent_reply(&terminal);
    let after = now_ms();

    let one = agents(
        &mux,
        serde_json::json!({"machine": "current", "session": "current",
                           "terminal_id": terminal.as_str()}),
    );
    assert_eq!(one.len(), 1, "{one:?}");
    let extra = &one[0]["extra"];
    assert_eq!(extra["last_reply_text"], whole.as_str(), "the reply whole: {extra}");
    let at = extra["last_reply_at_ms"]
        .as_str()
        .and_then(|text| text.parse::<u64>().ok())
        .unwrap_or_else(|| panic!("last_reply_at_ms is a decimal string: {extra}"));
    assert!((before..=after).contains(&at), "{before} <= {at} <= {after}");
    let folded = extra["last_reply"].as_str().unwrap_or_default();
    assert!(folded.starts_with("Canberra is the capital of Australia. "), "{folded}");
    assert!(folded.chars().count() <= crate::agent_hooks::LIVE_PROMPT_CHARS, "{folded}");

    // The session-wide list keeps its rows small: the folded line only.
    let all = agents(&mux, serde_json::json!({"machine": "current", "session": "current"}));
    let row = all
        .iter()
        .find(|agent| agent["terminal_id"] == terminal.as_str())
        .unwrap_or_else(|| panic!("{all:?}"));
    assert_eq!(row["extra"]["last_reply"], folded);
    assert!(row["extra"].get("last_reply_text").is_none(), "{row}");
}

#[test]
fn w5q_a_terminal_without_a_kept_reply_has_no_reply_text() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal = surface.terminal_public_id().cloned().unwrap();
    mux.report_agent(surface.id, AgentState::Working, AgentSource::Hook, Some("native-1".into()))
        .unwrap();
    let one = agents(
        &mux,
        serde_json::json!({"machine": "current", "session": "current",
                           "terminal_id": terminal.as_str()}),
    );
    assert_eq!(one.len(), 1, "{one:?}");
    assert!(one[0]["extra"].get("last_reply_text").is_none(), "{}", one[0]);
    assert!(one[0]["extra"].get("last_reply_at_ms").is_none(), "{}", one[0]);
}
