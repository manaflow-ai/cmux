//! Pages the host itself reloads (a web source change, crash recovery, any navigation the host
//! started) are loading, not hung, and a stall the renderer restarts cannot clear is not answered by
//! a renderer kill every 30 s.
//!
//! Leo, 2026-11-22 06:44Z: "also holy fuck idk why there was some sort of situation just now that
//! compLETELY blanked out this agent chat + the update notes". On cosmic-gray (load 133 on 15
//! cores) a `web-dev.json` change at 06:41:33.121Z reloaded every served page at the same ms; the
//! documents finished loading only at 06:42:17Z and 06:42:45Z. Health read the loading pages as
//! hung: `reloadPage` at 06:41:41.5Z (8.4 s into the host's reload) and 06:41:48.6Z, then
//! `restartRenderer`, "attempt 1", at 06:43:45, 06:44:17, 06:44:47, 06:45:17 and 06:45:47Z.

use super::*;
use crate::RepairAction::{ReloadPage, RestartRenderer};
use crate::State;
use crate::policy;

const A: &str = "page:agent-chat";
const B: &str = "page:update-notes";

/// 06:41:33.121Z on the test clock.
const T0: u64 = 100_000;

/// Ticks every 100 ms from `from` to `until`, calling `feed` first at each step:
/// `(at, id, action, attempt)` of every action.
fn drive(
    h: &mut Health,
    from: u64,
    until: u64,
    mut feed: impl FnMut(&mut Health, u64),
) -> Vec<(u64, String, RepairAction, u32)> {
    let mut out = Vec::new();
    for t in (from..=until).step_by(100) {
        feed(h, t);
        while let Some(at) = h.next_tick_ms().filter(|&at| at <= t) {
            out.extend(h.tick(at).into_iter().map(|a| (at, a.id, a.action, a.attempt)));
        }
    }
    out
}

/// The 06:41:33Z feed, `a_loads` / `b_loads` ms after the host's reload: A's old document beat last
/// 1.6 s before it, B's old document beat on for 5.5 s more (its new one had not committed), both
/// silent until their new documents load; then each beats every 2 s.
fn host_reload(a_loads: u64, b_loads: u64, until: u64) -> Vec<(u64, String, RepairAction, u32)> {
    let mut h = model();
    register(&mut h, A, Kind::Page, "Agent chat", 0);
    register(&mut h, B, Kind::Page, "Update notes", 0);
    drive(&mut h, 0, until, |h, t| {
        if t == T0 {
            // The host reloads every served page at the same ms.
            h.event(A, "navigationStarted", t, None);
            h.event(B, "navigationStarted", t, None);
        }
        let (a_at, b_at) = (T0 + a_loads, T0 + b_loads);
        if t == a_at {
            h.event(A, "loaded", t, None);
        }
        if t == b_at {
            h.event(B, "loaded", t, None);
        }
        let a_beats = t < T0 || t >= a_at;
        let b_beats = t <= T0 + 5_500 || t >= b_at;
        if a_beats && t % 2_000 == 400 {
            h.beat(A, t);
        }
        if b_beats && t % 2_000 == 1_500 {
            h.beat(B, t);
        }
    })
}

/// Before: `reloadPage` for A at 8.4 s into the host's reload (06:41:41.5Z, as logged), and B
/// reloaded once A answered while B still loaded. Now: nothing, through the five minutes to the
/// agent's `cmux live stop` (06:46:43Z).
#[test]
fn pages_the_host_reloads_together_under_load_are_loading_not_hung() {
    let actions = host_reload(44_000, 72_000, T0 + 310_000);
    let reloads = actions.iter().filter(|a| a.2 == ReloadPage).count();
    let restarts = actions.iter().filter(|a| a.2 == RestartRenderer).count();
    assert_eq!((reloads, restarts), (0, 0), "{actions:?}");
}

#[test]
fn documents_that_load_within_the_boot_wait_repair_nothing() {
    let actions = host_reload(3_000, policy::PAGE_BOOT_MS - 1_000, T0 + 120_000);
    assert_eq!(actions, vec![]);
}

/// A loading page is shown as slow, never as stuck, and a load that never ends is still repaired.
#[test]
fn a_page_whose_load_never_ends_is_repaired_once_its_load_wait_passes() {
    let mut h = model();
    register(&mut h, A, Kind::Page, "Agent chat", 0);
    h.event(A, "navigationStarted", 1_000, None);
    assert_eq!(run(&mut h, 1_000 + policy::PAGE_LOAD_MS - 1), vec![]);
    let p = part(&h, A).expect("listed while it loads long");
    assert_eq!((p.state, p.can_repair), (State::Slow, false));
    assert!(p.detail.starts_with("Loading for"), "{}", p.detail);
    assert_eq!(
        run(&mut h, 1_000 + policy::PAGE_LOAD_MS),
        vec![(1_000 + policy::PAGE_LOAD_MS, ReloadPage, 1)]
    );
}

