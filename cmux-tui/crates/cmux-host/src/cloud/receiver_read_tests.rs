//! Execute the receiving read through real install signatures and the generated
//! DTO, then feed the resulting authority into the real Native JWT verifier.
use std::cell::RefCell;
use std::rc::Rc;
use std::time::{Duration, Instant};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use cmux_link::dial::Service;
use cmux_link::native_token::NativeTokenVerifier;
use cmux_link::token::{Expected, TokenRefused, TokenVerifier};
use cmux_server_core::install_key::{InstallKey, SystemRandom, verify};
use serde_json::{Value, json};

use super::client::{CloudClient, Http};
use super::receiver::{REQUEST_BUDGET, install_point};
use super::wire::{Bound, Env};

#[cfg(target_os = "linux")]
#[path = "receiver_producer_root_tests.rs"]
mod producer_root;

const NOW: u64 = 1_792_000_010_000;
const MACHINE: &str = "vm_00000000000000000004";
const INSTALL: &str = "inst_00000000000000000004";
const USER: &str = "user_00000000000000000004";
const TEAM: &str = "team_00000000000000000001";
const GRANT: &str = "grant_00000000000000000004";
type Deadlines = Rc<RefCell<Vec<Instant>>>;
type ElapsedValue = std::sync::Arc<std::sync::Mutex<Option<Duration>>>;

fn elapsed_clock() -> (cmux_link::elapsed::Elapsed, ElapsedValue) {
    let value = std::sync::Arc::new(std::sync::Mutex::new(Some(Duration::from_secs(10))));
    let source = value.clone();
    let elapsed = cmux_link::elapsed::Elapsed::capture(move || *source.lock().unwrap()).unwrap();
    (elapsed, value)
}

#[test]
fn vm_receiver_snapshot_expires_when_elapsed_time_advances_and_active_time_is_frozen() {
    let (mut client, wg, _) = setup(|_, _| {});
    let (elapsed, clock) = elapsed_clock();
    let snapshot = client.receiving_policy_with_elapsed(&wg, NOW, Instant::now(), elapsed).unwrap();
    let active = Instant::now();
    assert!(snapshot.time(active).is_some(), "the original authenticated read must be live first");
    *clock.lock().unwrap() = Some(Duration::from_secs(40));
    assert_eq!(snapshot.elapsed(active), Some(Duration::from_secs(30)));
    assert!(snapshot.time(active).is_none(), "a frozen active clock retained expired authority");
    assert!(snapshot.public_reply(active).is_err());
}

#[test]
fn vm_receiver_snapshot_debits_suspended_time_from_issuer_time_and_public_remaining_budget() {
    let (mut client, wg, _) = setup(|_, _| {});
    let (elapsed, clock) = elapsed_clock();
    let snapshot = client.receiving_policy_with_elapsed(&wg, NOW, Instant::now(), elapsed).unwrap();
    let active = Instant::now();
    *clock.lock().unwrap() = Some(Duration::from_secs(11));
    let time = snapshot.time(active).unwrap();
    assert!((NOW + 1_000..NOW + 2_000).contains(&time.unix_ms), "suspend extended issuer time");
    let public = snapshot.public_reply(active).unwrap();
    assert!(public["value"]["remaining_ms"].as_u64().unwrap() <= 29_000);
}

#[test]
fn vm_receiver_client_request_budget_includes_suspend_before_the_next_http_call() {
    let (elapsed, clock) = elapsed_clock();
    let after = Rc::new(move || *clock.lock().unwrap() = Some(Duration::from_secs(31)));
    let (mut client, wg, calls) = setup_recorded(|_, _| {}, |_, _, _| {}, Some(after));
    assert!(
        client.receiving_policy_with_elapsed(&wg, NOW, Instant::now(), elapsed).is_err(),
        "a request older than its total budget reached keyset lookup and publication"
    );
    assert_eq!(calls.borrow().len(), 3, "the expired request sent another HTTP call");
}

