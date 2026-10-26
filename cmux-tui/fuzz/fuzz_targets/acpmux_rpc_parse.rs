//! acpmux JSON-RPC lines (`rpc::Message::parse`, `from_value`): every line a
//! peer, client or agent sends the daemon goes through them.
//!
//! Invariants past "no panic": a parsed message writes a line that parses
//! again, and one write and read normalizes it (`result: null` stays, an
//! unreadable `error` becomes an internal error), so a second write and read
//! gives the same message.
#![no_main]

use acpmux::rpc::Message;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let message = match std::str::from_utf8(data) {
        Ok(line) => Message::parse(line),
        Err(_) => match serde_json::from_slice(data) {
            Ok(value) => Message::from_value(value),
            Err(_) => return,
        },
    };
    let Ok(message) = message else { return };
    let line = message.to_line();
    assert!(Message::parse(&line).is_ok(), "a written message does not parse: {line}");
    let once = Message::from_value(message.to_value()).expect("a written message reads back");
    let twice = Message::from_value(once.to_value()).expect("a normalized message reads back");
    assert_eq!(once, twice, "reading a message back is not stable");
    let _ = message.bounded_line();
});
