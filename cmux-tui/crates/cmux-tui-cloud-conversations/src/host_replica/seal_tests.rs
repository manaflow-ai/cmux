//! The host replica sealed at rest: each paired viewer opens its own
//! envelope, nothing else does, no plaintext reaches the frame, and a lease
//! that asks for a seal without a usable key is refused.

use std::sync::Arc;
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_relay_snapshot::{Error, Position, key_id, open};
use p256::ecdsa::SigningKey;
use p256::{PublicKey, SecretKey};
use rand_core::OsRng;
use serde_json::{Value, json};

use super::{MAX_VIEWERS, ReplicaSeal, SEALED_FORMAT, Sealer};
use crate::host_replica::{
    HostOpRefusal, HostReplica, HostReplicaOptions, HostReplicaParams, HostSource,
};
use crate::testing::{FakeBackend, ScriptedWire, wait_until};

const HOST: &str = "host_0123456789abcdefghij";
/// `{sub, inst: "inst_mac", team, exp}`, unsigned (the daemon only reads it).
const INSTALL_TOKEN: &str = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ1c2VyXzAwMDAwMDAwMDAwMDAwMDAwMDAxIiwiaW5zdCI6Imluc3RfbWFjIiwidGVhbSI6InRlYW1fMSIsImV4cCI6NDEwMjQ0NDgwMH0.sig";
const SECRET: &str = "secret-workspace-name";

struct Keys {
    source: SigningKey,
    viewers: Vec<SecretKey>,
}

fn keys(viewers: usize) -> Keys {
    Keys {
        source: SigningKey::random(&mut OsRng),
        viewers: (0..viewers).map(|_| SecretKey::random(&mut OsRng)).collect(),
    }
}

fn seal_of(keys: &Keys) -> ReplicaSeal {
    ReplicaSeal {
        source_key: STANDARD.encode(keys.source.to_bytes()),
        viewers: keys
            .viewers
            .iter()
            .map(|viewer| STANDARD.encode(viewer.public_key().to_sec1_bytes()))
            .collect(),
    }
}

fn source_public(keys: &Keys) -> PublicKey {
    PublicKey::from(keys.source.verifying_key())
}

/// The envelope `sealed` holds for `viewer`, decoded.
fn envelope(sealed: &Value, viewer: &SecretKey) -> Vec<u8> {
    let id = hex::encode(key_id(&viewer.public_key()));
    STANDARD.decode(sealed["to"][&id].as_str().expect("an envelope per viewer")).unwrap()
}

#[test]
fn every_paired_viewer_opens_its_own_envelope_and_the_relay_reads_nothing() {
    let keys = keys(3);
    let sealer = Sealer::new(seal_of(&keys)).unwrap();
    let state = json!({ "workspaces": [{ "id": "w1", "name": SECRET }] });
    let stream = format!("host:{HOST}/session");
    let sealed = sealer.seal(&stream, 42, &state).unwrap();

    assert_eq!(sealed["sealed"], SEALED_FORMAT);
    assert_eq!(sealed["source"], hex::encode(key_id(&source_public(&keys))));
    assert_eq!(sealed["to"].as_object().unwrap().len(), 3);
    assert!(!sealed.to_string().contains(SECRET), "no plaintext in the stored state");
    for viewer in &keys.viewers {
        let opened =
            open(viewer, &source_public(&keys), &stream, None, &envelope(&sealed, viewer)).unwrap();
        assert_eq!(opened.position, Position { epoch: 0, seq: 42 });
        assert_eq!(serde_json::from_slice::<Value>(&opened.plaintext).unwrap(), state);
    }

    let viewer = &keys.viewers[0];
    let bytes = envelope(&sealed, viewer);
    // Bound to its stream: the Chief stream's reader cannot replay it.
    assert!(
        open(viewer, &source_public(&keys), &format!("host:{HOST}/chief"), None, &bytes).is_err()
    );
    // Another viewer's key, and another source, open nothing.
    assert!(open(&keys.viewers[1], &source_public(&keys), &stream, None, &bytes).is_err());
    let other = SigningKey::random(&mut OsRng);
    assert!(matches!(
        open(viewer, &PublicKey::from(other.verifying_key()), &stream, None, &bytes),
        Err(Error::WrongSource | Error::BadSignature)
    ));
    // A reader's floor refuses an older seq (no rollback through the relay).
    assert!(matches!(
        open(viewer, &source_public(&keys), &stream, Some(Position { epoch: 0, seq: 43 }), &bytes),
        Err(Error::Stale { .. })
    ));
}

#[test]
fn a_seal_without_usable_keys_is_refused() {
    let good = keys(1);
    let refused = |seal: ReplicaSeal| Sealer::new(seal).err().expect("refused").to_string();

    let mut seal = seal_of(&good);
    seal.source_key = "not base64!".into();
    assert!(refused(seal).contains("source_key"));
    let mut seal = seal_of(&good);
    seal.source_key = STANDARD.encode([0u8; 32]);
    assert!(refused(seal).contains("source_key"));
    let mut seal = seal_of(&good);
    seal.viewers = vec![];
    assert!(refused(seal).contains("viewers"));
    let mut seal = seal_of(&good);
    seal.viewers = vec![STANDARD.encode([4u8; 65])];
    assert!(refused(seal).contains("viewer"));
    assert!(refused(seal_of(&keys(MAX_VIEWERS + 1))).contains("viewers"));

    // The same device twice gets one envelope.
    let mut seal = seal_of(&good);
    seal.viewers.push(seal.viewers[0].clone());
    let sealed = Sealer::new(seal).unwrap().seal("host:h/session", 1, &json!({})).unwrap();
    assert_eq!(sealed["to"].as_object().unwrap().len(), 1);

    let debug = format!("{:?}", seal_of(&good));
    assert!(!debug.contains(&seal_of(&good).source_key), "{debug}");
}

