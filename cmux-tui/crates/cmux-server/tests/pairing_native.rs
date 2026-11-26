//! Real local keys and private records against an independently verifying Native API.
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use cmux_server::pairing::{self, EnrolledIdentity, Transport};
use cmux_server::{Error, Result};
use cmux_server_core::install_key::verify;
use cmux_server_core::pairing::enrollment::{Begun, Waited, jwk_thumbprint, read_frame};
use serde_json::{Value, json};

const NOW: u64 = 1_792_411_200_000;
const API: &str = "https://cloud.example.test";
const NATIVE: &str = "https://native.example.test";
const MESH: &str = "mesh_00000000000000000000000000";
const DEVICE: &str = "dev_00000000000000000000000000";
const CODE: &str = "msc_00000000000000000000000000";
const SECRET: &str =
    "AAAAAAAAAAAAAAAAAAAAAA.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

#[path = "support/native_backend.rs"]
mod backend;

#[derive(Clone, Copy, Default)]
enum Fault {
    #[default]
    None,
    Unavailable,
    Tenant,
    Mesh,
    Device,
    Wg,
    Install,
    Backend,
}
#[derive(Default)]
struct State {
    begin: Value,
    begins: usize,
    waits: usize,
    now: u64,
    live: bool,
    lose_enrollment_reply: bool,
    reject_enrollment: bool,
    bad_grant: Option<&'static str>,
    fault: Fault,
    calls: Vec<(String, Value)>,
    backend_calls: Vec<(String, Value)>,
    backend_fault: Option<&'static str>,
    lose_backend_reply: bool,
    confirmed_at: Option<u64>,
}
struct Api {
    path: PathBuf,
    state: Mutex<State>,
}
fn point(jwk: &Value) -> String {
    let mut bytes = vec![4];
    bytes.extend(URL_SAFE_NO_PAD.decode(jwk["x"].as_str().unwrap()).unwrap());
    bytes.extend(URL_SAFE_NO_PAD.decode(jwk["y"].as_str().unwrap()).unwrap());
    STANDARD.encode(bytes)
}
impl Api {
    fn new(path: &Path) -> Self {
        Self { path: path.into(), state: Mutex::new(State { now: NOW, ..State::default() }) }
    }
}
impl Transport for Api {
    fn now_ms(&self) -> u64 {
        self.state.lock().unwrap().now
    }
    fn health(&self, api: &str) -> Result<Value> {
        assert_eq!(api, API);
        Ok(json!({"environment":"test"}))
    }
    fn begin(&self, api: &str, body: &Value) -> Result<Value> {
        assert_eq!(api, API);
        let mut state = self.state.lock().unwrap();
        state.begins += 1;
        state.begin = body.clone();
        let thumb = jwk_thumbprint(&body["public_jwk"]).unwrap();
        let proof = format!(
            "cmux-pair-begin\ntest\n{thumb}\n{}\n{}",
            body["wg_public_key"].as_str().unwrap(),
            body["issued_at"].as_u64().unwrap()
        );
        assert!(verify(&body["public_jwk"], proof.as_bytes(), body["signature"].as_str().unwrap()));
        Ok(
            json!({"code":"7KQ4M2XD","expires_at":NOW+300_000,"thumbprint":thumb,"collect_secret":SECRET}),
        )
    }
    fn wait(&self, api: &str, begun: &Begun) -> Result<Waited> {
        assert_eq!(api, API);
        assert_eq!(begun.collect_secret(), SECRET);
        let mut state = self.state.lock().unwrap();
        state.waits += 1;
        let mut binding = json!({"name":"Build host","wgPublicKey":state.begin["wg_public_key"],"installPublicKey":point(&state.begin["public_jwk"])});
        if let Some(field) = state.bad_grant {
            binding[field] = match field {
                "wgPublicKey" => STANDARD.encode([3; 32]).into(),
                "installPublicKey" => {
                    let mut point = [0u8; 65];
                    point[0] = 4;
                    STANDARD.encode(point).into()
                }
                _ => panic!("unknown fixture field"),
            };
        }
        let frame = json!({"t":"paired","host":"host_00000000000000000001","team":"team_00000000000000000001","user":"user_00000000000000000001","install":"inst_00000000000000000001",
            "network":{"state":"reserved","tenant":"native_team","mesh":MESH,"device":DEVICE},
            "network_enrollment":{"origin":NATIVE,"code":CODE,"tenantId":"native_team","meshId":MESH,"deviceId":DEVICE,"expiresAt":"2026-10-19T12:10:00.000Z","binding":binding}});
        read_frame(&frame.to_string())
            .map_err(|_| Error::verification("fixture.invalid_frame"))?
            .ok_or_else(|| Error::verification("fixture.missing_frame"))
    }
    fn native_post(&self, origin: &str, path: &str, body: &Value) -> Result<Option<Value>> {
        // Crash recovery has been persisted before either Native operation.
        assert_eq!(pairing::status(&self.path).unwrap()["state"], "network_pending");
        assert!(EnrolledIdentity::load(&self.path).is_err());
        assert_eq!(origin, NATIVE);
        let mut state = self.state.lock().unwrap();
        let enroll = path == format!("/v1/meshes/{MESH}/overlay-server-enrollments");
        if !enroll {
            assert_eq!(path, format!("/v1/overlay-servers/{DEVICE}/signed/policy"));
        }
        assert_eq!(body.as_object().unwrap().len(), if enroll { 7 } else { 3 });
        assert_eq!(body["signedAt"], state.now);
        assert!(body["signedAt"].as_u64().unwrap() > state.begin["issued_at"].as_u64().unwrap());
        let nonce = body["nonce"].as_str().unwrap();
        assert_eq!(URL_SAFE_NO_PAD.decode(nonce).unwrap().len(), 16);
        assert!(state.calls.iter().all(|(_, old)| old["nonce"] != nonce));
        let install = point(&state.begin["public_jwk"]);
        let wg = state.begin["wg_public_key"].as_str().unwrap();
        let (purpose, target, wg_line, name_line) = if enroll {
            assert_eq!(body["code"], CODE);
            assert_eq!(body["name"], "Build host");
            assert_eq!(body["wgPublicKey"], wg);
            assert_eq!(body["installPublicKey"], install);
            ("enroll-overlay-server", MESH, wg, format!("{CODE}:Build host"))
        } else {
            ("overlay-server-policy", DEVICE, "", String::new())
        };
        let message = [
            "cmux-mesh-v1",
            purpose,
            target,
            wg_line,
            &install,
            &name_line,
            &state.now.to_string(),
            nonce,
        ]
        .join("\n");
        let signature =
            URL_SAFE_NO_PAD.encode(STANDARD.decode(body["signature"].as_str().unwrap()).unwrap());
        assert!(
            verify(&state.begin["public_jwk"], message.as_bytes(), &signature),
            "Native cannot verify the daemon's actual signature"
        );
        let wg = wg.to_owned();
        state.calls.push((path.into(), body.clone()));
        if enroll {
            if state.reject_enrollment {
                return Err(Error::rejected("fixture.revoked"));
            }
            state.live = true;
            if state.lose_enrollment_reply {
                state.lose_enrollment_reply = false;
                return Err(Error::unreachable("fixture.lost_enrollment_reply"));
            }
            return Ok(Some(
                json!({"id":DEVICE,"meshId":MESH,"name":"Build host","wgPublicKey":wg,"installPublicKey":install,"kind":"server","transport":"overlay"}),
            ));
        }
        if matches!(state.fault, Fault::Unavailable) {
            return Err(Error::unreachable("fixture.policy_unavailable"));
        }
        if !state.live {
            return Ok(None);
        }
        let mut policy = json!({"tenantId":"native_team","meshId":MESH,"deviceId":DEVICE,"wgPublicKey":wg,"installPublicKey":install,"peers":[],"policyDigest":"fixture"});
        let field = match state.fault {
            Fault::Tenant => Some("tenantId"),
            Fault::Mesh => Some("meshId"),
            Fault::Device => Some("deviceId"),
            Fault::Wg => Some("wgPublicKey"),
            Fault::Install => Some("installPublicKey"),
            _ => None,
        };
        if let Some(field) = field {
            policy[field] = "different-identity".into();
        }
        Ok(Some(policy))
    }
    fn backend_post(
        &self,
        origin: &str,
        path: &str,
        body: &Value,
        bearer: Option<&str>,
    ) -> Result<Value> {
        backend::post(self, origin, path, body, bearer)
    }
}
fn run(api: &Api, progress: &mut Vec<Value>) -> Result<Value> {
    // The human approval wait advanced the clock by three minutes.
    pairing::enroll(
        &api.path,
        API,
        json!({"name":"Build host","platform":"linux","os_version":"test","arch":"aarch64","cmux_version":"test"}),
        None,
        api,
        NOW - 180_000,
        |v| {
            progress.push(v.clone());
            Ok(())
        },
    )
}
fn private_record(path: &Path) -> Value {
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}
fn enroll_count(api: &Api) -> usize {
    api.state
        .lock()
        .unwrap()
        .calls
        .iter()
        .filter(|(path, _)| path.ends_with("/overlay-server-enrollments"))
        .count()
}

