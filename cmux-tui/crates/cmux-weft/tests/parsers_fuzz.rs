//! Property fuzzing of every parser that reads attacker-controlled input:
//! the policy (an admin's file), relay tickets and frames (any relay client),
//! and signature headers (any HTTP client). None may panic, and a valid
//! input mutated in one byte must not verify.

use cmux_weft::keys::SigningKey;
use cmux_weft::policy::Policy;
use cmux_weft::relay_frame;
use cmux_weft::signing::{SignedHeaders, Verifier};
use cmux_weft::ticket;
use proptest::prelude::*;

const NOW: u64 = 1_800_000_000_000;

proptest! {
    #![proptest_config(ProptestConfig { cases: 2000, ..ProptestConfig::default() })]

    #[test]
    fn policy_parse_never_panics(text in ".{0,400}") {
        let _ = Policy::parse(&text);
    }

    #[test]
    fn policy_parse_never_panics_on_structured_noise(
        src in proptest::collection::vec("(\\*|user:[a-z]{0,4}|group:[a-z]{0,3}|tag:[a-z]{0,3}|node:[a-z0-9]{0,4}|[:a-z*]{0,6})", 0..4),
        dst in proptest::collection::vec("[a-z:*0-9,-]{0,16}", 0..4),
    ) {
        let policy = serde_json::json!({
            "groups": {"group:a": ["user:x"]},
            "tagOwners": {"tag:t": ["group:a"]},
            "acls": [{"action": "accept", "src": src, "dst": dst}],
        });
        let _ = Policy::parse(&policy.to_string());
    }

    #[test]
    fn ticket_verify_never_panics(text in ".{0,300}") {
        let authority = SigningKey::generate();
        prop_assert!(ticket::verify(&authority.public(), &text, NOW).is_err());
    }

    #[test]
    fn a_ticket_mutated_anywhere_fails(index in 0usize..200, byte in any::<u8>()) {
        let authority = SigningKey::generate();
        let text = ticket::issue(&authority, "acme", &[3u8; 32], NOW + 1000);
        let mut bytes = text.into_bytes();
        let index = index % bytes.len();
        prop_assume!(bytes[index] != byte);
        bytes[index] = byte;
        if let Ok(mutated) = String::from_utf8(bytes) {
            prop_assert!(ticket::verify(&authority.public(), &mutated, NOW).is_err(), "{mutated}");
        }
    }

    #[test]
    fn relay_frame_decode_never_panics(bytes in proptest::collection::vec(any::<u8>(), 0..2200)) {
        if let Some((_, payload)) = relay_frame::decode(&bytes) {
            prop_assert!(!payload.is_empty() && payload.len() <= relay_frame::MAX_DATAGRAM);
        }
    }

    #[test]
    fn signature_verify_never_panics(
        node in ".{0,40}", ts in ".{0,24}", nonce in ".{0,40}", sig in ".{0,120}",
    ) {
        let key = SigningKey::generate();
        let headers = SignedHeaders { node, ts, nonce, sig };
        let mut verifier = Verifier::new();
        prop_assert!(verifier.verify(&key.public(), &headers, "GET", "/v1/netmap", b"", NOW).is_err());
    }
}
