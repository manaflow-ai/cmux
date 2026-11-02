//! The Swift tests of the hover rules, ported (`WorkspaceHoverCardBehaviorTests`,
//! `HoverCardEscapeGeometryTests`, `HoverCardRowAlignmentTests`,
//! `HoverCardWindowClampTests`, the timing parts of `TabHoverCardTimingTests`
//! and `TooltipHoverIntentTests`), plus the branches those reach only
//! through AppKit (pinned cards, an owner's card, removed targets, lingering
//! cards) and the C forms. Each test names the Swift test it ports.

#![allow(clippy::unwrap_used, clippy::indexing_slicing, clippy::arithmetic_side_effects)]

use super::c::*;
use super::*;

type Id = &'static str;
type E = HoverCardEffect<Id>;

const DELAY: i64 = HOVER_CARD_SHOW_DELAY;
const RESHOW: i64 = HOVER_CARD_RESHOW_WINDOW;

/// A sidebar workspace row as the sidebar reports it (`WorkspaceHoverCardBehaviorTests.row`).
fn row(n: usize) -> HoverTarget<Id> {
    const IDS: [&str; 6] = ["ws:ws-0", "ws:ws-1", "ws:ws-2", "ws:ws-3", "ws:ws-4", "ws:ws-5"];
    HoverTarget {
        id: IDS[n],
        window: 7,
        delay: DELAY,
        leave: HoverCardLeave::Hides { reshow: RESHOW },
    }
}

/// A target whose card lingers (the workspace card before #26942, a group chip).
fn lingering(id: Id, delay: i64) -> HoverTarget<Id> {
    HoverTarget { id, window: 1, delay, leave: HoverCardLeave::Lingers }
}

fn hit(target: Option<HoverTarget<Id>>, moved: bool) -> HoverCardEvent<Id> {
    HoverCardEvent::Hit { target, moved, aiming: false, bridging: false }
}

fn aimed(target: Option<HoverTarget<Id>>) -> HoverCardEvent<Id> {
    HoverCardEvent::Hit { target, moved: true, aiming: true, bridging: false }
}

fn bridged(target: Option<HoverTarget<Id>>) -> HoverCardEvent<Id> {
    HoverCardEvent::Hit { target, moved: true, aiming: false, bridging: true }
}

fn run(m: &mut HoverCardMachine<Id>, e: HoverCardEvent<Id>) -> Vec<E> {
    m.reduce(e).to_vec()
}

fn show(target: HoverTarget<Id>, sliding: bool) -> E {
    E::Show { target, sliding }
}

fn hides(effects: &[E]) -> bool {
    effects.contains(&E::Hide)
}

fn shows(effects: &[E]) -> bool {
    effects.iter().any(|e| matches!(e, E::Show { .. }))
}

/// Fires the armed timer.
fn fire_armed(m: &mut HoverCardMachine<Id>) -> Vec<E> {
    let token = m.armed_token().unwrap();
    run(m, HoverCardEvent::Deadline(token))
}

/// A machine with row 1's card on screen after its hover delay.
fn shown_on_row_one() -> HoverCardMachine<Id> {
    let mut m = HoverCardMachine::new();
    run(&mut m, hit(Some(row(1)), true));
    let token = m.armed_token().unwrap();
    run(&mut m, HoverCardEvent::Deadline(token));
    m
}

// MARK: timing (HoverCardTiming.swift, HoverIntent.swift's `standard`)

#[test]
fn hover_timing_tokens_match_the_swift_values() {
    assert_eq!(HOVER_CARD_SHOW_DELAY, 400_000_000, "the fast cold delay (Leo 2026-11-01)");
    assert_eq!(HOVER_CARD_RESHOW_WINDOW, 300_000_000);
    assert_eq!(HOVER_CARD_SWEEP_INTERVAL, 150_000_000);
    assert_eq!(HOVER_CARD_PIN_LIFETIME, 10_000_000_000);
    assert_eq!(HOVER_CARD_STILL_POINTER_DELAY, 300_000_000);
    let s = HoverIntentTiming::STANDARD;
    assert_eq!(
        (s.tooltip_delay, s.tooltip_warm, s.card_grace, s.card_aim),
        (450_000_000, 500_000_000, 200_000_000, 300_000_000)
    );
    let m = HoverCardMachine::<Id>::new();
    assert_eq!(
        (m.reshow_window, m.pin_lifetime, m.leave_window, m.aim_window, m.still_pointer_delay),
        (RESHOW, HOVER_CARD_PIN_LIFETIME, s.card_grace, s.card_aim, HOVER_CARD_STILL_POINTER_DELAY)
    );
    assert_eq!(CmuxHoverTiming::standard().card_show_delay, DELAY);
}

#[test]
fn hover_tunable_seconds_round_to_the_millisecond_and_never_go_negative() {
    assert_eq!(duration_from_seconds(0.45), millis(450));
    assert_eq!(duration_from_seconds(0.0004), 0);
    assert_eq!(duration_from_seconds(0.0006), millis(1));
    assert_eq!(duration_from_seconds(-1.), 0);
    assert_eq!(duration_from_seconds(f64::NAN), 0);
    assert_eq!(HoverIntentTiming::from_seconds(0.45, 0.5, 0.2, 0.3), HoverIntentTiming::STANDARD);
}

// MARK: WorkspaceHoverCardBehaviorTests

#[test]
fn hover_card_opens_only_after_the_hover_delay() {
    let mut m = HoverCardMachine::new();
    let effects = run(&mut m, hit(Some(row(1)), true));
    let token = m.armed_token().unwrap();
    assert_eq!(effects, vec![E::Schedule { token, after: DELAY }], "no card yet, only the delay");
    assert!(m.shown_target().is_none());
    assert_eq!(run(&mut m, HoverCardEvent::Deadline(token)), vec![show(row(1), false)]);
    assert_eq!(m.shown_target(), Some(&row(1)));
}

#[test]
fn hover_card_leaving_a_row_before_the_delay_shows_nothing() {
    let mut m = HoverCardMachine::new();
    run(&mut m, hit(Some(row(1)), true));
    let stale = m.armed_token().unwrap();
    assert_eq!(run(&mut m, hit(None, true)), vec![E::CancelTimer]);
    assert!(run(&mut m, HoverCardEvent::Deadline(stale)).is_empty());
    assert!(m.shown_target().is_none());
}

#[test]
fn hover_card_moving_to_the_next_row_swaps_the_content_without_closing() {
    let mut m = shown_on_row_one();
    assert_eq!(run(&mut m, hit(Some(row(2)), true)), vec![show(row(2), true)]);
    assert_eq!(m.shown_target(), Some(&row(2)));
}