#[test]
fn vm_receiver_client_auth_stops_when_total_elapsed_budget_expires() {
    let (elapsed, clock) = elapsed_clock();
    let after = Rc::new(move || *clock.lock().unwrap() = Some(Duration::from_secs(31)));
    let (mut client, wg, calls) = setup_tweaked(
        |_, _| {},
        |_, _, _| {},
        None,
        |http| {
            http.after_challenge = Some(after);
        },
    );
    assert!(client.receiving_policy_with_elapsed(&wg, NOW, Instant::now(), elapsed).is_err());
    assert_eq!(
        calls.borrow().len(),
        1,
        "expired authentication sent a token request after its challenge"
    );
}

#[test]
fn vm_receiver_snapshot_clock_loss_cannot_reopen_when_elapsed_clock_recovers() {
    let (mut client, wg, _) = setup(|_, _| {});
    let (elapsed, clock) = elapsed_clock();
    let snapshot = client.receiving_policy_with_elapsed(&wg, NOW, Instant::now(), elapsed).unwrap();
    let active = Instant::now();
    *clock.lock().unwrap() = None;
    assert!(snapshot.time(active).is_none(), "an unavailable clock retained policy");
    *clock.lock().unwrap() = Some(Duration::from_secs(11));
    assert!(snapshot.time(active).is_none(), "the old request recovered after losing its clock");
}

fn fixture() -> Value {
    serde_json::from_str(include_str!("../../../../../schemas/link-token/native.json")).unwrap()
}

pub(super) fn public_fixture()
-> (super::receiver::ReceiverBinding, cmux_link::keyset::Keyset, Vec<u8>) {
    let (mut client, wg, _) = setup(|_, _| {});
    let binding = super::receiver::ReceiverBinding::from_original(
        client.bound(),
        &wg,
        &client.install_public_jwk(),
    )
    .unwrap();
    let snapshot = client.receiving_policy(&wg, NOW).unwrap();
    (
        binding,
        snapshot.keys().clone(),
        serde_json::to_vec(&snapshot.public_reply(Instant::now()).unwrap()).unwrap(),
    )
}

#[derive(Clone)]
struct Server {
    public: Value,
    policy: Vec<u8>,
    keys: Vec<u8>,
    status: u16,
    deadlines: Deadlines,
    after_policy: Option<Rc<dyn Fn()>>,
    after_challenge: Option<Rc<dyn Fn()>>,
    lifecycle: Option<Rc<RefCell<Lifecycle>>>,
}
struct Lifecycle {
    phase: String,
    generation: String,
    counter: u64,
}
impl Http for Server {
    fn post(&self, _: &str, _: &Value, _: Option<&str>) -> Result<(u16, Value), String> {
        panic!("receiving read used an unbounded transport")
    }
    fn request_with_deadline(
        &self,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        deadline: &cmux_server::cloud_http::RequestDeadline,
    ) -> Result<(u16, Vec<u8>), String> {
        self.request_until(url, body, bearer, deadline.active())
    }
    fn request_until(
        &self,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        deadline: Instant,
    ) -> Result<(u16, Vec<u8>), String> {
        assert!(url.starts_with(Env::Dev.api_origin()));
        self.deadlines.borrow_mut().push(deadline);
        let value = if url.ends_with("/v1/auth/challenge") {
            assert!(bearer.is_none());
            if let Some(after) = &self.after_challenge {
                after();
            }
            json!({ "install":INSTALL, "nonce":"00000000000000000000000000000001",
                "message_prefix":format!("cmux-auth-v1\ndevelopment\n{INSTALL}\n") })
        } else if url.ends_with("/v1/auth/token") {
            assert!(bearer.is_none());
            assert!(verify(
                &self.public,
                format!("cmux-auth-v1\ndevelopment\n{INSTALL}\n00000000000000000000000000000001")
                    .as_bytes(),
                body.unwrap()["signature"].as_str().unwrap()
            ));
            json!({ "user":USER,"install":INSTALL,"team":TEAM,"grant":GRANT,"token_type":"Bearer",
                "access_token":"private-test-bearer","expires_at":NOW+600_000 })
        } else if url.ends_with("/v1/ops") {
            assert_eq!(bearer, Some("private-test-bearer"));
            let request = body.unwrap();
            assert_eq!(request["op"], "cloud.vm.receiver.lifecycle");
            assert!(request.get("idempotency_key").is_none());
            let params = &request["params"];
            assert_eq!(params["machine"], MACHINE);
            let mut state =
                self.lifecycle.as_ref().expect("lifecycle fixture enabled").borrow_mut();
            let phase = params["phase"].as_str().unwrap();
            if phase != "read" {
                assert_eq!(params["expected"], state.generation);
            }
            match phase {
                "read" => {}
                "begin" => {
                    assert!(state.phase == "idle" || state.phase == "stopped");
                    let nonce = params["attempt"].as_str().unwrap();
                    assert_eq!(nonce.len(), 32);
                    state.counter += 1;
                    state.generation = format!("{:064x}", state.counter);
                    state.phase = "starting".into();
                }
                "ready" => {
                    assert!(state.phase == "starting" || state.phase == "ready");
                    state.phase = "ready".into();
                }
                "end" => state.phase = "stopped".into(),
                _ => panic!("unknown lifecycle phase"),
            }
            json!({"ok":true,"op":"cloud.vm.receiver.lifecycle","value":{"machine":MACHINE,"generation":state.generation,"phase":state.phase},
                "transaction":"fixture-transaction","idempotency_key":"","replayed":false,"stream":"","sequence":0})
        } else if url.ends_with("/v1/read") {
            assert_eq!(bearer, Some("private-test-bearer"));
            assert_eq!(body.unwrap()["params"], json!({"machine":MACHINE}));
            if let Some(after) = &self.after_policy {
                after();
            }
            let mut policy = self.policy.clone();
            if let Some(state) = &self.lifecycle {
                let state = state.borrow();
                let mut value: Value = serde_json::from_slice(&policy).unwrap();
                value["value"]["receiver_generation"] =
                    if state.phase == "starting" || state.phase == "ready" {
                        state.generation.clone().into()
                    } else {
                        Value::Null
                    };
                policy = serde_json::to_vec(&value).unwrap();
            }
            return Ok((self.status, policy));
        } else {
            assert!(url.ends_with("/v1/cloud/keyset"));
            assert!(body.is_none() && bearer.is_none());
            return Ok((200, self.keys.clone()));
        };
        Ok((200, serde_json::to_vec(&value).unwrap()))
    }
}

