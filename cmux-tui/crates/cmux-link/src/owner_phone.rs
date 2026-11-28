//! The owner phone stamp: the first line the Cloud machine's cmux link writes
//! on the session daemon stream it opens for a phone chat
//! (`cmux-tui/src/link/phone_chat.rs`), after the PhoneChat owner check
//! (`OwnerSession::authorize`) admitted that phone and before the stream
//! declares the Cloud mobile capability.
//!
//! It names the phone (the stamp's `install`), so the daemon's Cloud mobile
//! prompts carry it to acpmux as `_meta.acpmux.ownerPhone`, and acpmux treats
//! the phone as the owner's own paired phone under D13 (RFD 0135 gate 4),
//! never with Full access (`acpmux` `remote_guard.rs`, `vouched_claim`).
//!
//! As with [`crate::carrier_role`], any same-user process may connect to that
//! socket and already has the owner's full rights there; the stamp lowers that
//! connection to a Cloud mobile one, so it gives nothing new. One stamp per
//! connection, never on a carrier stream that has a signed role.
//!
//! ```json
//! {"cmd":"owner-phone","id":"owner-phone","device":"<install id>"}
//! ```

use serde_json::{Map, Value, json};

/// The stamp's command name.
pub const COMMAND: &str = "owner-phone";

/// The stamp's request id; its reply carries the same id.
pub const REQUEST_ID: &str = "owner-phone";

/// The longest phone id a stamp carries (acpmux's bound for `ownerPhone.device`).
pub const MAX_DEVICE_BYTES: usize = 128;

/// The stamp naming `device`, without the trailing newline.
pub fn line(device: &str) -> String {
    json!({"cmd": COMMAND, "id": REQUEST_ID, "device": device}).to_string()
}

/// The phone a stamp's fields (the line without `cmd` and `id`) name: exactly
/// `device`, a non-empty string of at most [`MAX_DEVICE_BYTES`]. Anything else
/// is malformed.
pub fn parse(fields: &Map<String, Value>) -> Option<String> {
    if fields.len() != 1 {
        return None;
    }
    let device = fields.get("device")?.as_str()?;
    (!device.is_empty() && device.len() <= MAX_DEVICE_BYTES).then(|| device.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fields(line: &str) -> Map<String, Value> {
        let mut map: Map<String, Value> = serde_json::from_str(line).unwrap();
        map.remove("cmd");
        map.remove("id");
        map
    }

    #[test]
    fn a_stamp_round_trips_and_anything_else_is_malformed() {
        assert_eq!(parse(&fields(&line("install-1"))).as_deref(), Some("install-1"));
        assert_eq!(parse(&fields(&line(""))), None);
        assert_eq!(parse(&fields(&line(&"x".repeat(MAX_DEVICE_BYTES + 1)))), None);
        let mut extra = fields(&line("install-1"));
        extra.insert("fullAccess".into(), json!(true));
        assert_eq!(parse(&extra), None);
        assert_eq!(parse(&fields(r#"{"device":7}"#)), None);
    }
}
