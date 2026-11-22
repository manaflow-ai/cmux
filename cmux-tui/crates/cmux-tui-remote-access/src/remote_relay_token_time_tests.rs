use super::*;

struct Clock {
    monotonic: Instant,
    wall: Option<u64>,
}

impl RevocationClock for Clock {
    fn now(&self) -> Instant {
        self.monotonic
    }
    fn unix_time_ms(&self) -> Option<u64> {
        self.wall
    }
}

const WALL: u64 = 1_700_000_000_000;

fn set_time(state: &mut Revocation, monotonic: Instant, wall: Option<u64>) {
    state.set_clock(Arc::new(Clock { monotonic, wall }));
}

#[test]
fn offline_limits_run_from_issuance_on_both_sides_of_the_deadlines() {
    let mut state = Revocation::default();
    let now = Instant::now();
    set_time(&mut state, now, Some(WALL));
    assert!(state.record_good_check_at("inst_1", WALL - 90_000));
    let at = now - Duration::from_secs(90);
    assert_eq!(state.good_check_time("inst_1"), Some(at));
    for (age, policy) in [
        (REFUSE_NEW_STREAMS_AFTER, StreamPolicy::Serve),
        (REFUSE_NEW_STREAMS_AFTER + Duration::from_millis(1), StreamPolicy::RefuseNew),
        (CLOSE_STREAMS_AFTER, StreamPolicy::RefuseNew),
        (CLOSE_STREAMS_AFTER + Duration::from_millis(1), StreamPolicy::Close),
    ] {
        set_time(&mut state, at + age, Some(WALL));
        assert_eq!(state.policy("inst_1"), policy);
    }
}

#[test]
fn repeated_and_older_tokens_do_not_renew_or_roll_back_a_good_check() {
    let mut state = Revocation::default();
    let now = Instant::now();
    set_time(&mut state, now, Some(WALL));
    assert!(state.record_good_check_at("inst_1", WALL - 90_000));
    let at = state.good_check_time("inst_1");
    // Even a wall-clock rollback must not turn the same signed iat into a new check.
    set_time(&mut state, now + Duration::from_secs(10), Some(WALL - 30_000));
    for issue in [WALL - 90_000, WALL - 100_000] {
        assert!(state.record_good_check_at("inst_1", issue));
        assert_eq!(state.good_check_time("inst_1"), at);
    }
    assert!(state.record_good_check_at("inst_1", WALL - 50_000));
    assert!(state.good_check_time("inst_1") > at);
}

#[test]
fn zero_future_and_unavailable_wall_time_leave_no_check() {
    let mut state = Revocation::default();
    let now = Instant::now();
    for (wall, issue) in [(Some(WALL), 0), (Some(WALL), WALL + 1), (None, WALL)] {
        set_time(&mut state, now, wall);
        assert!(!state.record_good_check_at("inst_1", issue));
        assert_eq!(state.good_check_time("inst_1"), None);
        assert_eq!(state.policy("inst_1"), StreamPolicy::Close);
    }
}

#[test]
fn accepted_tokens_cannot_undo_final_revocation_or_replace_a_newer_direct_check() {
    let mut state = Revocation::default();
    let now = Instant::now();
    set_time(&mut state, now, Some(WALL));
    state.record_good_check("inst_1");
    assert!(state.record_good_check_at("inst_1", WALL - 90_000));
    assert_eq!(state.good_check_time("inst_1"), Some(now));
    state.record_revoked("inst_1");
    assert!(!state.record_good_check_at("inst_1", WALL));
    assert_eq!(state.policy("inst_1"), StreamPolicy::Close);
}
