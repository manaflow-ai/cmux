//! The Swift suites `CreationInputHoldTests` and `NewTerminalKeysTests` (their
//! hold-level cases), over event ids.

use super::*;

const S: i64 = 1_000_000_000;
const T0: i64 = 100 * S;

fn live() -> Live {
    Live { now_ns: T0, ..Live::default() }
}

fn listed(ticket: i64, tab: &str) -> Live {
    let mut live = live();
    live.listed.insert(ticket, tab.to_owned());
    live
}

fn open(hold: &mut CreationHold, generation: u64, tab: Option<&str>) -> i64 {
    hold.open(Open { tab: tab.map(str::to_owned), ..Open::generation(generation) }, &live()).ticket
}

fn new_terminal(hold: &mut CreationHold, tab: Option<&str>, stand_in_sends: bool) -> i64 {
    let open = Open {
        tab: tab.map(str::to_owned),
        machine: Some("local".into()),
        new_terminal: true,
        stand_in_sends,
        ..Open::generation(7)
    };
    hold.open(open, &live()).ticket
}

fn new_workspace(hold: &mut CreationHold, generation: u64) -> i64 {
    hold.open(Open { new_workspace: true, ..Open::generation(generation) }, &live()).ticket
}

fn key(hold: &mut CreationHold, event: u64, focused: Option<&str>) {
    hold.capture(event, false, focused, false, false, None);
}

fn ends(keys: &[HeldKey]) -> Vec<String> {
    keys.iter()
        .map(|key| match key {
            HeldKey::Run { .. } => "run".to_owned(),
            HeldKey::Type { events, lane, .. } => {
                format!("type {} into {}", events.len(), lane.tab)
            }
            HeldKey::Command { lane, .. } => format!("command in {}", lane.tab),
        })
        .collect()
}

fn take(hold: &mut CreationHold, focused: &str, live: &Live) -> Vec<String> {
    ends(&hold.take_focused(Some(focused), None, &BTreeSet::new(), live))
}

fn lane(tab: &str) -> HeldLane {
    HeldLane { tab: tab.into(), machine: None, made_surface: None }
}

const CMD_T: u64 = 17;
const CMD_W: u64 = 13;

fn tab_kinds(events: &[u64]) -> Live {
    let mut live = live();
    for event in events {
        match *event {
            CMD_T => live.kinds.insert(*event, TabKey::Makes),
            CMD_W => live.kinds.insert(*event, TabKey::Closes),
            _ => None,
        };
    }
    live
}

#[test]
fn a_close_key_is_never_held_behind_a_pending_creation() {
    let mut hold = CreationHold::new(T0);
    open(&mut hold, 1, None);
    assert!(!hold.holds(true, 2 * S, true, true, None, &live()));
    assert!(hold.holds(false, 2 * S, true, false, None, &live()));
    assert!(hold.holds(true, 2 * S, true, false, None, &live()));
}

#[test]
fn a_replied_creation_stops_holding_at_the_limit_even_when_its_focus_never_lands() {
    let mut hold = CreationHold::new(T0);
    let ticket = open(&mut hold, 7, None);
    hold.resolve(ticket, true, None, false, None, &live());
    assert!(hold.awaits(7));
    assert!(!hold.holds(false, 0, true, false, None, &live()));
    assert!(hold.holds(false, 60 * S, true, false, None, &live()));
}

#[test]
fn a_creation_waiting_for_its_reply_keeps_its_keys() {
    let mut hold = CreationHold::new(T0 - 30 * S);
    open(&mut hold, 3, None);
    assert!(hold.holds(false, 2 * S, true, false, None, &live()));
    assert!(hold.has_pending_creation());
}

#[test]
fn past_the_reply_bound_a_creation_keeps_no_key() {
    let mut hold = CreationHold::new(T0);
    open(&mut hold, 3, None);
    let later = Live { now_ns: T0 + REPLY_WAIT_BOUND_NS, ..Live::default() };
    assert!(hold.waited_past_reply_bound(None, &later));
    assert!(!hold.holds(false, 2 * S, true, false, None, &later));
    assert!(hold.reply_bound_passed(1) && !hold.limit_passed());
}

