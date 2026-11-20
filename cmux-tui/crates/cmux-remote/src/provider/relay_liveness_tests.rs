use super::*;

const HEARTBEAT: Duration = Duration::from_secs(15);

fn start() -> (Instant, SystemTime) {
    (Instant::now(), SystemTime::UNIX_EPOCH + Duration::from_secs(1_800_000_000))
}

#[test]
fn a_quiet_live_registration_pings_on_its_heartbeat() {
    let (mono, wall) = start();
    let mut live = Liveness::with_young(HEARTBEAT, Duration::ZERO, mono, wall);
    let at = |s: u64| (mono + Duration::from_secs(s), wall + Duration::from_secs(s));
    for s in 1..15 {
        let (m, w) = at(s);
        assert_eq!(live.check(m, w), Check::Idle, "{s}");
    }
    let (m, w) = at(15);
    assert_eq!(live.check(m, w), Check::Ping);
    live.on_inbound();
    let (m, w) = at(16);
    assert_eq!(live.check(m, w), Check::Idle);
}

#[test]
fn an_unanswered_ping_is_a_dead_registration() {
    let (mono, wall) = start();
    let mut live = Liveness::with_young(HEARTBEAT, Duration::ZERO, mono, wall);
    let at = |s: u64| (mono + Duration::from_secs(s), wall + Duration::from_secs(s));
    let (m, w) = at(15);
    assert_eq!(live.check(m, w), Check::Ping);
    let (m, w) = at(17);
    assert_eq!(live.check(m, w), Check::Idle);
    let (m, w) = at(18);
    assert_eq!(live.check(m, w), Check::Dead);
}

/// A short pause (30 s, inside the relay's 45 s): the monotonic clock
/// stands still while the wall clock moves. The next check pings at once,
/// and a dead registration is found within PONG_TIMEOUT, long before the
/// next heartbeat.
#[test]
fn a_short_pause_pings_at_once_and_finds_a_dead_registration_in_seconds() {
    let (mono, wall) = start();
    let mut live = Liveness::with_young(HEARTBEAT, Duration::ZERO, mono, wall);
    let (m, w) = (mono + Duration::from_secs(5), wall + Duration::from_secs(5));
    assert_eq!(live.check(m, w), Check::Idle);
    // Paused 30 s: monotonic +1 s (the next check), wall +31 s.
    let resumed = (m + CHECK_INTERVAL, w + Duration::from_secs(31));
    assert_eq!(live.check(resumed.0, resumed.1), Check::Ping);
    let later = |s: u64| (resumed.0 + Duration::from_secs(s), resumed.1 + Duration::from_secs(s));
    let (m, w) = later(2);
    assert_eq!(live.check(m, w), Check::Idle);
    let (m, w) = later(3);
    assert_eq!(live.check(m, w), Check::Dead);
}

/// A pause past the relay's 45 s: the registration is dead at once, with
/// no ping and no pong timeout.
#[test]
fn a_resume_past_the_relays_retirement_is_a_dead_registration_at_once() {
    let (mono, wall) = start();
    let mut live = Liveness::with_young(HEARTBEAT, Duration::ZERO, mono, wall);
    let (m, w) = (mono + CHECK_INTERVAL, wall + CHECK_INTERVAL + Duration::from_secs(600));
    assert_eq!(live.check(m, w), Check::Resumed);
}

/// A credential source failed three times before a pause (its backoff
/// is up to 8 s); the resume registers at once and starts the backoff over.
#[test]
fn a_young_registration_probes_every_check_and_finds_a_silent_death_in_seconds() {
    let (mono, wall) = start();
    let mut live = Liveness::new(Duration::from_secs(10), mono, wall);
    let at = |s: u64| (mono + Duration::from_secs(s), wall + Duration::from_secs(s));
    // Answered probes every second while young.
    for s in 1..=3 {
        let (m, w) = at(s);
        assert_eq!(live.check(m, w), Check::Ping, "{s}");
        live.on_inbound();
    }
    // The socket dies silently: the probe at 4 s goes unanswered.
    let (m, w) = at(4);
    assert_eq!(live.check(m, w), Check::Ping);
    let (m, w) = at(5);
    assert_eq!(live.check(m, w), Check::Idle);
    let (m, w) = at(6);
    assert_eq!(live.check(m, w), Check::Idle);
    let (m, w) = at(7);
    assert_eq!(live.check(m, w), Check::Dead, "found 3 s after the death, not 13 s");
}

