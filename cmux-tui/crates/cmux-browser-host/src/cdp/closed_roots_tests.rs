use super::super::state::State;
use super::*;
use crate::cdp::CdpEvent;
use std::time::Duration;

/// A tab whose session `S` was read `ago` before now (domain on).
fn read_state(ago: Duration) -> State {
    let mut state = State::default();
    let mut tab = super::super::state::TabState::new("S".into(), "u".into(), String::new(), None);
    tab.closed_roots.insert(
        "S".into(),
        SessionRoots {
            fresh: true,
            dom_on: true,
            last_read: Instant::now().checked_sub(ago),
            ..SessionRoots::default()
        },
    );
    state.tabs.insert("T".into(), tab);
    state.sessions.insert("S".into(), "T".into());
    state
}

fn dom_event(state: &mut State) -> String {
    let applied = state.apply(&CdpEvent {
        session_id: Some("S".into()),
        method: "DOM.characterDataModified".into(),
        params: json!({"nodeId": 7, "characterData": "x"}),
    });
    format!("{:?}", applied.follow_ups)
}

fn roots(state: &State) -> &SessionRoots {
    &state.tabs["T"].closed_roots["S"]
}

#[test]
fn a_session_counts_until_the_counts_cost_a_walk() {
    // No count yet: count.
    assert!(!walk_is_cheaper(0.0, None));
    assert!(!walk_is_cheaper(1e9, None));
    // 200k nodes: a walk is about 700 ms.
    assert!(!walk_is_cheaper(0.0, Some(200_000)));
    assert!(!walk_is_cheaper(699.0, Some(200_000)));
    assert!(walk_is_cheaper(700.0, Some(200_000)));
    // A small page walks soon: its walk is cheap too.
    assert!(walk_is_cheaper(1.0, Some(100)));
}

#[test]
fn a_churning_page_turns_dom_events_off_after_the_event_budget() {
    let mut state = read_state(Duration::from_secs(1));
    for _ in 1..DOM_EVENT_BUDGET {
        assert!(!dom_event(&mut state).contains("DisableDom"));
    }
    assert!(roots(&state).dom_on);
    assert!(dom_event(&mut state).contains("DisableDom"), "the budget's last event turns it off");
    assert!(!roots(&state).dom_on);
    assert!(!roots(&state).fresh, "roots are stale once the domain is off");
    assert!(!dom_event(&mut state).contains("DisableDom"), "turned off once");
}

#[test]
fn the_first_event_long_after_a_read_turns_dom_events_off() {
    let mut state = read_state(DOM_IDLE_AFTER_READ + Duration::from_secs(1));
    assert!(dom_event(&mut state).contains("DisableDom"));
    assert!(!roots(&state).dom_on && !roots(&state).fresh);
    let mut recent = read_state(Duration::from_secs(1));
    assert!(!dom_event(&mut recent).contains("DisableDom"));
    assert!(roots(&recent).dom_on && !roots(&recent).fresh);
}

#[test]
fn closed_roots_are_grouped_by_their_frame() {
    let tree = json!({"backendNodeId": 1, "children": [
        {"backendNodeId": 2, "shadowRoots": [{"backendNodeId": 3, "shadowRootType": "closed", "children": [
            {"backendNodeId": 4, "shadowRoots": [{"backendNodeId": 5, "shadowRootType": "closed"}]}]}]},
        {"backendNodeId": 6, "shadowRoots": [{"backendNodeId": 7, "shadowRootType": "open"}]},
        {"backendNodeId": 8, "frameId": "F2", "contentDocument": {"backendNodeId": 9, "children": [
            {"backendNodeId": 10, "shadowRoots": [{"backendNodeId": 11, "shadowRootType": "closed"}]}]}},
    ]});
    let mut out = HashMap::new();
    collect(&tree, "F1", &mut out);
    assert_eq!(out["F1"], vec![(2, 3), (4, 5)]);
    assert_eq!(out["F2"], vec![(10, 11)]);
    assert_eq!(out.len(), 2);
}