#[test]
fn closing_a_pending_creation_drops_only_the_keys_typed_for_it() {
    let mut hold = CreationHold::new(T0);
    open(&mut hold, 1, Some("first"));
    key(&mut hold, 1, Some("first"));
    open(&mut hold, 2, Some("second"));
    key(&mut hold, 2, Some("second"));
    assert!(hold.cancel("second", &live()));
    assert_eq!(hold.take(&live()), vec![1]);
}

#[test]
fn a_creation_is_cancelled_only_while_it_is_pending() {
    let mut hold = CreationHold::new(T0);
    let ticket = open(&mut hold, 1, Some("new"));
    assert!(hold.is_creating("new"));
    key(&mut hold, 1, Some("new"));
    hold.resolve(ticket, true, None, false, None, &live());
    assert!(!hold.is_creating("new"));
    assert!(!hold.cancel("new", &live()));
    assert_eq!(hold.take(&live()).len(), 1);
}

#[test]
fn closing_a_replay_opened_split_keeps_the_line_carried_for_another_terminal() {
    let mut hold = CreationHold::new(T0);
    open(&mut hold, 1, Some("split"));
    let a = lane("terminalA");
    let earlier = vec![
        Earlier { event: 2, chord: false, lane: Some(a.clone()), pane: None },
        Earlier { event: 3, chord: false, lane: Some(lane("terminalB")), pane: None },
    ];
    hold.prepend(earlier, Some(&a));
    assert!(hold.cancel("split", &live()));
    assert_eq!(hold.take(&live()), vec![3]);
}

#[test]
fn keys_typed_for_a_new_workspaces_terminal_go_only_to_that_workspace() {
    let mut made = CreationHold::new(T0);
    let ticket = new_workspace(&mut made, 4);
    assert_eq!(made.newest_generation, Some(4));
    made.capture(1, false, Some("home"), true, false, None);
    made.resolve(ticket, true, Some("ws-new".into()), false, None, &live());
    made.capture(2, false, Some("home"), true, false, None);
    assert_eq!(made.awaited_workspace().map(String::as_str), Some("ws-new"));
    assert!(made.drop_keys(Some("home")));
    assert!(made.take(&live()).is_empty());

    let mut shown = CreationHold::new(T0);
    let second = new_workspace(&mut shown, 5);
    shown.capture(1, false, Some("home"), true, false, None);
    shown.resolve(second, true, Some("ws-new".into()), false, None, &live());
    assert!(!shown.drop_keys(Some("ws-new")));
    assert_eq!(shown.take(&live()).len(), 1);

    let mut failed = CreationHold::new(T0);
    let third = new_workspace(&mut failed, 6);
    failed.capture(1, false, Some("home"), true, false, None);
    failed.resolve(third, false, None, false, None, &live());
    assert_eq!(failed.awaited_workspace(), None);
    assert!(failed.take(&live()).is_empty());
    assert_eq!(failed.dropped, vec![Dropped { count: 1, why: "its create failed".into() }]);

    let mut moved_on = CreationHold::new(T0);
    let fourth = new_workspace(&mut moved_on, 7);
    moved_on.capture(1, false, Some("other"), false, false, None);
    moved_on.resolve(fourth, true, Some("ws-new".into()), false, None, &live());
    assert!(moved_on.drop_keys(Some("home")));
    assert_eq!(moved_on.take(&live()).len(), 1);
}

#[test]
fn keys_for_a_persons_new_workspace_typed_during_a_surface_hold_go_to_the_new_terminal() {
    let mut hold = CreationHold::new(T0);
    hold.await_surface(&lane("cold"));
    key(&mut hold, 1, Some("cold"));
    let ticket = new_workspace(&mut hold, 9);
    hold.capture(2, false, Some("cold"), true, false, None);
    hold.capture(3, false, Some("cold"), true, false, None);
    hold.resolve(ticket, true, Some("ws-new".into()), false, None, &live());
    assert!(!hold.drop_keys(Some("ws-new")));
    hold.bind_new_workspace_keys(Some("new-terminal".into()), None, None);
    let routed: Vec<(u64, String)> = hold
        .take_focused(Some("new-terminal"), None, &BTreeSet::new(), &live())
        .into_iter()
        .flat_map(|key| match key {
            HeldKey::Type { events, lane, .. } => {
                events.into_iter().map(|e| (e, lane.tab.clone())).collect::<Vec<_>>()
            }
            HeldKey::Command { event, lane, .. } => vec![(event, lane.tab)],
            HeldKey::Run { event, lane, .. } => vec![(event, lane.map_or("-".into(), |l| l.tab))],
        })
        .collect();
    assert_eq!(
        routed,
        vec![(1, "cold".into()), (2, "new-terminal".into()), (3, "new-terminal".into())]
    );
}

