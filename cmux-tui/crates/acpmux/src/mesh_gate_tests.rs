use super::*;
use futures::FutureExt;

/// `ms` milliseconds after a fixed start.
fn at(ms: u64) -> Instant {
    static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
    *START.get_or_init(Instant::now) + Duration::from_millis(ms)
}

fn ms(d: Duration) -> u64 {
    u64::try_from(d.as_millis()).unwrap()
}

#[test]
fn an_open_gate_lets_every_post_go() {
    let gate = Gate::default();
    assert!((0..100).all(|_| gate.may_try_at(at(5))));
}

#[test]
fn a_shut_gate_lets_one_probe_go_per_window_and_the_window_doubles() {
    let gate = Gate::default();
    gate.failed_at(at(1_000), None);
    // Within the first window nothing goes.
    assert!(!gate.may_try_at(at(1_500)));
    // At its end one probe goes; the others in that window do not.
    assert!(gate.may_try_at(at(2_000)));
    assert!(!gate.may_try_at(at(2_000)));
    assert!(!gate.may_try_at(at(2_900)));
    // The probe failed too: two seconds now.
    gate.failed_at(at(2_100), None);
    assert!(!gate.may_try_at(at(3_500)));
    assert!(gate.may_try_at(at(4_100)));
    // A hundred failures in a row still wait one minute at most.
    for _ in 0..100 {
        gate.failed_at(at(10_000), None);
    }
    assert!(gate.may_try_at(at(10_000 + ms(MAX_WINDOW))));
    // An answer opens it.
    let opened = gate.opened.notified();
    tokio::pin!(opened);
    assert!(opened.as_mut().now_or_never().is_none(), "a shut gate has not opened yet");
    gate.answered();
    assert!(!gate.shut());
    assert!(opened.now_or_never().is_some(), "opening it wakes the waits armed before");
    assert!((0..10).all(|_| gate.may_try_at(at(10_001))));
}

#[tokio::test]
async fn an_answer_after_failing_wakes_every_send_waiting_behind_it() {
    let gate = Gate::default();
    gate.failed(Some(Duration::from_secs(30)));
    assert!(gate.reopens_at().is_some());
    let mut waits: Vec<_> = (0..20).map(|_| Box::pin(gate.opened.notified())).collect();
    for w in &mut waits {
        w.as_mut().enable();
    }
    gate.answered();
    assert!(gate.reopens_at().is_none());
    assert!(waits.into_iter().all(|w| w.now_or_never().is_some()));
}

#[test]
fn the_hubs_retry_after_is_kept_up_to_the_cap() {
    let gate = Gate::default();
    gate.failed_at(at(0), Some(Duration::from_secs(10)));
    assert!(!gate.may_try_at(at(9_999)));
    assert!(gate.may_try_at(at(10_000)));
    let gate = Gate::default();
    gate.failed_at(at(0), Some(Duration::from_secs(3_600)));
    assert!(gate.may_try_at(at(ms(MAX_WINDOW))));
}