#[test]
fn hover_card_crossing_a_gap_between_rows_keeps_the_card_within_the_grace() {
    let mut m = shown_on_row_one();
    let gap = run(&mut m, bridged(None));
    let token = m.armed_token().unwrap();
    assert_eq!(gap, vec![E::Schedule { token, after: RESHOW }]);
    assert!(!hides(&gap));
    assert_eq!(m.shown_target(), Some(&row(1)), "still on screen while the pointer crosses");
    let next = run(&mut m, hit(Some(row(3)), true));
    assert_eq!(next, vec![E::CancelTimer, show(row(3), true)]);
    assert_eq!(m.shown_target(), Some(&row(3)));
}

#[test]
fn hover_card_a_gap_longer_than_the_grace_lets_the_card_go() {
    let mut m = shown_on_row_one();
    run(&mut m, bridged(None));
    let token = m.armed_token().unwrap();
    run(&mut m, HoverCardEvent::PointerOnCard(false));
    assert!(hides(&run(&mut m, HoverCardEvent::Deadline(token))));
    assert!(m.shown_target().is_none());
}

#[test]
fn hover_card_coming_back_soon_after_it_hid_shows_at_once() {
    let mut m = shown_on_row_one();
    assert!(hides(&run(&mut m, hit(None, true))), "off the sidebar it hides at once");
    assert_eq!(run(&mut m, hit(Some(row(2)), true)), vec![E::CancelTimer, show(row(2), false)]);
}

#[test]
fn hover_card_a_scroll_closes_the_card() {
    let mut m = shown_on_row_one();
    assert!(hides(&run(&mut m, HoverCardEvent::Dismiss)));
    assert!(m.shown_target().is_none());
    assert!(
        run(&mut m, hit(Some(row(1)), false)).is_empty(),
        "the row under the still pointer brings no card"
    );
    assert!(m.active_target().is_none());
}

#[test]
fn hover_card_a_scroll_in_progress_keeps_cards_away() {
    let mut m = shown_on_row_one();
    assert!(hides(&run(&mut m, HoverCardEvent::Suppress(HoverSuppression::Scroll))));
    assert!(run(&mut m, hit(Some(row(2)), true)).is_empty());
    assert!(m.active_target().is_none());
}

#[test]
fn hover_card_a_click_closes_the_card_until_the_pointer_moves_on() {
    let mut m = shown_on_row_one();
    assert!(hides(&run(&mut m, HoverCardEvent::Dismiss)));
    assert!(m.shown_target().is_none());
    assert!(run(&mut m, hit(Some(row(1)), false)).is_empty());
    assert!(m.active_target().is_none());
    let next = run(&mut m, hit(Some(row(2)), true));
    assert!(
        next.iter().any(|e| matches!(e, E::Schedule { after, .. } if *after == DELAY)),
        "{next:?}"
    );
}

#[test]
fn hover_card_aiming_into_the_card_across_another_row_keeps_the_card() {
    let mut m = shown_on_row_one();
    let crossed = run(&mut m, aimed(Some(row(2))));
    assert!(!shows(&crossed), "crossing row 2 swapped the card: {crossed:?}");
    assert_eq!(m.shown_target(), Some(&row(1)));
    run(&mut m, aimed(Some(row(3))));
    assert_eq!(m.shown_target(), Some(&row(1)), "the aim restarts across row 3");
    run(&mut m, bridged(None));
    run(&mut m, HoverCardEvent::PointerOnCard(true));
    let token = m.armed_token().unwrap();
    run(&mut m, HoverCardEvent::Deadline(token));
    assert_eq!(m.shown_target(), Some(&row(1)), "the card went with the pointer on it");
}

#[test]
fn hover_card_stopping_on_a_crossed_row_hands_it_the_card() {
    let mut m = shown_on_row_one();
    run(&mut m, aimed(Some(row(2))));
    run(&mut m, HoverCardEvent::PointerOnCard(false));
    let token = m.armed_token().unwrap();
    assert_eq!(run(&mut m, HoverCardEvent::Deadline(token)), vec![show(row(2), true)]);
    assert_eq!(m.shown_target(), Some(&row(2)));
}

#[test]
fn hover_card_a_row_reached_without_aiming_swaps_at_once() {
    let mut m = shown_on_row_one();
    assert_eq!(run(&mut m, hit(Some(row(2)), true)), vec![show(row(2), true)]);
}

#[test]
fn hover_card_never_covers_its_row() {
    let screen = HoverRect::new(0., 0., 1440., 900.);
    let rows = [
        HoverRect::new(8., 600., 224., 32.),
        HoverRect::new(8., 40., 224., 32.),
        HoverRect::new(8., 850., 224., 32.),
        HoverRect::new(1200., 400., 232., 32.),
    ];
    for r in rows {
        let g = HoverCardEscapeGeometry::new(
            r,
            (280., 160.),
            Some(screen.inset_by(8., 8.)),
            2.,
            None,
            HoverRowAlignment::Top,
        );
        assert!(!g.card.intersects(&r), "row {r:?}: card {:?}", g.card);
        assert!(
            g.card.min_x() >= r.max_x() || g.card.max_x() <= r.min_x(),
            "beside the row: {:?}",
            g.card
        );
    }
}

// MARK: TabHoverCardTimingTests (the machine's half; tabs hide on leave)

#[test]
fn hover_card_tab_resting_on_the_card_keeps_it_and_off_it_hides_at_once() {
    // theCardStaysWithThePointerOnItAndFadesOutAtOnceOffIt.
    let mut m = shown_on_row_one();
    // From the tab onto the card: no target, bridging; it stays.
    assert!(!hides(&run(&mut m, bridged(None))));
    run(&mut m, HoverCardEvent::PointerOnCard(true));
    let token = m.armed_token().unwrap();
    let again = run(&mut m, HoverCardEvent::Deadline(token));
    assert_eq!(m.shown_target(), Some(&row(1)), "the card hid with the pointer resting on it");
    let next = m.armed_token().unwrap();
    assert_eq!(again, vec![E::Schedule { token: next, after: RESHOW }]);
    // Off the card and the strip: it hides on this move, with no grace timer first.
    let off = run(&mut m, hit(None, true));
    let grace = m.armed_token().unwrap();
    assert_eq!(off, vec![E::Hide, E::Schedule { token: grace, after: RESHOW }]);
    // Back onto a tab within the grace: its card at once.
    assert_eq!(run(&mut m, hit(Some(row(2)), true)), vec![E::CancelTimer, show(row(2), false)]);
    // Off again, past the grace: the next tab waits the delay again.
    run(&mut m, hit(None, true));
    let grace = m.armed_token().unwrap();
    assert!(run(&mut m, HoverCardEvent::Deadline(grace)).is_empty());
    assert_eq!(m.phase(), &HoverCardPhase::Idle);
    let cold = run(&mut m, hit(Some(row(3)), true));
    assert!(!shows(&cold), "past the grace, a new hover showed at once");
    run(&mut m, hit(None, true));
    assert_eq!(m.phase(), &HoverCardPhase::Idle, "leaving before the delay left a card pending");
}

