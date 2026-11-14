//! Parity with the interim Bun agent (web/tests/vm-image-vm-agent.test.ts):
//! what the Cloud role sends, when, and to where, against a fake server
//! that answers with the cloud-vectors.json shapes.

use std::cell::RefCell;
use std::collections::VecDeque;
use std::rc::Rc;

use cmux_server_core::install_key::{SystemRandom, verify};
use serde_json::{Value, json};

use super::client::{
    BindResult, Http, MemoryStore, Store, bind_machine, ensure_install_key, record_owner_kind,
};
use super::wire::*;

const DEV: &str = "https://cmux-api-development.debussy.workers.dev";
const TEAM: &str = "team_t0000000000000000001";
const MACHINE: &str = "vm_m0000000000000000004";
const INSTALL: &str = "inst_v0000000000000000004";
const USER: &str = "user_u0000000000000000001";
const T0: u64 = 1_790_000_000_000;

fn bind_text() -> String {
    json!({
        "team": TEAM,
        "machine": MACHINE,
        "bind_token": "bt_vector_one_time_token_000000000000000000",
        "api_origin": DEV,
        "env": "dev",
    })
    .to_string()
}

#[derive(Clone, Debug)]
struct Seen {
    url: String,
    bearer: Option<String>,
    body: Value,
}

#[derive(Default)]
struct FakeState {
    seen: Vec<Seen>,
    bind_calls: usize,
    registered: Option<Value>,
    prefix_env: String,
    ops: VecDeque<(u16, Value)>,
    empty_posts: Vec<Seen>,
}

#[derive(Clone, Default)]
struct Fake(Rc<RefCell<FakeState>>);

impl Fake {
    fn new() -> Fake {
        let fake = Fake::default();
        fake.0.borrow_mut().prefix_env = "development".to_owned();
        fake
    }
}

fn applied() -> Value {
    json!({ "ok": true, "op": "cloud.vm.status.report", "value": { "applied": true } })
}

impl Http for Fake {
    fn post(&self, url: &str, body: &Value, bearer: Option<&str>) -> Result<(u16, Value), String> {
        let mut st = self.0.borrow_mut();
        st.seen.push(Seen {
            url: url.to_owned(),
            bearer: bearer.map(str::to_owned),
            body: body.clone(),
        });
        let path = url.strip_prefix(DEV).ok_or_else(|| format!("unexpected origin in {url}"))?;
        match path {
            "/v1/cloud/bind" => {
                st.bind_calls += 1;
                if st.bind_calls == 1 {
                    st.registered = Some(body["install_public_jwk"].clone());
                    Ok((
                        200,
                        json!({ "ok": true, "value": {
                            "machine": MACHINE, "host": "host_h0000000000000000004", "epoch": 1,
                            "keyset": { "version": "0123456789abcdef", "keys": {} },
                            "install": { "id": INSTALL, "user": USER, "grant": "grant_v000000000000000004" },
                        }}),
                    ))
                } else {
                    Ok((
                        403,
                        json!({ "ok": false, "error": { "code": "auth.forbidden", "message": "bind refused" } }),
                    ))
                }
            }
            "/v1/auth/challenge" => Ok((
                200,
                json!({
                    "install": body["install"], "nonce": "nonce-1", "expires_at": T0 + 60_000,
                    "message_prefix": format!("cmux-auth-v1\n{}\n{}\n", st.prefix_env, body["install"].as_str().unwrap_or("")),
                }),
            )),
            "/v1/auth/token" => {
                let message = format!("cmux-auth-v1\ndevelopment\n{INSTALL}\nnonce-1");
                let jwk = st.registered.clone().unwrap_or(Value::Null);
                if !verify(&jwk, message.as_bytes(), body["signature"].as_str().unwrap_or("")) {
                    return Ok((403, json!({ "code": "auth.forbidden" })));
                }
                Ok((
                    200,
                    json!({ "access_token": "tok-1", "token_type": "Bearer", "expires_at": T0 + 3_600_000,
                        "user": USER, "install": INSTALL, "grant": "grant_v000000000000000004", "team": TEAM }),
                ))
            }
            "/v1/ops" => Ok(st.ops.pop_front().unwrap_or((200, applied()))),
            _ => Ok((404, json!({}))),
        }
    }

