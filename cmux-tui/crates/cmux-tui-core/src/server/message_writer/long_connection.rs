//! The gate a connection passes before it starts work that outlives a
//! request: a stream (`MessageWriter::start_stream`), a detached wait
//! (`resource_waits::start_resource_wait`) or a log follow (`apps-logs`).
//!
//! A terminal's connection that does so stops being one of the terminals' 48
//! short connections and becomes one of at most
//! `MAX_LONG_TERMINAL_CONNECTIONS` long ones
//! (`diagnostics/long_connections.rs`), so connections that stay open for
//! hours never fill the lane that hooks and typed commands need. At the bound
//! the work is not started and its request gets an error; the connection
//! stays open.
//!
//! A connection from outside the terminals passes with no change.

use std::sync::Arc;
use std::sync::OnceLock;
use std::sync::Weak;

use serde_json::json;

use crate::diagnostics::ConnectionLease;
use crate::diagnostics::LongConnectionsFull;
use crate::resource::ResourceError;
use crate::server::bounded_outbound::ConnectionPermit;

/// The most of the terminals' connections that may hold a stream, a wait or
/// a follow at one time. They are outside `MAX_SERVER_CONNECTIONS` and
/// `MAX_TERMINAL_CONNECTIONS`; each one holds its threads and its socket
/// until it ends, so the number is the bound of both. It is the server's
/// bound of resource streams (`RESOURCE_STREAMS_SERVER_CAPACITY`).
pub(in crate::server) const MAX_LONG_TERMINAL_CONNECTIONS: u64 = 256;

impl ConnectionPermit {
    pub(in crate::server) fn lease(&self) -> &Arc<ConnectionLease> {
        &self._lease
    }
}

/// A connection's way to its lease, kept by each clone of its writer.
#[derive(Default)]
pub(in crate::server) struct LongGate {
    /// Weak: the client registry and the stream threads keep the writer, and
    /// none of them may keep the connection's place after its thread ended.
    /// Not set for a connection that holds no slot (an in-process client).
    lease: OnceLock<Weak<ConnectionLease>>,
}

impl LongGate {
    /// Binds the gate to the connection's slot, once, before its first request.
    pub(in crate::server) fn attach(&self, permit: &ConnectionPermit) {
        let _ = self.lease.set(Arc::downgrade(permit.lease()));
    }

    /// The connection is about to start work that outlives a request. `Err`:
    /// the long connections are at their bound and the caller starts nothing.
    pub(in crate::server) fn hold(&self) -> Result<(), LongConnectionsFull> {
        let Some(lease) = self.lease.get().and_then(Weak::upgrade) else { return Ok(()) };
        lease.become_long(MAX_LONG_TERMINAL_CONNECTIONS)
    }
}

/// The resource error of a request refused at the bound.
pub(in crate::server) fn long_connections_full_error(
    operation: &str,
    full: LongConnectionsFull,
) -> ResourceError {
    ResourceError::operation_failed(
        operation,
        full.to_string(),
        json!({"reason_code":"long_connection_capacity","scope":"server","limit":full.limit}),
    )
}

/// The resource error of a `MessageWriter::start_stream` that failed: the
/// bound of the long connections, else the stream could not be allocated.
pub(in crate::server) fn stream_start_error(
    operation: &str,
    error: &std::io::Error,
) -> ResourceError {
    match error.get_ref().and_then(|inner| inner.downcast_ref::<LongConnectionsFull>()) {
        Some(full) => long_connections_full_error(operation, *full),
        None => ResourceError::transport_closed("could not allocate an outbound stream"),
    }
}
