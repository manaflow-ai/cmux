//! Part of `Hub`; see `hub/mod.rs`. The agent's state updates a chat's log leaves out when they
//! repeat what it last logged.
//!
//! A harness sends its whole state again and again: Claude Code's `session_info_update` with its
//! tools, MCP servers, plugins and skills (`_meta.claude`) at every turn's system/init, the turn's
//! context breakdown (`_meta.acpmux.contextBreakdown`) after it, and an `available_commands_update`
//! with every slash command each time its process starts. Those two `session_info_update` shapes
//! alternate, so a record is never equal to the one before it, while each section is. On Leo's Mac
//! (2026-11-08) they were ~55 MB a day (2,568 records, ~21 KB each) and ~30 MB a day (415, up to
//! 730 KB each) of acpmux's log.
//!
//! Each section below is compared with the last one logged for the session, as a hash of its JSON:
//! an unchanged section is left out of the record, and a record left with nothing is not logged.
//! The session's state is not built from the log: `on_update` takes every update as the agent
//! sends it (`permissions.rs`), so the meta a client attaches with is the same.

use sha2::{Digest, Sha256};
use std::collections::HashMap;

use serde_json::Value;

/// The sections compared, by update kind: JSON pointers into the update. Each is replaced whole
/// by its reader (`_meta.claude` by `absorb_reported_tools`), so each is compared whole.
const SECTIONS: &[(&str, &[&str])] = &[
    ("available_commands_update", &["/availableCommands"]),
    (
        "session_info_update",
        &["/_meta/claude", "/_meta/acpmux/contextBreakdown", "/_meta/acpmux/usageLimits"],
    ),
];

/// The sections a session last logged, as hashes of their JSON.
#[derive(Default)]
pub(crate) struct UpdateRepeats {
    logged: HashMap<&'static str, [u8; 32]>,
}

impl UpdateRepeats {
    /// Leaves out of `update` (a `session/update`'s `update` of `kind`) each section the session
    /// last logged the same; whether nothing is left to log.
    pub(crate) fn leave_out_repeats(&mut self, kind: &str, update: &mut Value) -> bool {
        let Some((_, sections)) = SECTIONS.iter().find(|(k, _)| *k == kind) else { return false };
        let mut left_out = false;
        for &pointer in *sections {
            let Some(section) = update.pointer(pointer) else { continue };
            let hash: [u8; 32] =
                Sha256::digest(serde_json::to_vec(section).unwrap_or_default()).into();
            if self.logged.get(pointer) == Some(&hash) {
                remove(update, pointer);
                left_out = true;
            } else {
                self.logged.insert(pointer, hash);
            }
        }
        left_out && is_empty(update)
    }
}

/// Removes the value at `pointer`, and each object on its path it leaves empty.
fn remove(value: &mut Value, pointer: &str) {
    let Some((parent, key)) = pointer.rsplit_once('/') else { return };
    if let Some(object) = value.pointer_mut(parent).and_then(Value::as_object_mut) {
        object.remove(key);
        if object.is_empty() && !parent.is_empty() {
            remove(value, parent);
        }
    }
}

/// An update that says nothing but its kind (a null field, such as the `title` Claude Code's
/// system/init update carries, sets nothing).
fn is_empty(update: &Value) -> bool {
    update.as_object().is_none_or(|fields| {
        fields.iter().all(|(key, value)| key == "sessionUpdate" || value.is_null())
    })
}

#[cfg(test)]
#[path = "update_repeats_tests.rs"]
mod tests;
