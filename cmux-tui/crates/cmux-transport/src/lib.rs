//! Pure core of the cmux overlay transport (plans/cmux-next/transport.md).
//!
//! Every remote link in cmux-next is one end-to-end WireGuard session between
//! two endpoints. The session's datagrams travel on interchangeable paths:
//! direct UDP (LAN, IPv6, a punched IPv4 mapping), the team VPC through the
//! device's Freestyle tunnel, or a binary WebSocket through the host's
//! Durable Object relay. This crate holds the parts of that design that need
//! no I/O, so they can be tested exhaustively and shared with other
//! implementations through golden vectors:
//!
//! - [`classify`]: tells WireGuard, STUN and anything else apart on the one
//!   UDP socket an endpoint owns.
//! - [`stun`]: RFC 5389 binding requests and responses, for the reflexive
//!   address candidate.
//! - [`relay_frame`]: the binary frame the Durable Object relay forwards.
//! - [`probe`]: path probes carried inside the WireGuard session.
//! - [`selector`]: which path the next datagram takes, with hysteresis.
//!
//! The I/O engine (sockets, boringtun sessions, the relay WebSocket) lives in
//! the endpoint and drives these types.

pub mod classify;
pub mod path;
pub mod probe;
pub mod relay_frame;
pub mod selector;
pub mod stun;

pub use classify::{DatagramClass, classify};
pub use path::{PathClass, PathId, PathKind};
pub use probe::{Probe, ProbeError, ProbeKind};
pub use relay_frame::{FrameKind, PeerId, RelayFrame, RelayFrameError};
pub use selector::{
    PathState, PathView, ProbeOutcome, Selector, SelectorConfig, SelectorError, Switch,
};
