use super::*;
use cmux_server::pairing::{self, Transport};
use cmux_server_core::pairing::enrollment::{Begun, Paired, Waited};
use serde_json::json;

struct Enrollment;
impl Transport for Enrollment {
    fn health(&self, _: &str) -> cmux_server::Result<Value> {
        Ok(json!({"environment":"test"}))
    }
    fn begin(&self, _: &str, body: &Value) -> cmux_server::Result<Value> {
        Ok(json!({"code":"7KQ4M2XD","expires_at":1_000_000,
            "thumbprint":cmux_server_core::pairing::enrollment::jwk_thumbprint(&body["public_jwk"]).unwrap(),
            "collect_secret":"AAAAAAAAAAAAAAAAAAAAAA.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "verification_uri":"https://example.test/pair"}))
    }
    fn wait(&self, _: &str, _: &Begun) -> cmux_server::Result<Waited> {
        Ok(Waited::Paired(Paired {
            host: "host_00000000000000000001".into(),
            team: "team_00000000000000000001".into(),
            user: "user_00000000000000000001".into(),
            install: "inst_00000000000000000001".into(),
        }))
    }
}

fn fixture() -> (Arc<Hub>, Arc<Session>) {
    let mut cfg = Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let meta: SessionMeta = serde_json::from_value(json!({"schema":META_SCHEMA,"id":"session-test",
        "name":"session-test","harness":"fake","cwd":"/tmp","status":"idle","createdAt":1,"updatedAt":1})).unwrap();
    store.save(&meta).unwrap();
    let hub = Hub::new(cfg, store);
    let session = hub.resolve("session-test").unwrap();
    let seq = hub.append(&session, "mux", "turn_started", json!({"turnId":"turn-test"})).seq;
    *session.turn.lock().unwrap() = Some(TurnInfo {
        started_at: 1,
        client: "test".into(),
        prompt_preview: String::new(),
        masked_preview: String::new(),
        turn_id: "turn-test".into(),
        prompt_id: "prompt-test".into(),
        turn_seq: seq,
        control: Control::Local,
        doing: Default::default(),
    });
    (hub, session)
}

#[test]
fn turn_attestation_signs_enrolled_identity_and_existing_journal_sequence_only() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    assert!(EnrolledIdentity::load(&path).is_err());
    pairing::enroll(
        &path,
        "https://example.test",
        json!({"name":"fixture","platform":"linux",
        "os_version":"test","arch":"aarch64","cmux_version":"test"}),
        None,
        &Enrollment,
        1_000,
        |_| Ok(()),
    )
    .unwrap();
    let enrolled = EnrolledIdentity::load(&path).unwrap();
    let record: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    let (hub, session) = fixture();
    let seq = session.turn.lock().unwrap().as_ref().unwrap().turn_seq;
    let value = hub.issue_turn_attestation(&session.id, &enrolled, 60_000).unwrap();
    let proof: TurnAttestation = serde_json::from_value(value.clone()).unwrap();
    assert_eq!(proof.turn_seq, seq);
    assert_eq!(proof.team_install, enrolled.paired().install);
    assert_eq!(proof.team, enrolled.paired().team);
    assert_eq!(proof.user, enrolled.paired().user);
    assert!(cmux_server_core::install_key::verify(
        &record["public_jwk"],
        &proof.signing_bytes().unwrap(),
        &proof.signature
    ));
    assert!(!value.to_string().contains("prompt"));
    let next = hub.issue_turn_attestation(&session.id, &enrolled, 60_000).unwrap();
    assert_ne!(next["nonce"], value["nonce"]);
    // A turn placeholder not backed by turn_started cannot be signed.
    session.turn.lock().unwrap().as_mut().unwrap().turn_seq = seq + 100;
    assert!(hub.issue_turn_attestation(&session.id, &enrolled, 60_000).is_err());
    session.turn.lock().unwrap().as_mut().unwrap().turn_seq = seq;
    // Journal end wins even while the in-memory turn has not been cleared yet.
    hub.append(&session, "mux", "turn_result", json!({"turnId":"turn-test","turnSeq":seq}));
    assert!(hub.issue_turn_attestation(&session.id, &enrolled, 60_000).is_err());
    assert!(hub.issue_turn_attestation("another-session", &enrolled, 60_000).is_err());
}

#[test]
fn turn_attestation_requires_authenticated_local_caller() {
    let (hub, session) = fixture();
    // Request ownership is checked independently of any caller-chosen identity fields.
    let ask = json!({"sessionId":session.id});
    assert!(crate::turn_attestation::request(&ask, Some("another-session"), true).is_err());
    assert!(crate::turn_attestation::request(&ask, None, true).is_err());
    assert!(crate::turn_attestation::request(&ask, Some(&session.id), false).is_err());
    assert!(crate::turn_attestation::request(&ask, Some(&session.id), true).is_ok());
    drop(hub);
}
