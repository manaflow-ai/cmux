//! attach-streams-v1 (p05-ipc-074, spec/events.md "Attach streams"): a view
//! is a stream the client mints on the connection it attaches on.
//!
//! `attach-surface {stream}` names a u16 the connection does not hold open;
//! every item of that view (its READY, output, resizes, notifications and
//! `detached`) carries `"stream": id`, and `stream-end {stream, reason}` is
//! its last item. The id stays the connection's until that terminal is
//! queued and is free for a new attach once the client reads it. A view
//! request that names `stream` is checked against it, and `cancel-stream`
//! ends a stream and answers the same way whether or not it was still open.
//!
//! Chrome: the side that creates an associated interface picks its endpoint
//! id, every message names its endpoint, closing one end sends the peer a
//! closed notification after the last message, and the router forgets an
//! endpoint only once both ends closed it
//! (mojo/public/cpp/bindings/lib/multiplex_router.cc, `AssociateInterface`,
//! `UpdateEndpointStateMayRemove`; pipe_control_message_proxy.cc,
//! `NotifyPeerEndpointClosed`). Here the id table lives in the connection's
//! outbound queue state, so queuing `stream-end` and freeing the id are one
//! step under the lock that already orders the stream's items.
//!
//! Caps: a connection holds at most [`ATTACH_STREAMS_PER_CLIENT_CAPACITY`]
//! open ids and the daemon at most [`ATTACH_STREAMS_SERVER_CAPACITY`]. Past
//! either, only the open is refused (`stream_capacity`,
//! `server_stream_capacity`); the connection and its open streams are
//! unchanged. HTTP/2 does the same: a stream past
//! SETTINGS_MAX_CONCURRENT_STREAMS is a stream error, not a connection error
//! (RFC 9113 section 5.1.2; chromium net/spdy/spdy_session.cc
//! `max_concurrent_streams_`), and a pool-wide bound sits over the per-group
//! one (net/socket/client_socket_pool_manager.cc).

use super::ATTACH_STREAMS_PER_CLIENT_CAPACITY;
use super::ATTACH_STREAMS_SERVER_CAPACITY;
use super::MessageWriter;
use super::OutboundStream;
use super::capabilities::IpcCapability;
use crate::Mux;
use crate::SurfaceId;
use serde_json::Value;
use serde_json::json;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::AtomicUsize;
use std::sync::atomic::Ordering;

/// `stream` on `attach-surface` and the view requests, `stream-end`, and
/// `cancel-stream`: a framed IPC grant (server/capabilities.rs), so a
/// connection uses them only once `set-client-info` granted it.
pub(super) const ATTACH_STREAMS_CAPABILITY: &str = IpcCapability::AttachStreams.name();

/// The last item of a client-minted stream.
pub(super) const STREAM_END_EVENT: &str = "stream-end";

/// A stream id the client minted for one view on its connection.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(super) struct ClientStreamId(pub(super) u16);

/// Why a client-minted stream ended (`stream-end.reason`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum StreamEndReason {
    /// `cancel-stream`, or `detach-attached-view` of that view.
    Canceled,
    /// The surface or its output tap ended, or the view was detached.
    Detached,
    /// The stream fell behind its outbound budget; reattach to resync.
    Overflow,
    /// `attach-surface` failed after it took the id; its error reply follows.
    AttachFailed,
}

impl StreamEndReason {
    pub(super) fn as_str(self) -> &'static str {
        match self {
            Self::Canceled => "canceled",
            Self::Detached => "detached",
            Self::Overflow => "overflow",
            Self::AttachFailed => "attach_failed",
        }
    }
}

pub(super) fn stream_end_json(stream: ClientStreamId, reason: StreamEndReason) -> Value {
    json!({"event": STREAM_END_EVENT, "stream": stream.0, "reason": reason.as_str()})
}

/// A request that names a stream this connection cannot use as it asks.
/// Each displays as its wire error code.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum AttachStreamError {
    /// `attach-surface` named an id whose `stream-end` is not queued yet.
    InUse(ClientStreamId),
    /// The connection already holds `ATTACH_STREAMS_PER_CLIENT_CAPACITY`
    /// open streams.
    ConnectionCapacity,
    /// The daemon already holds `ATTACH_STREAMS_SERVER_CAPACITY` open
    /// streams across its connections.
    ServerCapacity,
    /// A view request named an id with no open stream on this connection.
    Unknown(ClientStreamId),
    /// The stream is open but views another surface.
    SurfaceMismatch { stream: ClientStreamId, surface: SurfaceId },
    /// The request also named a lease, and it is not that stream's view.
    LeaseMismatch(ClientStreamId),
    /// The request selects a view by stream, and that view has no lease
    /// (its client did not send `view-attachment-lease-v1`).
    NoLease(ClientStreamId),
    /// This connection holds no `attach-streams-v1` grant.
    NotGranted,
    /// This connection's writer keeps no stream table (an in-process sink).
    Unsupported,
}

