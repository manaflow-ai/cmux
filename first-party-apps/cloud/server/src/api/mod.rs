//! Wire types, typed errors, Cloud API records and the control-plane boundary.

pub(crate) mod args;
mod call;
mod control_plane;
mod error;
pub(crate) mod events;
pub mod host;
mod ledger;
pub mod models;
mod relay;
mod serve;
mod wire;

pub(crate) use call::{Ctx, decode_answer};
pub use control_plane::{
    ControlPlane, RelayError, SessionStatus, WireCall, WireError, WireReply, WireResult,
};
pub use error::{CloudError, codes};
pub(crate) use ledger::Ledger;
pub use ledger::upstream_key;
pub use relay::{HOST_FRAME_LINES, HostRelay, RELAY_QUEUE_LINES};
pub(crate) use serve::event_line;
pub use serve::{OP_CANCELLED, serve, serve_with};
pub use wire::{Origin, Request};
