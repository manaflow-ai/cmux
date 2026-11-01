use super::*;
use base64::Engine as _;
use cmux_server::pairing::{self, Transport};
use cmux_server_core::install_key::{InstallKey, SystemRandom};
use cmux_server_core::pairing::enrollment::{Begun, Paired, Waited};
use serde_json::json;

struct Enrollment;
impl Transport for Enrollment {
    fn health(&self, _: &str) -> cmux_server::Result<Value> {
        Ok(json!({"environment":"test"}))
    }
    fn begin(&self, _: &str, body: &Value) -> cmux_server::Result<Value> {
        Ok(json!({"code":"7KQ4M2XD","expires_at":cmux_server::host::now_ms() + 60_000,
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
    fixture_with_status(SessionStatus::Idle)
}

fn fixture_with_status(status: SessionStatus) -> (Arc<Hub>, Arc<Session>) {
    let mut cfg = Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let mut meta: SessionMeta = serde_json::from_value(json!({"schema":META_SCHEMA,"id":"session-test",
        "name":"session-test","harness":"fake","cwd":"/tmp","status":"idle","createdAt":1,"updatedAt":1})).unwrap();
    meta.status = status;
    store.save(&meta).unwrap();
    let hub = Hub::new(cfg, store);
    let session = hub.resolve("session-test").unwrap();
    let seq = hub.append(&session, "mux", "turn_started", json!({"turnId":"turn-test"})).seq;
    *session.turn.lock().unwrap() = Some(TurnInfo {
        trigger: false,
        started_at: 1,
        client: "test".into(),
        prompt_preview: String::new(),
        masked_preview: String::new(),
        turn_id: "turn-test".into(),
        prompt_id: "prompt-test".into(),
        turn_seq: seq,
        control: Control::Local,
        doing: Default::default(),
        notice: false,
        persons: false,
    });
    (hub, session)
}

fn enrolled_identity() -> (tempfile::TempDir, EnrolledIdentity) {
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
        cmux_server::host::now_ms(),
        |_| Ok(()),
    )
    .unwrap();
    let enrolled = EnrolledIdentity::load(&path).unwrap();
    (dir, enrolled)
}

#[test]
fn turn_attestation_rejects_reconstructed_closed_session_with_stale_turn() {
    let (_dir, enrolled) = enrolled_identity();
    // Resolve persisted Closed metadata through the normal session reconstruction path,
    // then supply a stale turn backed by turn_started but no terminal journal event.
    let (hub, session) = fixture_with_status(SessionStatus::Closed);
    assert_eq!(session.status(), SessionStatus::Closed);
    assert!(!session.closing.load(Ordering::SeqCst));
    assert!(!session.purged.load(Ordering::SeqCst));
    assert!(session.turn.lock().unwrap().is_some());
    assert!(hub.session_log_loaded(&session));
    let error = match hub.issue_turn_attestation(&session.id, &enrolled, 60_000) {
        Ok(_) => panic!("closed session must not receive a turn attestation"),
        Err(error) => error,
    };
    assert_eq!(error, refused("turn_attestation.not_live"));
}

#[test]
fn turn_attestation_signs_enrolled_identity_and_existing_journal_sequence_only() {
    let (dir, enrolled) = enrolled_identity();
    let record: Value =
        serde_json::from_slice(&std::fs::read(dir.path().join("pairing/identity.json")).unwrap())
            .unwrap();
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
    // finish_turn's first operation clears this live state under append_lock; an attestation
    // requested after that point must fail even if the journal terminal record is delayed.
    assert!(hub.take_turn(&session, "turn-test", None).is_some());
    assert!(hub.issue_turn_attestation(&session.id, &enrolled, 60_000).is_err());
    *session.turn.lock().unwrap() = Some(TurnInfo {
        trigger: false,
        started_at: 1,
        client: "test".into(),
        prompt_preview: String::new(),
        masked_preview: String::new(),
        turn_id: "turn-test".into(),
        prompt_id: "prompt-test".into(),
        turn_seq: seq,
        control: Control::Local,
        doing: Default::default(),
        notice: false,
        persons: false,
    });
    // Journal end wins even while the in-memory turn has not been cleared yet.
    hub.append(&session, "mux", "turn_result", json!({"turnId":"turn-test","turnSeq":seq}));
    assert!(hub.issue_turn_attestation(&session.id, &enrolled, 60_000).is_err());
    assert!(hub.issue_turn_attestation("another-session", &enrolled, 60_000).is_err());
}

#[test]
fn shared_turn_attestation_vector_matches_platform_preimage() {
    let attestation = TurnAttestation {
        session_id: "vector-session".into(),
        turn_seq: 7,
        team_install: "inst_vector".into(),
        team: "team_vector".into(),
        user: "user_vector".into(),
        issued_at: 1_700_000_000_000,
        expiry: 1_700_000_060_000,
        nonce: "vector-nonce".into(),
        signature:
            "fmZ2JgEiGrBe1KTUFBQEGA-5j0xfdBwkkk6zCt3rp1NFr8_f79i4f4iGI_YCb-HcbSADTdRQOK4MeU-uh-47eg"
                .into(),
    };
    let bytes = attestation.signing_bytes().unwrap();
    assert_eq!(
        base64::engine::general_purpose::STANDARD.encode(&bytes),
        "WyJjbXV4LWFjcG11eC10dXJuLWF0dGVzdGF0aW9uLXYxIiwidmVjdG9yLXNlc3Npb24iLDcsImluc3RfdmVjdG9yIiwidGVhbV92ZWN0b3IiLCJ1c2VyX3ZlY3RvciIsMTcwMDAwMDAwMDAwMCwxNzAwMDAwMDYwMDAwLCJ2ZWN0b3Itbm9uY2UiXQ=="
    );
    let key = InstallKey::from_pkcs8_base64url(
        "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgQ_TnLhFXosdlChKo2LZw_HkVaWT4xNqGv-JOteU7MPyhRANCAAQWrvJjw4seSMCT_0NqTZf8SZ11uSHA9JQF9zPhWGqIqr_H69jrCgS38IPyK6ygg7NBc2W3zpnY68Ow6NUzMzqf",
        &SystemRandom::new(),
    )
    .unwrap();
    assert!(cmux_server_core::install_key::verify(
        &key.public_jwk(),
        &bytes,
        &attestation.signature
    ));
    assert!(cmux_server_core::install_key::verify(
        &key.public_jwk(),
        &bytes,
        &key.sign(&bytes, &SystemRandom::new()).unwrap()
    ));
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

// Per issuing thread, so parallel tests never share a pause or a session identifier.
thread_local! {
    static BEFORE_ADMISSION: std::cell::RefCell<Option<Box<dyn FnOnce()>>> = const {
        std::cell::RefCell::new(None)
    };
    static AFTER_LIVE_CHECK: std::cell::RefCell<Option<Box<dyn FnOnce()>>> = const {
        std::cell::RefCell::new(None)
    };
}

pub(super) fn before_admission() {
    let hook = BEFORE_ADMISSION.with(|slot| slot.borrow_mut().take());
    if let Some(hook) = hook {
        hook();
    }
}

pub(super) fn after_live_check() {
    let hook = AFTER_LIVE_CHECK.with(|slot| slot.borrow_mut().take());
    if let Some(hook) = hook {
        hook();
    }
}

#[test]
fn turn_attestation_rejects_detach_after_journal_validation() {
    let (_dir, enrolled) = enrolled_identity();
    let (hub, session) = fixture();
    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    let (resume_tx, resume_rx) = std::sync::mpsc::channel();
    let issue_hub = hub.clone();
    let id = session.id.clone();
    let issuer = std::thread::spawn(move || {
        BEFORE_ADMISSION.with(|slot| {
            *slot.borrow_mut() = Some(Box::new(move || {
                ready_tx.send(()).unwrap();
                resume_rx.recv_timeout(std::time::Duration::from_secs(5)).unwrap();
            }));
        });
        issue_hub.issue_turn_attestation(&id, &enrolled, 60_000)
    });
    ready_rx.recv_timeout(std::time::Duration::from_secs(5)).unwrap();
    // The fixture has a live journal-backed turn but no child and already-idle metadata.
    // Real detach clears the turn without needing a status-change journal append. This
    // completes while the issuer still holds append_lock, proving that lock is insufficient.
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(hub.detach_child(&session));
    assert!(session.turn().is_none());
    resume_tx.send(()).unwrap();
    match issuer.join().unwrap() {
        Ok(_) => panic!("detached turn must not receive a stale attestation"),
        Err(error) => assert_eq!(error, refused("turn_attestation.not_live")),
    }
}

#[test]
fn turn_attestation_rejects_replacement_after_journal_validation() {
    for replace_id in [false, true] {
        let (_dir, enrolled) = enrolled_identity();
        let (hub, session) = fixture();
        let changed = session.clone();
        BEFORE_ADMISSION.with(|slot| {
            *slot.borrow_mut() = Some(Box::new(move || {
                let mut live = changed.turn.lock().unwrap();
                let turn = live.as_mut().unwrap();
                if replace_id {
                    turn.turn_id = "replacement-turn".into();
                } else {
                    turn.turn_seq += 1;
                }
            }));
        });
        match hub.issue_turn_attestation(&session.id, &enrolled, 60_000) {
            Ok(_) => panic!("replaced turn must not receive a stale attestation"),
            Err(error) => assert_eq!(error, refused("turn_attestation.not_live")),
        }
    }
}

#[tokio::test]
async fn turn_attestation_rejects_transfer_instance_before_kill() {
    let (_dir, enrolled) = enrolled_identity();
    let (hub, session) = fixture();
    // Hold kill at harness_use while the real transfer-in retirement boundary seals
    // the old instance and releases append_lock. Its live turn is still resolvable.
    let using = session.harness_use.write().await;
    let retiring = hub.retire_transfer_instance(&session);
    tokio::pin!(retiring);
    assert!(futures::poll!(&mut retiring).is_pending());
    assert!(session.replaced.load(Ordering::SeqCst));
    assert!(!session.closing.load(Ordering::SeqCst));
    assert!(session.turn().is_some());
    assert!(Arc::ptr_eq(&hub.resolve(&session.id).unwrap(), &session));
    let result = hub.issue_turn_attestation(&session.id, &enrolled, 60_000);
    drop(using);
    retiring.await.unwrap();
    match result {
        Ok(_) => panic!("replaced transfer instance must not receive an attestation"),
        Err(error) => assert_eq!(error, refused("turn_attestation.not_live")),
    }
    assert!(session.turn().is_none());
    assert_eq!(session.status(), SessionStatus::Closed);
    assert!(hub.issue_turn_attestation(&session.id, &enrolled, 60_000).is_err());
}

#[test]
fn turn_attestation_rechecks_transfer_fence_after_journal_validation() {
    let (_dir, enrolled) = enrolled_identity();
    let (hub, session) = fixture();
    let changed = session.clone();
    let transfer_hub = hub.clone();
    let (before_tx, before_rx) = std::sync::mpsc::channel();
    let (hook_done_tx, hook_done_rx) = std::sync::mpsc::channel();
    let (seal_done_tx, seal_done_rx) = std::sync::mpsc::channel();
    AFTER_LIVE_CHECK.with(|slot| {
        *slot.borrow_mut() = Some(Box::new(move || {
            // The seal races the final live check. On the fixed path it blocks on
            // append_lock until signing is complete; on b3db459 it flips replaced here.
            let seal = std::thread::spawn(move || {
                transfer_hub.seal_retry_replacement(&changed);
                let _ = seal_done_tx.send(());
            });
            let sealed_before_sign =
                seal_done_rx.recv_timeout(std::time::Duration::from_millis(100)).is_ok();
            before_tx.send(sealed_before_sign).unwrap();
            let _ = hook_done_tx.send(seal);
        }));
    });
    let result = hub.issue_turn_attestation(&session.id, &enrolled, 60_000);
    assert!(!before_rx.recv_timeout(std::time::Duration::from_secs(5)).unwrap());
    let seal = hook_done_rx.recv_timeout(std::time::Duration::from_secs(5)).unwrap();
    seal.join().unwrap();
    assert!(result.is_ok(), "the serialized attestation admission must succeed");
    assert!(session.replaced.load(Ordering::SeqCst));
}

#[test]
fn turn_attestation_rechecks_terminal_flags_after_journal_validation() {
    for closing in [false, true] {
        let (_dir, enrolled) = enrolled_identity();
        let (hub, session) = fixture();
        let changed = session.clone();
        BEFORE_ADMISSION.with(|slot| {
            *slot.borrow_mut() = Some(Box::new(move || {
                if closing {
                    changed.closing.store(true, Ordering::SeqCst);
                } else {
                    changed.purged.store(true, Ordering::SeqCst);
                }
            }));
        });
        assert_eq!(
            hub.issue_turn_attestation(&session.id, &enrolled, 60_000).unwrap_err(),
            refused("turn_attestation.not_live")
        );
    }
}

#[tokio::test]
async fn turn_attestation_rejects_killed_session() {
    let (_dir, enrolled) = enrolled_identity();
    let (hub, session) = fixture();
    hub.kill(&session, false).await.unwrap();
    assert!(session.turn().is_none());
    assert!(session.closing.load(Ordering::SeqCst));
    assert_eq!(session.status(), SessionStatus::Closed);
    assert_eq!(
        hub.issue_turn_attestation(&session.id, &enrolled, 60_000).unwrap_err(),
        refused("turn_attestation.not_live")
    );
}
