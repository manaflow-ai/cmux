//! Registry entries and the revocation list: only a registry key opens
//! them, each only as its own kind, and the catalog refuses an installed
//! extension whose recorded build the list revokes, with the reason.

use std::cell::RefCell;
use std::path::{Path, PathBuf};

use base64::Engine as _;
use ring::signature::{Ed25519KeyPair, KeyPair as _};
use serde_json::{Value, json};

use super::super::catalog::{self, Sources};
use super::{
    ENTRY_PURPOSE, MARKER, REVOCATIONS_FILE, REVOCATIONS_PURPOSE, Revocations, open_entry,
    open_revocations, recorded_sha256,
};
use cmux_signed_envelope::Key;

thread_local! {
    /// The keys [`super::trusted_keys`] answers on this test thread.
    pub(crate) static TEST_KEYS: RefCell<Option<Vec<Key>>> = const { RefCell::new(None) };
}

const BUILD: &str = "a3c1b0f6b8f61b1e4d2b8c8f1f0e6a3d5c7b9e2f4a6c8e0b2d4f6a8c0e2b4d6f";
const OTHER: &str = "0000000000000000000000000000000000000000000000000000000000000000";

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
        "cmux-registry-trust-test-{}",
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

fn envelope(payload: &Value, pair: &Ed25519KeyPair, key_id: &str) -> Vec<u8> {
    let bytes = serde_json::to_vec(payload).unwrap();
    let b64 = base64::engine::general_purpose::STANDARD;
    let sig = pair.sign(&bytes);
    json!({
        "schema": 1,
        "payload": b64.encode(&bytes),
        "signatures": [{ "key_id": key_id, "sig": b64.encode(sig.as_ref()) }],
    })
    .to_string()
    .into_bytes()
}

fn entry_payload() -> Value {
    json!({
        "schema": 1, "purpose": ENTRY_PURPOSE, "id": "acme/hello", "version": "0.1.0",
        "repository": "acme/hello-ext", "commit": "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
        "sha256": BUILD.to_ascii_uppercase(),
    })
}

fn revocations_payload(sha256: &str) -> Value {
    json!({
        "schema": 1, "purpose": REVOCATIONS_PURPOSE, "sequence": 7,
        "revoked": [{ "sha256": sha256, "id": "acme/hello", "reason": "sends your files to a third party" }],
    })
}

#[test]
fn a_signed_entry_opens_with_its_hashes() {
    let (pair, key) = keypair();
    let body = envelope(&entry_payload(), &pair, &key.0);
    let entry = open_entry(&body, &[key.clone()]).unwrap();
    assert_eq!((entry.id.as_str(), entry.version.as_str()), ("acme/hello", "0.1.0"));
    assert_eq!(entry.sha256, BUILD, "lower-cased");
    assert_eq!(entry.commit, "4b825dc642cb6eb9a060e54bf8d69288fbee4904");

    let (_, stranger) = keypair();
    assert!(open_entry(&body, &[stranger]).is_err(), "another key");
    assert!(open_entry(&body, &[]).unwrap_err().contains("no registry key"), "no key at all");
    let mut bad = entry_payload();
    bad["sha256"] = json!("abc");
    assert!(open_entry(&envelope(&bad, &pair, &key.0), &[key]).is_err(), "not a sha256");
}

/// An entry never opens as a revocation list, nor a list as an entry.
#[test]
fn each_kind_opens_only_as_itself() {
    let (pair, key) = keypair();
    let entry = envelope(&entry_payload(), &pair, &key.0);
    let list = envelope(&revocations_payload(BUILD), &pair, &key.0);
    assert!(
        open_revocations(&entry, &[key.clone()])
            .unwrap_err()
            .contains("not cmux-extension-revocations")
    );
    assert!(open_entry(&list, &[key.clone()]).unwrap_err().contains("not cmux-extension-entry"));
    let opened = open_revocations(&list, &[key]).unwrap();
    assert_eq!(opened.sequence, 7);
    assert_eq!(
        opened.get(&BUILD.to_ascii_uppercase()).unwrap().reason,
        "sends your files to a third party"
    );
    assert!(opened.get(OTHER).is_none());
}

