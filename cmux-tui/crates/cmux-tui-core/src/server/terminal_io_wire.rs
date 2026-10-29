//! The `terminal-io` family's request params, generated at build
//! time from spec/sdk-schema.json by cmux-ipc build.rs: one struct per command
//! with fields, named `<Command>Params`. server.rs appends the family's
//! `Command` variants with `cmux_ipc::server_command_enum!`.
//!
//! The arguments are the daemon's own types for the object types the family
//! names by ref (still written by hand). server_generated_terminal_io_tests.rs
//! checks that these params decode every line as the hand-written variants
//! did.

use super::cmd_terminal_io::ExpectAgent;
use super::protocol_key::ProtocolKeyInput;
use super::terminal_history::RowMarkerPoint;
use super::terminal_snapshot::SnapshotHave;

cmux_ipc::terminal_io_params! {
    RowMarkerPoint = RowMarkerPoint,
    SendExpectAgent = ExpectAgent,
    SnapshotRequestHave = SnapshotHave,
    TerminalKeyInput = ProtocolKeyInput,
}

/// A schema `uint64` where the handler counts in `usize` (sizes, offsets,
/// byte caps). Every target cmux builds for has a 64-bit `usize`, so this
/// never saturates there.
pub(super) fn wire_usize(value: u64) -> usize {
    usize::try_from(value).unwrap_or(usize::MAX)
}

/// A schema `int64` where the handler counts in `isize` (a scroll delta).
pub(super) fn wire_isize(value: i64) -> isize {
    isize::try_from(value).unwrap_or(if value < 0 { isize::MIN } else { isize::MAX })
}

#[cfg(test)]
#[path = "server_generated_terminal_io_tests.rs"]
mod server_generated_terminal_io;
