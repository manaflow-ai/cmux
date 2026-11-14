use std::io::{BufRead, BufReader};
use std::os::unix::net::UnixStream;

use super::{REFUSED_BUSY_LINE, refuse_busy};

#[test]
fn a_refused_connection_reads_one_busy_line_then_end_of_stream() {
    let (server, client) = UnixStream::pair().unwrap();
    refuse_busy(Box::new(server));
    let mut reader = BufReader::new(client);
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    assert_eq!(line, REFUSED_BUSY_LINE);
    let reply: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(reply["type"], "refused");
    assert_eq!(reply["code"], "server.busy");
    line.clear();
    assert_eq!(reader.read_line(&mut line).unwrap(), 0, "the refused stream closes");
}
