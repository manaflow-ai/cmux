use super::*;

const PLAN2: Plan = Plan { kept_slots: 2, awake_minutes_left: 600 };

fn on(id: &str, at: u64) -> Chat {
    Chat {
        id: id.into(),
        keep: KeepChoice::On { turned_on_at_ms: at },
        in_turn: false,
        last_active_ms: 0,
    }
}
fn off(id: &str) -> Chat {
    Chat { id: id.into(), keep: KeepChoice::Off, in_turn: true, last_active_ms: 99 }
}
fn unset(id: &str, in_turn: bool, last: u64) -> Chat {
    Chat { id: id.into(), keep: KeepChoice::Unset, in_turn, last_active_ms: last }
}
fn d(ds: &[(ChatId, Decision)], id: &str) -> Decision {
    ds.iter().find(|(i, _)| i == id).unwrap().1
}
const KEPT: Decision = Decision::Kept;
fn not(r: Reason) -> Decision {
    Decision::NotKept(r)
}

#[test]
fn under_limit() {
    let ds = decide(PLAN2, &[on("a", 1)], false);
    assert_eq!(d(&ds, "a"), KEPT);
    assert_eq!(summary_line(&summary(PLAN2, &ds)), "1 of 2 kept running");
}

#[test]
fn exactly_at_limit() {
    let ds = decide(PLAN2, &[on("a", 1), on("b", 2)], false);
    assert_eq!((d(&ds, "a"), d(&ds, "b")), (KEPT, KEPT));
    assert_eq!(summary_line(&summary(PLAN2, &ds)), "2 of 2 kept running");
}

#[test]
fn over_limit_explicit_order_wins() {
    let ds = decide(PLAN2, &[on("c", 30), on("a", 20), on("b", 10)], true);
    assert_eq!(d(&ds, "b"), KEPT);
    assert_eq!(d(&ds, "a"), KEPT);
    assert_eq!(d(&ds, "c"), not(Reason::OverPlan));
}

#[test]
fn off_beats_auto() {
    let ds = decide(PLAN2, &[off("a"), unset("b", true, 5)], true);
    assert_eq!(d(&ds, "a"), not(Reason::SwitchOff));
    assert_eq!(d(&ds, "b"), KEPT);
}

#[test]
fn auto_fills_by_recency_in_turn_only() {
    let chats =
        [on("a", 1), unset("old", true, 10), unset("new", true, 50), unset("idle", false, 99)];
    let ds = decide(PLAN2, &chats, true);
    assert_eq!(d(&ds, "new"), KEPT);
    assert_eq!(d(&ds, "old"), not(Reason::OverPlan));
    assert_eq!(d(&ds, "idle"), not(Reason::SwitchOff));
    // Auto off: Unset chats are never kept.
    let ds = decide(PLAN2, &chats, false);
    assert_eq!(d(&ds, "new"), not(Reason::SwitchOff));
}

#[test]
fn zero_hours_keeps_nothing() {
    let plan = Plan { kept_slots: 2, awake_minutes_left: 0 };
    let ds = decide(plan, &[on("a", 1), unset("b", true, 1), off("c")], true);
    assert_eq!(d(&ds, "a"), not(Reason::NoHoursLeft));
    assert!(ds.iter().all(|(_, x)| *x != KEPT));
    assert_eq!(preview_turn_on(plan, &[on("a", 1)], true, "z"), Preview::NoHoursLeft);
}

#[test]
fn zero_slots() {
    let plan = Plan { kept_slots: 0, awake_minutes_left: 60 };
    let ds = decide(plan, &[on("a", 1), unset("b", true, 1)], true);
    assert_eq!(d(&ds, "a"), not(Reason::OverPlan));
    assert_eq!(d(&ds, "b"), not(Reason::OverPlan));
    assert_eq!(summary_line(&summary(plan, &ds)), "0 of 0 kept running");
    assert_eq!(preview_turn_on(plan, &[], true, "a"), Preview::Full { kept: 0, of: 0 });
}

#[test]
fn preview_fits() {
    assert_eq!(preview_turn_on(PLAN2, &[on("a", 1)], true, "b"), Preview::Fits);
    // Already kept (auto) also fits.
    assert_eq!(preview_turn_on(PLAN2, &[unset("a", true, 1)], true, "a"), Preview::Fits);
}

#[test]
fn preview_takes_auto_slot() {
    let chats = [on("a", 1), unset("old", true, 10), unset("new", true, 50), unset("x", false, 0)];
    assert_eq!(
        preview_turn_on(PLAN2, &chats, true, "x"),
        Preview::TakesAutoSlot { from: "new".into() }
    );
    let chats = [unset("p", true, 10), unset("q", true, 50), unset("x", false, 0)];
    assert_eq!(
        preview_turn_on(PLAN2, &chats, true, "x"),
        Preview::TakesAutoSlot { from: "p".into() }
    );
}

#[test]
fn preview_full_never_drops_explicit() {
    let chats = [on("a", 1), on("b", 2), unset("c", true, 5)];
    assert_eq!(preview_turn_on(PLAN2, &chats, true, "c"), Preview::Full { kept: 2, of: 2 });
    // A chat that is On but over plan also gets Full.
    let chats = [on("a", 1), on("b", 2), on("c", 3)];
    assert_eq!(preview_turn_on(PLAN2, &chats, false, "c"), Preview::Full { kept: 2, of: 2 });
}

#[test]
fn deterministic_under_shuffle() {
    let chats = vec![
        on("b", 5),
        on("a", 5),
        on("z", 1),
        off("o"),
        unset("u2", true, 7),
        unset("u1", true, 7),
        unset("u3", true, 9),
        unset("n", false, 1),
    ];
    for plan in [
        PLAN2,
        Plan { kept_slots: 4, awake_minutes_left: 1 },
        Plan { kept_slots: 6, awake_minutes_left: 1 },
    ] {
        let want = decide(plan, &chats, true);
        let want_prev = preview_turn_on(plan, &chats, true, "n");
        let mut v = chats.clone();
        for rot in 0..v.len() {
            v.rotate_left(1);
            assert_eq!(decide(plan, &v, true), want, "rot {rot}");
            assert_eq!(preview_turn_on(plan, &v, true, "n"), want_prev);
        }
        v.reverse();
        assert_eq!(decide(plan, &v, true), want);
    }
    // Tie on turned-on time breaks by id.
    let ds = decide(Plan { kept_slots: 1, awake_minutes_left: 1 }, &chats[..2], false);
    assert_eq!(d(&ds, "a"), KEPT);
    assert_eq!(d(&ds, "b"), not(Reason::OverPlan));
}
