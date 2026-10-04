//! The daemon proxy for cloud conversations (`cloud-conversations-v1`,
//! plans/cmux-next/home-cloud-proxy.md). The Durable Objects own every cloud
//! conversation and the inbox; the daemon only forwards typed ops with the
//! client's idempotency key and `origin`, returns the owner's result and
//! relays the owner's events to trusted local clients. It never acknowledges
//! an op itself and never queues: when the cloud is unreachable a command
//! fails at once.
//!
//! This module is transport-agnostic: [`CloudBackend`] is the HTTP and
//! WebSocket seam. The cmux-tui binary installs the real backend
//! (reqwest + tokio-tungstenite); tests install a scripted one.

mod contract;
mod error;
mod service;
mod session;
mod stream;

pub use contract::{CLOUD_OP_KINDS, OpRequest, Target, valid_conversation_id};
pub use error::CloudError;
pub use service::{
    CloudBackend, CloudConversations, CloudWire, ConnectError, EventSink, HttpReply,
    RequestPermit, ServiceOptions, TransportError, WireRecv,
};
pub use session::SessionParams;
pub use stream::CloudEvent;

/// The capability `identify` advertises when a cloud backend is installed.
pub const CLOUD_CONVERSATIONS_CAPABILITY: &str = "cloud-conversations-v1";

#[cfg(test)]
pub(crate) mod testing;
#[cfg(test)]
mod tests;