/// A `local/` extension `ext add` installed, with `sha256` in its marker's origin.
fn write_added(local: &Path, name: &str, sha256: Option<&str>) -> PathBuf {
    let app = local.join(name);
    std::fs::create_dir_all(app.join("dist")).unwrap();
    std::fs::write(app.join("dist/main.js"), "var __cmuxAppExports = {};").unwrap();
    let manifest = json!({
        "manifestVersion": 2, "id": format!("local/{name}"), "name": "Demo", "version": "0.1.0",
        "description": "d", "engines": { "cmux": "^2.0" }, "runtime": { "main": "dist/main.js" },
        "implements": { "cmux.section/1": { "export": "render", "title": "Demo" } },
        "scopes": {}, "files": ["dist/"],
    });
    std::fs::write(app.join("cmux-app.v2.json"), manifest.to_string()).unwrap();
    let marker = json!({ "source": "/x", "app": format!("local/{name}"),
        "origin": { "url": "https://github.com/acme/hello-ext", "commit": "c", "sha256": sha256 } });
    std::fs::write(app.join(MARKER), marker.to_string()).unwrap();
    app
}

/// `<state>/apps` with `local/` inside, and the sources that read it.
fn state(root: &Path) -> (PathBuf, Sources) {
    let apps = root.join("apps");
    let local = apps.join("local");
    std::fs::create_dir_all(&local).unwrap();
    (apps, Sources { local: Some(local), ..Sources::default() })
}

#[test]
fn the_catalog_refuses_a_revoked_build_with_the_reason() {
    let root = temp_dir();
    let (pair, key) = keypair();
    trust(vec![key.clone()]);
    let (apps, sources) = state(&root.0);
    let local = sources.local.clone().unwrap();
    let revoked = write_added(&local, "hello", Some(BUILD));
    write_added(&local, "other", Some(OTHER));
    write_added(&local, "mine", None);
    assert_eq!(recorded_sha256(&revoked).as_deref(), Some(BUILD));

    let before = catalog::load(&sources);
    assert_eq!(before.packages.len(), 3, "no list, nothing refused: {:?}", before.rejected);

    std::fs::write(
        apps.join(REVOCATIONS_FILE),
        envelope(&revocations_payload(BUILD), &pair, &key.0),
    )
    .unwrap();
    let after = catalog::load(&sources);
    assert!(
        after.packages.contains_key("local/other") && after.packages.contains_key("local/mine")
    );
    assert!(!after.packages.contains_key("local/hello"));
    let (dir, issue) = &after.rejected[0];
    assert_eq!(dir, &revoked);
    assert!(issue.contains("revoked by cmux: sends your files to a third party"), "{issue}");
    assert!(issue.contains(BUILD), "{issue}");

    // A reused earlier read is checked again: the list applies without a save.
    let reuse = |dir: &Path| before.packages.values().find(|p| p.dir == dir).cloned().map(Ok);
    let reused = catalog::load_reusing(&sources, &reuse, &|_| None);
    assert!(!reused.packages.contains_key("local/hello"));
}

/// A list another key signed, or one this build cannot open, revokes nothing.
#[test]
fn an_unsigned_or_mis_signed_list_revokes_nothing() {
    let root = temp_dir();
    let (pair, key) = keypair();
    let (_, trusted) = keypair();
    trust(vec![trusted]);
    let (apps, sources) = state(&root.0);
    write_added(sources.local.as_deref().unwrap(), "hello", Some(BUILD));
    std::fs::write(
        apps.join(REVOCATIONS_FILE),
        envelope(&revocations_payload(BUILD), &pair, &key.0),
    )
    .unwrap();
    assert!(Revocations::load(&apps, &super::trusted_keys()).is_none());
    assert!(catalog::load(&sources).packages.contains_key("local/hello"));

    std::fs::write(apps.join(REVOCATIONS_FILE), revocations_payload(BUILD).to_string()).unwrap();
    assert!(catalog::load(&sources).packages.contains_key("local/hello"), "a bare payload");
}

/// The shipped keys file parses (it holds no key until the registry has one).
#[test]
fn the_shipped_keys_file_parses() {
    let file: Value = serde_json::from_str(include_str!("registry-keys.json")).unwrap();
    assert!(file["keys"].is_array());
}
