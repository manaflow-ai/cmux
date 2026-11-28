//! The wire of a chat whose acpmux runs on another machine, as a sans-I/O state machine.
//!
//! The agent page speaks acpmux JSON-RPC. For a chat on another machine the app answers it with
//! typed calls on the owning session daemon (`agent-session-attach-v1` and its siblings). This
//! crate owns that translation: [`wire::Wire::frame`] takes one page frame, [`wire::Wire::event`]
//! one daemon push and [`wire::Wire::done`] the answer of one call, and each returns the
//! [`wire::Effect`]s the app runs in order (emit a frame to the page, call a daemon verb, ask the
//! app's own closures, note a link, close). Its C ABI ([`ffi`], `include/cmux_acpmux_remote_wire.h`,
//! Swift module `CCmuxAcpmuxRemoteWireFFI`) is linked through cmux-app-ffi.

pub mod ffi;
pub mod parse;
pub mod wire;