#[test]
fn hover_card_tab_a_click_keeps_the_card_away_until_the_pointer_leaves_the_tab() {
    // aClickKeepsTheCardAwayUntilThePointerLeavesTheTab: a small move on the
    // clicked tab (one whose card hides on leave) does not bring it back.
    let mut m = shown_on_row_one();
    assert!(hides(&run(&mut m, HoverCardEvent::Dismiss)));
    assert!(run(&mut m, hit(Some(row(1)), true)).is_empty(), "a 1-px move brought the card back");
    assert!(m.active_target().is_none());
    run(&mut m, hit(None, true));
    let back = run(&mut m, hit(Some(row(1)), true));
    let token = m.armed_token().unwrap();
    assert_eq!(back, vec![E::Schedule { token, after: DELAY }], "away and back: the delay again");
}

#[test]
fn hover_card_tab_crossing_a_tab_with_no_card_swaps_without_hiding() {
    // crossingANewTabPageTabSwapsWithoutHiding.
    let mut m = shown_on_row_one();
    assert!(!hides(&run(&mut m, bridged(None))), "the card hid crossing a tab with no card");
    assert_eq!(run(&mut m, hit(Some(row(3)), true)), vec![E::CancelTimer, show(row(3), true)]);
    // Resting on the cardless tab past the grace: the card goes.
    run(&mut m, bridged(None));
    let token = m.armed_token().unwrap();
    run(&mut m, HoverCardEvent::PointerOnCard(false));
    assert!(hides(&run(&mut m, HoverCardEvent::Deadline(token))));
    assert!(m.shown_target().is_none());
}

#[test]
fn hover_card_a_sweep_before_any_card_shows_starts_only_the_last_rows_delay() {
    // onlyAShownCardSamplesItsTab and SidebarHoverCardDwellTests.aSweepAcrossFiveRowsShowsNoCard.
    let mut m = HoverCardMachine::new();
    let mut tokens = Vec::new();
    for n in 1..=5 {
        let effects = run(&mut m, hit(Some(row(n)), true));
        assert!(!shows(&effects));
        tokens.push(m.armed_token().unwrap());
    }
    for stale in &tokens[..4] {
        assert!(
            run(&mut m, HoverCardEvent::Deadline(*stale)).is_empty(),
            "a stale token showed a card"
        );
    }
    assert_eq!(run(&mut m, HoverCardEvent::Deadline(tokens[4])), vec![show(row(5), false)]);
}

// MARK: branches the AppKit tests reach through the coordinator

#[test]
fn hover_card_lingering_card_stays_for_the_grace_then_hides() {
    let target = lingering("tab:a", DELAY);
    let mut m = HoverCardMachine::new();
    run(&mut m, hit(Some(target.clone()), true));
    fire_armed(&mut m);
    let leave = run(&mut m, hit(None, true));
    let token = m.armed_token().unwrap();
    assert_eq!(leave, vec![E::Schedule { token, after: m.leave_window }]);
    assert_eq!(m.shown_target(), Some(&target));
    run(&mut m, HoverCardEvent::PointerOnCard(false));
    let gone = run(&mut m, HoverCardEvent::Deadline(token));
    let grace = m.armed_token().unwrap();
    assert_eq!(gone, vec![E::Hide, E::Schedule { token: grace, after: m.reshow_window }]);
}

#[test]
fn hover_card_lingering_card_rested_on_gets_the_full_grace_after_the_pointer_leaves_it() {
    let target = lingering("tab:a", DELAY);
    let mut m = HoverCardMachine::new();
    run(&mut m, hit(Some(target.clone()), true));
    fire_armed(&mut m);
    run(&mut m, hit(None, true));
    run(&mut m, HoverCardEvent::PointerOnCard(true));
    let first = m.armed_token().unwrap();
    let kept = run(&mut m, HoverCardEvent::Deadline(first));
    let second = m.armed_token().unwrap();
    assert_eq!(kept, vec![E::Schedule { token: second, after: m.leave_window }]);
    // Just off the card at the next deadline: one more full grace.
    run(&mut m, HoverCardEvent::PointerOnCard(false));
    let grace = run(&mut m, HoverCardEvent::Deadline(second));
    let third = m.armed_token().unwrap();
    assert_eq!(grace, vec![E::Schedule { token: third, after: m.leave_window }]);
    assert!(hides(&run(&mut m, HoverCardEvent::Deadline(third))));
}

#[test]
fn hover_card_lingering_card_aimed_at_waits_the_aim_window() {
    let a = lingering("tab:a", DELAY);
    let b = lingering("tab:b", DELAY);
    let mut m = HoverCardMachine::new();
    run(&mut m, hit(Some(a.clone()), true));
    fire_armed(&mut m);
    let crossing = run(&mut m, aimed(Some(b.clone())));
    let token = m.armed_token().unwrap();
    assert_eq!(crossing, vec![E::Schedule { token, after: m.aim_window }]);
    // Off every target while still aiming: the aim restarts.
    let on = run(&mut m, aimed(None));
    let again = m.armed_token().unwrap();
    assert_eq!(on, vec![E::Schedule { token: again, after: m.aim_window }]);
    // Back on the shown target: it keeps the card, the timer stops.
    assert_eq!(run(&mut m, hit(Some(a.clone()), true)), vec![E::CancelTimer]);
    assert_eq!(m.phase(), &HoverCardPhase::Shown { target: a });
}

#[test]
fn hover_card_a_target_with_no_delay_shows_on_a_move_and_waits_under_a_still_pointer() {
    let instant = lingering("chip", 0);
    let mut m = HoverCardMachine::new();
    assert_eq!(run(&mut m, hit(Some(instant.clone()), true)), vec![show(instant.clone(), false)]);
    let mut still = HoverCardMachine::new();
    let effects = run(&mut still, hit(Some(instant), false));
    let token = still.armed_token().unwrap();
    assert_eq!(effects, vec![E::Schedule { token, after: HOVER_CARD_STILL_POINTER_DELAY }]);
}

