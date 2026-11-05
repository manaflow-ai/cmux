//! `cmux server unpair` / `cmux unpair`: the real enrollment record, crypto
//! and private files against a controlled API. The paired install signs
//! itself out with its own key before the local record is removed.

use std::collections::VecDeque;
use std::sync::Mutex;

use base64::Engine as _;
use cmux_server::pairing::{self, Transport, unpair};
use cmux_server::{Error, ExitKind, Result};
use cmux_server_core::pairing::enrollment::{Begun, Paired, Waited};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

const NOW: u64 = 1_790_978_474_000;
const API: &str = "https://api.example.test";
const SECRET: &str =
    "AAAAAAAAAAAAAAAAAAAAAA.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const NONCE: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const INSTALL: &str = "inst_00000000000000000001";

fn paired() -> Paired {
    Paired {
        host: "host_00000000000000000001".into(),
        team: "team_00000000000000000001".into(),
        user: "user_00000000000000000001".into(),
        install: INSTALL.into(),
    }
}

/// How the backend answers the sign-out.
#[derive(Clone, Copy)]
enum Cloud {
    Accepts,
    /// The challenge is refused 4xx: the install was revoked in the app.
    AlreadyRevoked,
    Down,
}

struct Api {
    cloud: Cloud,
    begin_lost: bool,
    posts: Mutex<Vec<(String, Value, Option<String>)>>,
    waits: Mutex<VecDeque<Waited>>,
}

impl Api {
    fn new(cloud: Cloud) -> Self {
        Self {
            cloud,
            begin_lost: false,
            posts: Mutex::default(),
            waits: Mutex::new(VecDeque::from([Waited::Paired(paired())])),
        }
    }
    fn paths(&self) -> Vec<String> {
        self.posts.lock().unwrap().iter().map(|(path, _, _)| path.clone()).collect()
    }
}

impl Transport for Api {
    fn health(&self, _api: &str) -> Result<Value> {
        match self.cloud {
            Cloud::Down => Err(Error::unreachable("fixture.down")),
            _ => Ok(json!({"environment":"staging"})),
        }
    }
    fn begin(&self, _api: &str, body: &Value) -> Result<Value> {
        if self.begin_lost {
            return Err(Error::unreachable("fixture.lost_begin_reply"));
        }
        let jwk = &body["public_jwk"];
        let canonical = json!({"crv":jwk["crv"],"kty":jwk["kty"],"x":jwk["x"],"y":jwk["y"]});
        let thumb = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(Sha256::digest(canonical.to_string()));
        Ok(json!({"code":"7KQ4M2XD","display":"7KQ4-M2XD",
            "expires_at":body["issued_at"].as_u64().unwrap()+600_000,"thumbprint":thumb,
            "collect_secret":SECRET}))
    }
    fn wait(&self, _api: &str, _begun: &Begun) -> Result<Waited> {
        Ok(self.waits.lock().unwrap().pop_front().expect("unexpected wait"))
    }
    fn now_ms(&self) -> u64 {
        NOW
    }
    fn backend_post(
        &self,
        api: &str,
        path: &str,
        body: &Value,
        bearer: Option<&str>,
    ) -> Result<Value> {
        assert_eq!(api, API);
        self.posts.lock().unwrap().push((path.into(), body.clone(), bearer.map(str::to_owned)));
        match (path, self.cloud) {
            ("/v1/auth/challenge", Cloud::AlreadyRevoked) => {
                Err(Error::rejected("server.pair.api_refused"))
            }
            ("/v1/auth/challenge", _) => Ok(json!({"install":INSTALL,"nonce":NONCE,
                "message_prefix":format!("cmux-auth-v1\nstaging\n{INSTALL}\n"),"expires_at":NOW+60_000})),
            ("/v1/auth/token", _) => {
                assert!(body["signature"].as_str().is_some_and(|s| !s.is_empty()));
                Ok(json!({"token_type":"Bearer","access_token":"tok-1","user":paired().user,
                    "install":INSTALL,"team":paired().team,"expires_at":NOW+60_000}))
            }
            ("/v1/ops", _) => Ok(json!({"ok":true,"op":"install.sign_out",
                "idempotency_key":body["idempotency_key"],"value":{"id":INSTALL,"revoked_at":NOW}})),
            _ => panic!("unexpected backend post {path}"),
        }
    }
}

