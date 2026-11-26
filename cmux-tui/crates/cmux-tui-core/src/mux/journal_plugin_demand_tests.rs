use super::*;

#[test]
fn shells_are_known_by_basename_and_login_dash() {
    for name in ["zsh", "-zsh", "/bin/bash", "/usr/local/bin/fish", "-/bin/sh", "login"] {
        assert!(is_shell(name), "{name} is a shell");
    }
    for name in ["claude", "/opt/homebrew/bin/codex", "node", "vim", "zshdb", ""] {
        assert!(!is_shell(name), "{name} is not a shell");
    }
}

#[test]
fn agent_reports_release_and_terminal_events_check_one_terminal() {
    assert_eq!(wake_of(&MuxEvent::SurfaceOutput(7)), Wake::Surface(7));
    assert_eq!(wake_of(&MuxEvent::AgentPresenceChanged { surface: 7, presence: None }), Wake::None);
    assert_eq!(
        wake_of(&MuxEvent::TerminalRegistryChanged {
            registry_id: "r".into(),
            generation: "g".into(),
            terminal_revision: 1,
        }),
        Wake::All
    );
    assert_eq!(wake_of(&MuxEvent::TreeChanged), Wake::None);
    assert!(!wakes(&MuxEvent::TreeChanged));
    assert!(wakes(&MuxEvent::SurfaceOutput(7)));
}

#[test]
fn a_shell_at_its_prompt_never_releases() {
    let mut watch = DemandWatch::default();
    let start = Instant::now();
    for second in 0..30 {
        assert!(!watch.check(100, start + Duration::from_secs(second), false, |_| None));
    }
    assert_eq!(watch.next_due(), None, "an idle terminal schedules no check");
}

#[test]
fn an_event_that_finds_the_shell_checks_once_more() {
    let mut watch = DemandWatch::default();
    let start = Instant::now();
    // The echo of `sleep 120⏎` comes before the shell forks `sleep`.
    assert!(!watch.check(100, start, true, |_| None));
    assert_eq!(watch.next_due(), Some(start + RECHECK), "one follow-up check");
    assert!(watch.due(start + RECHECK).contains(&100));
    // The follow-up finds the silent program; no further event comes.
    assert!(!watch.check(100, start + RECHECK, false, |_| Some(200)));
    assert!(watch.check(100, start + RECHECK + CONFIRM, false, |_| Some(200)));
    // A follow-up that finds the shell again schedules nothing more.
    let mut idle = DemandWatch::default();
    assert!(!idle.check(100, start, true, |_| None));
    assert!(!idle.check(100, start + RECHECK, false, |_| None));
    assert_eq!(idle.next_due(), None);
}

#[test]
fn a_quick_command_does_not_release() {
    let mut watch = DemandWatch::default();
    let start = Instant::now();
    assert!(!watch.check(100, start, true, |_| Some(200)));
    // `ls` ended before its confirmation: the shell holds the terminal again.
    assert!(!watch.check(100, start + CONFIRM, true, |_| None));
    // A new job is a new candidate, confirmed only CONFIRM after it was seen.
    assert!(!watch.check(100, start + CONFIRM + RECHECK, true, |_| Some(201)));
    assert!(!watch.check(100, start + CONFIRM + RECHECK * 2, true, |_| Some(202)));
}

#[test]
fn a_program_that_holds_the_terminal_releases_at_its_confirmation() {
    let mut watch = DemandWatch::default();
    let start = Instant::now();
    assert!(!watch.check(100, start, true, |_| Some(200)));
    assert_eq!(watch.next_due(), Some(start + CONFIRM), "the confirmation is scheduled");
    assert!(watch.due(start + CONFIRM).contains(&100));
    assert!(watch.check(100, start + CONFIRM, true, |_| Some(200)));
}

#[test]
fn checks_within_the_recheck_interval_are_deferred_not_dropped() {
    let mut watch = DemandWatch::default();
    let start = Instant::now();
    assert!(!watch.check(100, start, true, |_| None));
    let mut probed = false;
    assert!(!watch.check(100, start + Duration::from_millis(10), true, |_| {
        probed = true;
        Some(200)
    }));
    assert!(!probed, "a second event within RECHECK reads no process");
    assert_eq!(watch.next_due(), Some(start + RECHECK), "but a check is due at RECHECK");
}

#[test]
fn retain_forgets_ended_terminals() {
    let mut watch = DemandWatch::default();
    let start = Instant::now();
    assert!(!watch.check(100, start, true, |_| Some(200)));
    watch.retain(&HashSet::new());
    assert_eq!(watch.next_due(), None);
}

#[cfg(unix)]
#[test]
fn a_command_terminal_running_a_program_is_one() {
    // The test process's own pid is no terminal: no foreground group, so no program.
    assert_eq!(running_program(std::process::id()), None);
}

#[test]
fn a_tap_delivers_while_open_and_counts_a_full_queue() {
    let tap = DemandTap::default();
    // Closed: a send goes nowhere.
    tap.send(Wake::All);
    let (open, wakes) = tap.open();
    assert!(demand_tapped());
    tap.send(Wake::Agent);
    assert!(matches!(wakes.try_recv(), Ok(Wake::Agent)));
    for _ in 0..TAP_CAPACITY {
        tap.send(Wake::All);
    }
    assert!(!open.take_missed());
    tap.send(Wake::All);
    assert!(open.take_missed());
    assert!(!open.take_missed());
    drop(open);
    tap.send(Wake::Agent);
    assert_eq!(wakes.try_iter().count(), TAP_CAPACITY);
}
