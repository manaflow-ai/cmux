use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

use base64::Engine as _;
use ring::rand::SystemRandom;
use ring::signature::{Ed25519KeyPair, KeyPair as _};
use serde_json::{Value, json};

use super::*;
use crate::key_id;

const NOW: u64 = 1_795_400_000;
const BASE: &str = "57f3f5de38ddd7877ff263a2edee7fb6440f59ac";

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

fn file(path: &str, content: &[u8]) -> Value {
    let b64 = base64::engine::general_purpose::STANDARD;
    json!({"path": path, "sha256": hex(&Sha256::digest(content)), "content": b64.encode(content)})
}

fn payload(id: &str, files: Vec<Value>) -> Value {
    json!({
        "schema": 1, "purpose": PURPOSE, "id": id, "target": "acpmux", "base": BASE,
        "issued_at": NOW - 10, "expires_at": NOW + 3600, "files": files,
    })
}

/// A fresh directory this test made; removed when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Self {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let dir = std::env::temp_dir().join(format!(
            "patch-bundle-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(dir.join("root")).unwrap();
        Scratch(dir)
    }
    fn root(&self) -> PathBuf {
        self.0.join("root")
    }
    fn state(&self) -> PathBuf {
        self.0.join("state")
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn read(path: &Path) -> Option<Vec<u8>> {
    std::fs::read(path).ok()
}

fn bundle(pair: &Ed25519KeyPair, id: &str, files: Vec<Value>) -> Bundle {
    verify(&envelope(pair, &payload(id, files)), &trust(pair), "acpmux", BASE, NOW).unwrap()
}

#[test]
fn apply_ok_writes_files_and_records_it() {
    let pair = key_pair();
    let scratch = Scratch::new();
    std::fs::create_dir_all(scratch.root().join("web")).unwrap();
    std::fs::write(scratch.root().join("web/app.js"), b"old").unwrap();
    let bundle =
        bundle(&pair, "fix-1", vec![file("web/app.js", b"new"), file("web/added.css", b"css")]);
    let mut probes = 0;
    let outcome = apply(&bundle, &scratch.root(), &scratch.state(), &mut || {
        probes += 1;
        Ok(())
    })
    .unwrap();
    assert_eq!(outcome, Outcome::Applied { id: "fix-1".into(), files: 2 });
    assert_eq!(probes, 1);
    assert_eq!(read(&scratch.root().join("web/app.js")).unwrap(), b"new");
    assert_eq!(read(&scratch.root().join("web/added.css")).unwrap(), b"css");
    let record = applied(&scratch.state()).unwrap();
    assert_eq!(record.id, "fix-1");
    assert_eq!(record.files, vec!["web/app.js", "web/added.css"]);
    // The same bundle again changes nothing and runs no probe.
    let again =
        apply(&bundle, &scratch.root(), &scratch.state(), &mut || panic!("no probe")).unwrap();
    assert_eq!(again, Outcome::AlreadyApplied { id: "fix-1".into() });
}

#[cfg(unix)]
#[test]
fn apply_keeps_the_replaced_files_mode() {
    use std::os::unix::fs::PermissionsExt as _;
    let pair = key_pair();
    let scratch = Scratch::new();
    let bin = scratch.root().join("tool");
    std::fs::write(&bin, b"#!/bin/sh\n").unwrap();
    std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
    let bundle = bundle(&pair, "fix-mode", vec![file("tool", b"#!/bin/sh\nexit 0\n")]);
    apply(&bundle, &scratch.root(), &scratch.state(), &mut || Ok(())).unwrap();
    assert_eq!(std::fs::metadata(&bin).unwrap().permissions().mode() & 0o777, 0o755);
}

#[test]
fn bad_signature_is_refused_before_any_field() {
    let pair = key_pair();
    let other = key_pair();
    let body = envelope(&other, &payload("fix-1", vec![file("a.js", b"x")]));
    let err = verify(&body, &trust(&pair), "acpmux", BASE, NOW).unwrap_err();
    assert!(err.contains("no valid signature"), "{err}");
    // Bytes changed after signing.
    let mut body = envelope(&pair, &payload("fix-1", vec![file("a.js", b"x")]));
    let mut envelope_json: Value = serde_json::from_slice(&body).unwrap();
    let b64 = base64::engine::general_purpose::STANDARD;
    let mut inner: Value =
        serde_json::from_slice(&b64.decode(envelope_json["payload"].as_str().unwrap()).unwrap())
            .unwrap();
    inner["id"] = json!("fix-2");
    envelope_json["payload"] = json!(b64.encode(serde_json::to_vec(&inner).unwrap()));
    body = serde_json::to_vec(&envelope_json).unwrap();
    assert!(verify(&body, &trust(&pair), "acpmux", BASE, NOW).is_err());
}

#[test]
fn health_fail_rolls_back_and_marks_the_id_bad() {
    let pair = key_pair();
    let scratch = Scratch::new();
    std::fs::write(scratch.root().join("app.js"), b"old").unwrap();
    let bundle =
        bundle(&pair, "fix-bad", vec![file("app.js", b"broken"), file("new/added.js", b"x")]);
    let outcome = apply(&bundle, &scratch.root(), &scratch.state(), &mut || {
        // The probe sees the new files in place.
        assert_eq!(std::fs::read(scratch.root().join("app.js")).unwrap(), b"broken");
        Err("status did not answer".into())
    })
    .unwrap();
    assert_eq!(
        outcome,
        Outcome::RolledBack { id: "fix-bad".into(), why: "status did not answer".into() }
    );
    assert_eq!(read(&scratch.root().join("app.js")).unwrap(), b"old");
    assert!(!scratch.root().join("new/added.js").exists());
    assert!(applied(&scratch.state()).is_none());
    assert_eq!(bad(&scratch.state(), "fix-bad").unwrap().trim(), "status did not answer");
    // Never tried again on this host.
    let err =
        apply(&bundle, &scratch.root(), &scratch.state(), &mut || panic!("no probe")).unwrap_err();
    assert!(err.contains("marked bad"), "{err}");
    assert_eq!(read(&scratch.root().join("app.js")).unwrap(), b"old");
}

#[test]
fn rollback_keeps_an_earlier_bundle() {
    let pair = key_pair();
    let scratch = Scratch::new();
    let good = bundle(&pair, "fix-1", vec![file("app.js", b"v1")]);
    apply(&good, &scratch.root(), &scratch.state(), &mut || Ok(())).unwrap();
    let broken = bundle(&pair, "fix-2", vec![file("app.js", b"v2")]);
    let outcome =
        apply(&broken, &scratch.root(), &scratch.state(), &mut || Err("down".into())).unwrap();
    assert!(matches!(outcome, Outcome::RolledBack { .. }));
    assert_eq!(read(&scratch.root().join("app.js")).unwrap(), b"v1");
    assert_eq!(applied(&scratch.state()).unwrap().id, "fix-1");
}

#[test]
fn refuses_other_targets_builds_expiry_and_hashes() {
    let pair = key_pair();
    let keys = trust(&pair);
    let ok = envelope(&pair, &payload("fix-1", vec![file("a.js", b"x")]));
    assert!(verify(&ok, &keys, "cmux-tui", BASE, NOW).unwrap_err().contains("is for"));
    assert!(verify(&ok, &keys, "acpmux", "0000", NOW).unwrap_err().contains("applies onto"));
    assert!(verify(&ok, &keys, "acpmux", BASE, NOW + 3600).unwrap_err().contains("expired"));
    let mut tampered = payload("fix-1", vec![file("a.js", b"x")]);
    tampered["files"][0]["sha256"] = json!(hex(&Sha256::digest(b"y")));
    let err = verify(&envelope(&pair, &tampered), &keys, "acpmux", BASE, NOW).unwrap_err();
    assert!(err.contains("does not hash"), "{err}");
    let mut other = payload("fix-1", vec![file("a.js", b"x")]);
    other["purpose"] = json!("cmux-config-ring");
    assert!(
        verify(&envelope(&pair, &other), &keys, "acpmux", BASE, NOW)
            .unwrap_err()
            .contains("purpose")
    );
    let empty = payload("fix-1", vec![]);
    assert!(verify(&envelope(&pair, &empty), &keys, "acpmux", BASE, NOW).is_err());
}

#[test]
fn refuses_paths_outside_the_root() {
    let pair = key_pair();
    let keys = trust(&pair);
    for path in
        ["../escape", "/etc/passwd", "a/../../b", "", ".hidden", "a/./b", "a//b", "a\\b", "c:x"]
    {
        let body = envelope(&pair, &payload("fix-1", vec![file(path, b"x")]));
        let err = verify(&body, &keys, "acpmux", BASE, NOW).unwrap_err();
        assert!(err.contains("not a plain relative path"), "{path}: {err}");
    }
    let twice = payload("fix-1", vec![file("a.js", b"x"), file("a.js", b"y")]);
    assert!(
        verify(&envelope(&pair, &twice), &keys, "acpmux", BASE, NOW).unwrap_err().contains("twice")
    );
    let bad_id = payload("Fix 1", vec![file("a.js", b"x")]);
    assert!(
        verify(&envelope(&pair, &bad_id), &keys, "acpmux", BASE, NOW).unwrap_err().contains("id")
    );
}

#[cfg(unix)]
#[test]
fn command_probe_passes_fails_and_times_out() {
    assert_eq!(command_probe(&["sh", "-c", "exit 0"], Duration::from_secs(5)), Ok(()));
    assert!(
        command_probe(&["sh", "-c", "exit 3"], Duration::from_secs(5))
            .unwrap_err()
            .contains("failed")
    );
    let started = std::time::Instant::now();
    let err = command_probe(&["sleep", "5"], Duration::from_millis(200)).unwrap_err();
    assert!(err.contains("did not pass within"), "{err}");
    assert!(started.elapsed() < Duration::from_secs(3));
    assert!(command_probe(&[], HEALTH_BOUND).is_err());
}
