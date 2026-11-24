use super::*;

#[test]
fn one_waiting_thread_follows_the_latest_idle_time() {
    let start = Instant::now();
    let mut linger = Linger::default();
    assert!(linger.idle(start, LINGER), "the first idle starts the thread");
    assert_eq!(linger.wait(start), Next::Sleep(LINGER));
    // A second one-shot call came and went: the same thread waits longer.
    let later = start + Duration::from_secs(20);
    assert!(!linger.idle(later, LINGER), "no second thread");
    assert_eq!(linger.wait(start + LINGER), Next::Sleep(Duration::from_secs(20)));
    assert_eq!(linger.wait(later + LINGER), Next::Release);
    // The thread ended with the release; the next idle starts a new one.
    assert!(linger.idle(later + LINGER * 2, LINGER));
}

#[test]
fn an_idle_after_the_release_check_starts_a_new_wait() {
    let start = Instant::now();
    let mut linger = Linger::default();
    assert!(linger.idle(start, Duration::ZERO));
    assert_eq!(linger.wait(start), Next::Release);
    assert_eq!(linger.wait(start), Next::Stop);
    assert!(linger.idle(start, LINGER));
}