    fn post_empty(&self, url: &str, bearer: Option<&str>) -> Result<(u16, Value), String> {
        let mut st = self.0.borrow_mut();
        st.empty_posts.push(Seen {
            url: url.to_owned(),
            bearer: bearer.map(str::to_owned),
            body: Value::Null,
        });
        let path = url.strip_prefix(DEV).ok_or_else(|| format!("unexpected origin in {url}"))?;
        match path {
            "/v1/cloud/machines/vm_m0000000000000000004/carrier" => Ok((
                200,
                json!({ "ok": true, "value": {
                    "relay": "relay+do://relay.example",
                    "slot": "AAAAAAAAAAAAAAAAAAAAAA",
                    "ticket": "ticket-1",
                    "expires_at": T0 + 60_000,
                }}),
            )),
            _ => Ok((404, json!({}))),
        }
    }
}

fn daemon() -> DaemonInfo {
    DaemonInfo {
        version: "0.40.0".to_owned(),
        capabilities: vec!["terminal".to_owned(), "files".to_owned()],
    }
}

#[test]
fn bind_posts_the_vector_fields_writes_bound_then_removes_bind() {
    let fake = Fake::new();
    let rng = SystemRandom::new();
    let mut store = MemoryStore::default();
    store.write(BIND_FILE, &bind_text(), 0o600).unwrap();
    let key = ensure_install_key(&mut store, "i-aaa", &rng).unwrap().key;
    let result = bind_machine(&mut store, &fake, &key, "AAAA=", &daemon(), None, T0);
    assert!(matches!(result, BindResult::Bound(_)), "{result:?}");
    let seen = fake.0.borrow().seen[0].clone();
    assert_eq!(seen.url, format!("{DEV}/v1/cloud/bind"));
    assert_eq!(seen.bearer, None, "the one-time token is the credential");
    let mut keys: Vec<&String> = seen.body.as_object().unwrap().keys().collect();
    keys.sort();
    assert_eq!(
        keys,
        ["bind_token", "daemon", "install_public_jwk", "machine", "team", "wg_public_key"]
    );
    assert_eq!(seen.body["install_public_jwk"], key.public_jwk());
    let bound: Value = serde_json::from_str(&store.read(BOUND_FILE).unwrap()).unwrap();
    assert_eq!(bound["machine"], MACHINE);
    assert_eq!(bound["install"], INSTALL);
    assert_eq!(bound["user"], USER);
    assert_eq!(bound["env"], "dev");
    assert_eq!(store.read(BIND_FILE), None);
    assert_eq!(store.mode_of(BOUND_FILE), Some(0o600));
    let identity = crate::identity::enrolled(&store, "i-aaa").unwrap();
    assert_eq!(identity.machine, MACHINE);
    assert_eq!(identity.instance_id, "i-aaa");
}

const SLOT: &str = "AAAAAAAAAAAAAAAAAAAAAA";

fn bind_with_carrier(machine: &str) -> String {
    let mut bind: Value = serde_json::from_str(&bind_text()).unwrap();
    bind["carrier"] =
        json!({"relay": "relay+do://relay.cmux.dev", "machine": machine, "slot": SLOT});
    bind.to_string()
}

