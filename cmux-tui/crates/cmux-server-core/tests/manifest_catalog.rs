//! Channel manifest verification and the server.* catalog.
//!
//! Keys are the RFC 8032 Ed25519 test vectors 1 and 2 (public, no value).
//! The checked-in signatures were made with OpenSSL, so these tests also
//! cross-check `ring` against a second implementation.

use std::collections::BTreeSet;

use cmux_server_core::catalog::{Mcp, Owner, Risk, SERVER_OPS, find};
use cmux_server_core::layout::{LayoutEnv, layout};
use cmux_server_core::manifest::{
    Applied, SemVer, VerifyContext, Verified,
    ChannelManifest, ManifestError, TrustedKey, parse_rfc3339_utc_ms, parse_version, store_path,
    verify,
};
use cmux_server_core::{InstallMode, Platform};
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

fn signed(m: &ChannelManifest) -> (Vec<u8>, Vec<u8>) {
    let bytes = serde_json::to_vec(m).unwrap();
    let sig = signer().sign(&bytes).as_ref().to_vec();
    (bytes, sig)
}

fn base() -> ChannelManifest {
    serde_json::from_slice(MANIFEST).unwrap()
}

fn vf(
    bytes: &[u8],
    sig: &[u8],
    keys: &[TrustedKey],
    now_ms: u64,
    last_applied: Option<Applied>,
    running_cmux: &str,
) -> Result<Verified, ManifestError> {
    let ctx = VerifyContext { keys, now_ms, expected_channel: "stable", last_applied, running_cmux };
    verify(bytes, sig, &ctx)
}

fn seen(sequence: u64) -> Option<Applied> {
    Some(Applied { sequence, sha256: sha2::Sha256::digest(MANIFEST).into() })
}

#[test]
fn channel_and_reused_sequence_are_refused() {
    let ctx = VerifyContext {
        keys: &keys(),
        now_ms: NOW,
        expected_channel: "beta",
        last_applied: None,
        running_cmux: "1.0.0",
    };
    assert_eq!(
        verify(MANIFEST, &hex(SIG_1), &ctx),
        Err(ManifestError::ChannelMismatch { expected: "beta".into(), got: "stable".into() })
    );
    // Same sequence, same bytes: an idempotent re-apply.
    let same = vf(MANIFEST, &hex(SIG_1), &keys(), NOW, seen(42), "1.0.0").unwrap();
    assert!(same.reapply);
    assert_eq!(same.applied(), seen(42).unwrap());
    // Same sequence, other bytes (validly signed): refused.
    let mut m = base();
    m.packages[0].version = "0.70.2".into();
    let (bytes, sig) = signed(&m);
    assert_eq!(
        vf(&bytes, &sig, &keys(), NOW, seen(42), "1.0.0"),
        Err(ManifestError::SequenceReused { sequence: 42 })
    );
}