#[test]
fn hover_card_pin_shows_at_once_and_its_lifetime_ends_it() {
    let pinned = lingering("tab:a", DELAY);
    let mut m = HoverCardMachine::new();
    let effects = run(&mut m, HoverCardEvent::Pin(pinned.clone()));
    let token = m.armed_token().unwrap();
    assert_eq!(
        effects,
        vec![E::Schedule { token, after: HOVER_CARD_PIN_LIFETIME }, show(pinned.clone(), false)]
    );
    // The pointer leaving keeps it; a still pointer over another target does too.
    assert!(run(&mut m, hit(None, true)).is_empty());
    assert!(run(&mut m, hit(Some(row(2)), false)).is_empty());
    assert!(matches!(m.phase(), HoverCardPhase::Pinned { .. }));
    // The lifetime ends it; the pointer resting on row 2 gets row 2's card (after its delay).
    let end = run(&mut m, HoverCardEvent::Deadline(token));
    let next = m.armed_token().unwrap();
    assert_eq!(end, vec![E::Hide, E::Schedule { token: next, after: DELAY }]);
    assert_eq!(m.active_target(), Some(&row(2)));
}

#[test]
fn hover_card_pin_lifetime_with_the_pointer_on_it_keeps_it_as_a_hover_card() {
    let mut m = HoverCardMachine::new();
    run(&mut m, HoverCardEvent::Pin(row(1)));
    let token = m.armed_token().unwrap();
    run(&mut m, hit(Some(row(1)), true));
    assert!(run(&mut m, HoverCardEvent::Deadline(token)).is_empty());
    assert_eq!(m.phase(), &HoverCardPhase::Shown { target: row(1) });
}

#[test]
fn hover_card_pin_a_moving_pointer_on_another_target_takes_it_over() {
    let mut m = HoverCardMachine::new();
    run(&mut m, HoverCardEvent::Pin(row(1)));
    assert_eq!(run(&mut m, hit(Some(row(2)), true)), vec![E::CancelTimer, show(row(2), true)]);
}

#[test]
fn hover_card_no_pin_during_a_drag_and_the_drop_resumes_the_card() {
    let mut m = HoverCardMachine::new();
    run(&mut m, HoverCardEvent::Suppress(HoverSuppression::Drag));
    assert!(run(&mut m, HoverCardEvent::Pin(row(1))).is_empty());
    assert!(run(&mut m, hit(Some(row(2)), true)).is_empty(), "no card during a drag");
    assert!(m.suppressions().contains(HoverSuppression::Drag));
    let resumed = run(&mut m, HoverCardEvent::Unsuppress(HoverSuppression::Drag));
    let token = m.armed_token().unwrap();
    assert_eq!(
        resumed,
        vec![E::Schedule { token, after: DELAY }],
        "the pointer that moved gets its card"
    );
    assert!(m.suppressions().is_empty());
}

#[test]
fn hover_card_a_removed_target_ends_its_card_and_another_target_under_the_pointer_resumes() {
    let mut m = shown_on_row_one();
    assert_eq!(run(&mut m, HoverCardEvent::TargetRemoved("ws:ws-1")), vec![E::Hide]);
    assert!(m.last_hit().is_none());
    // A pinned card of row 1 while the pointer rests on row 2: removing row 1 resumes row 2.
    let mut p = HoverCardMachine::new();
    run(&mut p, HoverCardEvent::Pin(row(1)));
    run(&mut p, hit(Some(row(2)), false));
    let effects = run(&mut p, HoverCardEvent::TargetRemoved("ws:ws-1"));
    let token = p.armed_token().unwrap();
    assert_eq!(effects, vec![E::CancelTimer, E::Hide, E::Schedule { token, after: DELAY }]);
    // An id nobody shows changes nothing.
    assert!(run(&mut p, HoverCardEvent::TargetRemoved("ws:gone")).is_empty());
}

#[test]
fn hover_card_an_owners_card_takes_the_window_and_the_next_target_takes_it_back_at_once() {
    let mut m = HoverCardMachine::new();
    run(&mut m, hit(Some(row(1)), true));
    assert_eq!(
        run(&mut m, HoverCardEvent::Owned(true)),
        vec![E::CancelTimer],
        "no hide: the window morphs"
    );
    assert_eq!(m.phase(), &HoverCardPhase::Idle);
    assert!(m.owned_card_shown());
    assert_eq!(run(&mut m, hit(Some(row(2)), true)), vec![show(row(2), true)]);
    assert!(run(&mut m, HoverCardEvent::Owned(false)).is_empty());
    assert!(!m.owned_card_shown());
}

#[test]
fn hover_card_one_event_never_produces_more_than_the_effect_capacity() {
    // A small deterministic walk over every event kind from every phase.
    let targets = [Some(row(1)), Some(row(2)), Some(lingering("tab:a", 0)), None];
    let mut seed: u64 = 0x9E37_79B9_7F4A_7C15;
    let mut next = || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed
    };
    let mut m = HoverCardMachine::<Id>::new();
    for _ in 0..20_000 {
        let r = next();
        let target = targets[(r % 4) as usize].clone();
        let flag = (r >> 8) & 1 == 1;
        let event = match (r >> 16) % 10 {
            0..=2 => HoverCardEvent::Hit {
                target,
                moved: flag,
                aiming: (r >> 9) & 1 == 1,
                bridging: (r >> 10) & 1 == 1,
            },
            3 => HoverCardEvent::PointerOnCard(flag),
            4 => HoverCardEvent::Deadline(m.armed_token().unwrap_or(0)),
            5 => HoverCardEvent::Dismiss,
            6 => {
                let s = HoverSuppression::ALL[((r >> 20) % 3) as usize];
                if flag { HoverCardEvent::Suppress(s) } else { HoverCardEvent::Unsuppress(s) }
            }
            7 => HoverCardEvent::TargetRemoved(target.map_or("ws:ws-1", |t| t.id)),
            8 => HoverCardEvent::Pin(target.unwrap_or_else(|| row(3))),
            _ => HoverCardEvent::Owned(flag),
        };
        let effects = m.reduce(event);
        assert!(effects.len() <= MAX_EFFECTS_PER_EVENT);
        // A shown card is never pending a hover delay and an armed phase has a token.
        if let Some(token) = m.armed_token() {
            assert!(token < m.next_token());
        }
    }
}

// MARK: TooltipHoverIntentTests (the intent's half)

type I = HoverIntentEffect<u32>;

fn tooltips() -> HoverIntent<u32> {
    let t = HoverIntentTiming::STANDARD;
    HoverIntent::new(t.tooltip_delay, t.tooltip_warm)
}

