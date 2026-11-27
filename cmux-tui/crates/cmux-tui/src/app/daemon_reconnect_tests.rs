//! The reconnect decision and its backoff: which stream ends reconnect, how
//! long the client tries, and that quitting cancels the wait.

use std::cell::Cell;
use std::time::{Duration, Instant};

use super::*;

#[test]
fn daemon_reconnect_plan_follows_the_shutdown_notice() {
    use DaemonShutdownNotice::{Restart, Stop, Unspecified};
    let cases = [
        // `cmux daemon restart`: the replacement follows.
        (true, Some(Restart), StreamLossPlan::Reconnect { window: RESTART_WINDOW }),
        // `cmux daemon stop`: exit and say so, never wait.
        (true, Some(Stop), StreamLossPlan::Stopped),
        // An older daemon or an app handoff: a short window.
        (true, Some(Unspecified), StreamLossPlan::Reconnect { window: UNANNOUNCED_WINDOW }),
        // No notice: a crash, a kick or a local detach keep the old exit.
        (true, None, StreamLossPlan::Unchanged),
        // Clients without a way back keep their own exit path.
        (false, Some(Restart), StreamLossPlan::Unchanged),
        (false, Some(Stop), StreamLossPlan::Unchanged),
        (false, Some(Unspecified), StreamLossPlan::Unchanged),
        (false, None, StreamLossPlan::Unchanged),
    ];
    for (can_reconnect, notice, expected) in cases {
        assert_eq!(
            plan_for_stream_loss(can_reconnect, notice),
            expected,
            "{can_reconnect} {notice:?}"
        );
    }
}

#[test]
fn daemon_reconnect_notice_reads_the_restart_field() {
    let event = |restart: Option<bool>| {
        let mut event = serde_json::json!({"event": cmux_tui_core::server::DAEMON_SHUTDOWN_EVENT});
        if let Some(restart) = restart {
            event["restart"] = serde_json::json!(restart);
        }
        event
    };
    assert_eq!(DaemonShutdownNotice::from_event(&event(Some(true))), DaemonShutdownNotice::Restart);
    assert_eq!(DaemonShutdownNotice::from_event(&event(Some(false))), DaemonShutdownNotice::Stop);
    assert_eq!(DaemonShutdownNotice::from_event(&event(None)), DaemonShutdownNotice::Unspecified);
}

#[test]
fn daemon_reconnect_backoff_doubles_to_a_second_and_ends_at_the_window() {
    let start = Instant::now();
    let mut backoff = ReconnectBackoff::new(start, Duration::from_secs(3));
    let mut now = start;
    let mut delays = Vec::new();
    while let Some(delay) = backoff.next_delay(now) {
        delays.push(delay);
        now += delay;
        assert!(delays.len() < 100, "the backoff never ended: {delays:?}");
    }
    let ms = |value: u64| Duration::from_millis(value);
    // 100 + 200 + 400 + 800 + 1000 = 2500, then the last 500 ms to the deadline.
    assert_eq!(delays, vec![ms(100), ms(200), ms(400), ms(800), ms(1000), ms(500)]);
    assert_eq!(now, start + Duration::from_secs(3));
    assert_eq!(backoff.next_delay(now + ms(1)), None);
}

#[test]
fn daemon_reconnect_stops_trying_when_the_window_passes() {
    let cancellation = EventCancellation::new();
    let attempts = Cell::new(0);
    // A clock that moves 100 ms each time the loop reads it.
    let start = Instant::now();
    let reads = Cell::new(0u32);
    let now = || {
        let at = start + Duration::from_millis(100) * reads.get();
        reads.set(reads.get() + 1);
        at
    };
    let outcome = reconnect_until::<()>(Duration::from_millis(250), &cancellation, now, || {
        attempts.set(attempts.get() + 1);
        anyhow::bail!("no session socket")
    });
    assert_eq!(
        outcome,
        Some(ReconnectOutcome::Failed {
            window: Duration::from_millis(250),
            error: "no session socket".into(),
        })
    );
    // Read at 100 ms (wait 100), at 200 ms (wait the last 50), at 300 ms
    // (past the window): two attempts.
    assert_eq!(attempts.get(), 2);
}

#[test]
fn daemon_reconnect_returns_the_first_session_that_connects() {
    let cancellation = EventCancellation::new();
    let attempts = Cell::new(0);
    let outcome = reconnect_until(Duration::from_secs(5), &cancellation, Instant::now, || {
        attempts.set(attempts.get() + 1);
        if attempts.get() < 3 {
            anyhow::bail!("the daemon is still starting");
        }
        Ok(7)
    });
    assert_eq!(outcome, Some(ReconnectOutcome::Connected(7)));
    assert_eq!(attempts.get(), 3);
}

#[test]
fn daemon_reconnect_cancellation_ends_the_wait_without_an_outcome() {
    let cancellation = EventCancellation::new();
    cancellation.cancel();
    let attempts = Cell::new(0);
    let started = Instant::now();
    let outcome = reconnect_until(RESTART_WINDOW, &cancellation, Instant::now, || {
        attempts.set(attempts.get() + 1);
        Ok(())
    });
    assert_eq!(outcome, None);
    assert_eq!(attempts.get(), 0);
    assert!(started.elapsed() < Duration::from_secs(5));
}

#[test]
fn daemon_reconnect_state_tracks_one_attempt() {
    let mut reconnect = DaemonReconnect::default();
    assert!(!reconnect.can_reconnect());
    assert!(!reconnect.in_progress());
    assert_eq!(reconnect.finish(), None);
    let reconnector: SessionReconnector =
        Arc::new(|| -> anyhow::Result<Session> { anyhow::bail!("unreachable") });
    let reconnect = DaemonReconnect::new(Some(reconnector));
    assert!(reconnect.can_reconnect());
    assert!(!reconnect.in_progress());
}
