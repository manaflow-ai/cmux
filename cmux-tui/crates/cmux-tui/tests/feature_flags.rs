//! Tester rollout #10 (plans/cmux-next/tui-tester-rollout.md): invite waves.
//!
//! A signed flag document (`notes/flags.json` + `.sig`, signed with the same
//! `content-signing` key as the release notes) names policy keys per tester
//! cohort (`DisabledFeatures`, the shape of `managed/policy.rs`). The owner
//! fetches it at start, keeps it only when the signature verifies, and caches
//! it, so a feature can be turned off for one wave without a new build.
//! `cmux --version --json` reports the cohort and what the cached document
//! turns off for it. Debug builds take the URL and the public key from the
//! environment; this test serves a document signed by a test key.

#![cfg(all(unix, debug_assertions))]

use std::collections::BTreeMap;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine;
use ring::signature::{Ed25519KeyPair, KeyPair};

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

/// A local file server: each path's body, 404 for anything else.
fn serve(files: BTreeMap<String, Vec<u8>>) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut request_line = String::new();
            reader.read_line(&mut request_line).unwrap_or_default();
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap_or_default() == 0 || line == "\r\n" {
                    break;
                }
            }
            let path = request_line.split_whitespace().nth(1).unwrap_or_default();
            let response = match files.get(path) {
                Some(body) => {
                    let mut response = format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    )
                    .into_bytes();
                    response.extend_from_slice(body);
                    response
                }
                None => b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    .to_vec(),
            };
            let _ = stream.write_all(&response);
        }
    });
    format!("http://127.0.0.1:{port}")
}

fn test_key() -> Ed25519KeyPair {
    Ed25519KeyPair::from_seed_unchecked(&[7u8; 32]).unwrap()
}

fn public_key() -> String {
    base64::engine::general_purpose::STANDARD.encode(test_key().public_key().as_ref())
}

fn signature(data: &[u8]) -> Vec<u8> {
    let text = base64::engine::general_purpose::STANDARD.encode(test_key().sign(data).as_ref());
    format!("{text}\n").into_bytes()
}

const DOCUMENT: &str = r#"{
  "version": 1,
  "default": { "DisabledFeatures": ["cloud-vm"] },
  "cohorts": {
    "linux-wave-1": { "DisabledFeatures": ["cloud-vm", "remote-browser"] }
  }
}"#;

fn temp_dir(tag: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = PathBuf::from("/tmp").join(format!("cmux-ff-{tag}-{}-{stamp}", std::process::id()));
    fs::create_dir_all(dir.join("state").join("sessions")).unwrap();
    dir
}

fn command(dir: &Path, base: &str) -> Command {
    let mut command = Command::new(bin());
    command
        .env("CMUX_TUI_STATE_DIR", dir.join("state").join("sessions"))
        .env("CMUX_TUI_CONFIG", dir.join("config.json"))
        .env("CMUX_NEXT_CONFIG_FILE", dir.join("cmux-next.json"))
        .env("CMUX_TUI_LOG_FILE", dir.join("client.log"))
        .env("CMUX_TUI_TEST_FLAGS_URL", format!("{base}/notes/flags.json"))
        .env("CMUX_TUI_TEST_CONTENT_PUBLIC_KEY", public_key())
        .env("CMUX_TUI_COHORT", "linux-wave-1")
        .env_remove("CI");
    command
}

struct Owner {
    child: Child,
    dir: PathBuf,
    base: String,
    session: &'static str,
}

impl Owner {
    fn start(dir: &Path, base: &str, session: &'static str) -> Owner {
        let child = command(dir, base)
            .args(["--headless", "--session", session, "--socket"])
            .arg(dir.join("mux.sock"))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        Owner { child, dir: dir.to_path_buf(), base: base.to_string(), session }
    }

