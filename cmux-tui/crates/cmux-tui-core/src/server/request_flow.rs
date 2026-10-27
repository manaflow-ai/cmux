//! The flow of each request between a local client and the daemon
//! (p09-observability task 103), with no flow id on the wire. Chrome's Mojo
//! bindings write a flow-out where a message is sent and a flow-in where it is
//! dispatched (`mojo/public/cpp/bindings/lib/interface_endpoint_client.cc`,
//! `TRACE_EVENT_FLAG_FLOW_OUT` / `FLOW_IN`), keyed by an id both ends know.
//! Here both ends derive it from what they already have: the client hashes
//! its own pid and the request id it wrote; the daemon hashes the peer pid
//! the kernel reported at accept (the connection's peer key, from
//! `LOCAL_PEERTOKEN` on macOS and `SO_PEERCRED` on Linux) and the same id read
//! back from the line. The hash is FNV-1a 64 over the pid's 4 bytes, then the
//! id's 8, little-endian: the app's `LineTransport.requestFlow(seed:requestID:)`.
//!
//! One request is one chain of `daemon.request` flow records: the app's
//! flow-out at its send, the daemon's flow-in when the request's span opens
//! and flow-out at its reply, the app's flow-in when the reply is read
//! (`scripts/cmux-next/trace.py` `request_flow_summary`). An id that is not a
//! u64 (a JSON number, or the decimal string of a v2 envelope) has no flow,
//! and neither has a connection whose peer pid is unknown.

use serde_json::Value;

/// The per-connection start of every request flow: the FNV-1a state after the
/// peer's pid. `None` when the peer's pid is unknown (a WebSocket, a remote
/// entry, a test writer), so none of its requests has a flow.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) struct RequestFlowSeed(Option<u64>);

impl RequestFlowSeed {
    const OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
    const PRIME: u64 = 0x0000_0100_0000_01b3;

    /// The seed of a client whose process id is `pid`.
    pub(super) fn of_pid(pid: u32) -> Self {
        Self(Some(fnv1a(Self::OFFSET, u64::from(pid), 4)))
    }

    /// The seed of the peer that `key` (`token:<pid>.<version>`) names.
    pub(super) fn of_peer_key(key: Option<&str>) -> Self {
        key.and_then(super::origin_gate::peer_pid).map_or(Self::default(), Self::of_pid)
    }

    /// The flow of the request whose wire id is `id`; 0 (no flow) without a
    /// seed or a u64 id.
    pub(super) fn flow(self, id: Option<&Value>) -> u64 {
        let number = match id {
            Some(Value::Number(number)) => number.as_u64(),
            Some(Value::String(text)) => text.parse().ok(),
            _ => None,
        };
        number.map_or(0, |number| self.flow_of(number))
    }

    /// The flow of request number `id`; 0 without a seed.
    pub(super) fn flow_of(self, id: u64) -> u64 {
        self.0.map_or(0, |seed| fnv1a(seed, id, 8))
    }
}

/// FNV-1a 64 from `state` over the low `bytes` bytes of `value`, little-endian.
fn fnv1a(state: u64, value: u64, bytes: u32) -> u64 {
    (0..bytes).fold(state, |hash, index| {
        (hash ^ ((value >> (8 * index)) & 0xff)).wrapping_mul(RequestFlowSeed::PRIME)
    })
}

#[cfg(test)]
#[path = "request_flow_tests.rs"]
mod tests;