#[test]
fn a_failed_new_workspace_counts_as_left_once_the_person_acts() {
    let mut hold = CreationHold::new(T0);
    let failed = new_workspace(&mut hold, 1);
    new_workspace(&mut hold, 2);
    hold.resolve(failed, false, None, false, None, &live());
    assert!(!hold.person_left_every_creation());
    hold.person_moved_on();
    assert!(hold.person_left_every_creation());
    assert!(hold.passes_on(None));
}

#[test]
fn a_shown_second_workspace_ends_the_wait_for_a_left_ones_keys() {
    let mut hold = CreationHold::new(T0);
    let first = new_workspace(&mut hold, 1);
    hold.capture(1, false, None, true, false, None);
    hold.person_moved_on();
    let second = new_workspace(&mut hold, 2);
    hold.resolve(first, true, Some("w1".into()), false, None, &live());
    hold.resolve(second, true, Some("w2".into()), false, None, &live());
    assert_eq!(hold.shown_workspace_to_wait_for().map(String::as_str), Some("w2"));
    assert!(hold.keys_kept_for_left_workspace(Some("w1-not-shown"), true).is_some());
    assert_eq!(hold.keys_kept_for_left_workspace(Some("w2"), true), None);
}

#[test]
fn a_close_tab_key_in_a_shown_new_workspace_waits_behind_the_new_tab_keys_kept_for_its_terminal() {
    let mut hold = CreationHold::new(T0);
    let ticket = new_workspace(&mut hold, 1);
    let kinds = tab_kinds(&[CMD_T, CMD_W]);
    hold.capture(CMD_T, true, Some("old"), true, false, Some("old-pane".into()));
    hold.capture(CMD_T + 100, true, Some("old"), true, false, Some("old-pane".into()));
    let mut kinds2 = kinds;
    kinds2.kinds.insert(CMD_T + 100, TabKey::Makes);
    assert!(hold.close_key_acts_now(
        true,
        Some(TabKey::Closes),
        Some("new-pane"),
        Some("ws-old"),
        &kinds2
    ));
    hold.resolve(ticket, true, Some("ws-new".into()), false, None, &live());
    assert!(hold.close_key_acts_now(
        true,
        Some(TabKey::Closes),
        Some("new-pane"),
        Some("ws-old"),
        &kinds2
    ));
    assert!(!hold.close_key_acts_now(
        true,
        Some(TabKey::Closes),
        Some("new-pane"),
        Some("ws-new"),
        &kinds2
    ));
    hold.capture(CMD_W, true, Some("new-terminal"), false, false, Some("new-pane".into()));
    hold.bind_new_workspace_keys(Some("new-terminal".into()), None, Some("new-pane".into()));
    assert_eq!(hold.reduce_tab_keys(false, &kinds2), (1, 0));
    assert_eq!(hold.take(&live()), vec![CMD_T]);
}

#[test]
fn a_refused_new_workspace_takes_the_close_tab_key_that_waited_behind_its_new_tab_key() {
    let kinds = tab_kinds(&[CMD_T, CMD_W]);
    let mut hold = CreationHold::new(T0);
    let ticket = new_workspace(&mut hold, 1);
    hold.capture(CMD_T, true, Some("old"), true, false, Some("old-pane".into()));
    assert!(!hold.close_key_acts_now(
        true,
        Some(TabKey::Closes),
        Some("old-pane"),
        Some("ws-old"),
        &kinds
    ));
    hold.capture(CMD_W, true, Some("old"), true, false, Some("old-pane".into()));
    hold.resolve(ticket, false, None, false, None, &live());
    assert!(hold.is_empty());

    let mut left = CreationHold::new(T0);
    let second = new_workspace(&mut left, 2);
    left.capture(CMD_T, true, Some("old"), true, false, Some("old-pane".into()));
    left.person_moved_on();
    left.resolve(second, true, Some("ws-new".into()), false, None, &live());
    assert!(left.close_key_acts_now(
        true,
        Some(TabKey::Closes),
        Some("new-pane"),
        Some("ws-new"),
        &kinds
    ));
}

