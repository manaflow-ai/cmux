use super::*;

#[test]
fn buckets_are_powers_of_two_from_a_quarter_millisecond() {
    assert_eq!(bucket(0), 0);
    assert_eq!(bucket(249_999), 0);
    assert_eq!(bucket(250_000), 1);
    assert_eq!(bucket(499_999), 1);
    assert_eq!(bucket(500_000), 2);
    assert_eq!(bucket(4_095_999_999), 14);
    assert_eq!(bucket(4_096_000_000), 15);
    assert_eq!(bucket(u64::MAX), 15);
}

#[test]
fn a_connection_moves_its_accepted_count_with_its_kind() {
    let stats = Arc::new(CommandStats::default());
    let connection = ConnectionKind::default();
    connection.registered(&stats, ClientKind::Unknown);
    connection.observed(ClientKind::Terminal);
    connection.declare(ClientKind::declared("frontend"));
    // What the daemon sees later does not replace what the client said.
    connection.observed(ClientKind::Hook);
    assert_eq!(connection.get(), ClientKind::App);
    let snapshot = stats.snapshot();
    assert_eq!(snapshot.connections.len(), 1, "{snapshot:?}");
    assert_eq!(snapshot.connections[0].kind, "app");
    assert_eq!(snapshot.connections[0].accepted, 1);
}

#[test]
fn names_past_the_limit_count_in_other() {
    let stats = CommandStats::default();
    let words: Vec<&'static str> =
        (0..NAME_LIMIT + 40).map(|number| &*format!("word-{number}").leak()).collect();
    let kind = ConnectionKind::default();
    for word in &words {
        drop(stats.start(word, &kind));
    }
    // A line with no named request counts in the same row.
    drop(stats.start_line(&kind));
    let snapshot = stats.snapshot();
    assert_eq!(snapshot.names, NAME_LIMIT as u64);
    assert_eq!(snapshot.rows.len(), NAME_LIMIT + 1, "one row per name and one for the rest");
    let other = snapshot.rows.iter().find(|row| row.name == OTHER).expect("other");
    assert_eq!(other.count, 41);

    // A line with a named request does not.
    let line = stats.start_line(&kind);
    drop(stats.start(words[0], &kind));
    drop(line);
    let other_after = stats.snapshot().rows.into_iter().find(|row| row.name == OTHER);
    assert_eq!(other_after.map(|row| row.count), Some(41));
}

#[test]
fn a_request_answered_later_is_counted_once_by_the_thread_that_answers() {
    let stats = CommandStats::default();
    let kind = ConnectionKind::default();
    let name = "git.diff";
    let count = || -> u64 {
        stats.snapshot().rows.iter().filter(|row| row.name == name).map(|row| row.count).sum()
    };
    let arrived = Instant::now();
    let counted = stats.start(name, &kind);
    answered_later();
    drop(counted);
    assert_eq!(count(), 0, "the reader does not count a request another thread answers");
    stats.record_since(name, &kind, arrived);
    assert_eq!(count(), 1);
    // The thread's next request counts as usual.
    drop(stats.start(name, &kind));
    assert_eq!(count(), 2);
    // A mark with no request to take it does not reach the next request.
    answered_later();
    drop(stats.start(name, &kind));
    assert_eq!(count(), 3);
}
