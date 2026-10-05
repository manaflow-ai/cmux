//! The remote browser tab service, `cmux.rb/1`, a service inside one
//! `cmux.rd/1` session (plans/cmux-next/remote-tab-protocol.md).
//!
//! This crate holds the control messages and input events of a remote tab
//! and the pure reducers both ends share: the host's session state, the menu
//! token lifecycle, the scroll-offset writer handoff of the split compositor
//! and the cookie sync conflict rule. It does no I/O and reads no clock; time
//! is always an input. Shared test vectors: `schemas/remote-tab/`.

pub mod cookie;
pub mod menu;
pub mod proto;
pub mod scroll;
pub mod session;

/// Value of `hello.service` for this protocol (rd change C1).
pub const SERVICE: &str = "rb/1";
