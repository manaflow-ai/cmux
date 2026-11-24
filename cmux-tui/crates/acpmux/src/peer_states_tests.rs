use super::*;
use MachineLink::*;

fn seen(link: MachineLink) -> Observed {
    Observed::new(link, Some(1), None)
}

fn drain(rx: &mut broadcast::Receiver<Value>) -> Vec<(String, MachineLink, Option<String>)> {
    let mut out = Vec::new();
    while let Ok(v) = rx.try_recv() {
        let n: PeerStateChanged = serde_json::from_value(v[STATE_NOTE].clone()).unwrap();
        assert_eq!(n.state, n.link.folded(), "state is link folded");
        out.push((n.peer, n.link, n.error));
    }
    out
}

/// A replaced instance never speaks after its replacement, a replacement in the same state
/// sends no repeat, and a change of the replacement goes out.
#[test]
fn a_replacement_speaks_alone_and_repeats_nothing() {
    let states = PeerStates::default();
    let mut rx = states.subscribe();
    states.register("b", 1, seen(Connecting));
    states.changed("b", 1, seen(Reconnecting));
    // Reconnect: a new instance, still reconnecting.
    states.register("b", 2, seen(Reconnecting));
    // The old one's late change is dropped.
    states.changed("b", 1, seen(Connected));
    states.changed("b", 2, seen(Reconnecting));
    states.changed("b", 2, seen(Connected));
    let b = |s| ("b".to_owned(), s, None);
    assert_eq!(drain(&mut rx), [b(Connecting), b(Reconnecting), b(Connected)]);
}

/// A removal sends its last note only while the removed instance still speaks: a lease that
/// ended after a new one took its name says nothing, and the removed one stays silent.
#[test]
fn a_removal_is_the_last_word_only_for_the_instance_that_speaks() {
    let states = PeerStates::default();
    let mut rx = states.subscribe();
    states.register("b", 1, seen(Connected));
    states.register("b", 2, seen(Connecting));
    states.removed("b", 1, None);
    states.removed("b", 2, Some(5));
    states.changed("b", 2, seen(Connected));
    let got = drain(&mut rx);
    assert_eq!(got.len(), 3, "{got:?}");
    assert_eq!(got[2], ("b".to_owned(), Offline, Some(REMOVED.to_owned())));
    // Added again: its first state goes out.
    states.register("b", 3, seen(Connecting));
    assert_eq!(drain(&mut rx), [("b".to_owned(), Connecting, None)]);
}

/// A watcher that fell behind gets each name's last note, a removed one's included.
#[test]
fn the_snapshot_has_every_names_last_note() {
    let states = PeerStates::default();
    states.register("a", 1, seen(Connected));
    states.register("b", 2, seen(Connected));
    states.removed("b", 2, None);
    let notes: Vec<PeerStateChanged> = states
        .snapshot()
        .into_iter()
        .map(|v| serde_json::from_value(v[STATE_NOTE].clone()).unwrap())
        .collect();
    assert_eq!(
        notes.iter().map(|n| (n.peer.as_str(), n.link)).collect::<Vec<_>>(),
        [("a", Connected), ("b", Offline)]
    );
    assert_eq!(notes[1].error.as_deref(), Some(REMOVED));
}

/// Removed names keep their last note up to `REMOVED_KEPT`, the oldest removal going first;
/// a name added again is no longer a removal.
#[test]
fn removed_names_are_kept_up_to_a_bound() {
    let states = PeerStates::default();
    for g in 0..(REMOVED_KEPT as u64 + 10) {
        let name = format!("lease-{g}");
        states.register(&name, g, seen(Connected));
        states.removed(&name, g, None);
    }
    states.register("lease-20", 1000, seen(Connecting));
    let names: Vec<String> = states
        .snapshot()
        .into_iter()
        .map(|v| v[STATE_NOTE]["peer"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(names.len(), REMOVED_KEPT, "{names:?}");
    assert!(!names.contains(&"lease-0".to_owned()), "the oldest removal went first");
    assert!(names.contains(&"lease-20".to_owned()), "added again: it runs");
    assert!(names.contains(&format!("lease-{}", REMOVED_KEPT + 9)), "the newest is kept");
}