fn setup(change: impl FnOnce(&mut Value, &mut Value)) -> (CloudClient<Server>, String, Deadlines) {
    setup_recorded(change, |_, _, _| {}, None)
}

fn setup_recorded(
    change: impl FnOnce(&mut Value, &mut Value),
    record: impl FnOnce(&InstallKey, &Bound, &str),
    after_policy: Option<Rc<dyn Fn()>>,
) -> (CloudClient<Server>, String, Deadlines) {
    setup_tweaked(change, record, after_policy, |_| {})
}

fn setup_tweaked(
    change: impl FnOnce(&mut Value, &mut Value),
    record: impl FnOnce(&InstallKey, &Bound, &str),
    after_policy: Option<Rc<dyn Fn()>>,
    tweak: impl FnOnce(&mut Server),
) -> (CloudClient<Server>, String, Deadlines) {
    let key = InstallKey::generate(&SystemRandom::new()).unwrap();
    let f = fixture();
    let claims = &f["claims"];
    let network = &claims["network"];
    let bound = Bound {
        machine: MACHINE.into(),
        team: TEAM.into(),
        host: claims["aud"].as_str().unwrap().into(),
        epoch: 4,
        install: INSTALL.into(),
        user: USER.into(),
        grant: GRANT.into(),
        env: Env::Dev,
        api_origin: Env::Dev.api_origin().into(),
        keyset: Value::Null,
        bound_at: NOW,
    };
    let wg = STANDARD.encode(
        x25519_dalek::PublicKey::from(&x25519_dalek::StaticSecret::from([9u8; 32])).as_bytes(),
    );
    record(&key, &bound, &wg);
    let peer_key = InstallKey::generate(&SystemRandom::new()).unwrap();
    let mut policy = json!({ "op":"cloud.vm.network_policy", "stream":format!("cloud:{TEAM}"),"revision":"1","value":{
        "schema_version":2,"receiver_generation":"a".repeat(64),"machine":MACHINE,"host":bound.host,"epoch":4,"user":USER,"install":INSTALL,"team":TEAM,
        "origin":"https://native.example.com","tenant":network["tenant"],"mesh":network["mesh"],
        "vm":"vm_00000000000000000000000004","ipv4":"10.2.0.4","wg_public_key":wg,
        "install_public_key":install_point(&key.public_jwk()).unwrap(), "authority_version":"a".repeat(64),
        "checked_at":NOW,"expires_at":NOW+30_000,"acl_version":network["acl_version"],"policy_digest":"b".repeat(64),
        "peers":[{ "host":network["host"],"user":network["user"],"install":claims["sub"],"device":network["device"],
            "wg_public_key":network["wg_public_key"],"install_public_key":install_point(&peer_key.public_jwk()).unwrap(),
            "authority_version":network["authority_version"],"services":["daemon","ssh"] }] }});
    let mut keys = json!({"ok":true,"value":{"version":"0000000000000001","keys":{ f["kid"].as_str().unwrap(): {
        "kty":"OKP","crv":"Ed25519","alg":"EdDSA","kid":f["kid"],"x":f["public_key"] }}}});
    change(&mut policy, &mut keys);
    let deadlines = Rc::new(RefCell::new(Vec::new()));
    let mut http = Server {
        public: key.public_jwk(),
        policy: serde_json::to_vec(&policy).unwrap(),
        keys: serde_json::to_vec(&keys).unwrap(),
        status: 200,
        deadlines: deadlines.clone(),
        after_policy,
        after_challenge: None,
        lifecycle: None,
    };
    tweak(&mut http);
    (CloudClient::new(http, bound, key), wg, deadlines)
}

