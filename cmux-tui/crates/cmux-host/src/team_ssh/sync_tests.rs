use std::cell::RefCell;
use std::fs;
use std::rc::Rc;

use cmux_server_core::install_key::{InstallKey, SystemRandom, verify};
use serde_json::{Value, json};

use super::accounts_tests::FakeAccounts;
use super::enroll::TeamBound;
use super::store::load_state;
use super::sync::{accounts_once, client_bound, sync_once};
use super::test_support::{b64, ca_line, krl};
use super::{CA_FILE, KRL_FILE, PRINCIPALS_DIR};
use crate::cloud::client::{CloudClient, Http};
use crate::cloud::wire::Env;
use crate::config::Paths;

const ORIGIN: &str = "https://cloud-api-staging.cmux.dev";

/// A fake API: auth challenge + token (checking the install's signature) and `/v1/read`.
#[derive(Clone)]
struct Api {
    jwk: Value,
    read: Rc<RefCell<(u16, Value)>>,
    reads: Rc<RefCell<Vec<Value>>>,
}

impl Http for Api {
    fn post(&self, url: &str, body: &Value, bearer: Option<&str>) -> Result<(u16, Value), String> {
        match url.strip_prefix(ORIGIN) {
            Some("/v1/auth/challenge") => Ok((
                200,
                json!({ "install": body["install"], "nonce": "n1", "message_prefix": format!("cmux-auth-v1\nstaging\n{}\n", body["install"].as_str().unwrap_or("")) }),
            )),
            Some("/v1/auth/token") => {
                let msg = format!(
                    "cmux-auth-v1\nstaging\n{}\nn1",
                    body["install"].as_str().unwrap_or("")
                );
                if !verify(&self.jwk, msg.as_bytes(), body["signature"].as_str().unwrap_or("")) {
                    return Ok((403, json!({ "code": "auth.forbidden" })));
                }
                Ok((
                    200,
                    json!({ "access_token": "tok", "token_type": "Bearer", "expires_at": u64::MAX }),
                ))
            }
            Some("/v1/read") => {
                assert_eq!(bearer, Some("tok"));
                self.reads.borrow_mut().push(body.clone());
                Ok(self.read.borrow().clone())
            }
            _ => Ok((404, json!({}))),
        }
    }
}

fn snapshot_value(team: &str, version: u64) -> Value {
    json!({ "team": team, "generation": 1, "trusted_ca_keys": [ca_line(1)], "krl": b64(&krl(version)), "krl_version": version })
}

fn setup() -> (tempfile::TempDir, Paths, Api, CloudClient<Api>) {
    let dir = tempfile::tempdir().expect("tempdir");
    let paths = Paths::new(dir.path());
    let rng = SystemRandom::new();
    let key = InstallKey::generate(&rng).expect("key");
    let api = Api {
        jwk: key.public_jwk(),
        read: Rc::new(RefCell::new((200, json!({})))),
        reads: Rc::default(),
    };
    let bound = TeamBound {
        instance_id: "vm-a".into(),
        team: "team_t".into(),
        epoch: 1,
        user: "user_u".into(),
        install: "inst_i".into(),
        api_origin: ORIGIN.into(),
        env: Env::Stg,
    };
    let client = CloudClient::new(api.clone(), client_bound(&bound), key);
    (dir, paths, api, client)
}

#[test]
fn the_vm_reads_its_teams_ca_and_krl_as_its_own_install_and_applies_them() {
    let (_d, paths, api, mut client) = setup();
    *api.read.borrow_mut() =
        (200, json!({ "op": "team_vm.ssh_ca", "value": snapshot_value("team_t", 4) }));
    let applied = sync_once(&mut client, &paths, &|_| Ok(()), 1_000_000).expect("sync");
    assert_eq!(applied.state.krl_version, 4);
    assert_eq!(fs::read(paths.at(KRL_FILE)).expect("krl"), krl(4));
    assert_eq!(fs::read_to_string(paths.at(CA_FILE)).expect("ca"), format!("{}\n", ca_line(1)));
    assert_eq!(load_state(&paths).map(|s| s.synced_at), Some(1_000));
    assert_eq!(api.reads.borrow()[0], json!({ "op": "team_vm.ssh_ca", "params": {} }));
    // A revocation on the server reaches the files on the next sync.
    *api.read.borrow_mut() = (200, json!({ "value": snapshot_value("team_t", 5) }));
    assert!(sync_once(&mut client, &paths, &|_| Ok(()), 1_030_000).expect("sync").krl_changed);
    assert_eq!(fs::read(paths.at(KRL_FILE)).expect("krl"), krl(5));
}

