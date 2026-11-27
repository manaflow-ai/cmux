use std::path::Path;

use base64::Engine as _;
use ring::rand::SystemRandom;
use ring::signature::{Ed25519KeyPair, KeyPair as _};
use serde_json::{Value, json};

use super::*;
use crate::key_id;

const COMMIT: &str = "bfc014745f74c8822b49837a82cd90b7f23b3c47";
const TREE: &str = "df65220e9948cbe76924483c2a7ae1a98d52efbc";
const TARGET: &str = "x86_64-unknown-linux-musl";

fn key_pair() -> Ed25519KeyPair {
    let pkcs8 = Ed25519KeyPair::generate_pkcs8(&SystemRandom::new()).unwrap();
    Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).unwrap()
}

fn trust(pair: &Ed25519KeyPair) -> Vec<Key> {
    let raw: [u8; 32] = pair.public_key().as_ref().try_into().unwrap();
    vec![(key_id(&raw), raw)]
}

fn envelope(pair: &Ed25519KeyPair, payload: &Value) -> Vec<u8> {
    let bytes = serde_json::to_vec(payload).unwrap();
    let raw: [u8; 32] = pair.public_key().as_ref().try_into().unwrap();
    let b64 = base64::engine::general_purpose::STANDARD;
    serde_json::to_vec(&json!({
        "schema": 1,
        "payload": b64.encode(&bytes),
        "signatures": [{"key_id": key_id(&raw), "sig": b64.encode(pair.sign(&bytes).as_ref())}],
    }))
    .unwrap()
}

/// The phase 1 per-commit payload as CI publishes it (the live
/// `channels/linux-feat-cmux-next.json` of 2026-11-22, cut to one target).
fn payload(prefix: &str) -> Value {
    json!({
        "channel": "feat-cmux-next",
        "commit": COMMIT,
        "committed_at": 1_795_341_681_u64,
        "expires_at": 1_797_936_518_u64,
        "published_at": 1_795_344_518_u64,
        "purpose": "cmux-linux-release",
        "schema": 1,
        "targets": {(TARGET): {
            "cmux-tui": {"sha256": "0393bf56d8ce61b1f7d70d0d8bdce1642fd49fe35134895cdcff112efa014933",
                         "size": 142_076_464_u64, "url": format!("{prefix}cmux-tui-{TARGET}")},
            "cmux-tui-hook": {"sha256": "9331475e158579a41f939b1a9184e939bb359d2238796bd716b1060048ee99fc",
                              "size": 4_877_392_u64, "url": format!("{prefix}cmux-tui-hook-{TARGET}")},
        }},
        "version": "1.0.0+20261122100121.bfc014745f74",
    })
}

fn commit_prefix() -> String {
    format!("{FILES_PREFIX}{COMMIT}/")
}

fn tree_prefix() -> String {
    format!("{FILES_PREFIX}tree/{TREE}/")
}

#[test]
fn a_commits_signed_file_gives_its_binaries() {
    let pair = key_pair();
    let release =
        verify(&envelope(&pair, &payload(&commit_prefix())), &trust(&pair), Place::Commit(COMMIT))
            .unwrap();
    assert_eq!(release.commit, COMMIT);
    let binary = release.binary(TARGET, "cmux-tui").unwrap();
    assert_eq!(binary.url, format!("{}cmux-tui-{TARGET}", commit_prefix()));
    assert_eq!(binary.size, 142_076_464);
    assert!(release.binary(TARGET, "cmux-tui-hook").is_ok());
    assert!(release.binary(TARGET, "cmux-tui-acpmux").is_err(), "a file it does not list");
    assert!(release.binary("aarch64-unknown-linux-musl", "cmux-tui").is_err());
}

#[test]
fn a_file_no_trusted_key_signed_is_refused() {
    let (signer, other) = (key_pair(), key_pair());
    let body = envelope(&signer, &payload(&commit_prefix()));
    assert!(verify(&body, &trust(&other), Place::Commit(COMMIT)).is_err());
    // A payload changed after signing.
    let mut envelope_json: Value = serde_json::from_slice(&body).unwrap();
    let mut changed = payload(&commit_prefix());
    changed["targets"][TARGET]["cmux-tui"]["sha256"] = json!("a".repeat(64));
    envelope_json["payload"] = json!(
        base64::engine::general_purpose::STANDARD.encode(serde_json::to_vec(&changed).unwrap())
    );
    let tampered = serde_json::to_vec(&envelope_json).unwrap();
    assert!(verify(&tampered, &trust(&signer), Place::Commit(COMMIT)).is_err());
}