#[test]
fn vm_receiver_client_read_drives_real_backend_signed_token_verification() {
    let (mut client, wg, calls) = setup(|_, _| {});
    // A badly skewed local wall clock must not extend or invalidate issuer time.
    let snapshot = client.receiving_policy(&wg, NOW + 3_600_000).unwrap();
    let time = snapshot.time(Instant::now()).unwrap();
    assert!((NOW..NOW + 1000).contains(&time.unix_ms));
    let receiver =
        NativeTokenVerifier::new(snapshot.keys().clone(), move || Some(time), 2).unwrap();
    let mut policy = snapshot.native_policy();
    assert_eq!(policy.issuer, "cmux:cloud:development");
    receiver.replace_authority(policy.clone()).unwrap();
    let f = fixture();
    let expected = Expected {
        host: client.bound().host.as_str(),
        epoch: 4,
        service: Service::Daemon,
        peer_key: &[b'a'; 32],
    };
    // The backend interoperability fixture is explicitly signed for `test`.
    // The production projection must first refuse that other environment.
    assert_eq!(
        receiver.verify(f["token"].as_str().unwrap(), &expected),
        Err(TokenRefused::Invalid)
    );
    policy.issuer = f["claims"]["iss"].as_str().unwrap().into();
    let receiver =
        NativeTokenVerifier::new(snapshot.keys().clone(), move || Some(time), 2).unwrap();
    receiver.replace_authority(policy).unwrap();
    let verified = receiver.verify(f["token"].as_str().unwrap(), &expected).unwrap();
    assert_eq!(verified.issued_at_ms, 1_792_000_000_000);
    assert_eq!(
        receiver.verify(f["token"].as_str().unwrap(), &expected),
        Err(TokenRefused::Replayed)
    );
    let public = snapshot.public_reply(Instant::now()).unwrap().to_string();
    assert!(!public.contains("private-test-bearer") && !public.contains(GRANT));
    let calls = calls.borrow();
    assert_eq!(calls.len(), 4);
    assert!(
        calls.iter().all(|d| *d == calls[0]),
        "auth, policy and keyset must share one deadline"
    );
}

macro_rules! refuses {
    ($name:ident,$change:expr) => {
        #[test]
        fn $name() {
            let (mut client, wg, _) = setup($change);
            assert!(client.receiving_policy(&wg, NOW).is_err());
        }
    };
}
refuses!(vm_receiver_client_read_refuses_rebound_machine, |p, _| p["value"]["machine"] =
    "vm_00000000000000000005".into());
refuses!(vm_receiver_client_read_refuses_changed_epoch, |p, _| p["value"]["epoch"] = 5.into());
refuses!(vm_receiver_client_read_refuses_self_wg_replacement, |p, _| p["value"]["wg_public_key"] =
    STANDARD.encode([8u8; 32]).into());
