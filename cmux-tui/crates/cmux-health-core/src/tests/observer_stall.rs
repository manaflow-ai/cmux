//! The host's own stall is not the pages' silence. The model's timer runs on the app's main thread,
//! which also delivers every page beat; when that thread (or the whole Mac) stalls, the timer fires
//! late and the beats queued behind it have not arrived yet. Leo's Mac, 2026-11-27 13:30:57 and
//! 13:31:32 (load 187 on 15 cores): two agent chats were reloaded for "Not answering for 65 s" and
//! "Has not handled your clicks or typing for 10 s", and the app relaunched 37 s later. Leo,
//! 2026-11-22: "we need to make sure any solutions that reloading would help with, we never
//! encounter those classes of bugs in the first place."

use super::*;
use crate::RepairAction::ReloadPage;
use crate::State;
use crate::policy;

const CHAT: &str = "page:chat";

/// A beating chat, then the host runs nothing for 65 s: its timer fires 60 s late, before the
/// chat's queued beat. Before: `reloadPage` at that tick. Now: no action, and the beat that follows
/// leaves it healthy.
#[test]
fn a_late_timer_after_a_host_stall_does_not_reload_a_beating_chat() {
    let mut h = model();
    register(&mut h, CHAT, Kind::Page, "Agent chat", 0);
    h.beat(CHAT, 2_000);
    let due = h.next_tick_ms().expect("armed");
    assert_eq!(due, 2_000 + policy::PAGE_SLOW_SILENT_MS);
    let resumed = 67_000;
    assert_eq!(h.tick(resumed), vec![], "the stall is the host's, not the chat's");
    assert_eq!(h.observer_stalls(), 1);
    h.beat(CHAT, resumed + 1);
    assert_eq!(run(&mut h, resumed + 60_000).len(), 0);
    let p = part(&h, CHAT);
    assert!(p.is_none_or(|p| p.state == State::Healthy), "{p:?}");
}

/// Input the person sent just before the stall (handled only once the stall ends) is not
/// "has not handled your clicks or typing for 10 s".
#[test]
fn input_pending_across_a_host_stall_is_not_a_hang() {
    let mut h = model();
    register(&mut h, CHAT, Kind::Page, "Agent chat", 0);
    h.beat(CHAT, 1_000);
    h.input(CHAT, 1, 0, 1_500);
    let resumed = 40_000;
    assert_eq!(h.tick(resumed), vec![]);
    h.beat(CHAT, resumed + 1);
    h.input(CHAT, 1, 1, resumed + 1);
    assert_eq!(run(&mut h, resumed + 60_000).len(), 0);
}

/// A chat that really hangs stays silent after the stall and is still reloaded, judged from the
/// end of the stall: [`policy::PAGE_STUCK_MS`] of its own silence at most.
#[test]
fn a_chat_that_really_hangs_is_still_reloaded_after_the_stall() {
    let mut h = model();
    register(&mut h, CHAT, Kind::Page, "Agent chat", 0);
    h.beat(CHAT, 2_000);
    let resumed = 67_000;
    assert_eq!(h.tick(resumed), vec![]);
    let actions = run(&mut h, resumed + 30_000);
    let (at, action, attempt) = *actions.first().expect("reloaded");
    assert_eq!((action, attempt), (ReloadPage, 1));
    assert!(at > resumed && at <= resumed + policy::PAGE_STUCK_MS, "reloaded at {at}");
}

/// A timer on time (or a little late, under [`policy::OBSERVER_LATE_MS`]) forgives nothing: a
/// silent chat is reloaded at [`policy::PAGE_STUCK_MS`] as before.
#[test]
fn an_on_time_timer_forgives_nothing() {
    let mut h = model();
    register(&mut h, CHAT, Kind::Page, "Agent chat", 0);
    h.beat(CHAT, 2_000);
    let mut actions = Vec::new();
    for t in (2_000..=20_000).step_by(500) {
        while let Some(at) = h.next_tick_ms().filter(|&at| at <= t) {
            // Every tick a little late, still under the bound.
            let late = at + policy::OBSERVER_LATE_MS - 1;
            actions.extend(h.tick(late).into_iter().map(|a| (late, a.action)));
        }
    }
    assert_eq!(h.observer_stalls(), 0);
    let (at, action) = actions[0];
    assert_eq!(action, ReloadPage);
    assert!(at < 2_000 + policy::PAGE_STUCK_MS + policy::OBSERVER_LATE_MS, "reloaded at {at}");
}

/// Two chats silent through the same host stall keep their order for the shared-stall check (the
/// timed set is rebuilt with the shifted beats), and neither is reloaded at the late tick.
#[test]
fn two_chats_through_one_host_stall_are_not_reloaded() {
    let mut h = model();
    register(&mut h, "page:a", Kind::Page, "Agent chat", 0);
    register(&mut h, "page:b", Kind::Page, "Agent chat", 0);
    h.beat("page:a", 2_000);
    h.beat("page:b", 3_000);
    assert_eq!(h.tick(68_000), vec![]);
    h.beat("page:a", 68_001);
    h.beat("page:b", 68_002);
    assert_eq!(run(&mut h, 120_000).len(), 0);
}