#[test]
fn another_kind_or_another_commits_file_is_refused() {
    let pair = key_pair();
    let keys = trust(&pair);
    let mut machine = payload(&commit_prefix());
    machine["purpose"] = json!("cmux-cloud-machine-update");
    assert!(verify(&envelope(&pair, &machine), &keys, Place::Commit(COMMIT)).is_err());
    let mut web = payload(&commit_prefix());
    web.as_object_mut().unwrap().remove("purpose");
    assert!(verify(&envelope(&pair, &web), &keys, Place::Commit(COMMIT)).is_err());
    // Another build's genuine file served at this commit's path.
    let other = "1".repeat(40);
    assert!(
        verify(&envelope(&pair, &payload(&commit_prefix())), &keys, Place::Commit(&other)).is_err()
    );
    // A commit's file is not a tree's.
    assert!(
        verify(&envelope(&pair, &payload(&commit_prefix())), &keys, Place::Tree(TREE)).is_err()
    );
}

#[test]
fn a_url_off_the_files_own_prefix_is_refused() {
    let pair = key_pair();
    let keys = trust(&pair);
    for url in [
        format!("https://evil.example/cmux-tui/{COMMIT}/cmux-tui-{TARGET}"),
        format!("{FILES_PREFIX}{}/cmux-tui-{TARGET}", "2".repeat(40)),
        format!("{FILES_PREFIX}{COMMIT}/machine/cmux-tui-{TARGET}"),
        format!("{FILES_PREFIX}{COMMIT}/cmux-tui-hook-{TARGET}"),
        format!("{FILES_PREFIX}tree/{TREE}/cmux-tui-{TARGET}"),
    ] {
        let mut p = payload(&commit_prefix());
        p["targets"][TARGET]["cmux-tui"]["url"] = json!(url);
        let release = verify(&envelope(&pair, &p), &keys, Place::Commit(COMMIT)).unwrap();
        assert!(release.binary(TARGET, "cmux-tui").is_err(), "{url}");
    }
    for (field, value) in
        [("sha256", json!("ABC")), ("size", json!(0)), ("size", json!(MAX_FILE_BYTES + 1))]
    {
        let mut p = payload(&commit_prefix());
        p["targets"][TARGET]["cmux-tui"][field] = value;
        let release = verify(&envelope(&pair, &p), &keys, Place::Commit(COMMIT)).unwrap();
        assert!(release.binary(TARGET, "cmux-tui").is_err(), "{field}");
    }
}

/// Phase 1b: a commit that shares a tree has a signed alias whose URLs are under the tree, and
/// the tree's own file names the tree.
#[test]
fn a_tree_alias_and_a_trees_file_point_under_the_tree() {
    let pair = key_pair();
    let keys = trust(&pair);
    let mut alias = payload(&tree_prefix());
    alias["tree_key"] = json!(TREE);
    let release = verify(&envelope(&pair, &alias), &keys, Place::Commit(COMMIT)).unwrap();
    assert_eq!(release.tree_key.as_deref(), Some(TREE));
    assert!(release.binary(TARGET, "cmux-tui").is_ok());
    let tree = verify(&envelope(&pair, &alias), &keys, Place::Tree(TREE)).unwrap();
    assert!(tree.binary(TARGET, "cmux-tui").is_ok());
    assert!(verify(&envelope(&pair, &alias), &keys, Place::Tree(&"e".repeat(40))).is_err());
    // An alias that names a tree may not point at the commit's own prefix.
    let mut mixed = payload(&commit_prefix());
    mixed["tree_key"] = json!(TREE);
    let release = verify(&envelope(&pair, &mixed), &keys, Place::Commit(COMMIT)).unwrap();
    assert!(release.binary(TARGET, "cmux-tui").is_err());
}

#[test]
fn keys_are_the_web_update_keys() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(
        "../../../Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json",
    );
    // A sparse checkout without the app sources has nothing to compare.
    let Ok(text) = std::fs::read_to_string(&path) else { return };
    let mut web = crate::keys_from_json(&text);
    let mut ours = trusted_keys();
    web.sort();
    ours.sort();
    assert_eq!(ours, web, "linux_release::KEYS must equal web-update-keys.json");
    assert_eq!(ours.len(), KEYS.len(), "every KEYS entry decodes");
}
