use super::*;

fn closed(why: &str) -> RpcError {
    RpcError::internal(format!("{} (chief): {why}", crate::agent::AGENT_CLOSED))
}

#[test]
fn a_repeated_launch_failure_backs_off_up_to_a_bound_and_a_change_or_success_ends_it() {
    let backoff = LaunchBackoff::default();
    let t0 = Instant::now();
    let e = closed("cmux: unknown resource scope \"chief\"");
    assert!(is_launch_failure(&e));
    assert!(!is_launch_failure(&RpcError::internal("session/new refused")));
    // The first failure is retried as before.
    assert_eq!(backoff.failed(&e, t0), None);
    assert!(backoff.held(t0).is_none());
    // The second identical one holds starts for 30 s, then 60 s, ... up to 30 min.
    assert_eq!(backoff.failed(&e, t0), Some((2, FIRST_HOLD)));
    assert_eq!(backoff.held(t0 + Duration::from_secs(29)).unwrap().message, e.message);
    assert!(backoff.held(t0 + FIRST_HOLD).is_none());
    assert_eq!(backoff.failed(&e, t0), Some((3, Duration::from_secs(60))));
    let mut last = Duration::ZERO;
    for _ in 0..40 {
        last = backoff.failed(&e, t0).unwrap().1;
    }
    assert_eq!(last, MAX_HOLD);
    assert!(backoff.held(t0 + MAX_HOLD).is_none(), "a fix underneath is picked up");
    // Another error starts over: retried once.
    assert_eq!(backoff.failed(&closed("segfault"), t0), None);
    assert!(backoff.held(t0).is_none());
    backoff.failed(&closed("segfault"), t0);
    assert!(backoff.held(t0).is_some());
    backoff.clear();
    assert!(backoff.held(t0).is_none());
    assert_eq!(backoff.failed(&closed("segfault"), t0), None);
}
