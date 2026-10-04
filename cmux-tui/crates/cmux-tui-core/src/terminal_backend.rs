//! The daemon side of `cmux.terminal.connector/1` and
//! `cmux.terminal.backend/1` (plans/cmux-next/ghostty-next-switch.md 3.3,
//! cloud-app.md layer L4).
//!
//! The shared types and traits live in `cmux-terminal-iface` (app servers
//! take that crate by path); this module re-exports them and adds what only
//! the host does:
//!
//! - [`Declaration`]: what an app's manifest `implements` for an interface
//!   (`options.kinds`, `options.openOps`); anything not declared is denied.
//! - [`LinkRegistry`]: connector links by host-assigned channel id, keyed
//!   `app:<app>/<kind>` plus target. It runs the host op
//!   `cmux.terminal.connector.open` (the open token is consumed first, then
//!   the token's op, the kind and the target are checked) and enforces the
//!   credit and offset rule on every frame an app sends for a link.
//! - [`wire`]: the JSON-lines form of frames and host op params on a native
//!   server's stdin and stdout (`bytes` base64).
//!
//! The app supervisor wires these to its servers (`apps/terminal_ops.rs`).

mod declaration;
mod links;
pub(crate) mod relay;
pub(crate) mod wire;

pub(crate) use cmux_terminal_iface::*;
pub(crate) use declaration::Declaration;
pub(crate) use links::{LinkAnswer, LinkEvent, LinkOpen, LinkRegistry, OpenTokenGate};
pub(crate) use relay::RelaySet;

#[cfg(test)]
mod tests;
