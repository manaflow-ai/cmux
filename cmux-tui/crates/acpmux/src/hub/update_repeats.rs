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
//! The same lists come twice more at each process start, in the answers to acpmux's own
//! `initialize`: Claude Code's raw `control_response` (its slash commands, agents and models) and
//! the ACP `initialize` response translated from it (the commands again, under `_meta.claude`).
//! Agents stop when idle and start again at the next prompt, so on a busy machine (2026-11-11) a
//! chat started about twice in 16 minutes, and these two answers were ~84 KB per start and 36% of
//! the event log's bytes (57 starts of 29 chats), every one the same lists as the start before
//! (cmuxterm-hq#9263). Nothing reads them back from the log: the chat's commands are its meta's
//! (`available_commands_update`, `permissions.rs`), and the response's other fields stay.
//!
//! Each section below is compared with the last one logged for the session, as a hash of its JSON:
//! an unchanged section is left out of the record, and a record left with nothing is not logged.
//! The session's state is not built from the log: `on_update` takes every update as the agent
//! sends it (`permissions.rs`), so the meta a client attaches with is the same.

use sha2::{Digest, Sha256};
use std::collections::HashMap;

use serde_json::Value;

/// The sections compared, by update kind: JSON pointers into the update, each compared whole.
/// Of system/init's `_meta.claude` only its lists are: its `model` and `version` stay on every
/// record, as a paged attach finds the chat's session start in its newest page
/// (`webviews/.../sessionStart.ts`; review F1 on #39147).
const SECTIONS: &[(&str, &[&str])] = &[
    ("available_commands_update", &["/availableCommands"]),
    (
        "session_info_update",
        &[
            "/_meta/claude/tools",
            "/_meta/claude/mcp_servers",
            "/_meta/claude/plugins",
            "/_meta/claude/skills",
            "/_meta/acpmux/contextBreakdown",
            "/_meta/acpmux/usageLimits",
        ],
    ),
    // Claude Code's answer to acpmux's `initialize` control request, as the log keeps its raw
    // line (`claude.control_response`).
    (
        "claude.control_response",
        &["/response/response/commands", "/response/response/agents", "/response/response/models"],
    ),
    // The ACP `initialize` response (the whole JSON-RPC message, `in` `response`).
    ("response", &["/result/_meta/claude/commands"]),
];

/// The sections a session last logged, as hashes of their JSON.
#[derive(Default)]
pub(crate) struct UpdateRepeats {
    logged: HashMap<&'static str, [u8; 32]>,
}

/// What [`UpdateRepeats::leave_out_repeats`] found: whether nothing is left to log, and the
/// sections to record as the last logged once the update is ([`UpdateRepeats::note_logged`]), so a
/// write that failed and is retried is compared with what the log holds.
#[must_use]
pub(crate) struct Repeats {
    pub(crate) nothing_left: bool,
    changed: Vec<(&'static str, [u8; 32])>,
}

impl UpdateRepeats {
    /// Leaves out of `update` (a `session/update`'s `update` of `kind`) each section the session
    /// last logged the same.
    pub(crate) fn leave_out_repeats(&self, kind: &str, update: &mut Value) -> Repeats {
        let mut found = Repeats { nothing_left: false, changed: Vec::new() };
        let Some((_, sections)) = SECTIONS.iter().find(|(k, _)| *k == kind) else { return found };
        let mut left_out = false;
        for &pointer in *sections {
            let Some(section) = update.pointer(pointer) else { continue };
            let hash: [u8; 32] =
                Sha256::digest(serde_json::to_vec(section).unwrap_or_default()).into();
            if self.logged.get(pointer) == Some(&hash) {
                remove(update, pointer);
                left_out = true;
            } else {
                found.changed.push((pointer, hash));
            }
        }
        found.nothing_left = left_out && is_empty(update);
        found
    }

    /// The update [`Self::leave_out_repeats`] trimmed is in the log: its sections are the last
    /// logged.
    pub(crate) fn note_logged(&mut self, repeats: Repeats) {
        self.logged.extend(repeats.changed);
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
