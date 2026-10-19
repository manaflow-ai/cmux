//! The real enrollment reducer, crypto and private files with a controlled API.
//! No account is approved, service installed or role started by these tests.

use std::collections::VecDeque;
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use base64::Engine as _;
use cmux_server::pairing::{self, Transport};
use cmux_server::{Error, Result};
use cmux_server_core::install_key::verify;
use cmux_server_core::pairing::enrollment::{Begun, Paired, Waited};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

const NOW: u64 = 1_790_978_474_000;
const API: &str = "https://api.example.test";
const SECRET: &str =
    "AAAAAAAAAAAAAAAAAAAAAA.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn info() -> Value {
    json!({"name":"Test server","platform":"linux","os_version":"test","arch":"aarch64","cmux_version":"1.0.0"})
}

fn paired() -> Paired {
    Paired {
        host: "host_00000000000000000001".into(),
        team: "team_00000000000000000001".into(),
        user: "user_00000000000000000001".into(),
        install: "inst_00000000000000000001".into(),
    }
}

struct Api {
    begins: AtomicUsize,
    health: AtomicUsize,
    waits: Mutex<VecDeque<Result<Waited>>>,
    lose_begin: bool,
    reject_begin: bool,
    wrong_thumbprint: bool,
    verification_uri: Option<String>,
}

impl Api {
    fn new(waits: Vec<Result<Waited>>) -> Self {
        Self {
            begins: AtomicUsize::new(0),
            health: AtomicUsize::new(0),
            waits: Mutex::new(waits.into()),
            lose_begin: false,
            reject_begin: false,
            wrong_thumbprint: false,
            verification_uri: Some("https://dashboard.example.test/pair?c=7KQ4M2XD".into()),
        }
    }
}

impl Transport for Api {
    fn health(&self, api: &str) -> Result<Value> {
        assert_eq!(api, API);
        self.health.fetch_add(1, Ordering::SeqCst);
        Ok(json!({"environment":"staging"}))
    }
    fn begin(&self, api: &str, body: &Value) -> Result<Value> {
        assert_eq!(api, API);
        self.begins.fetch_add(1, Ordering::SeqCst);
        assert_eq!(body["info"], info());
        let jwk = &body["public_jwk"];
        // Independent canonical serialization, matching the API's thumbprint.
        let canonical = json!({"crv":jwk["crv"],"kty":jwk["kty"],"x":jwk["x"],"y":jwk["y"]});
        let thumb = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(Sha256::digest(canonical.to_string()));
        let proof = format!(
            "cmux-pair-begin\nstaging\n{thumb}\n{}\n{}",
            body["wg_public_key"].as_str().unwrap(),
            body["issued_at"].as_u64().unwrap()
        );
        assert!(
            verify(jwk, proof.as_bytes(), body["signature"].as_str().unwrap()),
            "the API cannot verify the actual possession proof"
        );
        if self.lose_begin {
            return Err(Error::unreachable("fixture.lost_begin_reply"));
        }
        if self.reject_begin {
            return Err(Error::rejected("fixture.rejected"));
        }
        Ok(
            json!({"code":"7KQ4M2XD","expires_at":body["issued_at"].as_u64().unwrap()+600_000,"thumbprint":if self.wrong_thumbprint { "wrong" } else { &thumb },"collect_secret":SECRET,"verification_uri":self.verification_uri}),
        )
    }
    fn wait(&self, api: &str, begun: &Begun) -> Result<Waited> {
        assert_eq!(api, API);
        assert_eq!(begun.code.as_str(), "7KQ4M2XD");
        assert_eq!(begun.collect_secret(), SECRET);
        self.waits.lock().unwrap().pop_front().expect("unexpected wait")
    }
}

fn run(
    path: &std::path::Path,
    api: &Api,
    intent: Option<&str>,
    progress: &mut Vec<Value>,
) -> Result<Value> {
    pairing::enroll(path, API, info(), intent, api, NOW, |value| {
        progress.push(value.clone());
        Ok(())
    })
}

