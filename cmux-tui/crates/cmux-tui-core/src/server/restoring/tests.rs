use std::io::{BufRead as _, BufReader};
use std::os::unix::net::UnixStream;

use super::{MAX_PARKED_CONNECTIONS, SessionSlot};
use crate::server::listen::REFUSED_BUSY_LINE;

/// A connection closed because the park is full gets the busy line, so a
/// client that already wrote its request knows the daemon refused it and
/// retries it, instead of taking the close for a request the daemon took
/// and never answered (the hook counts those as undeliverable).
#[test]
fn a_connection_evicted_from_a_full_park_reads_the_busy_line() {
    let slot = SessionSlot::restoring();
    let mut clients = Vec::new();
    for _ in 0..=MAX_PARKED_CONNECTIONS {
        let (server, client) = UnixStream::pair().unwrap();
        assert!(slot.route(Box::new(server)).is_none(), "restoring parks every connection");
        clients.push(client);
    }
    let mut oldest = BufReader::new(clients.remove(0));
    let mut line = String::new();
    oldest.read_line(&mut line).unwrap();
    assert_eq!(line, REFUSED_BUSY_LINE, "the evicted connection was closed with no answer");
}