#[test]
fn a_lone_close_tab_key_is_dropped_only_when_asked() {
    let kinds = tab_kinds(&[CMD_W]);
    let mut hold = CreationHold::new(T0);
    hold.capture(CMD_W, true, None, false, false, None);
    assert_eq!(hold.reduce_tab_keys(false, &kinds), (0, 0));
    assert_eq!(hold.reduce_tab_keys(true, &kinds), (0, 1));
    assert!(hold.is_empty());
}

#[test]
fn the_tab_keys_of_the_actions() {
    assert_eq!(TabKey::of_action(Some("closeTab")), Some(TabKey::Closes));
    assert_eq!(TabKey::of_action(Some("newSurface")), Some(TabKey::Makes));
    assert_eq!(TabKey::of_action(Some("newTab.toRight")), Some(TabKey::Makes));
    assert_eq!(TabKey::of_action(Some("splitRight")), None);
    assert_eq!(TabKey::of_action(None), None);
}

// NewTerminalKeysTests

#[test]
fn a_key_typed_for_a_refused_new_terminal_tab_with_no_stand_in_goes_into_no_terminal() {
    let mut hold = CreationHold::new(T0);
    let ticket = new_terminal(&mut hold, None, true);
    hold.capture(1, false, Some("press"), false, true, None);
    hold.resolve(ticket, false, None, false, None, &live());
    assert!(hold.is_empty());
    assert!(take(&mut hold, "press", &live()).is_empty());
}

#[test]
fn a_key_typed_after_the_person_moved_is_not_the_new_terminals() {
    let mut hold = CreationHold::new(T0);
    let ticket = new_terminal(&mut hold, None, true);
    hold.capture(1, false, Some("other"), false, false, None);
    hold.resolve(ticket, false, None, false, None, &live());
    assert_eq!(take(&mut hold, "other", &live()), vec!["run"]);
}

#[test]
fn a_key_typed_while_another_creation_waits_keeps_no_lane() {
    let mut hold = CreationHold::new(T0);
    let ticket =
        hold.open(Open { machine: Some("local".into()), ..Open::generation(7) }, &live()).ticket;
    hold.capture(1, false, Some("press"), false, true, None);
    hold.resolve(ticket, false, None, false, None, &live());
    assert_eq!(take(&mut hold, "press", &live()), vec!["run"]);
}

#[test]
fn a_key_typed_for_a_refused_stand_in_goes_into_no_terminal() {
    let mut hold = CreationHold::new(T0);
    let ticket = new_terminal(&mut hold, Some("pending_tab_1"), true);
    key(&mut hold, 1, Some("pending_tab_1"));
    key(&mut hold, 2, Some("other"));
    hold.resolve(ticket, false, None, false, None, &live());
    assert_eq!(take(&mut hold, "other", &live()), vec!["run"]);
}

#[test]
fn the_keys_of_a_made_terminal_go_into_its_tab() {
    for focused in ["press", "tab_9"] {
        let mut hold = CreationHold::new(T0);
        let ticket = new_terminal(&mut hold, Some("pending_tab_1"), true);
        key(&mut hold, 1, Some("pending_tab_1"));
        key(&mut hold, 2, Some("pending_tab_1"));
        hold.resolve(ticket, true, None, true, None, &live());
        assert!(hold.awaits_made_terminal(&live()));
        let store = listed(ticket, "tab_9");
        assert!(!hold.awaits_made_terminal(&store));
        let want = if focused == "tab_9" { vec!["run", "run"] } else { vec!["type 2 into tab_9"] };
        assert_eq!(take(&mut hold, focused, &store), want, "focused {focused}");
    }
}

#[test]
fn the_hold_waits_for_a_made_terminals_tab_only_while_it_holds_a_key_of_it() {
    let mut hold = CreationHold::new(T0);
    let ticket = new_terminal(&mut hold, None, true);
    hold.capture(1, false, Some("other"), false, false, None);
    hold.resolve(ticket, true, None, true, None, &live());
    assert!(!hold.awaits_made_terminal(&live()));
    hold.capture(2, false, Some("press"), false, true, None);
    assert!(hold.awaits_made_terminal(&live()));
    let store = listed(ticket, "tab_9");
    assert!(!hold.awaits_made_terminal(&store));
    assert_eq!(take(&mut hold, "other", &store), vec!["run", "type 1 into tab_9"]);
}

