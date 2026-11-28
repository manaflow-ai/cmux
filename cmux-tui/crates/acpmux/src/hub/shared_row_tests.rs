//! `HubEvent::row` (`SharedRow`): watchers sending one record share its row, and the event ring
//! keeps none once they sent it (cmuxterm-hq#14649).

use super::*;

#[test]
fn watchers_share_a_row_while_one_sends_it() {
    let row = SharedRow::default();
    let mut builds = 0;
    let first = row.get_or_build(|| {
        builds += 1;
        Some(serde_json::json!({"sessionId": "a"}))
    });
    let second = row.get_or_build(|| {
        builds += 1;
        Some(serde_json::json!({"sessionId": "b"}))
    });
    assert_eq!(builds, 1);
    assert!(Arc::ptr_eq(first.as_ref().unwrap(), second.as_ref().unwrap()));
}

#[test]
fn the_ring_keeps_no_row_after_its_watchers_sent_it() {
    let event = row_log::row_event("a");
    let [_, full, _] = &event.row.cells;
    let sent = full.get_or_build(|| Some(serde_json::json!({"spans": vec![0u64; 512]}))).unwrap();
    let held = Arc::downgrade(&sent);
    drop(sent);
    // The ring's copy of the event (`event`) still lives; the row it was sent with does not.
    assert!(held.upgrade().is_none());
    let again = full.get_or_build(|| Some(serde_json::json!({"sessionId": "a"}))).unwrap();
    assert_eq!(*again, serde_json::json!({"sessionId": "a"}));
}

#[test]
fn a_gone_session_builds_no_row() {
    let row = SharedRow::default();
    assert!(row.get_or_build(|| None).is_none());
    assert!(row.get_or_build(|| Some(Value::Null)).is_some());
}

/// N connections sending one event build its row once, though each lets go of it before the next
/// takes it (the fan-out tasks run one after another): the build the sample showed N times.
#[test]
fn n_receivers_trigger_one_build_and_the_last_to_take_it_frees_it() {
    const N: usize = 45;
    let event = row_log::row_event("a");
    event.row.fanout.arm(N);
    let builds = std::cell::Cell::new(0);
    let peer_builds = std::cell::Cell::new(0);
    let mut seen = None;
    let mut seen_peer = None;
    for taker in 0..N {
        let owed = event.row.fanout.owed();
        let row = event.row.cells[1]
            .get_or_build_for(owed, || {
                builds.set(builds.get() + 1);
                Some(serde_json::json!({"spans": vec![0u64; 512]}))
            })
            .unwrap();
        let peer = event
            .row
            .peer_cell(true, false)
            .get_or_build_for(owed, || {
                peer_builds.set(peer_builds.get() + 1);
                Some(serde_json::json!({"sessionId": "p"}))
            })
            .unwrap();
        seen.get_or_insert_with(|| Arc::downgrade(&row));
        seen_peer.get_or_insert_with(|| Arc::downgrade(&peer));
        drop((row, peer));
        let last = event.row.fanout.taken();
        assert_eq!(last, taker == N - 1);
        if last {
            assert!(seen.as_ref().unwrap().upgrade().is_some(), "held up to the last take");
            event.row.release();
        }
    }
    assert_eq!((builds.get(), peer_builds.get()), (1, 1), "one build for {N} receivers");
    assert!(seen.unwrap().upgrade().is_none(), "the last receiver's take freed the row");
    assert!(seen_peer.unwrap().upgrade().is_none());
}

/// The hold is bounded: an event owed to one connection holds nothing, and however many events
/// are owed to two, no more than `MAX_HELD_ROWS` rows are held (cmuxterm-hq#14649). Counted by
/// the rows still alive, the counter being shared with the tests running beside this one.
#[test]
fn held_rows_are_bounded_and_dropped_with_their_event() {
    let single = row_log::row_event("one");
    single.row.fanout.arm(1);
    let row =
        single.row.cells[1].get_or_build_for(1, || Some(serde_json::json!({"a": 1}))).unwrap();
    let weak = Arc::downgrade(&row);
    drop(row);
    assert!(weak.upgrade().is_none(), "a row owed to one connection is not held");

    let events: Vec<_> = (0..MAX_HELD_ROWS + 50)
        .map(|n| {
            let event = row_log::row_event(&format!("s{n}"));
            event.row.fanout.arm(2);
            event
        })
        .collect();
    let weaks: Vec<_> = events
        .iter()
        .map(|event| {
            let row = event.row.cells[1]
                .get_or_build_for(2, || Some(serde_json::json!({"spans": vec![0u64; 512]})))
                .unwrap();
            Arc::downgrade(&row)
        })
        .collect();
    let alive = weaks.iter().filter(|w| w.upgrade().is_some()).count();
    assert!(alive <= MAX_HELD_ROWS, "{alive} rows held, bound {MAX_HELD_ROWS}");
    assert!(held_rows() <= MAX_HELD_ROWS);
    // Each event, dropped from the ring with receivers still owing, lets its row go.
    drop(events);
    assert!(weaks.iter().all(|w| w.upgrade().is_none()), "a dropped event kept a row");
}