/// A bind with a `carrier` section sends the daemon's Noise key and keeps
/// the route as carrier.json (0600) with the team, the grant issuer and the
/// bind answer's keyset.
#[test]
fn a_carrier_bind_sends_the_noise_key_and_keeps_carrier_json() {
    use crate::carrier_entry::CARRIER_FILE;
    let fake = Fake::new();
    let rng = SystemRandom::new();
    let mut store = MemoryStore::default();
    store.write(BIND_FILE, &bind_with_carrier(MACHINE), 0o600).unwrap();
    let key = ensure_install_key(&mut store, "i-aaa", &rng).unwrap().key;
    let noise = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    let result = bind_machine(&mut store, &fake, &key, "AAAA=", &daemon(), Some(noise), T0);
    assert!(matches!(result, BindResult::Bound(_)), "{result:?}");
    let seen = fake.0.borrow().seen[0].clone();
    assert_eq!(seen.body["daemon_noise_key"], noise);
    assert!(seen.body.get("carrier").is_none(), "the route is not sent back");
    assert_eq!(store.mode_of(CARRIER_FILE), Some(0o600));
    let kept: Value = serde_json::from_str(&store.read(CARRIER_FILE).unwrap()).unwrap();
    assert_eq!(
        kept,
        json!({
            "relay": "relay+do://relay.cmux.dev",
            "machine": MACHINE,
            "slot": SLOT,
            "team": TEAM,
            "issuer": "cmux:cloud:development",
            "keyset": { "version": "0123456789abcdef", "keys": {} },
        })
    );
}

/// A bind without `carrier` writes no carrier.json and keeps one that is
/// there; the body stays the exact field set above.
#[test]
fn a_bind_without_carrier_changes_nothing() {
    use crate::carrier_entry::CARRIER_FILE;
    for existing in [None, Some("{\"kept\": true}\n")] {
        let fake = Fake::new();
        let rng = SystemRandom::new();
        let mut store = MemoryStore::default();
        if let Some(text) = existing {
            store.write(CARRIER_FILE, text, 0o600).unwrap();
        }
        store.write(BIND_FILE, &bind_text(), 0o600).unwrap();
        let key = ensure_install_key(&mut store, "i-aaa", &rng).unwrap().key;
        let result = bind_machine(&mut store, &fake, &key, "AAAA=", &daemon(), None, T0);
        assert!(matches!(result, BindResult::Bound(_)), "{result:?}");
        assert_eq!(store.read(CARRIER_FILE).as_deref(), existing);
        assert!(fake.0.borrow().seen[0].body.get("daemon_noise_key").is_none());
    }
}

#[test]
fn a_bad_or_foreign_carrier_section_refuses_the_bind_file() {
    assert!(parse_bind_file(&bind_with_carrier(MACHINE)).unwrap().carrier.is_some());
    assert_eq!(parse_bind_file(&bind_text()).unwrap().carrier, None);
    let foreign = parse_bind_file(&bind_with_carrier("vm_00000000000000000000")).unwrap_err();
    assert!(foreign.contains("not this machine"), "{foreign}");
    let mut bad: Value = serde_json::from_str(&bind_with_carrier(MACHINE)).unwrap();
    bad["carrier"]["slot"] = json!("short");
    assert!(parse_bind_file(&bad.to_string()).is_err());
}

/// Grants are signed as `cmux:cloud:<ENVIRONMENT>`, never the short tag.
#[test]
fn each_environment_names_its_grant_issuer() {
    assert_eq!(Env::Dev.grant_issuer(), "cmux:cloud:development");
    assert_eq!(Env::Stg.grant_issuer(), "cmux:cloud:staging");
    assert_eq!(Env::Prod.grant_issuer(), "cmux:cloud:production");
}

#[test]
fn owner_kind_is_written_once_and_never_replaces_a_record() {
    use crate::team_ssh::enroll::TEAM_ENROLL_FILE;
    // Nothing recorded: the bind records `owner`, 0644.
    let mut store = MemoryStore::default();
    record_owner_kind(&mut store).unwrap();
    assert_eq!(store.read(VM_KIND_FILE).as_deref(), Some("owner\n"));
    assert_eq!(store.mode_of(VM_KIND_FILE), Some(0o644));
    // A record the create (or anything else) wrote first is kept, whatever it says.
    for existing in ["team\n", "owner\n", "", "something-else\n"] {
        let mut store = MemoryStore::default();
        store.write(VM_KIND_FILE, existing, 0o600).unwrap();
        record_owner_kind(&mut store).unwrap();
        assert_eq!(store.read(VM_KIND_FILE).as_deref(), Some(existing));
        assert_eq!(store.mode_of(VM_KIND_FILE), Some(0o600));
    }
    // A team enroll on disk with no record: nothing is written.
    let mut store = MemoryStore::default();
    store.write(TEAM_ENROLL_FILE, "{}", 0o600).unwrap();
    record_owner_kind(&mut store).unwrap();
    assert_eq!(store.read(VM_KIND_FILE), None);
    // A check that fails for any reason but "not found" writes nothing.
    for broken in [VM_KIND_FILE, TEAM_ENROLL_FILE] {
        let mut store = MemoryStore::default();
        store.make_unreadable(broken);
        assert!(record_owner_kind(&mut store).is_err(), "{broken}");
        assert_eq!(store.mode_of(VM_KIND_FILE), None, "{broken}");
    }
}

