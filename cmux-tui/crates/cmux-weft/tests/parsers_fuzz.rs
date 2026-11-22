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
use proptest::test_runner::RngSeed;
use std::hash::{BuildHasher, Hasher};

const NOW: u64 = 1_800_000_000_000;
const CASES: u32 = 2000;

/// Each test's config, from the same variables as the Swift fuzz suites'
/// `FuzzSeed`: `CMUX_FUZZ_SEED=<u64>` (decimal or `0x` hex) or `random`, and
/// `CMUX_FUZZ_ITERATIONS=<n>`, which multiplies the case count. With no seed
/// set, the run is random, as proptest's own default always was here; the seed
/// is chosen here instead, so it can be named. The line goes to the test's
/// output, which libtest shows when the test fails.
fn fuzz_config() -> ProptestConfig {
    let seed = match std::env::var("CMUX_FUZZ_SEED") {
        Err(_) => random_seed(),
        Ok(value) if value == "random" => random_seed(),
        Ok(value) => {
            let parsed = match value.strip_prefix("0x") {
                Some(hex) => u64::from_str_radix(hex, 16),
                None => value.parse(),
            };
            parsed
                .unwrap_or_else(|_| panic!("CMUX_FUZZ_SEED must be a u64 or random, got '{value}'"))
        }
    };
    let scale = match std::env::var("CMUX_FUZZ_ITERATIONS") {
        Err(_) => 1,
        Ok(value) => match value.parse::<u32>() {
            Ok(n) if n > 0 => n,
            _ => panic!("CMUX_FUZZ_ITERATIONS must be a positive whole number, got '{value}'"),
        },
    };
    eprintln!("CMUX_FUZZ_SEED={seed} CMUX_FUZZ_ITERATIONS={scale}");
    ProptestConfig {
        cases: CASES.saturating_mul(scale),
        rng_seed: RngSeed::Fixed(seed),
        ..ProptestConfig::default()
    }
}

/// A random u64 from the process's random hash keys (no extra dependency).
fn random_seed() -> u64 {
    std::collections::hash_map::RandomState::new().build_hasher().finish()
}

proptest! {
    #![proptest_config(fuzz_config())]

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
