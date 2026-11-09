//! `cmux pair CODE` / `cmux server pair --invite CODE`: the real enrollment
//! reducer, crypto and private files against a controlled API. No account is
//! approved, service installed or role started by these tests.

use std::collections::VecDeque;
use std::sync::Mutex;

use base64::Engine as _;
use cmux_server::pairing::{self, Transport, invite};
use cmux_server::{Error, ExitKind, Result};
use cmux_server_core::pairing::enrollment::{Begun, MachineJoin, Paired, Waited};
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
        machine_join: None,
    }
}

/// What the begin route answers to each call, in order.
enum Begin {
    Invited(Option<&'static str>),
    Refused(&'static str),
    Lost,
}

struct Api {
    begins: Mutex<VecDeque<Begin>>,
    bodies: Mutex<Vec<Value>>,
    waits: Mutex<VecDeque<Result<Waited>>>,
    /// Each machine join asked for: (token, api, name).
    joins: Mutex<Vec<(String, String, String)>>,
}

impl Api {
    fn new(begins: Vec<Begin>, waits: Vec<Result<Waited>>) -> Self {
        Self {
            begins: Mutex::new(begins.into()),
            bodies: Mutex::default(),
            waits: Mutex::new(waits.into()),
            joins: Mutex::default(),
        }
    }
}

impl Transport for Api {
    fn health(&self, _api: &str) -> Result<Value> {
        Ok(json!({"environment":"staging"}))
    }
    fn begin(&self, api: &str, body: &Value) -> Result<Value> {
        assert_eq!(api, API);
        self.bodies.lock().unwrap().push(body.clone());
        let jwk = &body["public_jwk"];
        let canonical = json!({"crv":jwk["crv"],"kty":jwk["kty"],"x":jwk["x"],"y":jwk["y"]});
        let thumb = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(Sha256::digest(canonical.to_string()));
        match self.begins.lock().unwrap().pop_front().expect("unexpected begin") {
            Begin::Invited(inviter) => Ok(json!({"code":"7KQ4M2XD","display":"7KQ4-M2XD",
                "expires_at":body["issued_at"].as_u64().unwrap()+600_000,"thumbprint":thumb,
                "collect_secret":SECRET,"invited":true,"inviter":inviter})),
            Begin::Refused(code) => Err(Error::rejected(code)),
            Begin::Lost => Err(Error::unreachable("fixture.lost_begin_reply")),
        }
    }
    fn wait(&self, _api: &str, begun: &Begun) -> Result<Waited> {
        assert_eq!(begun.code.as_str(), "7KQ4M2XD");
        self.waits.lock().unwrap().pop_front().expect("unexpected wait")
    }
    fn machine_join(&self, join: &MachineJoin, api: &str, name: &str) -> Value {
        self.joins.lock().unwrap().push((join.token().into(), api.into(), name.into()));
        json!({"state":"joined","machine_id":"machine_1"})
    }
}

fn run(
    path: &std::path::Path,
    api: &Api,
    invite: &str,
    progress: &mut Vec<Value>,
) -> Result<Value> {
    pairing::enroll_with_invite(path, API, info(), None, Some(invite), api, NOW, |value| {
        progress.push(value.clone());
        Ok(())
    })
}

#[test]
fn server_pairing_invite_begins_with_the_normalized_code_names_the_inviter_and_pairs() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api::new(vec![Begin::Invited(Some("Leo"))], vec![Ok(Waited::Paired(paired()))]);
    let mut progress = vec![];
    let result = run(&path, &api, "abcde-1234o", &mut progress).unwrap();
    assert_eq!(result["state"], "paired");
    assert_eq!(result["host"], "host_00000000000000000001");
    let bodies = api.bodies.lock().unwrap();
    assert_eq!(bodies.len(), 1);
    assert_eq!(bodies[0]["invite"], "ABCDE12340");
    assert_eq!(progress.len(), 1);
    assert_eq!(progress[0]["invited"], true);
    assert_eq!(progress[0]["inviter"], "Leo");
    assert_eq!(progress[0]["words"].as_array().unwrap().len(), 4);
    let public = format!("{result:?}{progress:?}");
    assert!(!public.contains(SECRET), "{public}");
}

#[test]
fn server_pairing_invite_reports_unknown_used_and_voided_invites_and_allows_a_new_attempt() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api::new(
        vec![
            Begin::Refused(invite::UNKNOWN),
            Begin::Refused(invite::USED),
            Begin::Invited(None),
            Begin::Invited(None),
        ],
        vec![Ok(Waited::Refused), Ok(Waited::Paired(paired()))],
    );
    let mut progress = vec![];
    let error = run(&path, &api, "ABCDE-12345", &mut progress).unwrap_err();
    assert_eq!((error.kind, error.message.as_str()), (ExitKind::Rejected, invite::UNKNOWN));
    // A refused begin issued nothing: the next invite begins at once.
    assert_eq!(pairing::status(&path).unwrap(), json!({"state":"unpaired"}));
    let error = run(&path, &api, "ABCDE-12346", &mut progress).unwrap_err();
    assert_eq!((error.kind, error.message.as_str()), (ExitKind::Rejected, invite::USED));
    // The invite is voided while this machine waits (a second machine used it).
    let error = run(&path, &api, "ABCDE-12347", &mut progress).unwrap_err();
    assert_eq!((error.kind, error.message.as_str()), (ExitKind::Rejected, invite::VOIDED));
    assert_eq!(progress.last().unwrap()["invited"], true);
    assert!(progress.last().unwrap().get("inviter").is_none());
    assert_eq!(pairing::status(&path).unwrap(), json!({"state":"unpaired"}));
    // A fresh invite then pairs with the same identity.
    let result = run(&path, &api, "ABCDE-12348", &mut progress).unwrap();
    assert_eq!(result["state"], "paired");
}

