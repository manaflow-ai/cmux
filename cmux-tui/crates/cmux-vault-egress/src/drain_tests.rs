use super::*;
use std::time::Duration;

#[test]
fn unfinished_tunnel_defers_and_cancellation_reopens_admission() {
    tokio::runtime::Builder::new_current_thread().enable_time().build().unwrap().block_on(async {
        let admission = Arc::new(Admission::default());
        let tunnel = admission.admit().unwrap();
        let drain = admission.begin_drain();
        assert!(admission.admit().is_none());
        assert!(!drain.wait_until(tokio::time::Instant::now() + Duration::from_millis(1)).await);
        drop(drain);
        assert!(admission.admit().is_some());
        let drain = admission.begin_drain();
        drop(tunnel);
        assert!(drain.wait_until(tokio::time::Instant::now() + Duration::from_secs(1)).await);
        drain.commit();
        assert!(admission.admit().is_none());
    });
}

#[test]
fn cancelling_one_drain_cannot_reopen_another() {
    let admission = Arc::new(Admission::default());
    let first = admission.begin_drain();
    let second = admission.begin_drain();
    drop(first);
    assert!(admission.admit().is_none());
    drop(second);
    assert!(admission.admit().is_some());
}
