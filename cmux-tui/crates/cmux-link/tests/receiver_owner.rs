use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use cmux_link::dial::Service;
use cmux_link::keyset::Keyset;
use cmux_link::native_token::receiver::Owner;
use cmux_link::native_token::{NativeBinding, NativePeer, NativePolicy, ReceiverTime};
use cmux_link::token::{Expected, TokenRefused, TokenVerifier};
use serde_json::Value;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const NOW: u64 = 1_792_000_010_000;
fn fixture() -> Value {
    serde_json::from_str(include_str!("../../../../schemas/link-token/native.json")).unwrap()
}
fn keys() -> Keyset {
    let f = fixture();
    Keyset {
        version: "0000000000000001".into(),
        keys: [(
            f["kid"].as_str().unwrap().into(),
            URL_SAFE_NO_PAD.decode(f["public_key"].as_str().unwrap()).unwrap().try_into().unwrap(),
        )]
        .into(),
    }
}
fn policy(started: Instant, checked: u64) -> NativePolicy {
    let f = fixture();
    NativePolicy {
        issuer: f["claims"]["iss"].as_str().unwrap().into(),
        host: f["claims"]["aud"].as_str().unwrap().into(),
        epoch: 4,
        team: f["claims"]["team"].as_str().unwrap().into(),
        authority_version: "c".repeat(64),
        checked_at_ms: checked,
        expires_at_ms: checked + 30_000,
        request_started: started,
        peers: vec![NativePeer {
            install: f["claims"]["sub"].as_str().unwrap().into(),
            binding: serde_json::from_value::<NativeBinding>(f["claims"]["network"].clone())
                .unwrap(),
            services: vec![Service::Daemon, Service::Ssh],
        }],
    }
}
fn expected() -> Expected<'static> {
    Expected {
        host: "host_00000000000000000002",
        epoch: 4,
        service: Service::Daemon,
        peer_key: &[b'a'; 32],
    }
}
fn owner() -> (Owner, Arc<Mutex<Instant>>) {
    let now = Arc::new(Mutex::new(Instant::now()));
    let clock = now.clone();
    (Owner::with_clock(keys(), move || Some(*clock.lock().unwrap())).unwrap(), now)
}

#[test]
fn receiver_owner_atomic_snapshot_preserves_a_current_stream() {
    let (owner, clock) = owner();
    let first = owner.begin().unwrap();
    let start = first.started();
    owner
        .install(first, keys(), policy(start, NOW), ReceiverTime { unix_ms: NOW, monotonic: start })
        .unwrap();
    let verifier = owner.verifier();
    let stream =
        verifier.verify(fixture()["token"].as_str().unwrap(), &expected()).unwrap().lease.unwrap();
    *clock.lock().unwrap() += Duration::from_secs(1);
    let second = owner.begin().unwrap();
    let start = second.started();
    // A newly calibrated issuer upper bound can pass the old snapshot's
    // NumericDate expiry while its monotonic lease is still live. Publish
    // the new authenticated policy with its keys/time as one state change.
    owner
        .install(
            second,
            keys(),
            policy(start, NOW + 31_000),
            ReceiverTime { unix_ms: NOW + 31_000, monotonic: start },
        )
        .unwrap();
    assert!(stream.deadline().is_some(), "partial snapshot publication revoked a current stream");
}

#[test]
fn receiver_owner_late_reply_cannot_reopen_invalidated_authority() {
    let (owner, _) = owner();
    let read = owner.begin().unwrap();
    let start = read.started();
    owner.invalidate();
    assert!(
        owner
            .install(
                read,
                keys(),
                policy(start, NOW),
                ReceiverTime { unix_ms: NOW, monotonic: start }
            )
            .is_err()
    );
}

#[test]
fn receiver_owner_superseded_read_cannot_overwrite_a_newer_intent() {
    let (owner, _) = owner();
    let older = owner.begin().unwrap();
    let newer = owner.begin().unwrap();
    let start = newer.started();
    owner
        .install(newer, keys(), policy(start, NOW), ReceiverTime { unix_ms: NOW, monotonic: start })
        .unwrap();
    let start = older.started();
    assert!(
        owner
            .install(
                older,
                keys(),
                policy(start, NOW + 1),
                ReceiverTime { unix_ms: NOW + 1, monotonic: start }
            )
            .is_err()
    );
}

