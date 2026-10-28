//! The `tabs` family's request params (queue Q15), generated at
//! build time from spec/sdk-schema.json by cmux-ipc build.rs: one struct per
//! command, named `<Command>Params`. server.rs appends the family's `Command`
//! variants with `cmux_ipc::server_command_enum!`, the way Mojo generates an
//! interface's param structs from its mojom
//! (mojo/public/tools/bindings/generators/cpp_templates/struct_declaration.tmpl).
//!
//! The arguments are the daemon's own types for the types the family names by
//! ref. The two notification enums stay strings: their handler checks the value
//! and answers with its own error, as it did. server_generated_tabs_tests.rs
//! checks that these params decode every line as the hand-written variants did.

use super::TabRef;
use super::conversation_tabs_wire::{AgentSessionParams, ConversationTabSplitParams};
use super::split_respawn::SplitRespawnRequest;

cmux_ipc::tabs_params! {
    AgentSessionSource = AgentSessionParams,
    CloseReason = crate::mux::CloseReason,
    ColumnPin = crate::model::ColumnDock,
    ConversationTabSplit = ConversationTabSplitParams,
    JsonValue = serde_json::Value,
    NotificationLevel = String,
    NotificationSource = String,
    ResourceSelectors = crate::ResourceSelectors,
    SplitRespawn = SplitRespawnRequest,
    TabRef = TabRef,
}

/// A schema `uint64` where the handler counts in `usize` (a tab index, a
/// list limit). Every target cmux builds for has a 64-bit `usize`, so this
/// never saturates there.
pub(super) fn wire_usize(value: u64) -> usize {
    usize::try_from(value).unwrap_or(usize::MAX)
}

/// A schema `int64` where the handler counts in `isize` (a selection delta).
pub(super) fn wire_isize(value: i64) -> isize {
    isize::try_from(value).unwrap_or(if value < 0 { isize::MIN } else { isize::MAX })
}

#[cfg(test)]
#[path = "server_generated_tabs_tests.rs"]
mod server_generated_tabs;
