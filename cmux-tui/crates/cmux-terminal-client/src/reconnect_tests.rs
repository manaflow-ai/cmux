use super::*;

/// A reopen that is tried again forever waits at most the back-off's top (plus its jitter)
/// between tries, however many tries it has taken: no overflow, no growing wait.
#[test]
fn the_reconnect_back_off_stays_bounded_however_long_it_retries() {
    let id = TerminalPublicId::parse(format!("term_{:032x}", 7)).unwrap();
    let top = TERMINAL_RECONNECT_MAX_DELAY + StdDuration::from_millis(100);
    for attempt in [1, 2, 8, 9, 100, 10_000, u32::MAX] {
        let delay = terminal_reconnect_delay(&id, attempt);
        assert!(delay <= top, "attempt {attempt}: {delay:?}");
        assert!(delay >= TERMINAL_RECONNECT_INITIAL_DELAY, "attempt {attempt}: {delay:?}");
    }
    assert!(terminal_reconnect_delay(&id, 1_000) >= TERMINAL_RECONNECT_MAX_DELAY);
}