#[test]
fn running_prerelease_versions_use_semver_precedence() {
    let needs = |running: &str| vf(MANIFEST, &hex(SIG_1), &keys(), NOW, None, running).map(|v| v.needs_newer_cmux);
    // min_cmux_version is 0.70.0.
    assert_eq!(needs("0.70.0-nightly.20261002"), Ok(true), "a prerelease sorts before its release");
    assert_eq!(needs("0.70.0"), Ok(false));
    assert_eq!(needs("0.70.0+build.7"), Ok(false));
    assert_eq!(needs("0.70.1-rc.1"), Ok(false));
    assert_eq!(needs("0.69.9-rc.1+x"), Ok(true));
    for bad in ["0.70.0-", "0.70.0-01", "0.70.0-a..b", "0.70.0+", "v0.70.0", "0.70.0-é"] {
        assert!(matches!(needs(bad), Err(ManifestError::Invalid(_))), "{bad}");
    }
    let order = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"];
    for pair in order.windows(2) {
        assert!(SemVer::parse(pair[0]).unwrap() < SemVer::parse(pair[1]).unwrap(), "{pair:?}");
    }
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

#[test]
fn tampered_bytes_or_signature_are_refused() {
    let mut bytes = MANIFEST.to_vec();
    let pos = bytes.iter().position(|b| *b == b'2').unwrap();
    bytes[pos] = b'3';
    assert_eq!(
        vf(&bytes, &hex(SIG_1), &keys(), NOW, None, "1.0.0"),
        Err(ManifestError::BadSignature)
    );
    let mut sig = hex(SIG_1);
    sig[10] ^= 0x40;
    assert_eq!(
        vf(MANIFEST, &sig, &keys(), NOW, None, "1.0.0"),
        Err(ManifestError::BadSignature)
    );
    assert_eq!(
        vf(MANIFEST, &sig[..63], &keys(), NOW, None, "1.0.0"),
        Err(ManifestError::BadSignature)
    );
    assert_eq!(
        vf(MANIFEST, &hex(SIG_1), &[], NOW, None, "1.0.0"),
        Err(ManifestError::BadSignature)
    );
    // Trailing whitespace changes the bytes: the signature covers them exactly.
    let mut spaced = MANIFEST.to_vec();
    spaced.push(b' ');
    assert_eq!(
        vf(&spaced, &hex(SIG_1), &keys(), NOW, None, "1.0.0"),
        Err(ManifestError::BadSignature)
    );
}

#[test]
fn expiry_and_sequence_rules() {
    let expires = 1_893_456_000_000;
    assert_eq!(
        vf(MANIFEST, &hex(SIG_1), &keys(), expires, None, "1.0.0"),
        Err(ManifestError::Expired { expires_at_ms: expires, now_ms: expires })
    );
    assert!(vf(MANIFEST, &hex(SIG_1), &keys(), expires - 1, None, "1.0.0").is_ok());
    assert_eq!(
        vf(MANIFEST, &hex(SIG_1), &keys(), NOW, seen(43), "1.0.0"),
        Err(ManifestError::Rollback { sequence: 42, last_applied: 43 })
    );
    let same = vf(MANIFEST, &hex(SIG_1), &keys(), NOW, seen(42), "1.0.0").unwrap();
    assert!(same.reapply);
    let old_cmux = vf(MANIFEST, &hex(SIG_1), &keys(), NOW, None, "0.69.9").unwrap();
    assert!(old_cmux.needs_newer_cmux);
    assert!(matches!(
        vf(MANIFEST, &hex(SIG_1), &keys(), NOW, None, "dev"),
        Err(ManifestError::Invalid(_))
    ));
}

type Mutation = Box<dyn Fn(&mut ChannelManifest)>;

#[test]
fn signed_but_invalid_manifests_are_refused() {
    let cases: Vec<(&str, Mutation)> = vec![
        ("schema", Box::new(|m| m.schema = 2)),
        ("channel", Box::new(|m| m.channel = "Stable!".into())),
        ("expires_at", Box::new(|m| m.expires_at = "2030-01-01T00:00:00+02:00".into())),
        ("min_cmux_version", Box::new(|m| m.min_cmux_version = "1.0".into())),
        ("no packages", Box::new(|m| m.packages.clear())),
        ("package name", Box::new(|m| m.packages[0].name = "../etc".into())),
        ("url must be https", Box::new(|m| m.packages[0].url = "http://files.cmux.com/x".into())),
        ("url must be https", Box::new(|m| m.packages[0].url = "https://user@evil/x".into())),
        ("sha256", Box::new(|m| m.packages[0].sha256 = "AB".repeat(32))),
        ("size", Box::new(|m| m.packages[0].size = 0)),
        ("roles", Box::new(|m| m.packages[0].roles.clear())),
        ("duplicate package", Box::new(|m| m.packages[1].name = "cmux".into())),
    ];
    for (needle, mutate) in cases {
        let mut m = base();
        mutate(&mut m);
        let (bytes, sig) = signed(&m);
        match vf(&bytes, &sig, &keys(), NOW, None, "1.0.0") {
            Err(ManifestError::Invalid(msg)) => assert!(msg.contains(needle), "{needle}: {msg}"),
            other => panic!("{needle}: {other:?}"),
        }
    }
    let sig = signer().sign(b"{not json").as_ref().to_vec();
    assert!(matches!(
        vf(b"{not json", &sig, &keys(), NOW, None, "1.0.0"),
        Err(ManifestError::Parse(_))
    ));
}

#[test]
fn store_path_by_sha256() {
    let env = LayoutEnv { home: Some("/home/ana".into()), ..LayoutEnv::default() };
    let l = layout(InstallMode::User, Platform::Linux, &env).unwrap();
    let m = base();
    assert_eq!(
        store_path(&l, &m.packages[1]).unwrap().as_str(),
        "/home/ana/.local/share/cmux/store/aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff00112233"
    );
    let mut bad = m.packages[1].clone();
    bad.sha256 = "../../etc".into();
    assert_eq!(store_path(&l, &bad), None);
}

#[test]
fn time_and_version_parsing() {
    assert_eq!(parse_rfc3339_utc_ms("1970-01-01T00:00:00Z"), Some(0));
    assert_eq!(parse_rfc3339_utc_ms("2024-02-29T12:34:56.789Z"), Some(1_709_210_096_789));
    assert_eq!(parse_rfc3339_utc_ms("2026-10-02T00:00:00Z"), Some(NOW));
    for bad in [
        "2023-02-29T00:00:00Z",
        "2030-13-01T00:00:00Z",
        "2030-01-01 00:00:00Z",
        "2030-01-01T24:00:00Z",
        "1969-12-31T23:59:59Z",
        "2030-01-01T00:00:00.Z",
        "2030-1-01T00:00:00Z",
    ] {
        assert_eq!(parse_rfc3339_utc_ms(bad), None, "{bad}");
    }
    assert_eq!(parse_version("0.70.1"), Some((0, 70, 1)));
    assert!(parse_version("0.70.1") > parse_version("0.69.99"));
    for bad in ["0.70", "0.70.1.2", "0.70.x", "", "1..2", "+1.0.0"] {
        assert_eq!(parse_version(bad), None, "{bad}");
    }
}

#[test]
fn catalog_names_are_unique_and_consistent() {
    let names: BTreeSet<&str> = SERVER_OPS.iter().map(|o| o.name).collect();
    assert_eq!(names.len(), SERVER_OPS.len());
    assert!(SERVER_OPS.iter().all(|o| o.name.starts_with("server.")
        || o.name.starts_with("app.server.")
        || o.name == "host.revoke"));
    // server.md 13: app servers move by lease, not by start/stop/deploy.
    for gone in ["server.app.start", "server.app.stop", "server.app.deploy"] {
        assert!(find(gone).is_none(), "{gone}");
    }
    let restart = find("server.app.restart").unwrap();
    assert_eq!(restart.mcp, Mcp::OptIn);
    assert!(restart.precondition.unwrap().contains("lease"));
    for name in ["server.app.restore", "app.server.place", "app.server.move"] {
        assert_eq!(find(name).unwrap().mcp, Mcp::Never, "{name}");
    }
    assert_eq!(find("app.server.move").unwrap().owner, Owner::TeamDo);
    let clis: Vec<&str> = SERVER_OPS.iter().filter_map(|o| o.cli).collect();
    assert_eq!(clis.iter().collect::<BTreeSet<_>>().len(), clis.len(), "CLI paths are unique");
    // Approve and enroll are user-origin only and never reach MCP (server.md 6.2).
    for name in ["server.pair.approve", "server.enroll_self", "server.health.fix", "host.revoke"] {
        let op = find(name).unwrap();
        assert_eq!(op.mcp, Mcp::Never, "{name}");
        assert!(op.user_origin_only, "{name}");
    }
    assert!(
        SERVER_OPS.iter().filter(|o| o.risk == Risk::Destructive).all(|o| o.mcp != Mcp::Default)
    );
    assert_eq!(find("server.status").unwrap().mcp, Mcp::Default);
    assert!(find("server.nope").is_none());
}
