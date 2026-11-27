//! Requests addressed to one configured peer, after the caller's admission and target checks.

use crate::peer::Peer;
use crate::rpc::RpcError;
use serde_json::Value;

pub(super) async fn request(peer: &Peer, method: &str, params: Value) -> Result<Value, RpcError> {
    peer.note_use();
    if !peer.ready() {
        super::peer_forward::await_link(peer, super::peer_demand_wait::IDLE_DIAL_WAIT).await;
    }
    peer.request(method, params).await
}

#[cfg(test)]
#[path = "peer_targeted_tests.rs"]
mod tests;
