//! A failed renewal read is not a revocation: the receiver keeps the lease it
//! holds until that lease ends, and no longer. Before this, the first failed
//! read closed every stream and peer even with most of the lease left.
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use cmux_link::dial::Service;
use cmux_link::keyset::Keyset;
use cmux_link::native_token::receiver::{Owner, Refresh};
use cmux_link::native_token::{NativeBinding, NativePeer, NativePolicy, ReceiverTime};
use cmux_link::token::{Expected, TokenVerifier};
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
fn policy(started: Instant) -> NativePolicy {
    let f = fixture();
    NativePolicy {
        issuer: f["claims"]["iss"].as_str().unwrap().into(),
        host: f["claims"]["aud"].as_str().unwrap().into(),
        epoch: 4,
        team: f["claims"]["team"].as_str().unwrap().into(),
        authority_version: "c".repeat(64),
        checked_at_ms: NOW,
        expires_at_ms: NOW + 30_000,
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
fn token() -> String {
    fixture()["token"].as_str().unwrap().into()
}

/// An owner holding a fresh 30 s lease, and its injected active clock.
fn leased() -> (Owner, Arc<Mutex<Instant>>) {
    let now = Arc::new(Mutex::new(Instant::now()));
    let clock = now.clone();
    let owner = Owner::with_clock(keys(), move || Some(*clock.lock().unwrap())).unwrap();
    let read = owner.begin().unwrap();
    let start = read.started();
    owner
        .install(read, keys(), policy(start), ReceiverTime { unix_ms: NOW, monotonic: start })
        .unwrap();
    (owner, now)
}

fn renewal(owner: &Owner) -> Refresh {
    let mut read = owner.begin().unwrap();
    read.retain_installed();
    read
}

#[test]
fn a_failed_renewal_inside_the_lease_keeps_streams_and_admission() {
    let (owner, clock) = leased();
    let verifier = owner.verifier();
    let handshake = verifier.begin_handshake("host_00000000000000000002", 4, &[b'a'; 32]).unwrap();
    *clock.lock().unwrap() += Duration::from_secs(10);
    assert!(!owner.fail(renewal(&owner)), "a failed renewal closed a lease with 20 s left");
    assert!(handshake.deadline().is_some(), "an admitted stream closed on a failed read");
    // A valid token is still admitted after the failed read.
    let stream = verifier.verify(&token(), &expected()).unwrap().lease.unwrap();
    // An abandoned read (its future dropped mid-flight) keeps the lease too.
    *clock.lock().unwrap() += Duration::from_secs(5);
    drop(renewal(&owner));
    assert!(stream.deadline().is_some(), "an abandoned renewal closed a live stream");
    assert!(verifier.begin_handshake("host_00000000000000000002", 4, &[b'a'; 32]).is_ok());
    // Nothing moved the lease's end: it is still the installed policy's.
    assert!(stream.deadline().unwrap() <= *clock.lock().unwrap() + Duration::from_secs(15));
}

#[test]
fn reads_still_failing_when_the_lease_ends_close_streams_and_refuse_tokens() {
    let (owner, clock) = leased();
    let verifier = owner.verifier();
    let stream = verifier.verify(&token(), &expected()).unwrap().lease.unwrap();
    *clock.lock().unwrap() += Duration::from_secs(10);
    assert!(!owner.fail(renewal(&owner)));
    *clock.lock().unwrap() += Duration::from_secs(21);
    assert!(owner.fail(renewal(&owner)), "a failed read past the lease kept authority");
    assert!(stream.deadline().is_none(), "a stream outlived its lease");
    assert!(verifier.verify(&token(), &expected()).is_err());
    assert!(verifier.begin_handshake("host_00000000000000000002", 4, &[b'a'; 32]).is_err());
}

#[test]
fn a_retirement_during_renewal_still_closes_at_once() {
    let (owner, _) = leased();
    let verifier = owner.verifier();
    let stream = verifier.verify(&token(), &expected()).unwrap().lease.unwrap();
    assert!(owner.retire(renewal(&owner)));
    assert!(owner.is_retired());
    assert!(stream.deadline().is_none(), "a retired generation kept a stream");
    assert!(verifier.begin_handshake("host_00000000000000000002", 4, &[b'a'; 32]).is_err());
}

#[test]
fn a_failed_first_read_without_retention_still_closes() {
    let (owner, _) = leased();
    let stream = owner.verifier().verify(&token(), &expected()).unwrap().lease.unwrap();
    assert!(owner.fail(owner.begin().unwrap()));
    assert!(stream.deadline().is_none());
}

#[test]
fn a_superseded_renewal_cannot_install_late_and_keeps_the_lease() {
    let (owner, clock) = leased();
    let stream = owner.verifier().verify(&token(), &expected()).unwrap().lease.unwrap();
    *clock.lock().unwrap() += Duration::from_secs(1);
    // A renewal whose waiter gave up keeps running detached; the loop then
    // supersedes it with a fresh retained intent that it drops at once.
    let detached = renewal(&owner);
    let start = detached.started();
    drop(renewal(&owner));
    assert!(stream.deadline().is_some(), "superseding a renewal closed a valid lease");
    let late = owner.install(
        detached,
        keys(),
        NativePolicy { checked_at_ms: NOW + 1_000, ..policy(start) },
        ReceiverTime { unix_ms: NOW + 1_000, monotonic: start },
    );
    assert!(late.is_err(), "a detached renewal installed a policy the receiver never got");
    assert!(stream.deadline().is_some());
}

#[test]
fn a_rejected_renewal_reply_closes_at_once() {
    let (owner, _) = leased();
    let stream = owner.verifier().verify(&token(), &expected()).unwrap().lease.unwrap();
    // An authenticated reply that fails validation is not a transport
    // failure: it must not leave the old peers authorized.
    assert!(owner.reject(renewal(&owner)));
    assert!(stream.deadline().is_none(), "a rejected snapshot kept an old stream");
    assert!(owner.verifier().verify(&token(), &expected()).is_err());
}
