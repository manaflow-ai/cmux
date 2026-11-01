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
                    json!({ "access_token": "tok-1", "token_type": "Bearer", "expires_at": T0 + 3_600_000 }),
                ))
            }
            "/v1/ops" => Ok(st.ops.pop_front().unwrap_or((200, applied()))),
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
    let result = bind_machine(&mut store, &fake, &key, "AAAA=", &daemon(), T0);
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