#[test]
fn hover_intent_the_first_tooltip_waits_then_neighbors_show_at_once_until_the_group_cools() {
    let mut i = tooltips();
    let first = i.hover(Some(0)).to_vec();
    let token = match first.as_slice() {
        [I::Schedule { token, after }] if *after == millis(450) => *token,
        other => panic!("the first tooltip did not wait 450 ms: {other:?}"),
    };
    assert!(i.shown().is_none());
    assert_eq!(i.deadline(token).to_vec(), vec![I::Show(0)]);
    // Warm: the neighbor's shows at once.
    assert_eq!(i.hover(Some(1)).to_vec(), vec![I::Show(1)]);
    // Off the toolbar for a moment, then onto another: still at once.
    let off = i.hover(None).to_vec();
    let warm = match off.as_slice() {
        [I::Hide, I::Schedule { token, after }] if *after == millis(500) => *token,
        other => panic!("leaving did not start the warm time: {other:?}"),
    };
    assert!(i.is_warm());
    assert_eq!(i.hover(Some(2)).to_vec(), vec![I::CancelTimer, I::Show(2)]);
    // Away past the warm time: the next one waits the full delay again.
    let off = i.hover(None).to_vec();
    let I::Schedule { token: warm2, .. } = off[1] else { panic!("{off:?}") };
    assert_ne!(warm, warm2);
    assert!(i.deadline(warm2).is_empty());
    assert!(!i.is_warm());
    let cold = i.hover(Some(3)).to_vec();
    assert!(
        matches!(cold.as_slice(), [I::Schedule { after, .. }] if *after == millis(450)),
        "{cold:?}"
    );
}

#[test]
fn hover_intent_a_fast_sweep_across_the_toolbar_shows_no_tooltip() {
    let mut i = tooltips();
    let mut armed = Vec::new();
    for button in 0..5 {
        let effects = i.hover(Some(button)).to_vec();
        assert!(!effects.iter().any(|e| matches!(e, I::Show(_))), "{effects:?}");
        if let Some(I::Schedule { token, .. }) = effects.first() {
            armed.push(*token);
        }
        assert!(i.hover(None).iter().all(|e| matches!(e, I::CancelTimer)));
    }
    for token in armed {
        assert!(i.deadline(token).is_empty(), "a stale token showed a tooltip");
    }
    assert!(i.shown().is_none());
}

#[test]
fn hover_intent_dismiss_cools_the_group_and_no_delay_shows_at_once() {
    let mut i = tooltips();
    i.hover(Some(1));
    assert_eq!(i.dismiss().to_vec(), vec![I::CancelTimer]);
    let mut instant = HoverIntent::<u32>::new(0, millis(500));
    assert_eq!(instant.hover(Some(4)).to_vec(), vec![I::Show(4)]);
    assert_eq!(instant.hover(Some(4)).to_vec(), vec![], "the same target changes nothing");
    assert_eq!(instant.dismiss().to_vec(), vec![I::Hide]);
    assert_eq!(instant.dismiss().to_vec(), vec![]);
    assert_eq!(instant.phase(), &HoverIntentPhase::Idle);
}

// MARK: HoverCardEscapeGeometryTests (escape-slot layout)

const ROW: HoverRect = HoverRect::new(8., 600., 224., 32.);
const SIZE: (f64, f64) = (280., 160.);
const SCREEN: HoverRect = HoverRect::new(0., 0., 1440., 900.);
const GAP: f64 = 10.;

fn p(x: f64, y: f64) -> HoverPoint {
    HoverPoint { x, y }
}

fn middle(anchor: HoverRect) -> HoverCardEscapeGeometry {
    HoverCardEscapeGeometry::new(
        anchor,
        SIZE,
        Some(SCREEN),
        2.,
        Some(GAP),
        HoverRowAlignment::Middle,
    )
}

#[test]
fn hover_geometry_the_card_sits_right_of_the_row_with_its_top_on_the_rows_middle() {
    let g = middle(ROW);
    assert_eq!(g.card.min_x(), ROW.max_x() + GAP);
    assert_eq!(g.card.max_y(), ROW.mid_y());
    assert!(!g.is_leading);
    assert_eq!(
        g.escape_slot,
        HoverRect::new(ROW.max_x(), ROW.mid_y(), SIZE.0 + GAP, ROW.height / 2.)
    );
    assert_eq!(g.gap_strip, HoverRect::new(ROW.max_x(), g.card.min_y(), GAP, SIZE.1));
}

#[test]
fn hover_geometry_the_gap_between_the_row_and_the_card_keeps_no_card_by_itself() {
    let g = middle(ROW);
    let below = p(ROW.max_x() + 3., ROW.min_y() - 14.);
    assert_eq!(g.zone(below), HoverZone::Gap);
    assert!(!g.keeps_card(below));
}

#[test]
fn hover_geometry_the_escape_slot_dismisses() {
    let g = middle(ROW);
    for point in
        [p(ROW.max_x() + 1., ROW.max_y() - 2.), p(ROW.max_x() + SIZE.0 - 1., ROW.mid_y() + 1.)]
    {
        assert_eq!(g.zone(point), HoverZone::Escape, "{point:?}");
        assert!(!g.keeps_card(point));
        assert!(!g.card.contains(point), "the card covers {point:?}");
    }
}

#[test]
fn hover_geometry_the_straight_path_from_the_row_into_the_card_keeps_it() {
    let g = middle(ROW);
    let y = ROW.min_y() + 4.;
    let mut x = ROW.mid_x();
    while x < g.card.mid_x() {
        let zone = g.zone(p(x, y));
        assert!(
            matches!(zone, HoverZone::Row | HoverZone::Gap | HoverZone::Card),
            "{zone:?} at x {x}"
        );
        x += 0.5;
    }
    assert!(
        g.card.aimed_at(Some(p(ROW.max_x() - 2., y)), Some(p(ROW.max_x() + 2., y))),
        "a pointer moving right across the gap does not aim at the card"
    );
    assert_eq!(g.zone(p(g.card.min_x() + 2., ROW.mid_y() - 2.)), HoverZone::Card);
}

#[test]
fn hover_geometry_leaving_both_the_row_and_the_card_dismisses() {
    let g = middle(ROW);
    for point in [
        p(g.card.max_x() + 10., g.card.mid_y()),
        p(g.card.mid_x(), g.card.min_y() - 10.),
        p(ROW.max_x() + 20., ROW.max_y() + 10.),
        p(ROW.mid_x(), ROW.min_y() - 40.),
    ] {
        assert_eq!(g.zone(point), HoverZone::Outside, "{point:?}");
        assert!(!g.keeps_card(point));
    }
}