/// The agent's real store under a temporary root.
#[cfg(target_os = "linux")]
fn file_store() -> (tempfile::TempDir, super::role::FileStore, std::path::PathBuf) {
    let dir = tempfile::tempdir().expect("tempdir");
    let store = super::role::FileStore::new(crate::config::Paths::new(dir.path()));
    let kind = dir.path().join(VM_KIND_FILE.trim_start_matches('/'));
    (dir, store, kind)
}

#[cfg(target_os = "linux")]
#[test]
fn owner_kind_keeps_a_record_it_cannot_read() {
    // Not UTF-8: it cannot be read as text, but it is a record, so it stays.
    let (_dir, mut store, kind) = file_store();
    std::fs::create_dir_all(kind.parent().unwrap()).unwrap();
    std::fs::write(&kind, [0xff, 0xfe, b'\n']).unwrap();
    record_owner_kind(&mut store).unwrap();
    assert_eq!(std::fs::read(&kind).unwrap(), [0xff, 0xfe, b'\n']);
    // A path that cannot be checked (its directory is a file): an error, no write.
    let (dir, mut store, _) = file_store();
    std::fs::write(dir.path().join("etc"), "not a directory").unwrap();
    assert!(record_owner_kind(&mut store).is_err());
    assert_eq!(std::fs::read_to_string(dir.path().join("etc")).unwrap(), "not a directory");
}

/// A writer (the devbox sync, the create's write) that lands right after
/// `record_owner_kind` checks for a record.
#[cfg(target_os = "linux")]
struct LandsAfterCheck {
    inner: super::role::FileStore,
    kind: std::path::PathBuf,
}

#[cfg(target_os = "linux")]
impl Store for LandsAfterCheck {
    fn read(&self, file: &str) -> Option<String> {
        self.inner.read(file)
    }
    fn present(&self, file: &str) -> Result<bool, String> {
        let present = self.inner.present(file)?;
        if file == VM_KIND_FILE && !present {
            std::fs::write(&self.kind, "team\n").unwrap();
        }
        Ok(present)
    }
    fn write(&mut self, file: &str, text: &str, mode: u32) -> Result<(), String> {
        self.inner.write(file, text, mode)
    }
    fn create_new(&mut self, file: &str, text: &str, mode: u32) -> Result<bool, String> {
        self.inner.create_new(file, text, mode)
    }
    fn remove(&mut self, file: &str) {
        self.inner.remove(file);
    }
}

#[cfg(target_os = "linux")]
#[test]
fn owner_kind_never_replaces_a_record_written_after_its_check() {
    let (dir, inner, kind) = file_store();
    std::fs::create_dir_all(kind.parent().unwrap()).unwrap();
    let mut store = LandsAfterCheck { inner, kind: kind.clone() };
    record_owner_kind(&mut store).unwrap();
    assert_eq!(std::fs::read_to_string(&kind).unwrap(), "team\n");
    // No temp file is left beside it.
    let names: Vec<_> = std::fs::read_dir(kind.parent().unwrap())
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    assert_eq!(names, ["vm-kind"]);
    // With nothing there, the same store writes `owner`, 0644.
    let (_dir2, mut store, kind) = file_store();
    record_owner_kind(&mut store).unwrap();
    assert_eq!(std::fs::read_to_string(&kind).unwrap(), "owner\n");
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(std::fs::metadata(&kind).unwrap().permissions().mode() & 0o777, 0o644);
    drop(dir);
}