impl AttachStreamError {
    pub(super) fn code(self) -> &'static str {
        match self {
            Self::InUse(_) => "stream_in_use",
            Self::ConnectionCapacity => "stream_capacity",
            Self::ServerCapacity => "server_stream_capacity",
            Self::Unknown(_) => "unknown_stream",
            Self::SurfaceMismatch { .. } => "stream_surface_mismatch",
            Self::LeaseMismatch(_) => "stream_lease_mismatch",
            Self::NoLease(_) => "stream_has_no_lease",
            Self::NotGranted => "streams_not_granted",
            Self::Unsupported => "streams_unsupported",
        }
    }
}

impl std::fmt::Display for AttachStreamError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.code())?;
        match self {
            Self::InUse(stream) => write!(formatter, ": stream {} is open", stream.0),
            Self::ConnectionCapacity => write!(
                formatter,
                ": this connection holds {ATTACH_STREAMS_PER_CLIENT_CAPACITY} open streams"
            ),
            Self::ServerCapacity => {
                write!(
                    formatter,
                    ": the daemon holds {ATTACH_STREAMS_SERVER_CAPACITY} open streams"
                )
            }
            Self::Unknown(stream) => write!(formatter, ": no open stream {}", stream.0),
            Self::SurfaceMismatch { stream, surface } => {
                write!(formatter, ": stream {} does not view surface {surface}", stream.0)
            }
            Self::LeaseMismatch(stream) => {
                write!(formatter, ": the lease is not stream {}'s view", stream.0)
            }
            Self::NoLease(stream) => write!(formatter, ": stream {} has no view lease", stream.0),
            Self::NotGranted => {
                write!(formatter, ": set-client-info has not granted {ATTACH_STREAMS_CAPABILITY}")
            }
            Self::Unsupported => Ok(()),
        }
    }
}

impl std::error::Error for AttachStreamError {}

/// The daemon-wide count of open client-minted streams, shared by every
/// connection's [`ClientStreams`]: one atomic, no lock.
pub(crate) struct AttachStreamAdmission {
    open: AtomicUsize,
    capacity: usize,
}

impl AttachStreamAdmission {
    pub(super) fn new(capacity: usize) -> Arc<Self> {
        Arc::new(Self { open: AtomicUsize::new(0), capacity })
    }

    /// One open stream's place under the daemon cap, held until it drops.
    pub(super) fn try_reserve(self: &Arc<Self>) -> Result<AttachStreamPermit, AttachStreamError> {
        self.open
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |open| {
                (open < self.capacity).then_some(open + 1)
            })
            .map(|_| AttachStreamPermit { admission: self.clone() })
            .map_err(|_| AttachStreamError::ServerCapacity)
    }

    #[cfg(test)]
    pub(super) fn open(&self) -> usize {
        self.open.load(Ordering::Acquire)
    }
}

/// An open client-minted stream's place under the daemon cap.
pub(super) struct AttachStreamPermit {
    admission: Arc<AttachStreamAdmission>,
}

impl Drop for AttachStreamPermit {
    fn drop(&mut self) {
        self.admission.open.fetch_sub(1, Ordering::AcqRel);
    }
}

/// The client-minted ids a connection holds, each until its stream's
/// terminal is queued. Kept in the connection's outbound queue state.
#[derive(Default)]
pub(super) struct ClientStreams {
    open: HashMap<ClientStreamId, (OutboundStream, AttachStreamPermit)>,
}

impl ClientStreams {
    /// Takes `stream`'s id. An id still open, a connection at its cap and a
    /// daemon at its cap are refused, in that order, and change nothing.
    pub(super) fn claim(
        &mut self,
        stream: &OutboundStream,
        admission: &Arc<AttachStreamAdmission>,
    ) -> Result<(), AttachStreamError> {
        let Some(id) = stream.client_stream else { return Ok(()) };
        if self.open.contains_key(&id) {
            return Err(AttachStreamError::InUse(id));
        }
        if self.open.len() >= ATTACH_STREAMS_PER_CLIENT_CAPACITY {
            return Err(AttachStreamError::ConnectionCapacity);
        }
        let permit = admission.try_reserve()?;
        self.open.insert(id, (stream.clone(), permit));
        Ok(())
    }

