//! The daemon's generated request params (p05-ipc design 3.3, task 026).
//!
//! build.rs writes, for each family `server-families.json` lists, a
//! `<family>_params!` macro that defines one Deserialize struct per command
//! of that family (fields, presence and defaults from spec/sdk-schema.json),
//! and one `server_command_enum!` macro that appends those commands to the
//! daemon's `cmd`-tagged `Command` enum. They are macros so the structs are
//! the daemon crate's own types; this crate does not depend on serde.
//!
//! For `terminal-io`, cmux-tui-core `server/terminal_io_wire.rs` expands
//! `terminal_io_params!` and server.rs wraps `enum Command` in
//! `server_command_enum!`.

include!(concat!(env!("OUT_DIR"), "/server_families.rs"));
