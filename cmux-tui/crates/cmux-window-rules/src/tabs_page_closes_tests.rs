use super::*;

fn part(pane: &str, ids: &[&str]) -> Part {
    Part { pane: pane.into(), ids: ids.iter().map(|id| id.to_string()).collect() }
}

#[test]
fn pages_that_close_join_one_send() {
    let mut closes = Closes::default();
    let id = closes
        .begin(&[part("p", &["a"])], &[part("p", &["b", "c"]), part("q", &["d"])], true)
        .unwrap();
    assert!(closes.is_waiting());
    let first = closes.absorb(&[part("p", &["b"])]);
    assert_eq!(first, Absorbed::default(), "c and d still decide");
    let last = closes.absorb(&[part("q", &["d"]), part("p", &["c"])]);
    assert!(last.rest.is_empty());
    assert_eq!(
        last.finished,
        [Finished {
            id,
            first: "p".into(),
            user_close: true,
            decided: vec![part("p", &["b", "c"]), part("q", &["d"])]
        }]
    );
    assert!(!closes.is_waiting());
}

#[test]
fn a_page_that_keeps_its_tab_does_not_hold_the_rest() {
    let mut closes = Closes::default();
    let id = closes.begin(&[part("p", &["a"])], &[part("p", &["b", "c"])], false).unwrap();
    assert!(closes.absorb(&[part("p", &["b"])]).finished.is_empty());
    let deadline = closes.finish(id).unwrap();
    assert_eq!(deadline.decided, [part("p", &["b"])], "c stayed; the rest goes at the deadline");
    assert_eq!(closes.finish(id), None);
    assert_eq!(
        closes.absorb(&[part("p", &["c"])]).rest,
        [part("p", &["c"])],
        "c's later close is its own step"
    );
}

#[test]
fn a_tab_no_gesture_waits_for_closes_as_usual_and_no_part_starts_nothing() {
    let mut closes = Closes::default();
    assert_eq!(closes.begin(&[], &[], true), None);
    assert_eq!(closes.absorb(&[part("p", &["x"])]).rest, [part("p", &["x"])]);
    let older = closes.begin(&[], &[part("q", &["t"])], true).unwrap();
    let newer = closes.begin(&[], &[part("r", &["t", "u"])], true).unwrap();
    let absorbed = closes.absorb(&[part("q", &["t", "x"])]);
    assert_eq!(absorbed.rest, [part("q", &["x"])]);
    assert_eq!(absorbed.finished.iter().map(|done| done.id).collect::<Vec<_>>(), [older]);
    assert_eq!(
        absorbed.finished[0].first, "q",
        "a gesture of deciding pages only sends from its first"
    );
    assert!(closes.gestures.contains_key(&newer));
}
