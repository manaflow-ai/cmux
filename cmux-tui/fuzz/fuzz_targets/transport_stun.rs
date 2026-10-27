//! STUN binding success (`stun::parse_binding_success`) on the socket that
//! also carries WireGuard. The transaction id is the one in the datagram
//! when it has one, so the attribute walk is reached; whatever `classify`
//! says, the parser must not panic, and the success this side would send
//! for the parsed address parses back to it.
#![no_main]

use cmux_transport::classify::STUN_HEADER_LEN;
use cmux_transport::stun::{TransactionId, binding_success, parse_binding_success};
use cmux_transport::{DatagramClass, classify};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let class = classify(data);
    let transaction: TransactionId =
        data.get(8..STUN_HEADER_LEN).and_then(|bytes| bytes.try_into().ok()).unwrap_or_default();
    let Ok(address) = parse_binding_success(data, &transaction) else { return };
    assert_eq!(class, DatagramClass::Stun);
    let ours = binding_success(transaction, address);
    assert_eq!(classify(&ours), DatagramClass::Stun);
    assert_eq!(parse_binding_success(&ours, &transaction), Ok(address));
});
