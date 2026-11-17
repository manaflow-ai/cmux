//! The store tier through the catalog: a store package is `Verified` only
//! when the store key signed exactly its files.

use std::cell::RefCell;
use std::path::{Path, PathBuf};

use base64::Engine as _;
use ring::signature::{Ed25519KeyPair, KeyPair as _};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::super::catalog::{self, Sources};
use super::super::mirror::Tier;
use super::{PURPOSE, SIGNATURE_FILE};
use cmux_signed_envelope::Key;

thread_local! {
    /// The keys [`super::trusted_keys`] answers on this test thread.
    pub(crate) static TEST_KEYS: RefCell<Option<Vec<Key>>> = const { RefCell::new(None) };
}

struct TempDir(PathBuf);

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn temp_dir() -> TempDir {
    let mut bytes = [0u8; 8];
    getrandom::fill(&mut bytes).unwrap();
    let dir = std::env::temp_dir().join(format!(
        "cmux-store-trust-test-{}",
        bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    TempDir(dir)
}

fn keypair() -> (Ed25519KeyPair, Key) {
    let rng = ring::rand::SystemRandom::new();
    let pkcs8 = Ed25519KeyPair::generate_pkcs8(&rng).unwrap();
    let pair = Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).unwrap();
    let raw: [u8; 32] = pair.public_key().as_ref().try_into().unwrap();
    (pair, (cmux_signed_envelope::key_id(&raw), raw))
}

fn trust(keys: Vec<Key>) {
    TEST_KEYS.with(|cell| *cell.borrow_mut() = Some(keys));
}

/// A valid store package `id` in `root/<dir>`, as sync-app-runtime.sh copies one.
fn write_package(root: &Path, dir: &str, id: &str) -> PathBuf {
    let app = root.join(dir);
    std::fs::create_dir_all(app.join("dist")).unwrap();
    std::fs::write(app.join("dist/main.js"), "var __cmuxAppExports = {};").unwrap();
    let publisher = id.split('/').next().unwrap();
    let owner = if publisher == "cmux" { "manaflow-ai" } else { publisher };
    let manifest = json!({
        "manifestVersion": 2, "id": id, "name": "Demo", "version": "1.0.0", "description": "d",
        "engines": { "cmux": "^2.0" }, "runtime": { "main": "dist/main.js" },
        "implements": { "cmux.section/1": { "export": "render", "title": "Demo" } },
        "scopes": {}, "files": ["dist/"],
        "repository": format!("https://github.com/{owner}/demo"),
    });
    std::fs::write(app.join("cmux-app.v2.json"), manifest.to_string()).unwrap();
    app
}

/// The signed payload for the files of `app` now, as
/// scripts/cmux-next/store-package-sign.py writes it.
fn payload(app: &Path, id: &str, purpose: &str) -> Value {
    fn walk(dir: &Path, prefix: &str, out: &mut serde_json::Map<String, Value>) {
        for entry in std::fs::read_dir(dir).unwrap() {
            let entry = entry.unwrap();
            let rel = format!("{prefix}{}", entry.file_name().to_str().unwrap());
            if rel == SIGNATURE_FILE {
                continue;
            }
            if entry.file_type().unwrap().is_dir() {
                walk(&entry.path(), &format!("{rel}/"), out);
            } else {
                let digest = Sha256::digest(std::fs::read(entry.path()).unwrap());
                out.insert(rel, json!(format!("{digest:x}")));
            }
        }
    }
    let mut files = serde_json::Map::new();
    walk(app, "", &mut files);
    json!({ "schema": 1, "purpose": purpose, "id": id, "version": "1.0.0", "files": files })
}

fn sign(app: &Path, payload: &Value, pair: &Ed25519KeyPair, key_id: &str) {
    let bytes = serde_json::to_vec(payload).unwrap();
    let b64 = base64::engine::general_purpose::STANDARD;
    let sig = pair.sign(&bytes);
    let envelope = json!({
        "schema": 1,
        "payload": b64.encode(&bytes),
        "signatures": [{ "key_id": key_id, "sig": b64.encode(sig.as_ref()) }],
    });
    std::fs::write(app.join(SIGNATURE_FILE), envelope.to_string()).unwrap();
}

fn tier_of(root: &Path, id: &str) -> Tier {
    let catalog = catalog::load(&Sources { extra: vec![root.to_path_buf()], ..Sources::default() });
    assert!(catalog.rejected.is_empty(), "rejected: {:?}", catalog.rejected);
    catalog.packages.get(id).unwrap_or_else(|| panic!("{id} did not load")).tier
}

#[test]
fn a_store_package_cmux_signed_is_verified() {
    let root = temp_dir();
    let (pair, key) = keypair();
    trust(vec![key.clone()]);
    let app = write_package(&root.0, "hello", "cmux/hello");
    sign(&app, &payload(&app, "cmux/hello", PURPOSE), &pair, &key.0);
    assert_eq!(tier_of(&root.0, "cmux/hello"), Tier::Verified);
}

#[test]
fn a_cmux_named_unsigned_store_package_stays_unverified() {
    let root = temp_dir();
    let (_, key) = keypair();
    trust(vec![key]);
    write_package(&root.0, "hello", "cmux/hello");
    assert_eq!(tier_of(&root.0, "cmux/hello"), Tier::Unverified);
}

#[test]
fn a_third_party_package_signed_with_the_store_key_stays_unverified() {
    let root = temp_dir();
    let (pair, key) = keypair();
    trust(vec![key.clone()]);
    let app = write_package(&root.0, "hello", "acme/hello");
    sign(&app, &payload(&app, "acme/hello", PURPOSE), &pair, &key.0);
    assert_eq!(tier_of(&root.0, "acme/hello"), Tier::Unverified);
}

#[test]
fn a_changed_or_added_file_makes_a_signed_package_unverified() {
    let root = temp_dir();
    let (pair, key) = keypair();
    trust(vec![key.clone()]);
    let app = write_package(&root.0, "hello", "cmux/hello");
    sign(&app, &payload(&app, "cmux/hello", PURPOSE), &pair, &key.0);
    std::fs::write(app.join("dist/main.js"), "var __cmuxAppExports = { evil: 1 };").unwrap();
    assert_eq!(tier_of(&root.0, "cmux/hello"), Tier::Unverified);

    let root = temp_dir();
    let app = write_package(&root.0, "hello", "cmux/hello");
    sign(&app, &payload(&app, "cmux/hello", PURPOSE), &pair, &key.0);
    std::fs::write(app.join("dist/extra.js"), "1").unwrap();
    assert_eq!(tier_of(&root.0, "cmux/hello"), Tier::Unverified);
}

#[test]
fn a_signature_by_another_key_or_for_another_purpose_stays_unverified() {
    let root = temp_dir();
    let (pair, key) = keypair();
    let (other, other_key) = keypair();
    trust(vec![key.clone()]);
    let app = write_package(&root.0, "hello", "cmux/hello");
    // A key the store does not trust (the web update channel's, say).
    sign(&app, &payload(&app, "cmux/hello", PURPOSE), &other, &other_key.0);
    assert_eq!(tier_of(&root.0, "cmux/hello"), Tier::Unverified);
    // The store key, but over a file of another kind.
    sign(&app, &payload(&app, "cmux/hello", "cmux-cloud-machine-update"), &pair, &key.0);
    assert_eq!(tier_of(&root.0, "cmux/hello"), Tier::Unverified);
    // The store key, but another package's signature.
    sign(&app, &payload(&app, "cmux/other", PURPOSE), &pair, &key.0);
    assert_eq!(tier_of(&root.0, "cmux/hello"), Tier::Unverified);
}

/// `testdata/store-signed/hello`, signed by scripts/cmux-next/store-package-sign.py with a test
/// key whose public half is `testdata/store-signed/test-keys.json` (its private half was
/// shredded): the CI signer's files verify here.
#[test]
fn a_package_the_ci_signer_signed_is_verified() {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/apps/testdata/store-signed");
    let keys = std::fs::read_to_string(fixture.join("test-keys.json")).unwrap();
    let keys = cmux_signed_envelope::keys_from_json(&keys);
    assert_eq!(keys.len(), 1);
    trust(keys);
    let root = temp_dir();
    let app = root.0.join("hello");
    std::fs::create_dir_all(app.join("dist")).unwrap();
    for file in [SIGNATURE_FILE, "cmux-app.v2.json", "dist/main.js"] {
        std::fs::copy(fixture.join("hello").join(file), app.join(file)).unwrap();
    }
    assert_eq!(tier_of(&root.0, "cmux/hello"), Tier::Verified);
}

#[test]
fn the_shipped_store_keys_are_not_the_web_update_keys() {
    TEST_KEYS.with(|cell| *cell.borrow_mut() = None);
    let shipped = super::trusted_keys();
    assert!(shipped.iter().all(|(id, _)| id != "e5d7bbcacc70703d"), "{shipped:?}");
}

/// The store signing key (CI secret CMUX_STORE_SIGNING_KEY, env `artifacts`) ships, and its
/// listed id is its own: keys_from_json drops an entry whose id is not sha256(raw)[..16 hex].
#[test]
fn the_shipped_store_keys_hold_the_store_signing_key() {
    TEST_KEYS.with(|cell| *cell.borrow_mut() = None);
    let shipped = super::trusted_keys();
    let ids: Vec<&str> = shipped.iter().map(|(id, _)| id.as_str()).collect();
    assert_eq!(ids, ["4d2c4b445e2193fb"], "{shipped:?}");
    assert_ne!(ids[0], "e5d7bbcacc70703d", "the store key is not the web update key");
}
