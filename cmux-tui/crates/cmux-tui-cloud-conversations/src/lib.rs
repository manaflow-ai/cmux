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

mod attachments;
mod contract;
mod environments;
mod error;
mod host_replica;
pub mod platform;
mod service;
mod session;
mod stream;

/// How a stream asks again for a snapshot that did not decode
/// ([`ServiceOptions::snapshot_backoff`]).
pub use cmux_cloud_wire::SnapshotBackoff;
pub use contract::{
    CLOUD_INBOX_OP_KINDS, CLOUD_OP_KINDS, InboxOpRequest, OpRequest, Target, valid_conversation_id,
};
pub use error::CloudError;
pub use host_replica::{
    CLOUD_HOST_REPLICA_CAPABILITY, HostOpRefusal, HostReplica, HostReplicaOptions,
    HostReplicaParams, HostSource, valid_host_id,
};
pub use service::{
    CloudBackend, CloudConversations, CloudWire, ConnectError, EventSink, HttpReply,
    INBOX_ALL_BUDGET, MAX_INBOX_PAGES, PutBody, RangeReply, RequestPermit, ServiceOptions,
    TransportError, WireRecv,
};
pub use session::SessionParams;
pub use stream::CloudEvent;

/// The capability `identify` advertises when a cloud backend is installed.
pub const CLOUD_CONVERSATIONS_CAPABILITY: &str = "cloud-conversations-v1";

/// Advertised with `cloud-conversations-v1`: attachments of cloud
/// conversations through the daemon (`cloud-attachment-upload`,
/// `cloud-attachment-read`, `cloud-attachment-link`).
pub const CLOUD_ATTACHMENTS_CAPABILITY: &str = "cloud-attachments-v1";

/// Advertised with `cloud-conversations-v1`: a self-hosted chat server on
/// the tailnet (plans/cmux-next/dm-group-chat-DESIGN.md 4.5):
/// `cloud-session-set` with `auth: "tailscale"` (no token, tailnet origins
/// only, no Authorization header) and `cloud-selfhost-info`.
pub const CLOUD_SELFHOST_CAPABILITY: &str = "cloud-selfhost-v1";

#[cfg(feature = "test-support")]
pub mod testing;
