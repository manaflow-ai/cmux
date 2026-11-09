//! The carrier role stamp: the first line a Cloud machine's session host
//! writes on each `mux-control` stream it opens to the session daemon's unix
//! socket, before any byte of the person's own.
//!
//! A carrier stream reaches the daemon as a same-user unix connection, which
//! the daemon trusts as the machine's owner. The stamp carries the role the
//! verified carrier grant signed (`vmk`, [`crate::carrier_grant`]), so the
//! daemon holds a teammate's stream, or one whose grant names no role, to the
//! rules a signed Native role gets (`agent_host_gate`), never to the caller's
//! own `vm_kind` word.
//!
//! The stamp can only take rights away: any same-user process may connect to
//! that socket and already has the owner's rights there, so claiming `owner`
//! gives it nothing new. The daemon accepts one stamp per connection and
//! refuses a second, so the person's bytes, which follow the session host's
//! stamp, cannot replace it.
//!
//! ```json
//! {"cmd":"carrier-role","id":"carrier-role","vmk":"owner"|"team"|null}
//! ```

use serde_json::{Map, Value, json};

use crate::token::VmKind;

/// The stamp's command name.
pub const COMMAND: &str = "carrier-role";

/// The stamp's request id; its reply carries the same id.
pub const REQUEST_ID: &str = "carrier-role";

/// The longest stamp reply the session host reads. A daemon from before the
/// stamp answers it as an unknown command, and that reply lists every command
/// the daemon knows (over 6 KB), so the bound leaves room for that list to grow.
pub const MAX_REPLY_BYTES: usize = 256 * 1024;

/// The stamp for a grant that signed `vm_kind` (`None`: the grant names no
/// role), without the trailing newline.
pub fn line(vm_kind: Option<VmKind>) -> String {
    json!({"cmd": COMMAND, "id": REQUEST_ID, "vmk": vm_kind}).to_string()
}

/// The role a stamp's fields (the line without `cmd` and `id`) name: exactly
/// `vmk`, which is `"owner"`, `"team"` or `null`. Anything else is malformed.
pub fn parse(fields: &Map<String, Value>) -> Option<Option<VmKind>> {
    if fields.len() != 1 {
        return None;
    }
    match fields.get("vmk")? {
        Value::Null => Some(None),
        value => serde_json::from_value::<VmKind>(value.clone()).ok().map(Some),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fields(line: &str) -> Map<String, Value> {
        let mut object: Map<String, Value> = serde_json::from_str(line).unwrap();
        assert_eq!(object.remove("cmd"), Some(json!(COMMAND)));
        assert_eq!(object.remove("id"), Some(json!(REQUEST_ID)));
        object
    }

    #[test]
    fn each_role_round_trips() {
        for role in [Some(VmKind::Owner), Some(VmKind::Team), None] {
            assert_eq!(parse(&fields(&line(role))), Some(role), "{role:?}");
        }
    }

    #[test]
    fn anything_but_exactly_vmk_is_malformed() {
        for bad in [
            json!({}),
            json!({"vmk": "admin"}),
            json!({"vmk": 1}),
            json!({"vmk": "Owner"}),
            json!({"vmk": "owner", "extra": true}),
            json!({"role": "owner"}),
        ] {
            assert_eq!(parse(bad.as_object().unwrap()), None, "{bad}");
        }
    }
}
