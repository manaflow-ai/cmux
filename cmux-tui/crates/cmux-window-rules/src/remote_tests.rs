use super::*;

fn host(id: &str, names: &[&str]) -> Machine {
    Machine { id: id.to_owned(), names: names.iter().map(|name| (*name).to_owned()).collect() }
}

fn hosts() -> Vec<Machine> {
    vec![
        host("m1", &["Box", "me@box.lan"]),
        host("m2", &["Dev", "dev.lan"]),
        host("m3", &["dev", "other"]),
    ]
}

#[test]
fn a_target_matches_an_id_first() {
    assert_eq!(machine(Some("m2"), &hosts(), None), Ok(1));
}

#[test]
fn a_target_matches_exactly_one_name_case_insensitively() {
    assert_eq!(machine(Some("ME@BOX.LAN"), &hosts(), None), Ok(0));
    assert_eq!(
        machine(Some("dev"), &hosts(), None),
        Err(MachineRefusal::UnknownMachine { target: "dev".to_owned() })
    );
    assert_eq!(
        machine(Some("nope"), &hosts(), Some("m1")),
        Err(MachineRefusal::UnknownMachine { target: "nope".to_owned() })
    );
}

#[test]
fn without_a_target_the_active_window_then_the_only_machine() {
    assert_eq!(machine(None, &hosts(), Some("m3")), Ok(2));
    assert_eq!(machine(None, &hosts(), Some("local")), Err(MachineRefusal::NoMachine));
    assert_eq!(machine(None, &hosts()[..1], None), Ok(0));
    assert_eq!(machine(None, &[], None), Err(MachineRefusal::NoMachine));
}

#[test]
fn placement_words_map_to_right_or_down() {
    assert_eq!(
        terminal_here(Some("right"), true, false),
        TerminalHere::Open { split: Some(Split::Right) }
    );
    for word in ["down", "below", "bottom"] {
        assert_eq!(
            terminal_here(Some(word), false, false),
            TerminalHere::Open { split: Some(Split::Down) }
        );
    }
    assert_eq!(terminal_here(Some("left"), true, false), TerminalHere::SplitRightOrDown);
}

#[test]
fn the_panes_own_machine_with_nothing_asked_is_a_new_tab() {
    assert_eq!(terminal_here(None, true, false), TerminalHere::NewSurface);
    assert_eq!(terminal_here(None, true, true), TerminalHere::Open { split: None });
    assert_eq!(terminal_here(None, false, false), TerminalHere::Open { split: None });
}

#[test]
fn a_loaded_machine_shows_its_workspace_and_offline_ends() {
    let loaded = ConnectFacts {
        loaded: true,
        offline: true,
        needs_recovery: true,
        ..ConnectFacts::default()
    };
    assert_eq!(
        connect_step(loaded),
        ConnectStep { show_workspace: true, ..ConnectStep::default() }
    );
    let offline = ConnectFacts { offline: true, needs_recovery: true, ..ConnectFacts::default() };
    assert_eq!(connect_step(offline), ConnectStep { end: true, ..ConnectStep::default() });
}

#[test]
fn a_windowless_failure_of_the_current_attempt_opens_a_recovery_window() {
    let failed =
        ConnectFacts { failure_attempt: Some(1), current_attempt: 1, ..ConnectFacts::default() };
    assert_eq!(
        connect_step(failed),
        ConnectStep { open_window: true, recovery: true, ..ConnectStep::default() }
    );
    let shown = ConnectFacts { has_window: true, ..failed };
    assert_eq!(connect_step(shown), ConnectStep { recovery: true, ..ConnectStep::default() });
}

#[test]
fn an_old_attempts_failure_never_reopens_recovery() {
    let retried =
        ConnectFacts { failure_attempt: Some(1), current_attempt: 2, ..ConnectFacts::default() };
    assert_eq!(connect_step(retried), ConnectStep::default());
    let connecting = ConnectFacts::default();
    assert_eq!(connect_step(connecting), ConnectStep::default());
    let blocked =
        ConnectFacts { needs_recovery: true, has_window: true, ..ConnectFacts::default() };
    assert!(connect_step(blocked).recovery);
}
