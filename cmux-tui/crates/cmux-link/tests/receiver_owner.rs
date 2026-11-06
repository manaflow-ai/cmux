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

#[path = "receiver_owner/suspend.rs"]
mod suspend;
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
fn receiver_owner_retirement_drains_streams_and_cannot_be_reopened() {
    let (owner, _) = owner();
    let read = owner.begin().unwrap();
    let started = read.started();
    owner
        .install(
            read,
            keys(),
            policy(started, NOW),
            ReceiverTime { unix_ms: NOW, monotonic: started },
        )
        .unwrap();
    let lease = owner
        .verifier()
        .verify(fixture()["token"].as_str().unwrap(), &expected())
        .unwrap()
        .lease
        .unwrap();
    assert!(!owner.is_retired());
    assert!(owner.retire(owner.begin().unwrap()));
    assert!(owner.is_retired());
    assert!(lease.deadline().is_none());
    owner.invalidate();
    assert!(owner.is_retired(), "transient invalidation reopened a retired owner");
    assert!(owner.begin().is_err(), "retired generation prepared another read");
}

#[test]
fn receiver_owner_retirement_requires_its_current_read_intent() {
    let (owner, _) = owner();
    let (other, _) = self::owner();
    assert!(!owner.retire(other.begin().unwrap()));
    assert!(!owner.is_retired());
    assert!(!other.is_retired());
    let older = owner.begin().unwrap();
    let newer = owner.begin().unwrap();
    let started = newer.started();
    owner
        .install(
            newer,
            keys(),
            policy(started, NOW),
            ReceiverTime { unix_ms: NOW, monotonic: started },
        )
        .unwrap();
    assert!(!owner.retire(older));
    assert!(!owner.is_retired());
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

#[test]
fn receiver_handshake_does_not_spend_a_token_or_replace_service_authority() {
    let (owner, _) = owner();
    let first = owner.begin().unwrap();
    let start = first.started();
    owner
        .install(first, keys(), policy(start, NOW), ReceiverTime { unix_ms: NOW, monotonic: start })
        .unwrap();
    let verifier = owner.verifier();
    let handshake = verifier.begin_handshake(expected().host, 4, expected().peer_key).unwrap();
    let token = fixture()["token"].as_str().unwrap().to_owned();
    let verified = verifier.verify(&token, &expected()).unwrap();
    drop(handshake);
    assert!(verified.lease.unwrap().deadline().is_some());
    assert_eq!(verifier.verify(&token, &expected()), Err(TokenRefused::Replayed));
}

#[test]
fn receiver_handshake_renewal_cannot_extend_or_revive_a_partial_hello() {
    let (owner, clock) = owner();
    let first = owner.begin().unwrap();
    let start = first.started();
    owner
        .install(first, keys(), policy(start, NOW), ReceiverTime { unix_ms: NOW, monotonic: start })
        .unwrap();
    let verifier = owner.verifier();
    let handshake = verifier.begin_handshake(expected().host, 4, expected().peer_key).unwrap();
    let token = verifier.verify(fixture()["token"].as_str().unwrap(), &expected()).unwrap();
    let initial = handshake.deadline().unwrap();
    for elapsed in [1000, 30_000] {
        *clock.lock().unwrap() = start + Duration::from_millis(elapsed);
        let fresh = owner.begin().unwrap();
        let began = fresh.started();
        owner
            .install(
                fresh,
                keys(),
                policy(began, NOW + elapsed),
                ReceiverTime { unix_ms: NOW + elapsed, monotonic: began },
            )
            .unwrap();
        if elapsed == 1000 {
            assert_eq!(handshake.deadline(), Some(initial));
        } else {
            assert!(handshake.deadline().is_none());
            assert!(verifier.begin_handshake(expected().host, 4, expected().peer_key).is_ok());
            assert!(handshake.deadline().is_none(), "a new read revived an old partial hello");
        }
        assert!(token.lease.as_ref().unwrap().deadline().unwrap() > initial);
    }
}

#[test]
fn receiver_handshake_fences_every_authority_incarnation_and_service_change() {
    for change in ["generation", "peer", "services", "team", "epoch", "host"] {
        let (owner, _) = owner();
        let first = owner.begin().unwrap();
        let start = first.started();
        owner
            .install(
                first,
                keys(),
                policy(start, NOW),
                ReceiverTime { unix_ms: NOW, monotonic: start },
            )
            .unwrap();
        let handshake =
            owner.verifier().begin_handshake(expected().host, 4, expected().peer_key).unwrap();
        let next = owner.begin().unwrap();
        let start = next.started();
        let mut fresh = policy(start, NOW + 1);
        match change {
            "generation" => fresh.authority_version = "d".repeat(64),
            "peer" => fresh.peers[0].binding.authority_version = "d".repeat(64),
            "services" => fresh.peers[0].services = vec![Service::Ssh],
            "team" => fresh.team = "team_00000000000000000002".into(),
            "epoch" => fresh.epoch += 1,
            "host" => fresh.host = "host_00000000000000000003".into(),
            _ => unreachable!(),
        }
        owner
            .install(next, keys(), fresh, ReceiverTime { unix_ms: NOW + 1, monotonic: start })
            .unwrap();
        assert!(handshake.deadline().is_none(), "{change}");
    }
}

#[test]
fn receiver_handshake_pins_keys_while_ignoring_keyset_version_metadata() {
    let (owner, _) = owner();
    let first = owner.begin().unwrap();
    let start = first.started();
    owner
        .install(first, keys(), policy(start, NOW), ReceiverTime { unix_ms: NOW, monotonic: start })
        .unwrap();
    let handshake =
        owner.verifier().begin_handshake(expected().host, 4, expected().peer_key).unwrap();
    for changed in [false, true] {
        let next = owner.begin().unwrap();
        let start = next.started();
        let mut updated = keys();
        updated.version = "0000000000000002".into();
        if changed {
            updated.keys = [("replacement".into(), [7; 32])].into();
        }
        let checked = NOW + if changed { 2 } else { 1 };
        owner
            .install(
                next,
                updated,
                policy(start, checked),
                ReceiverTime { unix_ms: checked, monotonic: start },
            )
            .unwrap();
        assert_eq!(handshake.deadline().is_none(), changed);
    }
}

#[test]
fn receiver_handshake_rejects_another_host_epoch_or_transport_key() {
    let (owner, _) = owner();
    let first = owner.begin().unwrap();
    let start = first.started();
    owner
        .install(first, keys(), policy(start, NOW), ReceiverTime { unix_ms: NOW, monotonic: start })
        .unwrap();
    let verifier = owner.verifier();
    assert!(verifier.begin_handshake("host_00000000000000000003", 4, expected().peer_key).is_err());
    assert!(verifier.begin_handshake(expected().host, 5, expected().peer_key).is_err());
    assert!(verifier.begin_handshake(expected().host, 4, &[7; 32]).is_err());
    assert!(verifier.begin_handshake(expected().host, 4, expected().peer_key).is_ok());
}

#[test]
fn receiver_handshake_storage_is_bounded_and_dropped_slots_are_reusable() {
    let (owner, _) = owner();
    let first = owner.begin().unwrap();
    let start = first.started();
    owner
        .install(first, keys(), policy(start, NOW), ReceiverTime { unix_ms: NOW, monotonic: start })
        .unwrap();
    let verifier = owner.verifier();
    let mut held: Vec<_> = (0..4096)
        .map(|_| verifier.begin_handshake(expected().host, 4, expected().peer_key).unwrap())
        .collect();
    assert!(verifier.begin_handshake(expected().host, 4, expected().peer_key).is_err());
    held.pop();
    assert!(verifier.begin_handshake(expected().host, 4, expected().peer_key).is_ok());
    drop(held);
    assert!(verifier.verify(fixture()["token"].as_str().unwrap(), &expected()).is_ok());
}
