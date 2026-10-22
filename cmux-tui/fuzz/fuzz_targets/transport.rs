//! UDP datagrams the transport reads from the network: classification, STUN
//! binding responses, relay frames and path probes.
#![no_main]

use cmux_transport::{Probe, RelayFrame, classify, stun};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let _ = classify(data);
    // The transaction id is the one the request carried; take it from the
    // datagram itself so a matching response is reachable.
    let mut transaction = [0u8; 12];
    if let Some(id) = data.get(8..20) {
        transaction.copy_from_slice(id);
    }
    let _ = stun::parse_binding_success(data, &transaction);
    let _ = stun::parse_binding_success(data, &[0u8; 12]);
    if let Ok(frame) = RelayFrame::decode(data) {
        let _ = frame.encode();
    }
    if let Ok(probe) = Probe::decode(data) {
        let _ = probe.encode();
    }
});