#[test]
fn the_keys_of_a_stand_in_that_sends_nothing_wait_for_the_made_terminals_tab() {
    for is_listed in [true, false] {
        let mut hold = CreationHold::new(T0);
        let ticket = new_terminal(&mut hold, Some("pending_tab_1"), false);
        key(&mut hold, 1, Some("pending_tab_1"));
        assert!(!hold.awaits_made_terminal(&live()));
        hold.resolve(ticket, true, None, true, None, &live());
        assert!(hold.awaits_made_terminal(&live()));
        let store = if is_listed { listed(ticket, "tab_9") } else { live() };
        assert_eq!(hold.awaits_made_terminal(&store), !is_listed);
        let got = take(&mut hold, "other", &store);
        let want: Vec<&str> = if is_listed { vec!["type 1 into tab_9"] } else { vec![] };
        assert_eq!(got, want, "listed {is_listed}");
        assert_eq!(hold.untyped_terminal_keys, if is_listed { 0 } else { 1 });
    }
}

#[test]
fn the_keys_of_a_made_terminal_with_no_tab_and_no_stand_in_are_lost_and_go_into_no_terminal() {
    let mut hold = CreationHold::new(T0);
    let ticket = new_terminal(&mut hold, None, true);
    hold.capture(1, false, Some("press"), false, true, None);
    hold.resolve(ticket, true, None, true, None, &live());
    assert!(take(&mut hold, "press", &live()).is_empty());
    assert_eq!(hold.untyped_terminal_keys, 1);
}

#[test]
fn the_keys_of_a_made_terminal_with_no_tab_yet_go_into_its_stand_in() {
    for focused in ["press", "pending_tab_1"] {
        let mut hold = CreationHold::new(T0);
        let ticket = new_terminal(&mut hold, Some("pending_tab_1"), true);
        key(&mut hold, 1, Some("pending_tab_1"));
        hold.resolve(ticket, true, None, true, None, &live());
        assert!(hold.awaits_made_terminal(&live()));
        let want = if focused == "press" { vec!["type 1 into pending_tab_1"] } else { vec!["run"] };
        assert_eq!(take(&mut hold, focused, &live()), want);
        assert_eq!(hold.untyped_terminal_keys, 0);
    }
}

#[test]
fn the_lane_of_a_made_terminal_carries_the_id_that_the_reply_named() {
    let lanes = |keys: &[HeldKey]| -> Vec<Option<HeldLane>> {
        keys.iter()
            .map(|key| match key {
                HeldKey::Type { lane, .. } | HeldKey::Command { lane, .. } => Some(lane.clone()),
                HeldKey::Run { lane, .. } => lane.clone(),
            })
            .collect()
    };
    let local = |tab: &str, surface: Option<u64>| {
        Some(HeldLane { tab: tab.into(), machine: Some("local".into()), made_surface: surface })
    };

    let mut hold = CreationHold::new(T0);
    let ticket = new_terminal(&mut hold, Some("pending_tab_1"), true);
    key(&mut hold, 1, Some("pending_tab_1"));
    hold.resolve(ticket, true, None, true, Some(77), &live());
    let taken = hold.take_focused(Some("other"), None, &BTreeSet::new(), &live());
    assert_eq!(lanes(&taken), vec![local("pending_tab_1", Some(77))]);

    let mut next = CreationHold::new(T0);
    let earlier = taken
        .iter()
        .flat_map(|key| match key {
            HeldKey::Type { events, lane, panes } => events
                .iter()
                .zip(panes)
                .map(|(event, pane)| Earlier {
                    event: *event,
                    chord: false,
                    lane: Some(lane.clone()),
                    pane: pane.clone(),
                })
                .collect::<Vec<_>>(),
            _ => vec![],
        })
        .collect();
    next.prepend(earlier, None);
    assert_eq!(
        lanes(&next.take_focused(Some("other"), None, &BTreeSet::new(), &live())),
        vec![local("pending_tab_1", Some(77))]
    );

    let mut second = CreationHold::new(T0);
    let made = new_terminal(&mut second, Some("pending_tab_2"), true);
    key(&mut second, 2, Some("pending_tab_2"));
    second.resolve(made, true, None, true, Some(78), &live());
    let keys = second.take_focused(Some("other"), None, &BTreeSet::new(), &listed(made, "tab_9"));
    assert_eq!(lanes(&keys), vec![local("tab_9", Some(78))]);

    let mut third = CreationHold::new(T0);
    let split = third
        .open(
            Open {
                tab: Some("split_tab".into()),
                machine: Some("local".into()),
                ..Open::generation(9)
            },
            &live(),
        )
        .ticket;
    key(&mut third, 3, Some("split_tab"));
    third.resolve(split, true, None, false, None, &live());
    assert_eq!(
        lanes(&third.take_focused(Some("other"), None, &BTreeSet::new(), &live())),
        vec![local("split_tab", None)]
    );
}