#[test]
fn server_pairing_native_signs_with_its_own_keys_and_confirms_before_completing() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api::new(&path);
    let mut progress = vec![];
    let result = run(&api, &mut progress).unwrap();
    assert_eq!(result["state"], "paired");
    assert_eq!(result["network"]["state"], "confirmed");
    assert_eq!(result["network"]["tenant"], "native_team");
    assert_eq!(pairing::status(&path).unwrap(), result);
    let loaded = EnrolledIdentity::load(&path).unwrap();
    assert_eq!(loaded.native_network().unwrap().device, DEVICE);
    let public = format!("{result:?}{progress:?}");
    for private in [CODE, SECRET, "signature", "protected_keys", "installPublicKey", "wgPublicKey"]
    {
        assert!(!public.contains(private));
    }
    let record = private_record(&path);
    assert_eq!(record["schema"], 3);
    assert_eq!(record["native"]["state"], "registered");
    assert_eq!(record["native"]["confirmed_at"], NOW);
    assert!(record["native"].get("response").is_none());
    assert!(!record.to_string().contains(CODE));
    let state = api.state.lock().unwrap();
    assert_eq!(state.begins, 1);
    assert_eq!(state.waits, 1);
    assert_eq!(state.calls.len(), 3);
    assert_eq!(state.backend_calls.len(), 3);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    }
}

