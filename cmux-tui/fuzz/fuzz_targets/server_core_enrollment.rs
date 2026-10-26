//! Server enrollment wire (cmux-server-core `pairing::enrollment`): pushed
//! `read_frame` messages, the API's begin reply (`Begun::parse`),
//! `jwk_thumbprint`, `valid_collect_secret` and `begin_request` validation.
//!
//! Checked: a paired frame is a validated result; a parsed begin reply's
//! public progress never carries the collect secret; a thumbprint decodes to
//! fingerprint words.
//!
//! Input: one selector byte, then UTF-8 text (JSON or a secret).
#![no_main]

use cmux_server_core::pairing::enrollment::{
    Begun, MAX_FRAME_BYTES, Waited, begin_request, fingerprint_words, jwk_thumbprint, read_frame,
    valid_collect_secret,
};
use libfuzzer_sys::fuzz_target;
use serde_json::Value;

const NOW_MS: u64 = 1_800_000_000_000;

fuzz_target!(|data: &[u8]| {
    let Some((&selector, rest)) = data.split_first() else {
        return;
    };
    let Ok(text) = std::str::from_utf8(rest) else {
        return;
    };
    match selector % 4 {
        0 => match read_frame(text) {
            Ok(Some(Waited::Paired(paired))) => {
                assert!(text.len() <= MAX_FRAME_BYTES);
                assert!(paired.validate().is_ok(), "an invalid paired result was accepted");
            }
            Ok(_) => assert!(text.len() <= MAX_FRAME_BYTES),
            Err(error) => assert!(error.starts_with("pairing."), "untyped frame error {error}"),
        },
        1 => {
            let Ok(value) = serde_json::from_str::<Value>(text) else {
                return;
            };
            let expected = value["thumbprint"].as_str().unwrap_or_default().to_string();
            if let Ok(begun) = Begun::parse(&value, &expected, NOW_MS) {
                assert!(valid_collect_secret(begun.collect_secret()));
                assert!(fingerprint_words(&begun.thumbprint).is_some());
                let progress = begun.public_progress().to_string();
                assert!(
                    !progress.contains(begun.collect_secret()),
                    "public progress leaked the collect secret"
                );
                assert!(!format!("{begun:?}").contains(begun.collect_secret()));
            }
        }
        2 => {
            let Ok(jwk) = serde_json::from_str::<Value>(text) else {
                return;
            };
            if let Ok(thumbprint) = jwk_thumbprint(&jwk) {
                assert!(fingerprint_words(&thumbprint).is_some(), "a thumbprint has no words");
            }
            // The request validates every caller field before it signs.
            let wg_public = jwk["wg"].as_str().unwrap_or_default();
            let environment = jwk["env"].as_str().unwrap_or_default();
            let info = jwk["info"].clone();
            let mut signed = false;
            let request = begin_request(&jwk, wg_public, info, environment, NOW_MS, |proof| {
                signed = true;
                assert!(proof.starts_with(b"cmux-pair-begin\n"));
                Ok("signature".into())
            });
            assert_eq!(request.is_ok(), signed, "a request signed but failed, or not signed");
        }
        _ => {
            let _ = valid_collect_secret(text);
        }
    }
});
