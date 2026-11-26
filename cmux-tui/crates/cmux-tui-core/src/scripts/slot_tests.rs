use super::*;

#[test]
fn one_connection_starts_past_the_old_cap_of_eight_until_the_daemon_limit() {
    let slot = ScriptsSlot::default();
    // The old caps were 8 REPL opens and 8 one-shot runs per connection.
    let mut held: Vec<_> = (0..12)
        .map(|n| slot.reserve(1, &format!("open-{n}"), true).map(|(_, guard)| guard))
        .chain((0..12).map(|n| slot.reserve(1, &format!("run-{n}"), false).map(|(_, g)| g)))
        .collect::<Result<_, _>>()
        .unwrap_or_else(|error| panic!("{}", error.message));
    while held.len() < MAX_SESSIONS {
        let n = held.len();
        held.push(slot.reserve(2, &format!("other-{n}"), false).expect("room").1);
    }
    let refused = slot.reserve(3, "one-more", false).err().expect("the daemon is full");
    assert_eq!(refused.code, "script.limit");
    drop(held);
    assert!(slot.reserve(3, "after", false).is_ok());
}