    /// Frees `stream`'s id and its place under the daemon cap; an id a newer
    /// stream holds stays.
    pub(super) fn release(&mut self, stream: &OutboundStream) {
        let Some(id) = stream.client_stream else { return };
        if self.open.get(&id).is_some_and(|(open, _)| open.id == stream.id) {
            self.open.remove(&id);
        }
    }

    pub(super) fn get(&self, id: ClientStreamId) -> Option<OutboundStream> {
        self.open.get(&id).map(|(stream, _)| stream.clone())
    }

    pub(super) fn clear(&mut self) {
        self.open.clear();
    }
}

/// Writes `"stream":id` as the first member of the one JSON object written
/// after it, so a tagged item is serialized once, with no copy.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) enum StreamTagSplice {
    /// Untagged, or the tag is written.
    #[default]
    Done,
    /// The object's `{` is next.
    Open(ClientStreamId),
    /// `{"stream":id` is written; a `,` goes before the next member.
    Member,
}

impl StreamTagSplice {
    pub(super) fn of(stream: Option<ClientStreamId>) -> Self {
        stream.map_or(Self::Done, Self::Open)
    }
}

/// Refuses a request that names a stream on a connection without the grant.
pub(super) fn require_grant(mux: &Mux, client: u64) -> Result<(), AttachStreamError> {
    if mux.control_clients.supports_capability(client, ATTACH_STREAMS_CAPABILITY) {
        Ok(())
    } else {
        Err(AttachStreamError::NotGranted)
    }
}

/// The view `stream` names, checked for a request on `surface`: the lease a
/// view request acts on. `stream` absent leaves `lease` as the request gave it.
pub(super) fn checked_view_lease(
    mux: &Mux,
    client: u64,
    writer: &MessageWriter,
    surface: SurfaceId,
    stream: Option<u16>,
    lease: Option<String>,
) -> Result<Option<String>, AttachStreamError> {
    let Some(stream) = stream.map(ClientStreamId) else { return Ok(lease) };
    require_grant(mux, client)?;
    let outbound = writer.client_stream(stream).ok_or(AttachStreamError::Unknown(stream))?;
    let Some(stream_lease) = mux.control_clients.stream_view(client, surface, outbound.id) else {
        return Err(AttachStreamError::SurfaceMismatch { stream, surface });
    };
    match (lease, stream_lease) {
        (Some(lease), Some(stream_lease)) if lease == stream_lease => Ok(Some(lease)),
        (Some(_), _) => Err(AttachStreamError::LeaseMismatch(stream)),
        (None, Some(stream_lease)) => Ok(Some(stream_lease)),
        (None, None) => Err(AttachStreamError::NoLease(stream)),
    }
}

/// The internal id of the open stream `stream` names on `surface`, for a
/// request that narrows to one view and needs no lease (`snapshot-request`).
pub(super) fn checked_view_stream(
    mux: &Mux,
    client: u64,
    writer: &MessageWriter,
    surface: SurfaceId,
    stream: u16,
) -> Result<u64, AttachStreamError> {
    require_grant(mux, client)?;
    let stream = ClientStreamId(stream);
    let outbound = writer.client_stream(stream).ok_or(AttachStreamError::Unknown(stream))?;
    mux.control_clients
        .stream_view(client, surface, outbound.id)
        .map(|_| outbound.id)
        .ok_or(AttachStreamError::SurfaceMismatch { stream, surface })
}

/// `cancel-stream`: ends the stream with `stream-end{canceled}` and removes
/// its view before the reply, so the reply is a cleanup fence. An id with no
/// open stream answers `ended`: the stream already ended, or never opened.
pub(super) fn cancel_stream(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    stream: u16,
) -> anyhow::Result<Value> {
    require_grant(mux, client)?;
    let stream = ClientStreamId(stream);
    let Some(outbound) = writer.client_stream(stream) else {
        return Ok(json!({"stream": stream.0, "outcome": "ended"}));
    };
    writer.end_client_stream(&outbound, StreamEndReason::Canceled);
    if let Some(surface) = mux.control_clients.stream_surface(client, outbound.id) {
        super::detach_committed_attach(mux, client, surface, outbound.id);
    }
    Ok(json!({"stream": stream.0, "outcome": "applied"}))
}

#[cfg(test)]
#[path = "attach_streams_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "attach_stream_caps_tests.rs"]
mod stream_caps;
