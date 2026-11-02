//! The two local clocks advance independently; no host is actually suspended.
use super::*;
use cmux_link::elapsed::Elapsed;

type ElapsedValue = Arc<Mutex<Option<Duration>>>;

fn suspended_owner() -> (Owner, Instant, ElapsedValue) {
    let active = Instant::now();
    let value = Arc::new(Mutex::new(Some(Duration::from_secs(10))));
    let source = value.clone();
    let elapsed = Elapsed::capture(move || *source.lock().unwrap()).unwrap();
    let owner = Owner::with_elapsed_clock(keys(), move || Some(active), elapsed).unwrap();
    (owner, active, value)
}

fn publish(owner: &Owner, active: Instant, checked: u64) {
    owner
        .install(
            owner.begin().unwrap(),
            keys(),
            policy(active, checked),
            ReceiverTime { unix_ms: checked, monotonic: active },
        )
        .unwrap();
}

#[test]
fn receiver_owner_suspend_expiry_refuses_new_admission_and_drains_old_lease() {
    let (owner, active, clock) = suspended_owner();
    publish(&owner, active, NOW);
    let verifier = owner.verifier();
    let lease = verifier.begin_handshake(expected().host, 4, &[b'a'; 32]).unwrap();
    assert!(lease.deadline().is_some());
    *clock.lock().unwrap() = Some(Duration::from_secs(40));
    assert_eq!(
        verifier.begin_handshake(expected().host, 4, &[b'a'; 32]).err(),
        Some(TokenRefused::Expired)
    );
    assert!(lease.deadline().is_none(), "new admission retained an expired pre-auth lease");
}

#[test]
fn receiver_owner_suspend_advances_jwt_time_before_the_policy_expires() {
    let (owner, active, clock) = suspended_owner();
    let expiry = fixture()["claims"]["exp"].as_u64().unwrap() * 1000;
    publish(&owner, active, expiry - 5_000);
    let verifier = owner.verifier();
    assert!(verifier.begin_handshake(expected().host, 4, &[b'a'; 32]).is_ok());
    *clock.lock().unwrap() = Some(Duration::from_secs(16));
    assert_eq!(
        verifier.verify(fixture()["token"].as_str().unwrap(), &expected()).err(),
        Some(TokenRefused::Expired),
        "a signed JWT outlived NumericDate expiry while active uptime was frozen"
    );
}

#[test]
fn receiver_owner_suspend_rejects_a_reply_that_did_not_debit_its_prepared_read() {
    let (owner, active, clock) = suspended_owner();
    let read = owner.begin().unwrap();
    *clock.lock().unwrap() = Some(Duration::from_secs(11));
    assert_eq!(read.elapsed(active), Some(Duration::from_secs(1)));
    assert!(
        owner
            .install(
                read,
                keys(),
                policy(active, NOW),
                ReceiverTime { unix_ms: NOW, monotonic: active }
            )
            .is_err(),
        "a queued read installed issuer time that ignored time spent suspended"
    );
}

#[test]
fn receiver_owner_suspend_renewal_cannot_revive_an_expired_stream() {
    let (owner, active, clock) = suspended_owner();
    publish(&owner, active, NOW);
    let lease = owner
        .verifier()
        .verify(fixture()["token"].as_str().unwrap(), &expected())
        .unwrap()
        .lease
        .unwrap();
    assert!(lease.deadline().is_some());
    *clock.lock().unwrap() = Some(Duration::from_secs(41));
    publish(&owner, active, NOW + 31_000);
    assert!(lease.deadline().is_none(), "fresh policy revived a stream whose elapsed budget ended");
    assert!(
        owner.verifier().begin_handshake(expected().host, 4, &[b'a'; 32]).is_ok(),
        "fresh policy must authorize a new connection"
    );
}

#[test]
fn receiver_owner_suspend_clock_failure_closes_retained_readers() {
    let (owner, active, clock) = suspended_owner();
    publish(&owner, active, NOW);
    let verifier = owner.verifier();
    let lease = verifier.begin_handshake(expected().host, 4, &[b'a'; 32]).unwrap();
    *clock.lock().unwrap() = None;
    assert!(
        verifier.begin_handshake(expected().host, 4, &[b'a'; 32]).is_err(),
        "a lost elapsed clock retained authority"
    );
    assert!(lease.deadline().is_none());
    *clock.lock().unwrap() = Some(Duration::from_secs(11));
    assert!(
        verifier.begin_handshake(expected().host, 4, &[b'a'; 32]).is_err(),
        "the original clock failure was forgotten"
    );
}

#[test]
fn receiver_owner_suspend_renewal_extends_the_stream_but_not_its_partial_hello() {
    let (owner, active, clock) = suspended_owner();
    publish(&owner, active, NOW);
    let verifier = owner.verifier();
    let hello = verifier.begin_handshake(expected().host, 4, &[b'a'; 32]).unwrap();
    let stream =
        verifier.verify(fixture()["token"].as_str().unwrap(), &expected()).unwrap().lease.unwrap();
    *clock.lock().unwrap() = Some(Duration::from_secs(11));
    publish(&owner, active, NOW + 1_000);
    *clock.lock().unwrap() = Some(Duration::from_secs(40));
    assert!(hello.deadline().is_none(), "renewal extended the original partial hello budget");
    assert!(stream.deadline().is_some(), "the current authenticated stream did not renew");
    assert!(verifier.begin_handshake(expected().host, 4, &[b'a'; 32]).is_ok());
    *clock.lock().unwrap() = Some(Duration::from_secs(41));
    assert!(stream.deadline().is_none(), "renewed stream outlived the new elapsed deadline");
}
