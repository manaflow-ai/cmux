use super::*;

fn s(n: u64) -> Duration {
    Duration::from_secs(n)
}

/// A wait bounded by `stall` hears progress every `stall / 2` for `5 * stall`: it is still moving
/// at its old fixed deadline and all through, and gives up exactly `stall` after the last
/// progress, never before.
fn keeps_going_while_moving_then_gives_up_on_silence(stall: Duration) {
    let t0 = Instant::now();
    let mut link = LinkProgress::new();
    // The old fixed deadline gave up here even with the link moving.
    link.progressed(t0 + stall / 2);
    assert!(matches!(link.verdict(t0, stall, t0 + stall), Stall::Moving { .. }));
    let mut at = t0;
    while at < t0 + stall * 5 {
        at += stall / 2;
        link.progressed(at);
        assert!(matches!(link.verdict(t0, stall, at + stall / 2), Stall::Moving { .. }));
    }
    let last = at;
    assert_eq!(
        link.verdict(t0, stall, last + stall - Duration::from_millis(1)),
        Stall::Moving { left: Duration::from_millis(1) }
    );
    assert_eq!(link.verdict(t0, stall, last + stall), Stall::Stalled);
}

/// A wait that hears nothing gives up `stall` after it began, as before.
fn silence_gives_up_at_the_same_bound(stall: Duration) {
    let t0 = Instant::now();
    let link = LinkProgress::new();
    assert_eq!(link.verdict(t0, stall, t0), Stall::Moving { left: stall });
    assert_eq!(link.verdict(t0, stall, t0 + stall), Stall::Stalled);
}

/// `AcpmuxConnection.submit`'s write: 30 s of silence, not 30 s in all.
#[test]
fn acpmux_write_keeps_going_while_the_link_makes_progress() {
    keeps_going_while_moving_then_gives_up_on_silence(s(30));
    silence_gives_up_at_the_same_bound(s(30));
}

/// `DaemonTerminalSession`'s input-lane write (`within(10 s, submit)`).
#[test]
fn input_lane_write_keeps_going_while_the_lane_makes_progress() {
    keeps_going_while_moving_then_gives_up_on_silence(s(10));
    silence_gives_up_at_the_same_bound(s(10));
}

/// `DaemonTerminalSession`'s input-lane answer (`within(10 s, reply)`): answers to the sends
/// ahead of it are progress for the one behind.
#[test]
fn input_lane_answer_keeps_going_while_earlier_answers_arrive() {
    keeps_going_while_moving_then_gives_up_on_silence(s(10));
    silence_gives_up_at_the_same_bound(s(10));
}

/// `LiveCoordinator.pushReplyBudget`: a notification reply waiting for its Mac's link.
#[test]
fn push_reply_keeps_waiting_while_the_link_comes_up() {
    keeps_going_while_moving_then_gives_up_on_silence(s(4));
    silence_gives_up_at_the_same_bound(s(4));
}

/// `LiveCoordinator.sendToChief`: Send Message… waiting for that Mac's Chief.
#[test]
fn send_to_chief_keeps_waiting_while_the_link_comes_up() {
    keeps_going_while_moving_then_gives_up_on_silence(s(20));
    silence_gives_up_at_the_same_bound(s(20));
}

#[test]
fn progress_before_the_wait_began_does_not_shorten_it() {
    let t0 = Instant::now();
    let mut link = LinkProgress::new();
    link.progressed(t0);
    assert_eq!(link.verdict(t0 + s(5), s(10), t0 + s(14)), Stall::Moving { left: s(1) });
    assert_eq!(link.verdict(t0 + s(5), s(10), t0 + s(15)), Stall::Stalled);
}

#[test]
fn an_older_report_never_moves_progress_back() {
    let t0 = Instant::now();
    let mut link = LinkProgress::new();
    link.progressed(t0 + s(8));
    link.progressed(t0 + s(3));
    assert_eq!(link.last(), Some(t0 + s(8)));
}

/// `DaemonTerminalSession.inputHoldLimit`: keys held while the Mac is called offline go after
/// 10 s with no progress on the link, not 10 s after the later of the key and going offline.
#[test]
fn terminal_keys_held_offline_keep_waiting_while_the_link_makes_progress() {
    let (hold, ceiling) = (s(10), s(60));
    let t0 = Instant::now();
    let typed = [t0];
    let offline = Some(t0);
    // No progress: 10 s after going offline, as before.
    assert_eq!(held_keys_expiry(&typed, t0 + s(9), false, offline, None, hold, ceiling), None);
    assert_eq!(
        held_keys_expiry(&typed, t0 + s(10), false, offline, None, hold, ceiling),
        Some(HeldKeysExpiry::Offline)
    );
    // The link still moving (a channel bound, bytes heard) at 8 s: held to 18 s.
    let progress = Some(t0 + s(8));
    assert_eq!(held_keys_expiry(&typed, t0 + s(17), false, offline, progress, hold, ceiling), None);
    assert_eq!(
        held_keys_expiry(&typed, t0 + s(18), false, offline, progress, hold, ceiling),
        Some(HeldKeysExpiry::Offline)
    );
    // The ceiling still bounds a key's age however the link is doing.
    let late = Some(t0 + s(59));
    assert_eq!(
        held_keys_expiry(&typed, t0 + s(60), false, offline, late, hold, ceiling),
        Some(HeldKeysExpiry::Ceiling)
    );
    // Online (reconnecting): only the ceiling or a reattach that gave up.
    assert_eq!(held_keys_expiry(&typed, t0 + s(30), false, None, None, hold, ceiling), None);
    assert_eq!(
        held_keys_expiry(&typed, t0 + s(1), true, None, None, hold, ceiling),
        Some(HeldKeysExpiry::GaveUp)
    );
    assert_eq!(held_keys_expiry(&[], t0 + s(99), true, offline, None, hold, ceiling), None);
}
