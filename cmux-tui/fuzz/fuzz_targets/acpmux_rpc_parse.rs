//! acpmux JSON-RPC lines (`rpc::Message::parse`): every line a peer, client
//! or agent sends the daemon goes through it. `parse` is `serde_json` then
//! `Message::from_value`, so every JSON value reaches `from_value` here; a
//! host's tapped message (`agent.rs`, `Entry::Tap`) is such a value too.
//!
//! Invariants past "no panic": a parsed message writes a line that parses
//! again, and one write and read normalizes it (`result: null` stays, an
//! unreadable `error` becomes an internal error), so a second write and read
//! gives the same message.
#![no_main]

use acpmux::rpc::Message;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    // serde_json rejects bytes that are not UTF-8, so such input reaches nothing.
    let Ok(line) = std::str::from_utf8(data) else { return };
    let Ok(message) = Message::parse(line) else { return };
    let line = message.to_line();
    assert!(Message::parse(&line).is_ok(), "a written message does not parse: {line}");
    let once = Message::from_value(message.to_value()).expect("a written message reads back");
    let twice = Message::from_value(once.to_value()).expect("a normalized message reads back");
    assert_eq!(once, twice, "reading a message back is not stable");
    let _ = message.bounded_line();
});