#[test]
fn a_closed_window_gives_the_runs_held_for_a_terminal_and_counts_the_rest() {
    let mut hold = CreationHold::new(T0);
    let ticket = new_terminal(&mut hold, Some("pending_tab_1"), true);
    key(&mut hold, 1, Some("pending_tab_1"));
    key(&mut hold, 2, Some("elsewhere"));
    hold.resolve(ticket, true, None, true, None, &live());
    let (runs, lost) = hold.take_for_closed_window(&live());
    assert_eq!(
        runs,
        vec![(
            vec![1],
            HeldLane {
                tab: "pending_tab_1".into(),
                machine: Some("local".into()),
                made_surface: None
            }
        )]
    );
    assert_eq!(lost, 1);
}

#[test]
fn past_the_reply_bound_the_keys_run_as_typed() {
    let mut hold = CreationHold::new(T0);
    new_terminal(&mut hold, None, true);
    hold.capture(1, false, Some("press"), false, true, None);
    hold.end_reply_wait(None, &BTreeSet::new(), &live());
    assert_eq!(take(&mut hold, "press", &live()), vec!["run"]);
}

#[test]
fn a_shortcut_typed_for_another_terminal_runs_in_its_tab() {
    let mut hold = CreationHold::new(T0);
    let ticket = open(&mut hold, 1, Some("split"));
    hold.capture(5, true, Some("split"), false, false, None);
    hold.capture(6, true, Some("split"), false, false, None);
    hold.resolve(ticket, true, None, false, None, &live());
    assert_eq!(hold.held_tabs(&live()), vec![(5, Some("split".into())), (6, Some("split".into()))]);
    let keys = hold.take_focused(Some("other"), None, &BTreeSet::from([5]), &live());
    assert_eq!(ends(&keys), vec!["command in split", "type 1 into split"]);
}

#[test]
fn a_close_whose_question_asks_hands_its_keys_to_the_tab_that_stays() {
    let mut hold = CreationHold::new(T0);
    let close = hold.open_close(vec!["a".into(), "b".into()], Some("local".into()), false, &live());
    assert!(hold.is_closing(Some("b")) && !hold.is_closing(Some("c")));
    assert_eq!(hold.lane(Some("a")), Some(close.ticket));
    key(&mut hold, 1, Some("a"));
    hold.park_close(close.ticket, &live());
    assert!(!hold.is_closing(Some("a")));
    hold.settle_close(close.ticket, None, true, None, &live());
    assert_eq!(take(&mut hold, "other", &live()), vec!["type 1 into a"]);
}

#[test]
fn the_state_round_trips_in_the_wire_shape() {
    let mut hold = CreationHold::new(T0);
    let ticket = new_terminal(&mut hold, Some("pending_tab_1"), false);
    key(&mut hold, 1, Some("pending_tab_1"));
    hold.resolve(ticket, true, None, true, Some(9), &live());
    let json = serde_json::to_value(&hold).unwrap();
    assert_eq!(json["newTerminals"]["surfaces"]["1"], 9);
    let back: CreationHold = serde_json::from_value(json).unwrap();
    assert_eq!(back, hold);
    let empty: CreationHold = serde_json::from_str("{}").unwrap();
    assert_eq!(empty.reply_wait_limit_ns, REPLY_WAIT_BOUND_NS);
}