#[test]
fn server_pairing_native_backend_failure_keeps_registration_pending_and_link_blocked() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api::new(&path);
    api.state.lock().unwrap().fault = Fault::Backend;
    assert!(
        run(&api, &mut vec![]).is_err(),
        "Native registration alone is not backend confirmation"
    );
    assert_eq!(pairing::status(&path).unwrap()["state"], "network_pending");
    assert!(EnrolledIdentity::load(&path).is_err());
    let record = private_record(&path);
    assert!(record["native"].get("response").is_none(), "discard the spent private invitation");
    assert!(!record.to_string().contains(CODE));
    assert_eq!(enroll_count(&api), 1);
}

#[test]
fn server_pairing_native_legacy_registered_record_still_needs_backend_confirmation() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api::new(&path);
    api.state.lock().unwrap().fault = Fault::Backend;
    let _ = run(&api, &mut vec![]);
    // Schema 2 could finish Native enrollment without ever notifying TeamDO.
    let mut legacy = private_record(&path);
    legacy["schema"] = json!(2);
    legacy["native"].as_object_mut().unwrap().remove("confirmed_at");
    std::fs::write(&path, serde_json::to_vec(&legacy).unwrap()).unwrap();
    assert_eq!(pairing::status(&path).unwrap()["state"], "network_pending");
    assert!(EnrolledIdentity::load(&path).is_err());
    api.state.lock().unwrap().fault = Fault::None;
    assert_eq!(run(&api, &mut vec![]).unwrap()["network"]["state"], "confirmed");
    assert_eq!(private_record(&path)["schema"], 3);
    assert_eq!(api.state.lock().unwrap().calls.len(), 3);
}

#[test]
fn server_pairing_native_lost_backend_reply_retries_fresh_proof_after_invitation_expiry() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api::new(&path);
    api.state.lock().unwrap().lose_backend_reply = true;
    assert!(run(&api, &mut vec![]).is_err());
    let before = private_record(&path);
    assert_eq!(before["schema"], 3);
    assert_eq!(before["native"]["state"], "registered");
    assert!(before["native"].get("confirmed_at").is_none());
    assert_eq!(pairing::status(&path).unwrap()["network"]["state"], "confirmation_pending");
    assert!(!before.to_string().contains(CODE));
    api.state.lock().unwrap().now += 720_000;
    let result = run(&api, &mut vec![]).unwrap();
    assert_eq!(result["network"]["confirmed_at"], NOW);
    let after = private_record(&path);
    assert_eq!(before["public_jwk"], after["public_jwk"]);
    assert_eq!(before["protected_keys"], after["protected_keys"]);
    let state = api.state.lock().unwrap();
    assert_eq!(state.calls.len(), 3, "do not redeem or read Native again");
    assert_eq!(state.backend_calls.len(), 6);
    assert_eq!(state.begins, 1);
    assert_eq!(state.waits, 1);
    for secret in [CODE, SECRET, "fixture-daemon-access", "fixture-must-not-persist"] {
        assert!(!after.to_string().contains(secret));
        assert!(!result.to_string().contains(secret));
    }
    for field in ["signature", "nonce", "access_token", "accountCredential"] {
        let key = format!("\"{field}\":");
        assert!(!after.to_string().contains(&key));
        assert!(!result.to_string().contains(&key));
    }
}