#[test]
fn hover_geometry_near_the_screens_bottom_the_card_flips_and_keeps_the_slot() {
    let low = HoverRect::new(8., 40., 224., 32.);
    let g = middle(low);
    assert_eq!(g.card.min_y(), low.mid_y());
    assert_eq!(
        g.escape_slot,
        HoverRect::new(low.max_x(), low.min_y(), SIZE.0 + GAP, low.height / 2.)
    );
    assert_eq!(g.zone(p(low.max_x() + 4., low.min_y() + 2.)), HoverZone::Escape);
    assert_eq!(g.zone(p(low.max_x() + 4., low.max_y() - 2.)), HoverZone::Gap);
    assert_eq!(g.zone(p(low.max_x() + GAP + 4., low.max_y() - 2.)), HoverZone::Card);
}

#[test]
fn hover_geometry_at_the_screens_right_edge_the_card_goes_left_and_keeps_the_slot() {
    let right = HoverRect::new(1200., 600., 232., 32.);
    let g = middle(right);
    assert!(g.is_leading);
    assert_eq!(g.card.max_x(), right.min_x() - GAP);
    assert_eq!(g.zone(p(right.min_x() - 4., right.max_y() - 2.)), HoverZone::Escape);
    assert_eq!(g.zone(p(right.min_x() - 4., right.min_y() + 2.)), HoverZone::Gap);
    assert_eq!(g.zone(p(right.min_x() - GAP - 4., right.min_y() + 2.)), HoverZone::Card);
}

#[test]
fn hover_geometry_the_near_edge_touches_the_sidebar_at_every_scale() {
    for scale in [1., 2., 3.] {
        let fractional = HoverRect::new(8.3, 600.3, 224.1, 31.7);
        let g = HoverCardEscapeGeometry::new(
            fractional,
            SIZE,
            Some(SCREEN),
            scale,
            None,
            HoverRowAlignment::Top,
        );
        let gap = g.card.min_x() - fractional.max_x();
        assert!(gap <= 0.0001 && gap > -1. / scale, "@{scale}x: {gap} pt between row and preview");
        assert!(((g.card.min_x() * scale).round() - g.card.min_x() * scale).abs() < 0.0001);
        assert_eq!(hover_edge_gap(scale), 1. / scale);
        let right = HoverRect::new(1440. - 240.3, 600., 240.3, 32.);
        let leading = HoverCardEscapeGeometry::new(
            right,
            SIZE,
            Some(SCREEN),
            scale,
            None,
            HoverRowAlignment::Top,
        );
        assert!(leading.is_leading);
        let leading_gap = right.min_x() - leading.card.max_x();
        assert!(
            leading_gap <= 0.0001 && leading_gap > -1. / scale,
            "@{scale}x leading: {leading_gap} pt"
        );
    }
}

#[test]
fn hover_geometry_a_rows_band_spans_the_column() {
    let column = HoverRect::new(0., 0., 260., 900.);
    let nested = HoverRect::new(36., 500., 190., 28.);
    let band = hover_row_band(nested, column);
    assert_eq!(band, HoverRect::new(0., 500., 260., 28.));
    let top =
        HoverCardEscapeGeometry::new(band, SIZE, Some(SCREEN), 2., None, HoverRowAlignment::Top);
    assert_eq!(top.card.min_x(), 260.);
    assert_eq!(top.card.max_y(), nested.max_y());
}

// MARK: HoverCardRowAlignmentTests (the default, top-aligned layout; HoverCardPanel.rest's
// `.besideRow` is `hover_card_room` then the geometry)

const MARGIN: f64 = 8.;

fn rest(anchor: HoverRect, visible: HoverRect, window: Option<HoverRect>, scale: f64) -> HoverRect {
    let room = hover_card_room(visible, window, MARGIN);
    HoverCardEscapeGeometry::new(anchor, SIZE, Some(room), scale, None, HoverRowAlignment::Top).card
}

#[test]
fn hover_alignment_the_cards_top_is_the_rows_top_beside_the_sidebar() {
    let card = rest(ROW, SCREEN, None, 2.);
    assert_eq!(card.max_y(), ROW.max_y());
    assert_eq!(card.min_x(), ROW.max_x());
}

#[test]
fn hover_alignment_the_geometry_has_no_escape_slot_when_top_aligned() {
    let g = HoverCardEscapeGeometry::new(ROW, SIZE, Some(SCREEN), 2., None, HoverRowAlignment::Top);
    assert_eq!(g.card, HoverRect::new(ROW.max_x(), ROW.max_y() - SIZE.1, SIZE.0, SIZE.1));
    assert!(!g.is_leading);
    assert_eq!(g.escape_slot, HoverRect::ZERO);
    assert_eq!(g.gap_strip, HoverRect::ZERO);
    assert_eq!(g.zone(p(ROW.max_x() + 4., ROW.max_y() - 3.)), HoverZone::Card);
}

#[test]
fn hover_alignment_the_card_follows_the_row_from_row_to_row() {
    for offset in [0., -32., -64., -200.] {
        let next = HoverRect::new(ROW.x, ROW.y + offset, ROW.width, ROW.height);
        let card = rest(next, SCREEN, None, 2.);
        assert_eq!(card.max_y(), next.max_y(), "row at {}", next.min_y());
        assert_eq!(card.min_x(), next.max_x());
    }
}

#[test]
fn hover_alignment_near_the_screens_bottom_the_card_is_clamped_up_beside_the_row() {
    let low = HoverRect::new(8., 40., 224., 32.);
    let card = rest(low, SCREEN, None, 2.);
    assert_eq!(card.min_y(), SCREEN.min_y() + MARGIN);
    assert!(card.min_y() <= low.min_y() && card.max_y() >= low.max_y());
    assert_eq!(card.min_x(), low.max_x());
}

#[test]
fn hover_alignment_near_the_screens_top_the_card_stays_in_the_visible_frame() {
    let visible = HoverRect::new(0., 0., 1440., 875.);
    let high = HoverRect::new(8., 860., 224., 32.);
    assert_eq!(rest(high, visible, None, 2.).max_y(), visible.max_y() - MARGIN);
}

#[test]
fn hover_alignment_at_the_screens_right_edge_the_card_goes_left_top_aligned() {
    let right = HoverRect::new(1200., 600., 232., 32.);
    let g = HoverCardEscapeGeometry::new(
        right,
        SIZE,
        Some(SCREEN.inset_by(MARGIN, MARGIN)),
        2.,
        None,
        HoverRowAlignment::Top,
    );
    assert!(g.is_leading);
    assert_eq!(g.card.max_x(), right.min_x());
    assert_eq!(g.card.max_y(), right.max_y());
}