#[cfg(target_os = "linux")]
#[test]
fn a_failed_write_leaves_no_temp_file() {
    use super::role::WriteStep;
    let temps = |dir: &std::path::Path| -> Vec<String> {
        std::fs::read_dir(dir)
            .map(|entries| {
                entries
                    .map(|e| e.unwrap().file_name().into_string().unwrap())
                    .filter(|name| name.contains(".tmp-"))
                    .collect()
            })
            .unwrap_or_default()
    };
    for step in [WriteStep::Write, WriteStep::Permissions, WriteStep::Rename] {
        let (_dir, mut store, kind) = file_store();
        store.fail_next(step);
        assert!(store.write(VM_KIND_FILE, "owner\n", 0o644).is_err(), "{step:?}");
        assert_eq!(temps(kind.parent().unwrap()), Vec::<String>::new(), "{step:?}");
        assert!(!kind.exists(), "{step:?}");
    }
    for step in [WriteStep::Write, WriteStep::Permissions, WriteStep::Link] {
        let (_dir, mut store, kind) = file_store();
        store.fail_next(step);
        assert!(store.create_new(VM_KIND_FILE, "owner\n", 0o644).is_err(), "{step:?}");
        assert_eq!(temps(kind.parent().unwrap()), Vec::<String>::new(), "{step:?}");
        assert!(!kind.exists(), "{step:?}");
    }
    // A write that works leaves only the file.
    let (_dir, mut store, kind) = file_store();
    store.write(VM_KIND_FILE, "owner\n", 0o644).unwrap();
    assert_eq!(temps(kind.parent().unwrap()), Vec::<String>::new());
    assert_eq!(std::fs::read_to_string(&kind).unwrap(), "owner\n");
}

/// Token pinning also applies to the existing bind/report path. Use the key
/// actually registered at bind, and retain the existing single refresh on403.
#[test]
fn vm_receiver_client_existing_bind_auth_report_and_refresh_keep_working() {
    use super::client::CloudClient;
    use super::sender::{Answer, OpRequest};
    let fake = Fake::new();
    let rng = SystemRandom::new();
    let mut store = MemoryStore::default();
    store.write(BIND_FILE, &bind_text(), 0o600).unwrap();
    let key = ensure_install_key(&mut store, "i-original", &rng).unwrap().key;
    let bound = bind_machine(&mut store, &fake, &key, "AAAA=", &daemon(), None, T0);
    assert!(matches!(bound, BindResult::Bound(_)), "original bind failed");
    let saved: Bound = serde_json::from_str(&store.read(BOUND_FILE).unwrap()).unwrap();
    if let BindResult::Bound(bound) = bound {
        assert_eq!(*bound, saved);
    }
    let mut client = CloudClient::new(fake.clone(), saved, key);
    let report = OpRequest {
        op: STATUS_REPORT_OP,
        params: json!({"machine":MACHINE,"state":"running","daemon":daemon().to_json()}),
        reason: "start".into(),
    };
    assert!(matches!(client.op(&report, T0), Answer::Http { status: 200, .. }));
    fake.0.borrow_mut().ops.push_back((403, json!({"code":"auth.forbidden"})));
    assert!(matches!(client.op(&report, T0 + 1), Answer::Http { status: 200, .. }));
    let state = fake.0.borrow();
    assert_eq!(state.seen.iter().filter(|s| s.url.ends_with("/v1/auth/token")).count(), 2);
    let ops: Vec<_> = state.seen.iter().filter(|s| s.url.ends_with("/v1/ops")).collect();
    assert_eq!(ops.len(), 3, "the refused report gets exactly one retry");
    assert!(ops.iter().all(|s|s.bearer.as_deref()==Some("tok-1") && s.body["params"]["machine"]==MACHINE));
    assert_eq!(store.read(BIND_FILE), None);
}

