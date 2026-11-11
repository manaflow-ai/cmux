use serde_json::Value;

use super::super::contract::{Failure, Step, start_refusal_final, start_refusal_line};
use super::connection_refusal_line;

fn parsed(line: &str) -> Value {
    assert_eq!(line.matches('\n').count(), 1, "{line}");
    serde_json::from_str(line.trim()).unwrap()
}

/// A serve that cannot read this device's key (exit 5, `handshake`, before
/// the ready line) says no new serve gets past it, so the app ends its wait
/// at once instead of starting serve again until the deadline.
#[test]
fn a_handshake_refusal_before_ready_is_final() {
    let line = parsed(&start_refusal_line(
        Step::Handshake.error_code(),
        Some("the Keychain refused the carrier key (-128)"),
    ));
    assert_eq!(line["ok"], false);
    assert_eq!(line["error_code"], "handshake");
    assert_eq!(line["error_detail"], "the Keychain refused the carrier key (-128)");
    assert_eq!(line["final"], true);
    assert_eq!(line["route"], "carrier");
    assert!(start_refusal_final("handshake"));
}

/// Refusals a later start can pass (no credential yet, a socket another
/// serve still holds, a usage the caller changes) are not final, and still
/// say so.
#[test]
fn other_refusals_before_ready_are_not_final() {
    for code in [Step::Ticket.error_code(), Step::Relay.error_code(), "bad_request"] {
        let line = parsed(&start_refusal_line(code, Some("why")));
        assert_eq!(line["final"], false, "{code}");
        assert!(!start_refusal_final(code), "{code}");
    }
}

/// The same step refused for one connection of a ready serve (the daemon
/// refused this dial's handshake) is that connection's: its line carries no
/// `"final"`, so the app reads it as one that may pass next time.
#[test]
fn a_per_connection_refusal_of_a_ready_serve_is_not_final() {
    let refused = Failure::fatal(Step::Handshake, "pin mismatch");
    let line = parsed(&connection_refusal_line(&refused));
    assert_eq!(line["error_code"], "handshake");
    assert_eq!(line["error_detail"], "pin mismatch");
    assert!(line.get("final").is_none(), "{line}");
}