#[test]
fn server_pairing_native_backend_response_must_match_the_reserved_identity_and_operation() {
    for field in [
        "/op",
        "/idempotency_key",
        "/value/host",
        "/value/network/state",
        "/value/network/tenant",
        "/value/network/mesh",
        "/value/network/device",
        "/value/network/confirmed_at",
    ] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pairing/identity.json");
        let api = Api::new(&path);
        api.state.lock().unwrap().backend_fault = Some(field);
        assert_eq!(
            run(&api, &mut vec![]).unwrap_err().message,
            "server.pair.invalid_backend_confirmation"
        );
        assert_eq!(pairing::status(&path).unwrap()["state"], "network_pending");
        assert!(EnrolledIdentity::load(&path).is_err());
        api.state.lock().unwrap().backend_fault = None;
        assert_eq!(run(&api, &mut vec![]).unwrap()["state"], "paired");
        assert_eq!(enroll_count(&api), 1);
    }
}

#[test]
fn server_pairing_native_backend_auth_checks_namespace_expiry_and_token_identity() {
    for fault in [
        "prefix",
        "challenge_install",
        "nonce",
        "challenge_expired",
        "token_team",
        "token_user",
        "token_install",
        "token_expired",
    ] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pairing/identity.json");
        let api = Api::new(&path);
        api.state.lock().unwrap().backend_fault = Some(fault);
        assert_eq!(
            run(&api, &mut vec![]).unwrap_err().message,
            "server.pair.invalid_backend_confirmation"
        );
        assert_eq!(pairing::status(&path).unwrap()["state"], "network_pending");
        assert!(api.state.lock().unwrap().backend_calls.iter().all(|(path, _)| path != "/v1/ops"));
        assert!(EnrolledIdentity::load(&path).is_err());
    }
}

#[test]
fn server_pairing_native_backend_refusals_preserve_recovery_without_echoing_private_errors() {
    for (fault, kind) in [
        ("refused", cmux_server::ExitKind::Rejected),
        ("retryable", cmux_server::ExitKind::Unreachable),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pairing/identity.json");
        let api = Api::new(&path);
        api.state.lock().unwrap().backend_fault = Some(fault);
        let error = run(&api, &mut vec![]).unwrap_err();
        assert_eq!(error.kind, kind);
        assert!(!error.message.contains("private fixture error"));
        assert_eq!(pairing::status(&path).unwrap()["state"], "network_pending");
        assert!(EnrolledIdentity::load(&path).is_err());
    }
}

#[test]
fn server_pairing_native_confirmed_checkpoint_is_read_only_on_subsequent_pair_commands() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api::new(&path);
    let result = run(&api, &mut vec![]).unwrap();
    let before = std::fs::read(&path).unwrap();
    api.state.lock().unwrap().fault = Fault::Backend;
    assert_eq!(run(&api, &mut vec![]).unwrap(), result);
    assert_eq!(std::fs::read(&path).unwrap(), before);
    assert_eq!(api.state.lock().unwrap().backend_calls.len(), 3);
    assert!(EnrolledIdentity::load(&path).is_ok());
}

#[test]
fn server_pairing_native_lost_reply_recovers_after_code_expiry_without_new_identity() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api::new(&path);
    api.state.lock().unwrap().lose_enrollment_reply = true;
    assert!(run(&api, &mut vec![]).is_err());
    assert_eq!(pairing::status(&path).unwrap()["state"], "network_pending");
    assert_eq!(EnrolledIdentity::load(&path).err().unwrap().message, "server.pair.network_pending");
    let before = private_record(&path);
    api.state.lock().unwrap().now += 720_000;
    assert_eq!(run(&api, &mut vec![]).unwrap()["state"], "paired");
    let after = private_record(&path);
    assert_eq!(before["public_jwk"], after["public_jwk"]);
    assert_eq!(before["protected_keys"], after["protected_keys"]);
    assert_eq!(enroll_count(&api), 1);
    assert_eq!(api.state.lock().unwrap().begins, 1);
}

