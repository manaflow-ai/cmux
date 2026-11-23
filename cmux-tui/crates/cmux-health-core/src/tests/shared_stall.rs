//! Pages that go silent together: one stall of their shared renderer (or of the Mac), waited out,
//! not one reload per page followed by a kill of the renderer every chat shares.

use super::*;
use crate::RepairAction::{ReloadPage, RestartRenderer};
use crate::State;

const A: &str = "page:a";
const B: &str = "page:b";
const C: &str = "page:c";

fn chats(h: &mut Health, ids: &[&str]) {
    for id in ids {
        register(h, id, Kind::Page, "Agent chat", 0);
    }
}

/// Ticks to `until` while `beating` beats every 2 s: `(at, id, action, attempt)` of every action.
fn run_beating(
    h: &mut Health,
    from: u64,
    until: u64,
    beating: &[&str],
) -> Vec<(u64, String, RepairAction, u32)> {
    let mut out = Vec::new();
    for t in (from..=until).step_by(500) {
        if t % 2_000 == 0 {
            for id in beating {
                h.beat(id, t);
            }
        }
        while let Some(at) = h.next_tick_ms().filter(|&at| at <= t) {
            out.extend(h.tick(at).into_iter().map(|a| (at, a.id, a.action, a.attempt)));
        }
    }
    out
}

/// Leo, 2026-11-21: "the gui agent chats all blanked out just now". On a Mac in swap the renderer
/// every agent chat shares stalled; three chats read stuck within 7 s of each other, each was
/// reloaded (making the stall worse), none could boot in the 30 s wait, and step 2 restarted the
/// renderer they share: every chat blanked. Before this change the same feed gave reloads at 10 s,
/// 11 s and 17 s and three renderer restarts from 40 s on. Now the stall is waited out, and only
/// past PAGE_SHARED_STALL_MS does the page silent longest restart the renderer, once.
#[test]
fn pages_silent_together_are_waited_out_not_reloaded_each_then_their_renderer_killed() {
    let mut h = model();
    chats(&mut h, &[A, B, C]);
    // The stall starts: A's last beat at 0, B's at 1 s, C's at 7 s.
    h.beat(B, 1_000);
    h.beat(C, 7_000);

    assert_eq!(run(&mut h, 119_999), vec![], "no reload, no renderer restart while it stalls");
    for id in [A, B, C] {
        let p = part(&h, id).expect("listed");
        assert_eq!((p.state, p.action, p.can_repair), (State::Slow, RepairAction::None, false));
        assert!(p.detail.contains("along with other open pages"), "{}", p.detail);
    }
    assert!(receipts(&h, A).is_empty() && receipts(&h, B).is_empty() && receipts(&h, C).is_empty());

    // Two minutes from the oldest silence: the page silent longest restarts the renderer, alone.
    assert_eq!(h.next_tick_ms(), Some(120_000));
    let actions = h.tick(120_000);
    assert_eq!(actions.len(), 1, "{actions:?}");
    assert_eq!(
        (actions[0].id.as_str(), actions[0].action, actions[0].attempt),
        (A, RestartRenderer, 1)
    );
    assert_eq!(part(&h, A).map(|p| p.state), Some(State::Repairing));
    assert_eq!(part(&h, B).map(|p| p.state), Some(State::Slow));

    // The restart reloads every chat in it; they load and rest: all healthy, nothing more sent.
    for id in [A, B, C] {
        h.event(id, "loaded", 125_000, None);
        h.rest(id, 126_000);
    }
    assert_eq!(h.snapshot().worst, State::Healthy);
    assert_eq!(h.next_tick_ms(), None);
    assert_eq!(
        receipts(&h, A),
        vec![(RestartRenderer, Outcome::Started), (RestartRenderer, Outcome::Ok)]
    );
    assert!(receipts(&h, B).is_empty());
}

#[test]
fn a_shared_stall_that_clears_repairs_nothing() {
    let mut h = model();
    chats(&mut h, &[A, B, C]);
    assert_eq!(run(&mut h, 60_000), vec![]);
    for id in [A, B, C] {
        h.beat(id, 60_000);
    }
    assert_eq!(h.snapshot().worst, State::Healthy);
    assert!(receipts(&h, A).is_empty());
}

#[test]
fn a_page_silent_while_its_siblings_beat_is_still_a_hung_page() {
    let mut h = model();
    chats(&mut h, &[A, B]);
    assert_eq!(
        run_beating(&mut h, 0, 40_000, &[B]),
        vec![(10_000, A.into(), ReloadPage, 1), (40_000, A.into(), RestartRenderer, 2)]
    );
}

#[test]
fn a_resting_sibling_is_no_sign_of_a_shared_stall() {
    let mut h = model();
    chats(&mut h, &[A, B]);
    h.rest(B, 1_000);
    assert_eq!(run(&mut h, 10_000), vec![(10_000, ReloadPage, 1)]);
}

/// A page reloaded alone whose siblings then go silent too: the stall is shared after all, so the
/// ladder's next step is not a renderer kill 30 s into the reload.
#[test]
fn a_page_reloaded_alone_is_not_escalated_once_its_siblings_stall_too() {
    let mut h = model();
    chats(&mut h, &[A, B]);
    // B beats until 8 s, then stalls with A.
    assert_eq!(run_beating(&mut h, 0, 8_000, &[B]), vec![]);
    assert_eq!(run_beating(&mut h, 8_500, 119_999, &[]), vec![(10_000, A.into(), ReloadPage, 1)]);
    assert_eq!(part(&h, A).map(|p| p.state), Some(State::Slow));
    assert_eq!(
        run_beating(&mut h, 120_000, 120_000, &[]),
        vec![(120_000, A.into(), RestartRenderer, 1)]
    );
}

/// Pages that stay silent after a renderer restart (another renderer, or the Mac still in swap)
/// restart nothing more until that restart had its boot wait.
#[test]
fn one_renderer_restart_per_boot_wait_for_a_stall() {
    let mut h = model();
    chats(&mut h, &[A, B, C]);
    h.beat(B, 1_000);
    h.beat(C, 7_000);
    assert_eq!(run_beating(&mut h, 0, 120_000, &[]), vec![(120_000, A.into(), RestartRenderer, 1)]);
    h.event(A, "loaded", 121_000, None);
    h.rest(A, 122_000);
    assert_eq!(run_beating(&mut h, 120_500, 149_999, &[]), vec![]);
    assert_eq!(
        run_beating(&mut h, 150_000, 150_000, &[]),
        vec![(150_000, B.into(), RestartRenderer, 1)]
    );
}