refuses!(
    vm_receiver_client_read_refuses_self_install_replacement,
    |p, _| p["value"]["install_public_key"] = STANDARD.encode([4u8; 65]).into()
);
refuses!(vm_receiver_client_read_refuses_wrong_stream, |p, _| p["stream"] =
    "cloud:another-team".into());
refuses!(vm_receiver_client_read_refuses_wrong_operation, |p, _| p["op"] =
    "cloud.vm.self.get".into());
refuses!(vm_receiver_client_read_refuses_long_lease, |p, _| p["value"]["expires_at"] =
    (NOW + 30_001).into());
refuses!(vm_receiver_client_read_refuses_empty_lease, |p, _| p["value"]["expires_at"] = NOW.into());
refuses!(vm_receiver_client_read_refuses_missing_generation, |p, _| {
    p["value"].as_object_mut().unwrap().remove("receiver_generation");
});
refuses!(vm_receiver_client_read_refuses_unsafe_number, |p, _| p["value"]["acl_version"] =
    9_007_199_254_740_992i64.into());
refuses!(
    vm_receiver_client_read_refuses_unknown_service,
    |p, _| p["value"]["peers"][0]["services"] = json!(["owner_session"])
);
refuses!(
    vm_receiver_client_read_refuses_daemon_without_ssh,
    |p, _| p["value"]["peers"][0]["services"] = json!(["daemon"])
);
refuses!(
    vm_receiver_client_read_refuses_duplicate_service,
    |p, _| p["value"]["peers"][0]["services"] = json!(["ssh", "ssh"])
);
refuses!(vm_receiver_client_read_refuses_duplicate_peer, |p, _| {
    let peer = p["value"]["peers"][0].clone();
    p["value"]["peers"].as_array_mut().unwrap().push(peer);
});
refuses!(vm_receiver_client_read_refuses_oversize_peer_set, |p, _| {
    let peer = p["value"]["peers"][0].clone();
    p["value"]["peers"] = vec![peer; 129].into();
});
refuses!(vm_receiver_client_read_refuses_insecure_native_origin, |p, _| p["value"]["origin"] =
    "http://native.example.com".into());
refuses!(vm_receiver_client_read_refuses_native_origin_path, |p, _| p["value"]["origin"] =
    "https://native.example.com/path".into());
refuses!(vm_receiver_client_read_refuses_private_keyset, |_, k| {
    let kid = fixture()["kid"].as_str().unwrap().to_owned();
    k["value"]["keys"][&kid]["d"] = "private".into();
});
refuses!(vm_receiver_client_read_refuses_empty_keyset, |_, k| k["value"]["keys"] = json!({}));

#[test]
fn vm_receiver_client_read_deadline_debits_auth_and_stalled_response_time() {
    let (mut client, wg, _) = setup(|_, _| {});
    let started = Instant::now() - REQUEST_BUDGET;
    assert!(client.receiving_policy_at(&wg, NOW, started).is_err());
    let snapshot = client.receiving_policy(&wg, NOW).unwrap();
    assert!(snapshot.time(snapshot.expires()).is_none());
    assert!(snapshot.public_reply(snapshot.expires()).is_err());
    assert!(snapshot.time(snapshot.expires() - Duration::from_millis(1)).is_some());
}

#[test]
fn vm_receiver_client_read_refuses_duplicate_raw_fields_and_oversized_bodies() {
    for case in ["policy", "keyset", "oversized", "redirect", "forbidden"] {
        let (mut client, wg, calls) = setup_tweaked(
            |_, _| {},
            |_, _, _| {},
            None,
            |http| match case {
                "policy" => {
                    let text = String::from_utf8(http.policy.clone()).unwrap();
                    http.policy =
                        text.replacen("\"epoch\":4", "\"epoch\":5,\"epoch\":4", 1).into_bytes();
                    assert!(http.policy.len() > text.len());
                }
                "keyset" => {
                    let text = String::from_utf8(http.keys.clone()).unwrap();
                    http.keys =
                        text.replacen("\"ok\":true", "\"ok\":false,\"ok\":true", 1).into_bytes();
                    assert!(http.keys.len() > text.len());
                }
                "oversized" => http.policy = vec![b' '; 1024 * 1024 + 1],
                "redirect" => http.status = 307,
                "forbidden" => http.status = 403,
                _ => unreachable!(),
            },
        );
        assert!(client.receiving_policy(&wg, NOW).is_err(), "{case}");
        assert!(calls.borrow().len() <= 4, "a refusal retried or escaped its request budget");
    }
}