/// A repair's own reload is a navigation the host started too: the ladder keeps its own boot wait
/// after it (`policy::wait_after`), so a renderer too hung to load is still restarted 30 s on.
#[test]
fn a_repairs_own_reload_keeps_the_ladders_boot_wait() {
    let mut h = model();
    register(&mut h, A, Kind::Page, "Agent chat", 0);
    assert_eq!(run(&mut h, 10_000), vec![(10_000, ReloadPage, 1)]);
    h.event(A, "navigationStarted", 10_050, None);
    assert_eq!(run(&mut h, 39_999), vec![]);
    assert_eq!(part(&h, A).map(|p| (p.state, p.attempt)), Some((State::Repairing, 1)));
    assert_eq!(run(&mut h, 40_000), vec![(40_000, RestartRenderer, 2)]);
}

#[test]
fn a_reload_that_loads_ends_the_episode() {
    let mut h = model();
    register(&mut h, A, Kind::Page, "Agent chat", 0);
    assert_eq!(run(&mut h, 10_000), vec![(10_000, ReloadPage, 1)]);
    h.event(A, "navigationStarted", 10_050, None);
    h.event(A, "loaded", 52_000, None);
    h.beat(A, 52_100);
    assert_eq!(h.snapshot().worst, State::Healthy);
    assert_eq!(receipts(&h, A), vec![(ReloadPage, Outcome::Started), (ReloadPage, Outcome::Ok)]);
}

/// The crash path's own reload: the crash is answered by the host, so health sends nothing.
#[test]
fn a_crash_the_host_reloads_by_itself_is_loading_not_crashed() {
    let mut h = model();
    register(&mut h, A, Kind::Page, "Agent chat", 0);
    h.event(A, "crashed", 1_000, None);
    h.event(A, "navigationStarted", 1_000, None);
    assert_eq!(run(&mut h, 20_000), vec![]);
    h.event(A, "loaded", 20_000, None);
    assert_eq!(h.snapshot().worst, State::Healthy);
}

/// Six chats in a stall a renderer restart does not clear (the Mac in swap): each restart loaded
/// the page it was sent for, the next silent page became the one silent longest, and the
/// restart's 30 s boot wait was the whole backoff, so every 30 s another restart went out, each
/// "attempt 1" (06:43:45Z to 06:45:47Z). Before: restarts at 120, 150, 180, 210, 240 and 270 s,
/// all attempt 1. Now the stall's restarts are counted for every page together: attempt 1, 2, 3,
/// each wait doubling from PAGE_SHARED_STALL_MS, then the stall is `failed` (the person's click).
#[test]
fn a_stall_restarts_its_renderer_at_most_max_repairs_times_with_backoff() {
    let mut h = model();
    let pages: Vec<String> = (1..=6).map(|n| format!("page:{n}")).collect();
    for id in &pages {
        register(&mut h, id, Kind::Page, "Agent chat", 0);
    }
    let mut loads: Vec<(u64, String)> = Vec::new();
    let mut back: Vec<String> = Vec::new();
    let mut out = Vec::new();
    for t in (0..=900_000u64).step_by(500) {
        for (at, id) in &loads {
            if *at == t {
                h.event(id, "loaded", t, None);
                back.push(id.clone());
            }
        }
        if t % 2_000 == 0 {
            for id in &back {
                h.beat(id, t);
            }
        }
        while let Some(at) = h.next_tick_ms().filter(|&at| at <= t) {
            for a in h.tick(at) {
                if a.action == RestartRenderer {
                    loads.push((at + 10_000, a.id.clone()));
                }
                out.push((at, a.action, a.attempt));
            }
        }
    }
    assert_eq!(
        out,
        vec![
            (120_000, RestartRenderer, 1),
            (240_000, RestartRenderer, 2),
            (480_000, RestartRenderer, 3),
            // The first restart left the cap's window at 720 s: the stall tries again by itself.
            (720_000, RestartRenderer, 3),
        ]
    );
    let in_five_minutes = out.iter().filter(|a| a.0 < 300_000).count();
    assert!(in_five_minutes <= 2, "{out:?}");
}