#[test]
fn server_pairing_invite_refuses_a_malformed_code_before_any_file_or_request() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api::new(vec![], vec![]);
    for bad in ["7KQ4-M2XD", "ABCDE-1234U", "nope"] {
        let error = run(&path, &api, bad, &mut vec![]).unwrap_err();
        assert_eq!(
            (error.kind, error.message.as_str()),
            (ExitKind::Usage, "server.pair.invalid_invite")
        );
    }
    assert!(!dir.path().join("pairing").exists());
    assert!(api.bodies.lock().unwrap().is_empty());
}

#[test]
fn server_pairing_invite_does_not_replace_an_unknown_begin_with_another_invite() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api::new(vec![Begin::Lost], vec![]);
    let error = run(&path, &api, "ABCDE-12345", &mut vec![]).unwrap_err();
    assert_eq!(error.kind, ExitKind::Unreachable);
    // The lost begin may have redeemed the first invite: another invite conflicts with it.
    let error = run(&path, &api, "ABCDE-99999", &mut vec![]).unwrap_err();
    assert_eq!(error.kind, ExitKind::Conflict);
    // So does a plain begin.
    let error = pairing::enroll(&path, API, info(), None, &api, NOW, |_| Ok(())).unwrap_err();
    assert_eq!(error.kind, ExitKind::Conflict);
}

#[test]
fn server_pairing_invite_redeems_the_pushed_join_token_and_never_stores_it() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let token = format!("cmj_{}", "t".repeat(43));
    let mut with_join = paired();
    with_join.machine_join = Some(MachineJoin::for_tests(&token, NOW + 600_000));
    let api = Api::new(vec![Begin::Invited(Some("Leo"))], vec![Ok(Waited::Paired(with_join))]);
    let mut progress = vec![];
    let result = run(&path, &api, "ABCDE-12345", &mut progress).unwrap();
    assert_eq!(result["state"], "paired");
    assert_eq!(result["machine"], json!({"state":"joined","machine_id":"machine_1"}));
    assert_eq!(
        *api.joins.lock().unwrap(),
        vec![(token.clone(), API.to_owned(), "Test server".to_owned())]
    );
    let saved = std::fs::read_to_string(&path).unwrap();
    assert!(!saved.contains(&token), "the identity file holds no join token");
    assert!(!format!("{result:?}{progress:?}").contains(&token));
    // Without a token, nothing is joined and the result has no machine field.
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api::new(vec![Begin::Invited(None)], vec![Ok(Waited::Paired(paired()))]);
    let result = run(&path, &api, "ABCDE-12345", &mut vec![]).unwrap();
    assert!(result.get("machine").is_none());
    assert!(api.joins.lock().unwrap().is_empty());
}
