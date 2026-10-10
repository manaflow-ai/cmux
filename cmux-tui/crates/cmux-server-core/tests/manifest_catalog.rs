//! Channel manifest verification and the server.* catalog.
//!
//! Keys are the RFC 8032 Ed25519 test vectors 1 and 2 (public, no value).
//! The checked-in signatures were made with OpenSSL, so these tests also
//! cross-check `ring` against a second implementation.

use cmux_server_core::manifest::{
    Applied, ManifestError, TrustedKey, Verified, VerifyContext, verify,
};
use ring::signature::{Ed25519KeyPair, KeyPair};
use sha2::Digest;

const SEED_1: &str = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60";
const PUB_1: &str = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
const PUB_2: &str = "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c";
const MANIFEST: &[u8] = include_bytes!("fixtures/manifest/manifest.json");
const SIG_1: &str = include_str!("fixtures/manifest/manifest.json.key1.sig.hex");
const SIG_2: &str = include_str!("fixtures/manifest/manifest.json.key2.sig.hex");
/// 2026-10-02T00:00:00Z
const NOW: u64 = 1_790_899_200_000;

fn hex(s: &str) -> Vec<u8> {
    let s = s.trim();
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
}

fn key(id: &str, h: &str) -> TrustedKey {
    TrustedKey { id: id.to_owned(), public_key: hex(h).try_into().unwrap() }
}

fn keys() -> Vec<TrustedKey> {
    vec![key("release-2026", PUB_1), key("release-next", PUB_2)]
}

fn signer() -> Ed25519KeyPair {
    Ed25519KeyPair::from_seed_unchecked(&hex(SEED_1)).unwrap()
}

fn vf(
    bytes: &[u8],
    sig: &[u8],
    keys: &[TrustedKey],
    now_ms: u64,
    last_applied: Option<Applied>,
    running_cmux: &str,
) -> Result<Verified, ManifestError> {
    let ctx =
        VerifyContext { keys, now_ms, expected_channel: "stable", last_applied, running_cmux };
    verify(bytes, sig, &ctx)
}

fn seen(sequence: u64) -> Option<Applied> {
    Some(Applied { sequence, sha256: sha2::Sha256::digest(MANIFEST).into() })
}

#[test]
fn test_key_matches_fixture() {
    assert_eq!(signer().public_key().as_ref(), hex(PUB_1).as_slice());
}

#[test]
fn fixture_verifies_with_current_and_next_key() {
    let v = vf(MANIFEST, &hex(SIG_1), &keys(), NOW, seen(41), "0.70.1").unwrap();
    assert_eq!(v.key_id, "release-2026");
    assert_eq!(v.manifest.sequence, 42);
    assert_eq!(v.expires_at_ms, 1_893_456_000_000);
    assert!(!v.reapply);
    assert!(!v.needs_newer_cmux);
    assert_eq!(v.manifest.packages.len(), 2);
    let pg: Vec<&str> = v.manifest.packages_for(&["postgres"]).map(|p| p.name.as_str()).collect();
    assert_eq!(pg, ["cmux", "postgresql-17"]);
    let plain: Vec<&str> = v.manifest.packages_for(&["session"]).map(|p| p.name.as_str()).collect();
    assert_eq!(plain, ["cmux"]);

    let v2 = vf(MANIFEST, &hex(SIG_2), &keys(), NOW, None, "0.70.1").unwrap();
    assert_eq!(v2.key_id, "release-next");
    // Only the current key baked: the next key's signature is refused.
    let only_current = [key("release-2026", PUB_1)];
    assert_eq!(
        vf(MANIFEST, &hex(SIG_2), &only_current, NOW, None, "0.70.1"),
        Err(ManifestError::BadSignature)
    );
}