#[test]
fn carrier_ticket_request_uses_an_empty_body() {
    use super::client::CloudClient;

    let fake = Fake::new();
    let rng = SystemRandom::new();
    let mut store = MemoryStore::default();
    store.write(BIND_FILE, &bind_text(), 0o600).unwrap();
    let key = ensure_install_key(&mut store, "i-original", &rng).unwrap().key;
    let result = bind_machine(&mut store, &fake, &key, "AAAA=", &daemon(), None, T0);
    assert!(matches!(result, BindResult::Bound(_)), "original bind failed");
    let saved: Bound = serde_json::from_str(&store.read(BOUND_FILE).unwrap()).unwrap();

    let mut client = CloudClient::new(fake.clone(), saved, key);
    let reply = client.carrier_ticket(T0);
    assert_eq!(reply["ok"], true);

    let state = fake.0.borrow();
    assert_eq!(state.empty_posts.len(), 1, "carrier route should use the no-body path");
    let request = &state.empty_posts[0];
    assert_eq!(request.url, format!("{DEV}/v1/cloud/machines/{MACHINE}/carrier"));
    assert_eq!(request.bearer.as_deref(), Some("tok-1"));
}

/// The bind endpoint answering from a script, then like [`Fake`].
struct Scripted(RefCell<VecDeque<Result<(u16, Value), String>>>, Fake);

impl Scripted {
    fn new(answers: impl IntoIterator<Item = Result<(u16, Value), String>>) -> Scripted {
        Scripted(RefCell::new(answers.into_iter().collect()), Fake::new())
    }
}

impl Http for Scripted {
    fn post(&self, url: &str, body: &Value, bearer: Option<&str>) -> Result<(u16, Value), String> {
        let next = self.0.borrow_mut().pop_front();
        next.unwrap_or_else(|| self.1.post(url, body, bearer))
    }
}

fn forbidden() -> Result<(u16, Value), String> {
    Ok((403, json!({ "ok": false, "error": { "code": "auth.forbidden" } })))
}

/// hq#7542: a bind whose answer was lost may have spent the token; the
/// platform's refusal of the retry must not delete bind.json while the
/// token can live, or the machine never binds.
#[test]
fn a_refusal_after_a_lost_answer_keeps_bind_json_while_the_token_lives() {
    let rng = SystemRandom::new();
    let mut store = MemoryStore::default();
    store.write(BIND_FILE, &bind_text(), 0o600).unwrap();
    let key = ensure_install_key(&mut store, "i-aaa", &rng).unwrap().key;
    let http = Scripted::new([Err("connection reset".to_owned()), forbidden(), forbidden()]);
    let mut bind = |at| bind_machine(&mut store, &http, &key, "AAAA=", &daemon(), None, at);
    assert!(matches!(bind(T0), BindResult::Retry(_)));
    let result = bind(T0 + 1_100);
    assert!(matches!(result, BindResult::Retry(_)), "{result:?}");
    let result = bind(T0 + 15 * 60 * 1000);
    assert_eq!(result, BindResult::Refused("auth.forbidden".to_owned()), "past the token's life");
    assert_eq!(store.read(BIND_FILE), None);
    assert_eq!(store.read(BIND_UNANSWERED_FILE), None);
}

#[test]
fn a_retry_after_a_lost_answer_that_binds_clears_the_record() {
    let rng = SystemRandom::new();
    let mut store = MemoryStore::default();
    store.write(BIND_FILE, &bind_text(), 0o600).unwrap();
    let key = ensure_install_key(&mut store, "i-aaa", &rng).unwrap().key;
    let http = Scripted::new([Ok((503, json!({}))), forbidden()]);
    let mut bind = |at| bind_machine(&mut store, &http, &key, "AAAA=", &daemon(), None, at);
    assert!(matches!(bind(T0), BindResult::Retry(_)));
    assert!(matches!(bind(T0 + 1_000), BindResult::Retry(_)));
    let result = bind(T0 + 5_000);
    assert!(matches!(result, BindResult::Bound(_)), "{result:?}");
    assert_eq!(store.mode_of(BIND_UNANSWERED_FILE), None);
    assert_eq!(store.read(BIND_FILE), None);
}