#[test]
fn server_pairing_records_only_a_pushed_approval_and_redacts_all_public_results() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    assert_eq!(pairing::status(&path).unwrap(), json!({"state":"unpaired"}));
    assert!(!path.parent().unwrap().exists());
    let api = Api::new(vec![Ok(Waited::Paired(paired()))]);
    let mut progress = vec![];
    let result = run(&path, &api, Some("intent-1"), &mut progress).unwrap();
    assert_eq!(result["state"], "paired");
    assert_eq!(result["install"], "inst_00000000000000000001");
    assert_eq!(pairing::status(&path).unwrap(), result);
    let public = format!("{result:?}{progress:?}");
    for private in [SECRET, "pkcs8", "protected_keys", "wg_private", "collect_secret"] {
        assert!(!public.contains(private));
    }
    assert_eq!(progress.len(), 1);
    assert_eq!(progress[0]["state"], "pending");
    let bytes = std::fs::read(&path).unwrap();
    assert_eq!(run(&path, &api, Some("intent-1"), &mut progress).unwrap(), result);
    assert_eq!(std::fs::read(&path).unwrap(), bytes);
    assert_eq!(api.begins.load(Ordering::SeqCst), 1);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    }
}

#[test]
fn server_pairing_progress_uses_the_apis_verification_link_and_preserves_it_on_resume() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api =
        Api::new(vec![Err(Error::unreachable("fixture.lost_wait")), Ok(Waited::Paired(paired()))]);
    let mut progress = vec![];
    assert!(run(&path, &api, None, &mut progress).is_err());
    assert_eq!(progress[0]["verification_uri"], "https://dashboard.example.test/pair?c=7KQ4M2XD");
    assert_eq!(run(&path, &api, None, &mut progress).unwrap()["state"], "paired");
    assert_eq!(progress[0], progress[1]);
    assert_eq!(api.begins.load(Ordering::SeqCst), 1);
}

#[test]
fn server_pairing_progress_omits_invalid_or_missing_verification_links() {
    for uri in [
        None,
        Some("javascript:alert(1)"),
        Some("https://user:password@dashboard.example.test/pair?c=7KQ4M2XD"),
        Some("https://dashboard.example.test/pair?c=WRONG"),
        Some("https://dashboard.example.test/pair?c=7KQ4M2XD&collect=private"),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pairing/identity.json");
        let api = Api {
            verification_uri: uri.map(str::to_owned),
            ..Api::new(vec![Ok(Waited::Paired(paired()))])
        };
        let mut progress = vec![];
        assert_eq!(run(&path, &api, None, &mut progress).unwrap()["state"], "paired");
        assert!(progress[0].get("verification_uri").is_none());
    }
}

#[test]
fn server_pairing_connection_loss_resumes_the_same_code_without_another_begin() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api::new(vec![
        Err(Error::unreachable("fixture.connection_lost")),
        Ok(Waited::Paired(paired())),
    ]);
    let mut progress = vec![];
    assert!(run(&path, &api, Some("intent"), &mut progress).is_err());
    assert_eq!(pairing::status(&path).unwrap()["state"], "pending");
    let before: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(run(&path, &api, Some("intent"), &mut progress).unwrap()["state"], "paired");
    assert_eq!(api.begins.load(Ordering::SeqCst), 1);
    assert_eq!(api.health.load(Ordering::SeqCst), 1);
    assert_eq!(progress[0], progress[1]);
    let after: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(before["public_jwk"], after["public_jwk"]);
    assert_eq!(before["protected_keys"], after["protected_keys"]);
}

#[test]
fn server_pairing_lost_begin_reply_stays_indeterminate_without_reissuing_it() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api { lose_begin: true, ..Api::new(vec![]) };
    assert!(run(&path, &api, None, &mut vec![]).is_err());
    assert_eq!(
        run(&path, &api, None, &mut vec![]).unwrap_err().message,
        "server.pair.begin_indeterminate"
    );
    assert_eq!(api.begins.load(Ordering::SeqCst), 1);
    assert_eq!(api.health.load(Ordering::SeqCst), 1);
    assert_eq!(pairing::status(&path).unwrap()["state"], "indeterminate");
}

#[test]
fn server_pairing_acknowledged_begin_refusal_keeps_the_key_and_allows_correction() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api { reject_begin: true, ..Api::new(vec![]) };
    assert_eq!(
        run(&path, &api, None, &mut vec![]).unwrap_err().kind,
        cmux_server::ExitKind::Rejected
    );
    let before: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(pairing::status(&path).unwrap()["state"], "unpaired");
    assert_eq!(
        run(&path, &api, None, &mut vec![]).unwrap_err().kind,
        cmux_server::ExitKind::Rejected
    );
    let after: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(before["public_jwk"], after["public_jwk"]);
    assert_eq!(before["protected_keys"], after["protected_keys"]);
    assert_eq!(api.begins.load(Ordering::SeqCst), 2);
}