#[test]
fn another_teams_answer_errors_and_stale_answers_change_nothing() {
    let (_d, paths, api, mut client) = setup();
    *api.read.borrow_mut() = (200, json!({ "value": snapshot_value("team_other", 9) }));
    assert!(sync_once(&mut client, &paths, &|_| Ok(()), 1_000_000).is_err());
    assert!(!paths.at(KRL_FILE).exists());
    *api.read.borrow_mut() = (200, json!({ "value": snapshot_value("team_t", 5) }));
    sync_once(&mut client, &paths, &|_| Ok(()), 1_000_000).expect("sync");
    *api.read.borrow_mut() = (200, json!({ "value": snapshot_value("team_t", 4) }));
    assert!(sync_once(&mut client, &paths, &|_| Ok(()), 1_030_000).is_err(), "older KRL");
    assert_eq!(load_state(&paths).map(|s| (s.krl_version, s.synced_at)), Some((5, 1_000)));
    *api.read.borrow_mut() = (403, json!({ "ok": false, "error": { "code": "auth.forbidden" } }));
    let err = sync_once(&mut client, &paths, &|_| Ok(()), 1_060_000).expect_err("refused");
    assert!(err.contains("auth.forbidden"), "{err}");
}

fn accounts_value(team: &str, users: &[(&str, u32, &str)]) -> Value {
    let users: Vec<Value> = users
        .iter()
        .map(|(u, uid, class)| json!({ "user": u, "uid": uid, "class": class, "principals": [u] }))
        .collect();
    json!({ "team": team, "users": users })
}

#[test]
fn the_vm_reads_its_teams_accounts_as_its_own_install_and_reconciles_them() {
    let (_d, paths, api, mut client) = setup();
    let host = FakeAccounts::default();
    *api.read.borrow_mut() = (
        200,
        json!({ "op": "team_vm.accounts", "value": accounts_value("team_t", &[("ada", 20000, "human"), ("ada-agents", 20002, "agent")]) }),
    );
    let done = accounts_once(&mut client, &paths, &host, 1_000_000).expect("accounts");
    assert_eq!(done.created, vec!["ada", "ada-agents"]);
    assert_eq!(api.reads.borrow()[0], json!({ "op": "team_vm.accounts", "params": {} }));
    let dir = paths.at(PRINCIPALS_DIR);
    assert_eq!(fs::read_to_string(dir.join("ada-agents")).expect("principals"), "ada-agents\n");
    // The member leaves: the next pass removes the principals.
    *api.read.borrow_mut() = (200, json!({ "value": accounts_value("team_t", &[]) }));
    let done = accounts_once(&mut client, &paths, &host, 1_030_000).expect("accounts");
    assert_eq!(done.removed, vec!["ada", "ada-agents"]);
    assert!(!dir.join("ada").exists());
}

#[test]
fn another_teams_accounts_a_bad_row_and_errors_change_nothing() {
    let (_d, paths, api, mut client) = setup();
    let host = FakeAccounts::default();
    *api.read.borrow_mut() =
        (200, json!({ "value": accounts_value("team_other", &[("ada", 20000, "human")]) }));
    assert!(accounts_once(&mut client, &paths, &host, 1_000_000).is_err());
    *api.read.borrow_mut() =
        (200, json!({ "value": accounts_value("team_t", &[("root", 0, "human")]) }));
    // A bad row is refused on its own; nothing is made for it.
    let done = accounts_once(&mut client, &paths, &host, 1_000_000).expect("rows");
    assert!(done.refused.iter().any(|r| r.contains("root") && r.contains("uid 0")), "{done:?}");
    *api.read.borrow_mut() =
        (400, json!({ "ok": false, "error": { "code": "validation.invalid" } }));
    let err = accounts_once(&mut client, &paths, &host, 1_000_000).expect_err("old backend");
    assert!(err.contains("validation.invalid"), "{err}");
    assert!(host.created.borrow().is_empty());
    assert!(!paths.at(PRINCIPALS_DIR).join("ada").exists());
}