struct Source;

impl HostSource for Source {
    fn session_state(&self) -> Value {
        json!({ "workspaces": [{ "id": "w1", "name": SECRET }] })
    }
    fn chief_state(&self) -> Option<Value> {
        Some(json!({ "messages": [{ "text": SECRET }] }))
    }
    fn apply(&self, _: &str, _: &Value, _: &str, _: &str) -> Result<Value, HostOpRefusal> {
        Ok(json!({}))
    }
}

fn params(seal: Option<ReplicaSeal>) -> HostReplicaParams {
    HostReplicaParams {
        api_base_url: "https://api.cmux.test".into(),
        install_token: INSTALL_TOKEN.into(),
        expires_at: 4_102_444_800_000,
        client_version: None,
        host_name: "studio".into(),
        seal,
    }
}

fn start_replica(require_seal: bool) -> (HostReplica, Arc<FakeBackend>, ScriptedWire) {
    let backend = Arc::new(FakeBackend::default());
    backend.reply("/v1/ops", 200, json!({"ok":true,"value":{"id":HOST,"name":"studio"}}));
    let wire = backend.wire();
    wire.push_text(json!({"t":"welcome","role":"publisher","host":HOST,"heads":{}}).to_string());
    let replica = HostReplica::with_options(
        backend.clone(),
        HostReplicaOptions {
            backoff_min: Duration::from_millis(5),
            backoff_max: Duration::from_millis(20),
            poll: Duration::from_millis(5),
            settle: Duration::from_millis(5),
            max_delay: Duration::from_millis(50),
            require_seal,
            ..HostReplicaOptions::default()
        },
    );
    replica.start(Arc::new(Source)).unwrap();
    (replica, backend, wire)
}

fn frames(wire: &ScriptedWire) -> Vec<Value> {
    wire.sent().iter().map(|text| serde_json::from_str(text).unwrap()).collect()
}

fn snapshot_of(wire: &ScriptedWire, suffix: &str) -> Value {
    let stream = format!("host:{HOST}/{suffix}");
    let found = |frames: Vec<Value>| {
        frames
            .into_iter()
            .find(|f| f["t"] == "publish" && f["stream"] == stream && f["snapshot"].is_object())
    };
    wait_until(suffix, || found(frames(wire)).is_some());
    found(frames(wire)).unwrap()
}

/// With a seal on the lease, the session and Chief snapshots and a reader's
/// `snapshot.request` answer carry only sealed state, which the paired
/// viewer opens at the frame's own seq.
#[test]
fn a_sealed_lease_publishes_only_sealed_state() {
    let keys = keys(2);
    let (replica, _backend, wire) = start_replica(false);
    let status = replica.set_lease(params(Some(seal_of(&keys)))).unwrap();
    assert!(!status.to_string().contains(&seal_of(&keys).source_key));

    for suffix in ["session", "chief"] {
        let frame = snapshot_of(&wire, suffix);
        let snapshot = &frame["snapshot"];
        let seq = snapshot["seq"].as_u64().unwrap();
        assert_eq!(snapshot["state"]["sealed"], SEALED_FORMAT, "{suffix}");
        let viewer = &keys.viewers[1];
        let stream = format!("host:{HOST}/{suffix}");
        let opened = open(
            viewer,
            &source_public(&keys),
            &stream,
            None,
            &envelope(&snapshot["state"], viewer),
        )
        .unwrap();
        assert_eq!(opened.position, Position { epoch: 0, seq });
        assert!(String::from_utf8(opened.plaintext).unwrap().contains(SECRET));
    }

    wire.push_text(
        json!({"t":"snapshot.request","stream":format!("host:{HOST}/session"),"to":"reader1","pending":[]})
            .to_string(),
    );
    let answered =
        || frames(&wire).into_iter().find(|f| f["t"] == "snapshot" && f["to"] == "reader1");
    wait_until("the reader's answer", || answered().is_some());
    assert_eq!(answered().unwrap()["state"]["sealed"], SEALED_FORMAT);

    assert!(
        wire.sent().iter().all(|text| !text.contains(SECRET)),
        "no frame carries the plaintext"
    );
    replica.shutdown();
}

#[test]
fn without_a_seal_the_frames_are_unchanged_and_require_seal_refuses_the_lease() {
    let (replica, _backend, wire) = start_replica(false);
    replica.set_lease(params(None)).unwrap();
    let frame = snapshot_of(&wire, "session");
    assert!(frame["snapshot"]["state"].to_string().contains(SECRET), "off: today's frames");
    replica.shutdown();

    let (replica, backend, _wire) = start_replica(true);
    let refused = replica.set_lease(params(None)).err().expect("refused").to_string();
    assert!(refused.contains("seal is required"), "{refused}");
    std::thread::sleep(Duration::from_millis(30));
    assert!(backend.posted().is_empty() && backend.connected().is_empty(), "nothing enrolled");
    replica.shutdown();
}
