use super::*;

fn never(_: &str) -> bool {
    false
}

#[test]
fn a_detached_session_is_kept_between_its_calls() {
    let mut d = Detached::default();
    let t0 = Instant::now();
    assert!(d.touch("cli", t0, never).is_empty());
    // The next CLI process calls a minute later: the session (its ids) is still there.
    assert!(d.touch("cli", t0 + Duration::from_secs(60), never).is_empty());
    assert!(d.contains("cli"));
    // Its idle clock restarted at its last call.
    let later = t0 + Duration::from_secs(60) + DETACHED_IDLE - Duration::from_secs(1);
    assert!(d.touch("other", later, never).is_empty());
    assert!(d.contains("cli"));
}

#[test]
fn a_detached_session_idle_past_the_limit_ends_on_the_next_call() {
    let mut d = Detached::default();
    let t0 = Instant::now();
    d.touch("cli", t0, never);
    d.touch("remote:mini:a", t0, never);
    let ended = d.touch("remote:mini:a", t0 + DETACHED_IDLE, never);
    // The caller itself never ends on its own call; the idle one does.
    assert_eq!(ended.len(), 1);
    assert_eq!(ended[0].0, "cli");
    assert!(!d.contains("cli"));
    assert!(d.contains("remote:mini:a"));
}

#[test]
fn past_the_cap_the_least_recently_used_end_first() {
    let mut d = Detached::default();
    let t0 = Instant::now();
    for i in 0..DETACHED_MAX {
        assert!(d.touch(&format!("s{i}"), t0 + Duration::from_secs(i as u64), never).is_empty());
    }
    // s0 calls again: s1 is now the oldest.
    d.touch("s0", t0 + Duration::from_secs(100), never);
    let ended = d.touch("new", t0 + Duration::from_secs(101), never);
    assert_eq!(ended.len(), 1);
    assert_eq!(ended[0].0, "s1");
    assert_eq!(d.len(), DETACHED_MAX);
    assert!(d.contains("s0") && d.contains("new"));
}

#[test]
fn an_attached_session_is_never_ended_here() {
    let mut d = Detached::default();
    let t0 = Instant::now();
    d.touch("agent", t0, never);
    // The agent attached since: its attach's close ends it, not the idle clock.
    let ended = d.touch("cli", t0 + DETACHED_IDLE * 2, |s| s == "agent");
    assert!(ended.is_empty());
    assert!(!d.contains("agent"));
    // An attached caller is not tracked at all.
    assert!(d.touch("agent", t0, |s| s == "agent").is_empty());
    assert!(!d.contains("agent"));
}

#[test]
fn forget_drops_a_session_that_ended_another_way() {
    let mut d = Detached::default();
    d.touch("cli", Instant::now(), never);
    d.forget("cli");
    assert!(!d.contains("cli"));
}

#[test]
fn a_touch_invalidates_queued_expiry_even_if_the_session_expires_again() {
    let mut d = Detached::default();
    let t0 = Instant::now();
    d.touch("cli", t0, never);
    let first = d.touch("other", t0 + DETACHED_IDLE, never)[0].clone();
    d.touch("cli", t0 + DETACHED_IDLE, never);
    let second = d.touch("other", t0 + DETACHED_IDLE * 2, never)[0].clone();
    assert_eq!(first.0, "cli");
    assert_eq!(second.0, "cli");
    assert!(!d.take_expiry(&first.0, first.1));
    assert!(d.take_expiry(&second.0, second.1));
    assert!(!d.take_expiry(&second.0, second.1));
}

#[test]
fn forgetting_a_session_invalidates_its_queued_expiry() {
    let mut d = Detached::default();
    let t0 = Instant::now();
    d.touch("cli", t0, never);
    let expired = d.touch("other", t0 + DETACHED_IDLE, never)[0].clone();
    d.forget("cli");
    assert!(!d.take_expiry(&expired.0, expired.1));
}
