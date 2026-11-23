use super::*;

/// R-LIFECYCLE S1b: an abandoned respawn changes what keeps an app
/// session's owner (server/owner_keepers.rs), so it wakes the terminal
/// lifecycle watchers, as the other ends of a respawn do.
#[cfg(any(unix, windows))]
#[test]
fn an_abandoned_respawn_wakes_the_terminal_lifecycle_watchers() {
    let mux = Mux::new_for_test("test", SurfaceOptions::default());
    let events = mux.subscribe_terminal_lifecycle();
    while events.try_recv().is_ok() {}
    mux.pending_terminals
        .lock()
        .unwrap()
        .insert("term_x".to_string(), ("t1".to_string(), PendingTerminal::Respawning));
    mux.abandon_terminal_respawn("t1");
    assert!(!mux.terminal_is_respawning("t1"));
    assert!(events.try_recv().is_ok(), "an abandoned respawn woke no terminal lifecycle watcher");
}

#[test]
fn a_closed_terminals_argv_is_forgotten_and_the_memory_is_bounded() {
    let respawns = TerminalRespawns::from_env();
    let argv = vec!["make".to_string(), "test".to_string()];
    respawns.remember_argv("t1", &argv);
    assert_eq!(respawns.argv("t1"), Some(argv.clone()));
    respawns.forget_argv("t1");
    assert_eq!(respawns.argv("t1"), None);
    for index in 0..ARGV_LIMIT + 10 {
        respawns.remember_argv(&format!("t{index}"), &argv);
    }
    assert_eq!(respawns.argv("t0"), None, "the oldest argv was not evicted");
    assert_eq!(respawns.argv(&format!("t{}", ARGV_LIMIT + 9)), Some(argv));
    let memory = respawns.argv.lock().unwrap_or_else(PoisonError::into_inner);
    assert_eq!(memory.by_terminal.len(), ARGV_LIMIT);
    assert_eq!(memory.order.len(), ARGV_LIMIT);
}