/// With no unanswered try, or one of an earlier token, a refusal is final.
#[test]
fn a_refusal_with_no_lost_answer_of_this_token_is_final() {
    let rng = SystemRandom::new();
    let mut store = MemoryStore::default();
    let key = ensure_install_key(&mut store, "i-aaa", &rng).unwrap().key;
    store.write(BIND_FILE, &bind_text(), 0o600).unwrap();
    let http = Scripted::new([forbidden(), Err("connection reset".to_owned()), forbidden()]);
    let result = bind_machine(&mut store, &http, &key, "AAAA=", &daemon(), None, T0);
    assert_eq!(result, BindResult::Refused("auth.forbidden".to_owned()));
    assert_eq!(store.read(BIND_FILE), None);
    store.write(BIND_FILE, &bind_text(), 0o600).unwrap();
    let result = bind_machine(&mut store, &http, &key, "AAAA=", &daemon(), None, T0);
    assert!(matches!(result, BindResult::Retry(_)), "{result:?}");
    let mut next: Value = serde_json::from_str(&bind_text()).unwrap();
    next["bind_token"] = json!("bt_a_new_one_time_token_from_the_driver_0000");
    store.write(BIND_FILE, &next.to_string(), 0o600).unwrap();
    let result = bind_machine(&mut store, &http, &key, "AAAA=", &daemon(), None, T0 + 1_000);
    assert_eq!(result, BindResult::Refused("auth.forbidden".to_owned()), "another token");
    assert_eq!(store.read(BIND_FILE), None);
}

/// Review F2 of #38326's P2s: the Cloud role's bind (`hold_then_bind`, the
/// call `bind_now` makes) takes the updater's connect hold, so the bound
/// machine's first link is held from any update's restart. Driven through
/// the real path to `BindResult::Bound`, under a temporary root.
#[test]
fn a_bind_that_lands_holds_the_updaters_flip() {
    use crate::updater::gate::{CONNECT_HOLD, Gate, Honor};

    let root = tempfile::tempdir().unwrap();
    let paths = crate::config::Paths::new(root.path());
    let fake = Fake::new();
    let mut store = MemoryStore::default();
    store.write(BIND_FILE, &bind_text(), 0o600).unwrap();
    let key = ensure_install_key(&mut store, "i-aaa", &SystemRandom::new()).unwrap().key;
    let result = super::client::hold_then_bind(
        &paths,
        &mut store,
        &fake,
        &key,
        "AAAA=",
        &daemon(),
        None,
        T0,
    );
    assert!(matches!(result, Some(BindResult::Bound(_))), "{result:?}");
    assert_eq!(
        Gate::new(&paths).held_left(T0),
        Some(CONNECT_HOLD),
        "the bind did not hold the updater's flip"
    );
    let mut flipped = false;
    assert!(Gate::new(&paths).run(T0 + 1_000, Honor::AllButResume, |_| flipped = true).is_err());
    assert!(!flipped, "an update flipped during the bound machine's first connect");
}

/// With a restart of the service pending (queued by any process), the bind
/// does not go out: no request, and bind.json stays for the restarted service.
#[test]
fn a_bind_with_a_restart_pending_waits_for_the_restarted_service() {
    use crate::updater::gate::{Gate, Honor};

    let root = tempfile::tempdir().unwrap();
    let paths = crate::config::Paths::new(root.path());
    assert!(Gate::new(&paths).run(T0, Honor::All, |inside| inside.restart_queued(T0)).is_ok());
    let fake = Fake::new();
    let mut store = MemoryStore::default();
    store.write(BIND_FILE, &bind_text(), 0o600).unwrap();
    let key = ensure_install_key(&mut store, "i-aaa", &SystemRandom::new()).unwrap().key;
    let result = super::client::hold_then_bind(
        &paths,
        &mut store,
        &fake,
        &key,
        "AAAA=",
        &daemon(),
        None,
        T0 + 1_000,
    );
    assert!(result.is_none(), "{result:?}");
    assert!(fake.0.borrow().seen.is_empty(), "the bind went out");
    assert!(store.read(BIND_FILE).is_some(), "bind.json is kept for the restarted service");
}