#[test]
fn hover_alignment_the_top_snaps_to_the_nearest_device_pixel() {
    for scale in [1., 2., 3.] {
        let fractional = HoverRect::new(8.3, 600.3, 224.1, 31.7);
        let card = rest(fractional, SCREEN, None, scale);
        assert!((card.max_y() - fractional.max_y()).abs() <= 0.5 / scale + 0.001, "@{scale}x");
        assert!(
            ((card.max_y() * scale).round() - card.max_y() * scale).abs() < 0.001,
            "@{scale}x off the grid"
        );
    }
}

#[test]
fn hover_alignment_the_middle_alignment_keeps_the_escape_slot_layout() {
    let room = hover_card_room(SCREEN, None, MARGIN);
    let g =
        HoverCardEscapeGeometry::new(ROW, SIZE, Some(room), 2., None, HoverRowAlignment::Middle);
    assert_eq!(g.card.min_y() + SIZE.1, ROW.mid_y());
}

// MARK: HoverCardWindowClampTests

const CLAMP_VISIBLE: HoverRect = HoverRect::new(0., 0., 1512., 950.);
const CLAMP_WINDOW: HoverRect = HoverRect::new(100., 300., 900., 500.);
const CLAMP_SIZE: (f64, f64) = (180., 30.);

fn clamp_rest(anchor: HoverRect, window: Option<HoverRect>) -> HoverRect {
    let room = hover_card_room(CLAMP_VISIBLE, window, MARGIN);
    HoverCardEscapeGeometry::new(anchor, CLAMP_SIZE, Some(room), 2., None, HoverRowAlignment::Top)
        .card
}

#[test]
fn hover_clamp_the_bottom_rows_card_stays_inside_the_window() {
    let row = HoverRect::new(CLAMP_WINDOW.min_x(), CLAMP_WINDOW.min_y() + 10., 6., 6.);
    let card = clamp_rest(row, Some(CLAMP_WINDOW));
    assert!(card.min_y() >= CLAMP_WINDOW.min_y(), "the card hangs below the window");
    assert_eq!(card.min_x() - row.max_x(), 0.);
    assert!(card.max_y() > row.min_y(), "still beside its row");
}

#[test]
fn hover_clamp_a_row_with_room_keeps_its_top_on_the_rows_top() {
    let row = HoverRect::new(CLAMP_WINDOW.min_x(), CLAMP_WINDOW.max_y() - 120., 6., 6.);
    assert_eq!(clamp_rest(row, Some(CLAMP_WINDOW)).max_y(), row.max_y());
}

#[test]
fn hover_clamp_a_sidebar_that_fills_its_window_keeps_its_card_beside_it() {
    let narrow = HoverRect::new(200., 100., 240., 400.);
    let row = HoverRect::new(narrow.min_x(), narrow.max_y() - 120., narrow.width, 28.);
    let card = clamp_rest(row, Some(narrow));
    assert_eq!(card.min_x() - row.max_x(), 0.);
    assert_eq!(card.max_y(), row.max_y());
}

#[test]
fn hover_clamp_the_room_is_the_screen_when_the_window_leaves_none_or_is_absent() {
    assert_eq!(
        hover_card_room(CLAMP_VISIBLE, None, MARGIN),
        CLAMP_VISIBLE.inset_by(MARGIN, MARGIN)
    );
    let above = HoverRect::new(0., 2000., 100., 100.);
    assert_eq!(
        hover_card_room(CLAMP_VISIBLE, Some(above), MARGIN),
        CLAMP_VISIBLE.inset_by(MARGIN, MARGIN)
    );
    let room = hover_card_room(CLAMP_VISIBLE, Some(CLAMP_WINDOW), MARGIN);
    assert_eq!(room, HoverRect::new(MARGIN, 300., 1512. - 2. * MARGIN, 500.));
    assert!(
        HoverRect::new(0., 0., 10., 10.).inset_by(6., 6.).is_null(),
        "an inset past empty is null"
    );
}

// MARK: the safe triangle (`CGRect.isAimedAt`)

#[test]
fn hover_aim_a_move_into_the_card_or_toward_its_near_edge_aims() {
    let card = HoverRect::new(240., 400., 280., 160.);
    assert!(card.aimed_at(Some(p(200., 500.)), Some(p(250., 500.))), "into it");
    assert!(card.aimed_at(Some(p(200., 500.)), Some(p(210., 503.))), "toward its near edge");
    assert!(!card.aimed_at(Some(p(200., 500.)), Some(p(201., 520.))), "mostly along it");
    assert!(!card.aimed_at(Some(p(200., 500.)), Some(p(190., 500.))), "away from it");
    assert!(!card.aimed_at(Some(p(200., 500.)), Some(p(200., 500.))), "no move");
    assert!(!card.aimed_at(None, Some(p(250., 500.))), "no previous point");
    assert!(!HoverRect::ZERO.aimed_at(Some(p(0., 0.)), Some(p(1., 1.))), "an empty card");
    // Below the card, heading up into its bottom edge's triangle.
    assert!(card.aimed_at(Some(p(380., 350.)), Some(p(381., 360.))));
    // Outside the triangle: past the edge's end.
    assert!(!card.aimed_at(Some(p(200., 500.)), Some(p(230., 300.))));
}

// MARK: the C forms

fn c_target(id: u64) -> CmuxHoverTarget {
    CmuxHoverTarget { id, window: 7, delay: DELAY, reshow: RESHOW, leave: LEAVE_HIDES }
}

fn c_hit(id: Option<u64>) -> CmuxHoverCardEvent {
    CmuxHoverCardEvent {
        target: id.map(c_target).unwrap_or_default(),
        kind: EVENT_HIT,
        flag: id.is_some(),
        moved: true,
        ..CmuxHoverCardEvent::default()
    }
}

#[test]
fn hover_c_machine_round_trips_every_field() {
    let mut m = HoverCardMachine::<u64>::new();
    m.reduce(HoverCardEvent::Hit {
        target: Some(HoverTarget::from(c_target(9))),
        moved: true,
        aiming: false,
        bridging: false,
    });
    m.reduce(HoverCardEvent::Suppress(HoverSuppression::Scroll));
    m.reduce(HoverCardEvent::PointerOnCard(true));
    m.leave_window = millis(123);
    let c = CmuxHoverCardMachine::from(&m);
    assert_eq!(HoverCardMachine::<u64>::from(c), m);
    assert_eq!(
        CmuxHoverCardMachine::new(),
        CmuxHoverCardMachine::from(&HoverCardMachine::<u64>::new())
    );
}