#[test]
fn receiver_owner_superseded_failure_cannot_clear_current_authority() {
    let (owner, _) = owner();
    let older = owner.begin().unwrap();
    let newer = owner.begin().unwrap();
    let start = newer.started();
    owner
        .install(newer, keys(), policy(start, NOW), ReceiverTime { unix_ms: NOW, monotonic: start })
        .unwrap();
    assert!(!owner.fail(older));
    assert!(owner.verifier().verify(fixture()["token"].as_str().unwrap(), &expected()).is_ok());
}

#[test]
fn receiver_owner_keeps_original_jws_identity_and_single_use() {
    let (owner, _) = owner();
    let read = owner.begin().unwrap();
    let start = read.started();
    owner
        .install(read, keys(), policy(start, NOW), ReceiverTime { unix_ms: NOW, monotonic: start })
        .unwrap();
    let verifier = owner.verifier();
    let f = fixture();
    let verified = verifier.verify(f["token"].as_str().unwrap(), &expected()).unwrap();
    assert_eq!(verified.issued_at_ms, 1_792_000_000_000);
    assert_eq!(
        verifier.verify(f["token"].as_str().unwrap(), &expected()),
        Err(TokenRefused::Replayed)
    );
}

#[test]
fn receiver_owner_dropped_current_read_closes_authority_but_stale_drop_does_not() {
    let (owner, _) = owner();
    let first = owner.begin().unwrap();
    let start = first.started();
    owner
        .install(first, keys(), policy(start, NOW), ReceiverTime { unix_ms: NOW, monotonic: start })
        .unwrap();
    let verifier = owner.verifier();
    let lease =
        verifier.verify(fixture()["token"].as_str().unwrap(), &expected()).unwrap().lease.unwrap();
    let stale = owner.begin().unwrap();
    let current = owner.begin().unwrap();
    drop(stale);
    assert!(lease.deadline().is_some());
    drop(current);
    assert!(lease.deadline().is_none());
}

#[test]
fn receiver_owner_readers_cannot_publish_partial_snapshots() {
    let (owner, _) = owner();
    let first = owner.begin().unwrap();
    let start = first.started();
    owner
        .install(first, keys(), policy(start, NOW), ReceiverTime { unix_ms: NOW, monotonic: start })
        .unwrap();
    let verifier = owner.verifier();
    assert!(verifier.replace_keys(keys()).is_err());
    assert!(verifier.replace_authority(policy(start, NOW + 1)).is_err());
    assert!(verifier.verify(fixture()["token"].as_str().unwrap(), &expected()).is_ok());
}

#[test]
fn receiver_owner_drop_closes_retained_verifier_and_active_lease() {
    let (owner, _) = owner();
    let first = owner.begin().unwrap();
    let start = first.started();
    owner
        .install(first, keys(), policy(start, NOW), ReceiverTime { unix_ms: NOW, monotonic: start })
        .unwrap();
    let verifier = owner.verifier();
    let token = fixture()["token"].as_str().unwrap().to_owned();
    let lease = verifier.verify(&token, &expected()).unwrap().lease.unwrap();
    drop(owner);
    assert!(lease.deadline().is_none());
    assert!(verifier.verify(&token, &expected()).is_err());
}

#[test]
fn receiver_owner_invalid_current_snapshot_closes_then_recovers_without_replay_reset() {
    let (owner, _) = owner();
    let first = owner.begin().unwrap();
    let start = first.started();
    owner
        .install(first, keys(), policy(start, NOW), ReceiverTime { unix_ms: NOW, monotonic: start })
        .unwrap();
    let verifier = owner.verifier();
    let token = fixture()["token"].as_str().unwrap().to_owned();
    let lease = verifier.verify(&token, &expected()).unwrap().lease.unwrap();
    let second = owner.begin().unwrap();
    let start = second.started();
    let mut bad = policy(start, NOW + 1);
    bad.epoch = 0;
    assert!(
        owner
            .install(second, keys(), bad, ReceiverTime { unix_ms: NOW + 1, monotonic: start })
            .is_err()
    );
    assert!(lease.deadline().is_none());
    let third = owner.begin().unwrap();
    let start = third.started();
    owner
        .install(
            third,
            keys(),
            policy(start, NOW + 2),
            ReceiverTime { unix_ms: NOW + 2, monotonic: start },
        )
        .unwrap();
    assert_eq!(verifier.verify(&token, &expected()), Err(TokenRefused::Replayed));
}
