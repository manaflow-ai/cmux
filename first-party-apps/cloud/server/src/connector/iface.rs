//! LOCAL MIRROR of `cmux.terminal.connector/1` (host mode), as landed in
//! cmux-tui/crates/cmux-app-host/interfaces/cmux.terminal.connector/1.json:
//! `connect {kind, target, open_token} -> {channel, window_bytes}`,
//! `close {channel}`, and `end {channel, lost: {reason, retryable}}`.
//!
//! The ghostty-next lead owns the real interface and the Rust traits
//! (plans/cmux-next/ghostty-next-switch.md 3.2 to 3.4, module
//! `terminal_backend` in cmux-tui-core). The traits are not on
//! feat-cmux-next yet. The types the connector shares with
//! `cmux.terminal.backend/1` (local ids, registry ids, the typed errors,
//! `open_token`) come from the one backend mirror in
//! [`crate::rescue::iface`], so there is one copy of each rule. When the
//! real crate lands, delete both mirrors and import the real types; keep
//! the names so the swap stays mechanical.
//!
//! Differences from the real shape, on purpose:
//! - Synchronous. The Cloud server is a single-threaded op loop with no async
//!   runtime. The real traits are `async fn`; each method here maps 1:1.
//! - Events are drained with `take_events` instead of a `BoxStream`.
//! - GAP(one queue): `take_events` and the serve loop's `cloud.link.changed`
//!   drain the same supervisor queue. Today only tests call the connector;
//!   when a host-facing connector runs beside the serve loop, the
//!   supervisor must fan each event out to both.
//! - GAP(data plane): the landed channel is a viewer-protocol byte stream
//!   on the app host's stream (`data`/`credit`/`end` frames with offsets).
//!   The app host has no stream for native servers yet, so [`HostLink`] also
//!   exposes the [`Carrier`]: the link's local socket, which the daemon
//!   dials. `window_bytes` is the window the frames will start with.

use std::path::PathBuf;

pub use crate::rescue::iface::{
    BackendError, BackendId, LocalId, MAX_LOCAL_ID, OpenToken, allow_kind, check_kinds,
};

/// The interface id.
pub const CONNECTOR_INTERFACE: &str = "cmux.terminal.connector/1";

/// The first window of each direction (the interface default; 64 KiB to 1 MiB).
pub const DEFAULT_WINDOW_BYTES: u32 = 256 * 1024;

/// `connect {kind, target, open_token}`. `target` is a Cloud machine id.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectRequest {
    pub kind: String,
    pub target: String,
    /// Issued by the host for this connect; passed on, never minted here.
    pub open_token: OpenToken,
}

/// `lost {reason, retryable}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Lost {
    pub reason: String,
    /// A new `connect` may work (false: access ended).
    pub retryable: bool,
}

/// The connector's events (`events: ["end"]`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectorEvent {
    /// `end {channel, lost}`: exactly once per channel, after its last data.
    /// Nothing queues for the channel after it; reconnect is one `connect`.
    End { channel: String, lost: Lost },
}

/// The byte carrier to the far session host. Until the app host passes a
/// stream (or a socketpair fd), this is the local socket of the link
/// process (owner-only directory).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Carrier {
    /// The channel: `<kind>/<target>#<generation>`; a new one after every reconnect.
    pub id: String,
    pub target: String,
    pub generation: u64,
    pub socket: PathBuf,
}

/// The channel id of the link to `target` of `generation` (`cloud-vm/<target>#<generation>`).
pub fn channel_id(kind: &str, target: &str, generation: u64) -> String {
    format!("{kind}/{target}#{generation}")
}

/// Link supervisor events (the serve loop sends them as
/// `cloud.link.changed`; the connector maps them to `end`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CarrierEvent {
    Up {
        carrier: Carrier,
    },
    /// The link ended. `opened`: it was up, so a connect answered its
    /// channel (false: a connect that failed before the ready line).
    Down {
        target: String,
        generation: u64,
        retryable: bool,
        reason: String,
        opened: bool,
    },
    /// Access to `target` ended. `generation`: the up link (open channel)
    /// this ended, `None` when no link was up.
    Revoked {
        target: String,
        reason: String,
        generation: Option<u64>,
    },
}

/// The connect answer `{channel, window_bytes}`.
pub trait HostLink: Send {
    fn channel(&self) -> &str;
    fn window_bytes(&self) -> u32;
    /// The local carrier until the app host's stream exists (GAP above).
    fn carrier(&self) -> &Carrier;
}

/// `cmux.terminal.connector/1`: the far end runs its own session host.
pub trait TerminalConnector {
    fn id(&self) -> &BackendId;
    fn kinds(&self) -> &[LocalId];
    /// At most one channel per target: a second call while it is up returns
    /// it. A kind not in `kinds` fails with `denied`.
    fn connect(&mut self, request: ConnectRequest) -> Result<Box<dyn HostLink>, BackendError>;
    /// Ends the channel; its `end` follows. A channel that is not open is `invalid`.
    fn close(&mut self, channel: &str) -> Result<(), BackendError>;
    /// `end` events since the last call, in order.
    fn take_events(&mut self) -> Vec<ConnectorEvent>;
}