#[test]
fn vm_receiver_client_read_projects_only_public_generated_fields() {
    let (mut client, wg, _) = setup(|p, _| {
        p["value"]["private_key"] = "must-not-be-forwarded".into();
        p["value"]["peers"][0]["grant"] = "must-not-be-forwarded".into();
        p["value"]["peers"][0]["services"] = json!(["ssh"]);
        p["value"]["tenant"] = "Tenant_Uppercase-1".into();
    });
    let snapshot = client.receiving_policy(&wg, NOW).unwrap();
    let reply = snapshot.public_reply(Instant::now()).unwrap();
    assert!(!reply.to_string().contains("must-not-be-forwarded"));
    assert_eq!(snapshot.native_policy().peers[0].services, vec![Service::Ssh]);
}

#[cfg(target_os = "linux")]
#[test]
fn vm_receiver_client_read_rechecks_private_files_after_network_without_rebinding() {
    rechecks_files(false);
}

#[cfg(target_os = "linux")]
#[test]
fn native_receiver_private_bootstrap_rechecks_original_files_around_cloud_read() {
    rechecks_files(true);
}

#[cfg(target_os = "linux")]
fn rechecks_files(private: bool) {
    use super::wire::{BOUND_FILE, INSTALL_KEY_FILE, STATE_DIR, WG_KEY_FILE};
    use crate::config::Paths;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    for change in ["unchanged", "rebound", "key_removed", "public_file"] {
        let root = tempfile::tempdir().unwrap();
        let paths = Paths::new(root.path());
        let after_paths = paths.clone();
        let (mut client, _, _) = setup_recorded(
            |_, _| {},
            |key, bound, wg| {
                for (name, value) in [
                    (BOUND_FILE, serde_json::to_value(bound).unwrap()),
                    (
                        INSTALL_KEY_FILE,
                        json!({"instance_id":"instance-a","pkcs8":key.pkcs8_base64url()}),
                    ),
                    (
                        WG_KEY_FILE,
                        json!({"instance_id":"instance-a","private_key":STANDARD.encode([9u8;32]),"public_key":wg}),
                    ),
                ] {
                    let path = paths.at(name);
                    fs::create_dir_all(path.parent().unwrap()).unwrap();
                    fs::write(&path, value.to_string()).unwrap();
                    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
                }
                fs::set_permissions(paths.at(STATE_DIR), fs::Permissions::from_mode(0o700))
                    .unwrap();
            },
            Some(Rc::new(move || match change {
                "rebound" => {
                    let path = after_paths.at(BOUND_FILE);
                    let mut value: Value =
                        serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
                    value["epoch"] = 5.into();
                    fs::write(path, value.to_string()).unwrap();
                }
                "key_removed" => fs::remove_file(after_paths.at(INSTALL_KEY_FILE)).unwrap(),
                "public_file" => fs::set_permissions(
                    after_paths.at(WG_KEY_FILE),
                    fs::Permissions::from_mode(0o644),
                )
                .unwrap(),
                _ => {}
            })),
        );
        let result = if private {
            super::receiver_files::bootstrap(&paths, "instance-a", &mut client, NOW).map(|b| {
                assert_eq!(b.binding().machine, MACHINE);
                assert!(!b.keys().keys.is_empty());
                let encoded = b.encode().unwrap();
                let decoded = super::private_bootstrap::NativeBootstrap::decode(&encoded).unwrap();
                assert_eq!(*decoded.into_parts().2, [9; 32]);
                json!({"value":{"policy":{"machine":b.binding().machine}}})
            })
        } else {
            super::receiver_files::reply(&paths, "instance-a", &mut client, NOW)
        };
        assert_eq!(result.is_ok(), change == "unchanged", "{change}");
        if let Ok(reply) = result {
            assert_eq!(reply["value"]["policy"]["machine"], MACHINE);
            assert!(!reply.to_string().contains("private-test-bearer"));
        }
        if change == "key_removed" {
            assert!(!paths.at(INSTALL_KEY_FILE).exists(), "read recreated a removed key");
        }
    }
}