#[test]
fn a_registration_past_young_falls_back_to_its_heartbeat() {
    let (mono, wall) = start();
    let mut live = Liveness::new(Duration::from_secs(10), mono, wall);
    let at = |s: u64| (mono + Duration::from_secs(s), wall + Duration::from_secs(s));
    let young = YOUNG.as_secs();
    for s in 1..young {
        let (m, w) = at(s);
        assert_eq!(live.check(m, w), Check::Ping, "{s}");
        live.on_inbound();
    }
    // The last young probe was at young - 1; the next is a heartbeat later.
    for s in young..young - 1 + 10 {
        let (m, w) = at(s);
        assert_eq!(live.check(m, w), Check::Idle, "{s}");
    }
    let (m, w) = at(young - 1 + 10);
    assert_eq!(live.check(m, w), Check::Ping);
}

#[test]
fn a_resume_registers_with_no_backoff_and_starts_the_backoffs_over() {
    let mut retry = Retry::new();
    for _ in 0..3 {
        retry.wait(Ended::Credential, 1.0);
    }
    assert_eq!(retry.wait(Ended::Credential, 1.0), Duration::from_secs(8));
    assert_eq!(retry.wait(Ended::Resumed, 1.0), Duration::ZERO);
    assert_eq!(retry.wait(Ended::Credential, 1.0), FIRST_CREDENTIAL_BACKOFF);
    assert_eq!(retry.wait(Ended::Relay, 1.0), FIRST_BACKOFF);
}

#[test]
fn the_clock_watch_sees_a_pause_and_not_a_steady_clock() {
    let (mono, wall) = start();
    let mut clocks = ClockWatch::new(mono, wall);
    assert_eq!(clocks.jump(mono + CHECK_INTERVAL, wall + CHECK_INTERVAL), Duration::ZERO);
    let (m, w) = (mono + CHECK_INTERVAL * 2, wall + CHECK_INTERVAL * 2 + RELAY_RETIRES_SILENT);
    assert_eq!(clocks.jump(m, w), RELAY_RETIRES_SILENT);
    let (m, w) = (m + CHECK_INTERVAL, w + CHECK_INTERVAL + Duration::from_secs(46));
    assert_eq!(clocks.jump(m, w), Duration::from_secs(46));
    let back = clocks.jump(m + CHECK_INTERVAL, w - Duration::from_secs(600));
    assert_eq!(back, Duration::ZERO, "a clock set back is no resume");
}

#[test]
fn a_wall_clock_set_backwards_or_a_small_step_is_no_resume() {
    let (mono, wall) = start();
    let mut live = Liveness::with_young(HEARTBEAT, Duration::ZERO, mono, wall);
    let m = mono + CHECK_INTERVAL;
    assert_eq!(live.check(m, wall - Duration::from_secs(60)), Check::Idle);
    let m2 = m + CHECK_INTERVAL;
    assert_eq!(
        live.check(m2, wall - Duration::from_secs(60) + CHECK_INTERVAL + CLOCK_JUMP),
        Check::Idle
    );
}

#[test]
fn backoff_is_jittered_from_100ms_doubles_to_5s_and_resets() {
    let mut backoff = Backoff::new();
    assert_eq!(backoff.next(0.5), Duration::from_millis(50));
    assert_eq!(backoff.next(1.0), Duration::from_millis(200));
    assert_eq!(backoff.next(0.0), Duration::ZERO);
    for _ in 0..10 {
        backoff.next(0.5);
    }
    assert_eq!(backoff.next(1.0), MAX_BACKOFF);
    backoff.reset();
    assert_eq!(backoff.next(1.0), FIRST_BACKOFF);
    let unit = random_unit();
    assert!((0.0..1.0).contains(&unit) || unit == 1.0);
}

#[test]
fn credential_backoff_doubles_from_1s_to_a_60s_cap() {
    let mut backoff = Backoff::credential();
    assert_eq!(backoff.next(1.0), FIRST_CREDENTIAL_BACKOFF);
    assert_eq!(backoff.next(1.0), Duration::from_secs(2));
    for _ in 0..20 {
        backoff.next(0.5);
    }
    assert_eq!(backoff.next(1.0), MAX_CREDENTIAL_BACKOFF);
    backoff.reset();
    assert_eq!(backoff.next(1.0), FIRST_CREDENTIAL_BACKOFF);
}
