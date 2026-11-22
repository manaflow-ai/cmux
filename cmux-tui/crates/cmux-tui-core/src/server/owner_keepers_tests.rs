use std::time::{Duration, Instant};

use super::{Keepers, UNATTENDED_TERMINAL_KEEP, unattended_after};

fn idle() -> Keepers {
    Keepers {
        armed: true,
        clients: 0,
        browser_host: false,
        app_servers: 0,
        chief_brains: 0,
        terminals: Some(0),
        unattended: false,
    }
}

#[test]
fn an_armed_owner_with_nothing_kept_may_stop() {
    assert!(idle().none());
}

#[test]
fn an_owner_its_app_never_reached_is_kept() {
    assert!(!Keepers { armed: false, ..idle() }.none());
}

#[test]
fn each_keeper_alone_keeps_the_owner() {
    assert!(!Keepers { clients: 1, ..idle() }.none());
    assert!(!Keepers { browser_host: true, ..idle() }.none());
    assert!(!Keepers { app_servers: 1, ..idle() }.none());
    assert!(!Keepers { chief_brains: 1, ..idle() }.none());
    assert!(!Keepers { terminals: Some(1), ..idle() }.none());
}

#[test]
fn an_unread_terminal_count_keeps_the_owner() {
    assert!(!Keepers { terminals: None, ..idle() }.none());
}

#[test]
fn terminals_are_read_only_when_nothing_cheaper_keeps_the_owner() {
    assert!(idle().terminals_decide());
    assert!(!Keepers { armed: false, ..idle() }.terminals_decide());
    assert!(!Keepers { clients: 1, ..idle() }.terminals_decide());
    assert!(!Keepers { browser_host: true, ..idle() }.terminals_decide());
    assert!(!Keepers { app_servers: 2, ..idle() }.terminals_decide());
    assert!(!Keepers { chief_brains: 1, ..idle() }.terminals_decide());
}

/// A developer Mac, 2026-11-21: owners whose app never came back, and their
/// terminal hosts, ran for up to 34 days, each keeping the other. Live
/// terminals keep an owner only while a client came within the bound.
#[test]
fn live_terminals_stop_keeping_an_owner_no_client_reached_for_a_day() {
    let kept = Keepers { terminals: Some(3), ..idle() };
    assert!(!kept.none(), "a live terminal keeps an attended owner");
    assert!(Keepers { unattended: true, ..kept }.none());
    assert_eq!(UNATTENDED_TERMINAL_KEEP, Duration::from_secs(24 * 60 * 60));
}

#[test]
fn an_unattended_owner_is_still_kept_by_everything_but_its_terminals() {
    let unattended = Keepers { terminals: Some(3), unattended: true, ..idle() };
    assert!(!Keepers { armed: false, ..unattended }.none());
    assert!(!Keepers { clients: 1, ..unattended }.none());
    assert!(!Keepers { browser_host: true, ..unattended }.none());
    assert!(!Keepers { app_servers: 1, ..unattended }.none());
    assert!(!Keepers { chief_brains: 1, ..unattended }.none());
    assert!(!Keepers { terminals: None, ..unattended }.none(), "an unread count keeps it");
}

#[test]
fn the_unattended_clock_runs_only_with_no_client_and_says_when_it_ends() {
    let start = Instant::now();
    let keep = Duration::from_secs(100);
    assert_eq!(unattended_after(None, start + keep * 10, keep), (false, None));
    assert_eq!(
        unattended_after(Some(start), start + Duration::from_secs(40), keep),
        (false, Some(Duration::from_secs(60)))
    );
    assert_eq!(unattended_after(Some(start), start + keep, keep), (true, None));
}
