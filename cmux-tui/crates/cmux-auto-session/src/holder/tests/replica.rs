//! Running journal checkpoints must not depend on another token or a tool finishing.

use super::*;

#[test]
fn running_replica_checkpoints_silent_turns_on_both_holders() {
    for chat in [laptop::holding(0), machine::serving(0)] {
        let started = Event::Changed { change: Change::TurnStarted, needs_run: true };
        let (chat, _) = step(chat, started, 1);
        let at = chat.wake_at().unwrap();
        let (chat, effects) = step(chat, Event::Tick, at);
        assert!(has(&effects, "upload_events"), "{effects:?}");
        assert!(has(&effects, "upload_snapshot"), "{effects:?}");
        assert!(chat.may_run(), "copying must not freeze a live chat");

        // A slow network may span a renewal. One copy stays in flight, while the lease
        // continues to renew; neither an unbounded backlog nor a second writer is made.
        let (_, effects) = step(chat, Event::Tick, at + RENEW_MS);
        assert!(!has(&effects, "upload_snapshot"), "{effects:?}");
        assert!(has(&effects, "renew"));
    }
}

#[test]
fn running_replica_retries_failed_copies_without_retrying_the_size_cap() {
    for chat in [laptop::holding(0), machine::serving(0)] {
        for too_large in [false, true] {
            let mut active = chat;
            active.needs_run = true;
            let failed = Event::SnapshotFailed { copy: active.copies, too_large };
            let (active, _) = step(active, failed, 1);
            let at = active.wake_at().unwrap();
            let (_, effects) = step(active, Event::Tick, at);
            assert_eq!(has(&effects, "upload_snapshot"), !too_large, "{effects:?}");
        }
    }
}
