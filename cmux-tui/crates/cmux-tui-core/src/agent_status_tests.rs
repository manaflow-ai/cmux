use super::*;

#[test]
fn finished_turn_is_done_until_its_marker_is_read() {
    assert_eq!(AgentStatus::from_state(AgentState::Idle, true), Some(AgentStatus::Done));
    assert_eq!(AgentStatus::from_state(AgentState::Idle, false), Some(AgentStatus::Idle));
    // A working or blocked agent keeps its state whatever the marker says.
    assert_eq!(AgentStatus::from_state(AgentState::Working, true), Some(AgentStatus::Working));
    assert_eq!(AgentStatus::from_state(AgentState::Blocked, true), Some(AgentStatus::Blocked));
    // An ended session is no agent.
    assert_eq!(AgentStatus::from_state(AgentState::Done, true), None);
    assert_eq!(AgentStatus::from_state_str("done", false), None);
    assert_eq!(AgentStatus::from_state_str("odd", false), Some(AgentStatus::Unknown));
}

#[test]
fn rollup_prefers_blocked_then_done_then_working() {
    use AgentStatus::*;
    assert_eq!(AgentStatus::rollup([Idle, Working, Done]), Some(Done));
    assert_eq!(AgentStatus::rollup([Idle, Blocked, Done, Working]), Some(Blocked));
    assert_eq!(AgentStatus::rollup([Unknown, Idle]), Some(Idle));
    assert_eq!(AgentStatus::rollup([Unknown, Working]), Some(Working));
    assert_eq!(AgentStatus::rollup([]), None);
    let mut ranked = AgentStatus::ALL.to_vec();
    ranked.sort_by_key(|status| std::cmp::Reverse(status.rank()));
    assert_eq!(ranked, AgentStatus::ALL);
}

#[test]
fn status_words_round_trip_and_accept_old_cli_words() {
    for status in AgentStatus::ALL {
        assert_eq!(AgentStatus::parse(status.as_str()), Some(status));
    }
    assert_eq!(AgentStatus::parse("busy"), Some(AgentStatus::Working));
    assert_eq!(AgentStatus::parse("waiting-for-input"), Some(AgentStatus::Blocked));
    assert_eq!(AgentStatus::parse("ended"), None);
}