#[test]
fn hover_c_batch_matches_the_machine_event_by_event() {
    let events = [
        c_hit(Some(1)),
        CmuxHoverCardEvent { kind: EVENT_DEADLINE, token: 1, ..Default::default() },
        c_hit(Some(2)),
        c_hit(None),
    ];
    let mut c = CmuxHoverCardMachine::new();
    let mut out = [CmuxHoverCardEffect::default(); 12];
    let r = reduce_card_batch(&mut c, &events, &mut out);
    assert_eq!(r.events, 4);
    let mut m = HoverCardMachine::<u64>::new();
    let expected: Vec<CmuxHoverCardEffect> = events
        .iter()
        .flat_map(|e| m.reduce(e.event().unwrap()).to_vec())
        .map(|e| CmuxHoverCardEffect::from(&e))
        .collect();
    assert_eq!(&out[..r.effects], expected.as_slice());
    assert_eq!(c, CmuxHoverCardMachine::from(&m));
    assert_eq!(out[1].kind, EFFECT_SHOW);
    assert_eq!(out[1].target.id, 1);
}

#[test]
fn hover_c_batch_stops_before_an_event_that_might_not_fit() {
    let events = [c_hit(Some(1)), c_hit(Some(2))];
    let mut c = CmuxHoverCardMachine::new();
    let mut out = [CmuxHoverCardEffect::default(); MAX_EFFECTS_PER_EVENT];
    let r = reduce_card_batch(&mut c, &events, &mut out);
    assert_eq!((r.events, r.effects), (1, 1));
    let mut none = [CmuxHoverCardEffect::default(); 2];
    let before = c;
    assert_eq!(reduce_card_batch(&mut c, &events[1..], &mut none), BatchResult::default());
    assert_eq!(c, before, "no room: nothing applied");
}

#[test]
fn hover_c_garbage_reads_as_safe_values() {
    let garbage = CmuxHoverCardMachine {
        phase: 200,
        suppressions: 0xFF,
        next_token: 0,
        target: CmuxHoverTarget { leave: 77, ..c_target(3) },
        ..CmuxHoverCardMachine::default()
    };
    let m = HoverCardMachine::<u64>::from(garbage);
    assert_eq!(m.phase(), &HoverCardPhase::Idle);
    assert_eq!(m.suppressions().bits(), 0b111);
    assert_eq!(m.next_token(), 1, "token 0 is never armed");
    assert!(CmuxHoverCardEvent { kind: 99, ..Default::default() }.event().is_none());
    assert!(
        CmuxHoverCardEvent { kind: EVENT_SUPPRESS, suppression: 9, ..Default::default() }
            .event()
            .is_none()
    );
    let mut c = garbage;
    let mut out = [CmuxHoverCardEffect::default(); 3];
    let r = reduce_card_batch(
        &mut c,
        &[CmuxHoverCardEvent { kind: 99, ..Default::default() }],
        &mut out,
    );
    assert_eq!((r.events, r.effects), (1, 0));
    assert_eq!(
        HoverTarget::from(CmuxHoverTarget { leave: 77, ..c_target(3) }).leave,
        HoverCardLeave::Lingers
    );
}

#[test]
fn hover_c_intent_calls_match_the_intent() {
    let t = HoverIntentTiming::STANDARD;
    let mut c = CmuxHoverIntent::new(t.tooltip_delay, t.tooltip_warm);
    let mut out = [CmuxHoverIntentEffect::default(); 2];
    assert_eq!(intent_call(&mut c, INTENT_CALL_HOVER, true, 5, &mut out), 1);
    assert_eq!((out[0].kind, out[0].after), (EFFECT_SCHEDULE, t.tooltip_delay));
    let token = out[0].token;
    assert_eq!(intent_call(&mut c, INTENT_CALL_DEADLINE, false, token, &mut out), 1);
    assert_eq!((out[0].kind, out[0].target), (EFFECT_SHOW, 5));
    assert_eq!(c.phase, INTENT_SHOWN);
    assert_eq!(intent_call(&mut c, INTENT_CALL_HOVER, false, 0, &mut out), 2);
    assert_eq!((out[0].kind, out[1].kind), (EFFECT_HIDE, EFFECT_SCHEDULE));
    assert_eq!(intent_call(&mut c, INTENT_CALL_DISMISS, false, 0, &mut out), 1);
    assert_eq!(out[0].kind, EFFECT_CANCEL_TIMER);
    let before = c;
    assert_eq!(intent_call(&mut c, 9, true, 1, &mut out), 0);
    assert_eq!(intent_call(&mut c, INTENT_CALL_HOVER, true, 1, &mut out[..1]), 0);
    assert_eq!(c, before);
}

#[test]
fn hover_c_geometry_and_zone_numbers() {
    let g = CmuxHoverEscapeGeometry::from(middle(ROW));
    assert_eq!(zone(g, p(ROW.max_x() + 1., ROW.max_y() - 2.)), ZONE_ESCAPE);
    assert_eq!(zone(g, p(ROW.mid_x(), ROW.mid_y())), ZONE_ROW);
    assert_eq!(zone(g, p(g.card.mid_x(), g.card.mid_y())), ZONE_CARD);
    assert_eq!(zone(g, p(ROW.max_x() + 3., ROW.min_y() - 14.)), ZONE_GAP);
    assert_eq!(zone(g, p(-50., -50.)), ZONE_OUTSIDE);
    assert_eq!(row_alignment(1), HoverRowAlignment::Middle);
    assert_eq!(row_alignment(7), HoverRowAlignment::Top);
}

#[test]
fn hover_c_struct_layouts_match_the_header() {
    use std::mem::{align_of, size_of};
    // The C sizes of cmux_motion_ffi.h's structs (8-byte aligned, fields in header order).
    assert_eq!(size_of::<CmuxHoverTarget>(), 40);
    assert_eq!(size_of::<CmuxHoverCardMachine>(), 144);
    assert_eq!(size_of::<CmuxHoverCardEvent>(), 56);
    assert_eq!(size_of::<CmuxHoverCardEffect>(), 64);
    assert_eq!(size_of::<CmuxHoverTiming>(), 72);
    assert_eq!(size_of::<CmuxHoverIntent>(), 48);
    assert_eq!(size_of::<CmuxHoverIntentEffect>(), 32);
    assert_eq!(size_of::<HoverPoint>(), 16);
    assert_eq!(size_of::<HoverRect>(), 32);
    assert_eq!(size_of::<CmuxHoverEscapeGeometry>(), 136);
    assert_eq!(align_of::<CmuxHoverCardMachine>(), 8);
    assert_eq!(std::mem::offset_of!(CmuxHoverCardMachine, phase), 136);
    assert_eq!(std::mem::offset_of!(CmuxHoverCardEvent, kind), 48);
    assert_eq!(std::mem::offset_of!(CmuxHoverCardEffect, kind), 56);
}
