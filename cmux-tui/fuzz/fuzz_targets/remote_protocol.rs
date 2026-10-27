//! The remote-session wire (`cmux-remote-protocol`): the binary `WireFrame`
//! (CMXR) every remote lane carries, the JSON RPC messages inside it, and the
//! relay control messages a relay or a peer on the far side sends. Every
//! input runs through all of them; the decoders reject what is not theirs.
//!
//! Properties, beyond "no crash, leak or hang":
//! - a frame that decodes encodes back to exactly the input bytes (the format
//!   is canonical: one byte string per frame);
//! - a JSON message that decodes serializes to JSON that decodes to the same
//!   value (no field is lost or changed by a peer that forwards it; these
//!   types hold no floats, so equality is exact);
//! - `ByteString` carries any bytes through base64 unchanged.

#![no_main]

use cmux_remote_protocol::{
    ByteString, RelayControl, RelayTicketClaims, RpcEvent, RpcRequest, RpcResponse, WireFrame,
};
use libfuzzer_sys::fuzz_target;
use serde::Serialize;
use serde::de::DeserializeOwned;

fn round_trip<T: Serialize + DeserializeOwned + PartialEq>(json: &[u8]) {
    let Ok(value) = serde_json::from_slice::<T>(json) else { return };
    let encoded = serde_json::to_vec(&value).expect("a decoded message serializes");
    let again = serde_json::from_slice::<T>(&encoded).expect("a re-encoded message decodes");
    assert!(again == value, "JSON round trip changed {}", std::any::type_name::<T>());
}

fuzz_target!(|data: &[u8]| {
    if let Ok(frame) = WireFrame::decode(data) {
        let encoded = frame.encode().expect("a decoded frame encodes");
        assert!(encoded == data, "frame re-encodes differently");
    }

    round_trip::<RpcRequest>(data);
    round_trip::<RpcResponse>(data);
    round_trip::<RpcEvent>(data);
    round_trip::<RelayControl>(data);
    round_trip::<RelayTicketClaims>(data);

    if let Ok(byte_string) = serde_json::from_slice::<ByteString>(data) {
        let _ = byte_string.decode();
    }
    let carried = ByteString::from_bytes(data).decode().expect("own base64 decodes");
    assert!(carried == data, "ByteString changed its bytes");
});