fn pair(path: &std::path::Path, api: &Api) {
    let result = pairing::enroll(
        path,
        API,
        json!({"name":"Test server","platform":"linux",
        "os_version":"test","arch":"aarch64","cmux_version":"1.0.0"}),
        None,
        api,
        NOW,
        |_| Ok(()),
    )
    .unwrap();
    assert_eq!(result["state"], "paired");
}

#[test]
fn server_unpair_signs_the_install_out_with_its_own_key_then_removes_the_local_record() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api::new(Cloud::Accepts);
    pair(&path, &api);
    let out = pairing::unpair(&path, &api, false).unwrap();
    assert_eq!(
        out,
        json!({"state":"unpaired","cloud":"signed_out","removed":true,
            "host":"host_00000000000000000001","install":INSTALL})
    );
    assert_eq!(api.paths(), ["/v1/auth/challenge", "/v1/auth/token", "/v1/ops"]);
    let posts = api.posts.lock().unwrap();
    let (_, op, bearer) = &posts[2];
    assert_eq!(op["op"], "install.sign_out");
    assert_eq!(op["idempotency_key"], format!("server-unpair:{INSTALL}"));
    assert_eq!(bearer.as_deref(), Some("tok-1"));
    drop(posts);
    // What identity.rs wrote (keys, paired IDs) is gone; status and a second unpair agree.
    assert!(!path.exists());
    assert_eq!(pairing::status(&path).unwrap(), json!({"state":"unpaired"}));
    let again = pairing::unpair(&path, &api, false).unwrap();
    assert_eq!(again, json!({"state":"unpaired","cloud":"none","removed":false}));
    assert_eq!(api.paths().len(), 3, "nothing paired: no backend call");
    // A fresh pairing makes a new key.
    api.waits.lock().unwrap().push_back(Waited::Paired(paired()));
    pair(&path, &api);
}

#[test]
fn server_unpair_after_the_app_revoked_the_machine_still_forgets_it_here() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api::new(Cloud::AlreadyRevoked);
    pair(&path, &api);
    let out = pairing::unpair(&path, &api, false).unwrap();
    assert_eq!(out["cloud"], "already_revoked");
    assert_eq!(out["removed"], true);
    assert_eq!(api.paths(), ["/v1/auth/challenge"]);
    assert!(!path.exists());
}

#[test]
fn server_unpair_keeps_the_record_when_cmux_cloud_cannot_be_reached() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let accepts = Api::new(Cloud::Accepts);
    pair(&path, &accepts);
    let before = std::fs::read(&path).unwrap();
    let down = Api::new(Cloud::Down);
    let error = pairing::unpair(&path, &down, false).unwrap_err();
    assert_eq!((error.kind, error.message.as_str()), (ExitKind::Unreachable, unpair::UNREACHABLE));
    assert_eq!(std::fs::read(&path).unwrap(), before);
    assert_eq!(pairing::status(&path).unwrap()["state"], "paired");
}

#[test]
fn server_unpair_local_never_contacts_cmux_cloud() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api::new(Cloud::Accepts);
    pair(&path, &api);
    let out = pairing::unpair(&path, &Api::new(Cloud::Down), true).unwrap();
    assert_eq!(out["cloud"], "skipped");
    assert_eq!(out["removed"], true);
    assert_eq!(out["install"], INSTALL);
    assert!(!path.exists());
}

#[test]
fn server_unpair_removes_a_pending_attempt_with_no_install_to_sign_out() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let api = Api { begin_lost: true, ..Api::new(Cloud::Accepts) };
    let error = pairing::enroll(
        &path,
        API,
        json!({"name":"Test server","platform":"linux",
        "os_version":"test","arch":"aarch64","cmux_version":"1.0.0"}),
        None,
        &api,
        NOW,
        |_| Ok(()),
    )
    .unwrap_err();
    assert_eq!(error.kind, ExitKind::Unreachable);
    assert_eq!(pairing::status(&path).unwrap()["state"], "indeterminate");
    let out = pairing::unpair(&path, &api, false).unwrap();
    assert_eq!(out, json!({"state":"unpaired","cloud":"none","removed":true}));
    assert!(api.paths().is_empty());
    assert!(!path.exists());
}

#[test]
fn server_unpair_on_a_machine_that_never_paired_creates_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    let out = pairing::unpair(&path, &Api::new(Cloud::Down), false).unwrap();
    assert_eq!(out, json!({"state":"unpaired","cloud":"none","removed":false}));
    assert!(!path.parent().unwrap().exists());
}