#[test]
fn server_pairing_native_wrong_grant_key_is_refused_before_native_io_or_completion() {
    for field in ["wgPublicKey", "installPublicKey"] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pairing/identity.json");
        let api = Api::new(&path);
        api.state.lock().unwrap().bad_grant = Some(field);
        assert!(run(&api, &mut vec![]).is_err());
        assert_eq!(pairing::status(&path).unwrap()["state"], "pending");
        assert!(api.state.lock().unwrap().calls.is_empty());
        assert!(private_record(&path)["paired"].is_null());
    }
}

#[test]
fn server_pairing_native_policy_must_confirm_tenant_locator_and_both_keys() {
    for fault in [Fault::Tenant, Fault::Mesh, Fault::Device, Fault::Wg, Fault::Install] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pairing/identity.json");
        let api = Api::new(&path);
        api.state.lock().unwrap().fault = fault;
        assert!(run(&api, &mut vec![]).is_err());
        assert_eq!(pairing::status(&path).unwrap()["state"], "network_pending");
        assert!(EnrolledIdentity::load(&path).is_err());
        api.state.lock().unwrap().fault = Fault::None;
        assert_eq!(run(&api, &mut vec![]).unwrap()["state"], "paired");
        assert_eq!(enroll_count(&api), 1);
    }
}

#[test]
fn server_pairing_native_policy_failure_or_expired_unused_code_preserves_pending_state() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api::new(&path);
    api.state.lock().unwrap().fault = Fault::Unavailable;
    assert!(run(&api, &mut vec![]).is_err());
    let before = std::fs::read(&path).unwrap();
    {
        let mut state = api.state.lock().unwrap();
        state.now += 720_000;
        state.fault = Fault::None;
    }
    assert_eq!(run(&api, &mut vec![]).unwrap_err().message, "server.pair.network_code_expired");
    assert_eq!(std::fs::read(&path).unwrap(), before);
    assert_eq!(enroll_count(&api), 0);
    assert_eq!(api.state.lock().unwrap().begins, 1);
}

#[test]
fn server_pairing_native_revoked_reserved_identity_is_never_reported_as_paired() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api::new(&path);
    api.state.lock().unwrap().lose_enrollment_reply = true;
    assert!(run(&api, &mut vec![]).is_err());
    {
        let mut state = api.state.lock().unwrap();
        state.live = false;
        state.reject_enrollment = true;
    }
    assert_eq!(run(&api, &mut vec![]).unwrap_err().message, "fixture.revoked");
    assert_eq!(pairing::status(&path).unwrap()["state"], "network_pending");
    assert!(EnrolledIdentity::load(&path).is_err());
    assert_eq!(api.state.lock().unwrap().begins, 1);
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn server_pairing_native_cli_reports_pending_registration_without_mutating_it() {
    for backend_pending in [false, true] {
        let home = tempfile::tempdir().unwrap();
        #[cfg(target_os = "linux")]
        let path = home.path().join("state/cmux/server/pairing/identity.json");
        #[cfg(target_os = "macos")]
        let path =
            home.path().join("Library/Application Support/cmux/server/pairing/identity.json");
        let api = Api::new(&path);
        if backend_pending {
            api.state.lock().unwrap().lose_backend_reply = true;
        } else {
            api.state.lock().unwrap().lose_enrollment_reply = true;
        }
        assert!(run(&api, &mut vec![]).is_err());
        let before = std::fs::read(&path).unwrap();
        for machine in [false, true] {
            let mut command = std::process::Command::new(env!("CARGO_BIN_EXE_cmux-server"));
            command.args(["pair", "status"]);
            if machine {
                command.arg("--json");
            }
            let output = command
                .env_clear()
                .env("HOME", home.path())
                .env("XDG_STATE_HOME", home.path().join("state"))
                .env("CMUX_SERVER_MODE", "user")
                .env("LANG", "ja_JP.UTF-8")
                .current_dir(home.path())
                .output()
                .unwrap();
            assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
            if machine {
                assert_eq!(
                    serde_json::from_slice::<Value>(&output.stdout).unwrap(),
                    pairing::status(&path).unwrap()
                );
            } else {
                assert_eq!(String::from_utf8(output.stdout).unwrap(), "ネットワーク登録待ち\n");
            }
        }
        assert_eq!(std::fs::read(&path).unwrap(), before);
    }
}
