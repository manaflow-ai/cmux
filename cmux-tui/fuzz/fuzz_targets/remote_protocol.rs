//! Remote protocol bytes from a relay or peer: wire frames and the JSON
//! bodies they carry (RPC requests, responses, events, relay control).
#![no_main]

use cmux_remote_protocol::{
    RelayControl, RelayTicketClaims, RpcEvent, RpcRequest, RpcResponse, WireFrame,
};
use libfuzzer_sys::fuzz_target;

fn bodies(bytes: &[u8]) {
    let _ = serde_json::from_slice::<RpcRequest>(bytes);
    let _ = serde_json::from_slice::<RpcResponse>(bytes);
    let _ = serde_json::from_slice::<RpcEvent>(bytes);
    let _ = serde_json::from_slice::<RelayControl>(bytes);
    if let Ok(claims) = serde_json::from_slice::<RelayTicketClaims>(bytes) {
        let _ = claims.has_valid_lifetime();
        let _ = claims.is_temporally_valid_at(1_800_000_000);
        let _ = claims.signing_payload();
    }
}

fuzz_target!(|data: &[u8]| {
    if let Ok(frame) = WireFrame::decode(data) {
        let _ = frame.encode();
        bodies(&frame.payload);
    }
    bodies(data);
});
