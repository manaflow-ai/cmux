//! Device request signatures, relay tickets and relay frames.

use cmux_weft::keys::SigningKey;
use cmux_weft::relay_frame;
use cmux_weft::signing::{SignError, Verifier, sign_request};
use cmux_weft::ticket::{self, TicketError};

const NOW: u64 = 1_800_000_000_000;

#[test]
fn a_signed_request_verifies_once() {
    let key = SigningKey::generate();
    let mut verifier = Verifier::new();
    let headers = sign_request(&key, "n1", "GET", "/v1/netmap?since=3", b"", NOW);
    verifier.verify(&key.public(), &headers, "GET", "/v1/netmap?since=3", b"", NOW + 10).unwrap();
    // The same nonce again is a replay.
    let error =
        verifier.verify(&key.public(), &headers, "GET", "/v1/netmap?since=3", b"", NOW + 20);
    assert_eq!(error, Err(SignError::Replay));
}

#[test]
fn every_signed_field_is_bound() {
    let key = SigningKey::generate();
    let other = SigningKey::generate();
    let headers = sign_request(&key, "n1", "POST", "/v1/rotate", b"{\"a\":1}", NOW);
    let mut verifier = Verifier::new();
    let bad = [
        verifier.verify(&other.public(), &headers, "POST", "/v1/rotate", b"{\"a\":1}", NOW),
        verifier.verify(&key.public(), &headers, "GET", "/v1/rotate", b"{\"a\":1}", NOW),
        verifier.verify(&key.public(), &headers, "POST", "/v1/endpoints", b"{\"a\":1}", NOW),
        verifier.verify(&key.public(), &headers, "POST", "/v1/rotate", b"{\"a\":2}", NOW),
    ];
    for result in bad {
        assert_eq!(result, Err(SignError::BadSignature));
    }
    let mut tampered = headers.clone();
    tampered.node = "n2".into();
    assert_eq!(
        verifier.verify(&key.public(), &tampered, "POST", "/v1/rotate", b"{\"a\":1}", NOW),
        Err(SignError::BadSignature)
    );
    // None of the failures burned the nonce: the genuine request still works.
    verifier.verify(&key.public(), &headers, "POST", "/v1/rotate", b"{\"a\":1}", NOW).unwrap();
}

#[test]
fn stale_and_future_timestamps_are_refused() {
    let key = SigningKey::generate();
    let mut verifier = Verifier::new();
    let old = sign_request(&key, "n1", "GET", "/x", b"", NOW - 61_000);
    assert_eq!(verifier.verify(&key.public(), &old, "GET", "/x", b"", NOW), Err(SignError::Clock));
    let future = sign_request(&key, "n1", "GET", "/x", b"", NOW + 61_000);
    assert_eq!(
        verifier.verify(&key.public(), &future, "GET", "/x", b"", NOW),
        Err(SignError::Clock)
    );
}

#[test]
fn a_ticket_names_its_tailnet_and_node_key_and_expires() {
    let authority = SigningKey::generate();
    let node_key = [7u8; 32];
    let text = ticket::issue(&authority, "acme", &node_key, NOW + 600_000);
    let parsed = ticket::verify(&authority.public(), &text, NOW).unwrap();
    assert_eq!(parsed.tailnet, "acme");
    assert_eq!(parsed.node_key, node_key);
    assert_eq!(parsed.expires_ms, NOW + 600_000);
    assert_eq!(
        ticket::verify(&authority.public(), &text, NOW + 600_001),
        Err(TicketError::Expired)
    );
    let forger = SigningKey::generate();
    assert_eq!(ticket::verify(&forger.public(), &text, NOW), Err(TicketError::BadSignature));
    // Changing one character of the payload breaks the signature.
    let mut bytes = text.into_bytes();
    bytes[3] = if bytes[3] == b'A' { b'B' } else { b'A' };
    let tampered = String::from_utf8(bytes).unwrap();
    assert!(ticket::verify(&authority.public(), &tampered, NOW).is_err());
}

#[test]
fn relay_frames_round_trip_and_reject_bad_sizes() {
    let key = [9u8; 32];
    let frame = relay_frame::encode(&key, b"datagram");
    let (peer, payload) = relay_frame::decode(&frame).unwrap();
    assert_eq!(peer, key);
    assert_eq!(payload, b"datagram");
    assert!(relay_frame::decode(&[0u8; 32]).is_none(), "an empty datagram is refused");
    assert!(relay_frame::decode(&[0u8; 31]).is_none());
    assert!(relay_frame::decode(&vec![0u8; 32 + relay_frame::MAX_DATAGRAM + 1]).is_none());
}