    /// The owner's one `feature-flags:` outcome line for this start.
    fn outcome(&self) -> String {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let log = fs::read_to_string(self.dir.join("client.log")).unwrap_or_default();
            if let Some(line) = log.lines().find(|line| line.contains("feature-flags:")) {
                return line.to_string();
            }
            assert!(Instant::now() < deadline, "no feature-flags outcome in client.log:\n{log}");
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

impl Drop for Owner {
    fn drop(&mut self) {
        let _ = command(&self.dir, &self.base)
            .args(["server", "stop", "--session", self.session, "--end-terminals", "--socket"])
            .arg(self.dir.join("mux.sock"))
            .output();
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
        }
        let _ = self.child.wait();
    }
}

fn version_json(dir: &Path, base: &str) -> serde_json::Value {
    let output = command(dir, base).args(["--version", "--json"]).output().unwrap();
    assert!(output.status.success(), "{output:?}");
    serde_json::from_slice(&output.stdout).unwrap()
}

#[test]
fn feature_flags_a_signed_document_turns_features_off_for_the_cohort() {
    let files = BTreeMap::from([
        ("/notes/flags.json".to_string(), DOCUMENT.as_bytes().to_vec()),
        ("/notes/flags.json.sig".to_string(), signature(DOCUMENT.as_bytes())),
    ]);
    let base = serve(files);
    let dir = temp_dir("signed");
    let owner = Owner::start(&dir, &base, "ff-signed");
    let outcome = owner.outcome();
    assert!(outcome.contains("feature-flags: updated"), "{outcome}");
    drop(owner);

    let report = version_json(&dir, &base);
    assert_eq!(report["cohort"], "linux-wave-1", "{report}");
    assert_eq!(
        report["disabled_features"],
        serde_json::json!(["cloud-vm", "remote-browser"]),
        "{report}"
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn feature_flags_a_document_with_a_bad_signature_is_never_used() {
    let tampered = DOCUMENT.replace("remote-browser", "terminals");
    let files = BTreeMap::from([
        ("/notes/flags.json".to_string(), tampered.into_bytes()),
        ("/notes/flags.json.sig".to_string(), signature(DOCUMENT.as_bytes())),
    ]);
    let base = serve(files);
    let dir = temp_dir("tampered");
    let owner = Owner::start(&dir, &base, "ff-tampered");
    let outcome = owner.outcome();
    assert!(outcome.contains("feature-flags: rejected"), "{outcome}");
    drop(owner);

    let report = version_json(&dir, &base);
    assert_eq!(report["disabled_features"], serde_json::json!([]), "{report}");
    assert!(!dir.join("state").join("flags.json").exists(), "a rejected document was cached");
    let _ = fs::remove_dir_all(&dir);
}

/// A document with the `Features*` keys (schemas/features/flags-document.md), still version 1.
fn features_document(serial: u64) -> String {
    format!(
        r#"{{
  "version": 1,
  "default": {{ "Features": {{ "cefLayerHosting": "off" }}, "FeaturesSerial": {serial} }},
  "cohorts": {{
    "linux-wave-1": {{ "DisabledFeatures": ["cloud-vm"], "Features": {{ "cefLayerHosting": "on" }} }}
  }}
}}"#
    )
}

fn signed(document: &str) -> BTreeMap<String, Vec<u8>> {
    BTreeMap::from([
        ("/notes/flags.json".to_string(), document.as_bytes().to_vec()),
        ("/notes/flags.json.sig".to_string(), signature(document.as_bytes())),
    ])
}

#[test]
fn feature_flags_a_document_with_features_keys_is_cached_and_keeps_disabled_features() {
    let base = serve(signed(&features_document(3)));
    let dir = temp_dir("features");
    let owner = Owner::start(&dir, &base, "ff-features");
    let outcome = owner.outcome();
    assert!(outcome.contains("feature-flags: updated"), "{outcome}");
    drop(owner);

    let report = version_json(&dir, &base);
    assert_eq!(report["disabled_features"], serde_json::json!(["cloud-vm"]), "{report}");
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn feature_flags_one_changed_byte_in_a_features_document_is_rejected() {
    let document = features_document(3);
    let mut tampered = document.clone().into_bytes();
    let at = document.find(r#""on""#).unwrap() + 2;
    tampered[at] = b'f';
    let files = BTreeMap::from([
        ("/notes/flags.json".to_string(), tampered),
        ("/notes/flags.json.sig".to_string(), signature(document.as_bytes())),
    ]);
    let base = serve(files);
    let dir = temp_dir("byte");
    let owner = Owner::start(&dir, &base, "ff-byte");
    let outcome = owner.outcome();
    assert!(outcome.contains("feature-flags: rejected (bad signature)"), "{outcome}");
    drop(owner);
    assert!(!dir.join("state").join("flags.json").exists(), "a tampered document was cached");
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn feature_flags_a_replayed_document_with_a_lower_serial_keeps_the_cache() {
    let dir = temp_dir("serial");
    let newer = features_document(5);
    let owner = Owner::start(&dir, &serve(signed(&newer)), "ff-serial-new");
    let outcome = owner.outcome();
    assert!(outcome.contains("feature-flags: updated"), "{outcome}");
    drop(owner);
    fs::remove_file(dir.join("client.log")).unwrap();

    let owner = Owner::start(&dir, &serve(signed(&features_document(4))), "ff-serial-old");
    let outcome = owner.outcome();
    assert!(outcome.contains("feature-flags: rejected (older FeaturesSerial"), "{outcome}");
    drop(owner);
    let cached = fs::read_to_string(dir.join("state").join("flags.json")).unwrap();
    assert_eq!(cached, newer, "the replayed document replaced the cache");
    let _ = fs::remove_dir_all(&dir);
}
