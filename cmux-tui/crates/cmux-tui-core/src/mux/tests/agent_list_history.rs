//! W6-A (bench round 5, orchestration row 6): `agent.list` keeps the history
//! of an agent that ended. A hook-ended agent is listed by `state: done`
//! (`cmux agent list --state ended`), so the agent `agent resume` can bring
//! back is findable; the live list still leaves it out.

use super::*;

fn agents(mux: &Arc<Mux>, state: Option<&str>) -> Vec<Value> {
    let mut params = serde_json::json!({"machine": "current", "session": "current"});
    if let Some(state) = state {
        params["state"] = Value::String(state.to_string());
    }
    let listed = public_request(mux, "agents", "agent.list", params, None);
    listed["result"].as_array().cloned().unwrap_or_else(|| panic!("agent.list: {listed}"))
}

fn rows_of<'a>(rows: &'a [Value], terminal: &TerminalPublicId) -> Vec<&'a Value> {
    rows.iter().filter(|row| row["terminal_id"] == terminal.as_str()).collect()
}

#[test]
fn w6a_agent_list_state_done_lists_a_hook_ended_agent() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal = surface.terminal_public_id().cloned().unwrap();
    let hook = |event: &str| {
        crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            event,
            Some(terminal.as_str()),
            serde_json::json!({"session_id":"w6a-session"}),
        )
        .unwrap()
    };
    mux.apply_agent_hook_record(&hook("SessionStart"), 1).unwrap();
    mux.apply_agent_hook_record(&hook("SessionEnd"), 2).unwrap();
    settled(&mux);

    let ended = agents(&mux, Some("done"));
    let rows = rows_of(&ended, &terminal);
    assert_eq!(rows.len(), 1, "the ended agent is listed as done: {ended:?}");
    assert_eq!(rows[0]["state"], "done");
    // The live roster still leaves it out: its delete event said so.
    assert!(rows_of(&agents(&mux, None), &terminal).is_empty());
}