#[test]
fn server_pairing_pending_identity_cannot_be_retargeted_to_another_api_or_intent() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api::new(vec![Err(Error::unreachable("fixture.lost"))]);
    assert!(run(&path, &api, Some("original"), &mut vec![]).is_err());
    let before = std::fs::read(&path).unwrap();
    assert_eq!(
        run(&path, &api, Some("different"), &mut vec![]).unwrap_err().kind,
        cmux_server::ExitKind::Conflict
    );
    assert!(
        pairing::enroll(
            &path,
            "https://another.example.test",
            info(),
            Some("original"),
            &api,
            NOW,
            |_| Ok(())
        )
        .is_err()
    );
    assert_eq!(std::fs::read(&path).unwrap(), before);
    assert_eq!(api.begins.load(Ordering::SeqCst), 1);
}

#[test]
fn server_pairing_refused_or_expired_waits_never_store_a_paired_binding() {
    for outcome in [Waited::Refused, Waited::Expired] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pairing/identity.json");
        let api = Api::new(vec![Ok(outcome)]);
        assert!(run(&path, &api, None, &mut vec![]).is_err());
        assert_eq!(pairing::status(&path).unwrap()["state"], "unpaired");
        let value: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert!(value["attempt"].is_null());
        assert!(value["paired"].is_null());
    }
}

#[test]
fn server_pairing_wrong_thumbprint_never_reaches_the_approval_wait() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api { wrong_thumbprint: true, ..Api::new(vec![]) };
    assert_eq!(
        run(&path, &api, None, &mut vec![]).unwrap_err().kind,
        cmux_server::ExitKind::Verification
    );
    assert_eq!(pairing::status(&path).unwrap()["state"], "indeterminate");
    assert!(run(&path, &api, None, &mut vec![]).is_err());
    assert_eq!(api.begins.load(Ordering::SeqCst), 1);
}

#[test]
fn server_pairing_expired_pending_attempt_can_start_a_new_explicit_intent_with_the_same_key() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api =
        Api::new(vec![Err(Error::unreachable("fixture.lost_wait")), Ok(Waited::Paired(paired()))]);
    assert!(run(&path, &api, Some("old"), &mut vec![]).is_err());
    let before: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(
        pairing::enroll(&path, API, info(), Some("new"), &api, NOW + 600_001, |_| Ok(())).unwrap()
            ["state"],
        "paired"
    );
    let after: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(before["public_jwk"], after["public_jwk"]);
    assert_eq!(before["protected_keys"], after["protected_keys"]);
    assert_eq!(api.begins.load(Ordering::SeqCst), 2);
}

#[test]
fn server_pairing_serializes_concurrent_enrollment_before_any_second_begin() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api::new(vec![Ok(Waited::Paired(paired()))]);
    let result = pairing::enroll(&path, API, info(), None, &api, NOW, |_| {
        assert_eq!(run(&path, &api, None, &mut vec![]).unwrap_err().message, "server.pair.busy");
        Ok(())
    })
    .unwrap();
    assert_eq!(result["state"], "paired");
    assert_eq!(api.begins.load(Ordering::SeqCst), 1);
}

#[test]
fn server_pairing_does_not_replace_a_corrupt_identity_with_new_keys() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    cmux_server::fsx::ensure_dir(path.parent().unwrap(), 0o700).unwrap();
    std::fs::write(&path, b"invalid-existing-identity").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    }
    let api = Api::new(vec![]);
    assert!(run(&path, &api, None, &mut vec![]).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), b"invalid-existing-identity");
    assert_eq!(api.health.load(Ordering::SeqCst), 0);
    assert_eq!(api.begins.load(Ordering::SeqCst), 0);
}

#[cfg(unix)]
#[test]
fn server_pairing_refuses_shared_or_symlinked_identity_files_without_touching_them() {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api::new(vec![Err(Error::unreachable("fixture.connection_lost"))]);
    assert!(run(&path, &api, None, &mut vec![]).is_err());
    assert_eq!(api.begins.load(Ordering::SeqCst), 1, "fixture never reached its intended wait");
    let bytes = std::fs::read(&path).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(pairing::status(&path).is_err());
    assert!(run(&path, &api, None, &mut vec![]).is_err());
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let target = path.with_file_name("preserved");
    std::fs::rename(&path, &target).unwrap();
    symlink(&target, &path).unwrap();
    assert!(pairing::status(&path).is_err());
    assert!(run(&path, &api, None, &mut vec![]).is_err());
    assert_eq!(std::fs::read(&target).unwrap(), bytes);
    assert_eq!(api.begins.load(Ordering::SeqCst), 1);
}
