//! Stream leases preserve the exact authority verified before handoff. A new
//! grant with the same public install/user ids cannot adopt an older stream.
use std::future::Future;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
};
use std::task::{Context, Poll, Wake, Waker};
use std::time::{Duration, Instant};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use cmux_link::dial::Service;
use cmux_link::keyset::Keyset;
use cmux_link::native_token::{NativePeer, NativePolicy, NativeTokenVerifier, ReceiverTime};
use cmux_link::stream_lease::StreamLease;
use cmux_link::token::{Expected, TokenRefused, TokenVerifier};
use serde_json::Value;

type Clock = Arc<Mutex<ReceiverTime>>;
fn fixture() -> Value {
    serde_json::from_str(include_str!("../../../../schemas/link-token/native.json")).unwrap()
}

fn configured() -> (NativeTokenVerifier, Clock, NativePolicy) {
    let f = fixture();
    let now = ReceiverTime { unix_ms: 1_792_000_010_000, monotonic: Instant::now() };
    let clock = Arc::new(Mutex::new(now));
    let reader = clock.clone();
    let keys = Keyset {
        version: "0000000000000001".into(),
        keys: [(
            f["kid"].as_str().unwrap().into(),
            URL_SAFE_NO_PAD.decode(f["public_key"].as_str().unwrap()).unwrap().try_into().unwrap(),
        )]
        .into(),
    };
    let verifier =
        NativeTokenVerifier::new(keys, move || Some(*reader.lock().unwrap()), 16).unwrap();
    let policy = NativePolicy {
        issuer: f["claims"]["iss"].as_str().unwrap().into(),
        host: f["claims"]["aud"].as_str().unwrap().into(),
        epoch: 4,
        team: f["claims"]["team"].as_str().unwrap().into(),
        authority_version: "c".repeat(64),
        checked_at_ms: now.unix_ms,
        expires_at_ms: now.unix_ms + 30_000,
        request_started: now.monotonic,
        peers: vec![NativePeer {
            install: f["claims"]["sub"].as_str().unwrap().into(),
            binding: serde_json::from_value(f["claims"]["network"].clone()).unwrap(),
            services: vec![Service::Daemon, Service::Ssh],
        }],
    };
    verifier.replace_authority(policy.clone()).unwrap();
    (verifier, clock, policy)
}

fn expected(service: Service) -> Expected<'static> {
    Expected { host: "host_00000000000000000002", epoch: 4, service, peer_key: &[b'a'; 32] }
}
fn lease(verifier: &NativeTokenVerifier, service: Service) -> StreamLease {
    verifier
        .verify(fixture()["token"].as_str().unwrap(), &expected(service))
        .unwrap()
        .lease
        .unwrap()
}
fn refresh(clock: &Clock, policy: &mut NativePolicy, elapsed: u64) {
    let mut now = clock.lock().unwrap();
    now.unix_ms += elapsed;
    now.monotonic += Duration::from_millis(elapsed);
    policy.checked_at_ms = now.unix_ms;
    policy.expires_at_ms = now.unix_ms + 30_000;
    policy.request_started = now.monotonic;
}

#[test]
fn native_receiver_stream_same_ids_with_replacement_authority_cannot_adopt_old_stream() {
    let (verifier, clock, mut policy) = configured();
    let stream = lease(&verifier, Service::Daemon);
    let original = policy.peers[0].binding.authority_version.clone();
    policy.peers[0].binding.authority_version = "b".repeat(64);
    refresh(&clock, &mut policy, 1);
    verifier.replace_authority(policy.clone()).unwrap();
    assert!(stream.deadline().is_none());
    policy.peers[0].binding.authority_version = original;
    refresh(&clock, &mut policy, 1);
    verifier.replace_authority(policy).unwrap();
    assert!(stream.deadline().is_none(), "a new generation revived an already revoked lease");
    assert_eq!(
        verifier.verify(fixture()["token"].as_str().unwrap(), &expected(Service::Daemon)),
        Err(TokenRefused::Replayed)
    );
}

#[test]
fn native_receiver_stream_policy_removal_or_binding_changes_revoke_active_lease() {
    for field in [
        "remove",
        "user",
        "device",
        "host",
        "wg",
        "acl",
        "epoch",
        "team",
        "issuer",
        "destination",
        "receiving_generation",
    ] {
        let (verifier, clock, mut policy) = configured();
        let stream = lease(&verifier, Service::Daemon);
        match field {
            "remove" => policy.peers.clear(),
            "user" => policy.peers[0].binding.user = "user_00000000000000000003".into(),
            "device" => policy.peers[0].binding.device = "dev_00000000000000000000000003".into(),
            "host" => policy.peers[0].binding.host = "host_00000000000000000003".into(),
            "wg" => {
                policy.peers[0].binding.wg_public_key =
                    base64::engine::general_purpose::STANDARD.encode([3u8; 32]);
            }
            "acl" => policy.peers[0].binding.acl_version += 1,
            "epoch" => policy.epoch += 1,
            "team" => policy.team = "team_00000000000000000003".into(),
            "issuer" => policy.issuer = "cmux:cloud:another".into(),
            "destination" => policy.host = "host_00000000000000000003".into(),
            "receiving_generation" => policy.authority_version = "d".repeat(64),
            _ => unreachable!(),
        }
        refresh(&clock, &mut policy, 1);
        verifier.replace_authority(policy).unwrap();
        assert!(stream.deadline().is_none(), "kept old {field} authority");
    }
}

#[test]
fn native_receiver_stream_service_narrowing_only_retires_the_removed_service() {
    for service in [Service::Daemon, Service::Ssh] {
        let (verifier, clock, mut policy) = configured();
        let stream = lease(&verifier, service);
        policy.peers[0].services = vec![Service::Ssh];
        refresh(&clock, &mut policy, 1);
        verifier.replace_authority(policy).unwrap();
        assert_eq!(stream.deadline().is_some(), service == Service::Ssh);
    }
}

#[test]
fn native_receiver_stream_current_authority_can_renew_only_before_old_deadline() {
    for elapsed in [1000, 30_000, 30_001] {
        let (verifier, clock, mut policy) = configured();
        let stream = lease(&verifier, Service::Daemon);
        let original = stream.deadline().unwrap();
        refresh(&clock, &mut policy, elapsed);
        verifier.replace_authority(policy).unwrap();
        if elapsed < 30_000 {
            assert!(stream.deadline().unwrap() > original);
        } else {
            assert!(stream.deadline().is_none(), "late renewal resurrected a stream");
        }
    }
}

#[test]
fn native_receiver_stream_lease_debits_the_original_request_elapsed_time() {
    let (verifier, clock, mut policy) = configured();
    refresh(&clock, &mut policy, 1);
    policy.request_started -= Duration::from_secs(15);
    verifier.replace_authority(policy).unwrap();
    let stream = lease(&verifier, Service::Daemon);
    assert_eq!(
        stream.deadline().unwrap(),
        clock.lock().unwrap().monotonic + Duration::from_secs(15)
    );
}

#[test]
fn native_receiver_stream_owner_drop_revokes_a_retained_proof() {
    let (verifier, _, _) = configured();
    let stream = lease(&verifier, Service::Daemon);
    drop(verifier);
    assert!(stream.deadline().is_none());
}

#[derive(Default)]
struct Counter(AtomicUsize);
impl Wake for Counter {
    fn wake(self: Arc<Self>) {
        self.0.fetch_add(1, Ordering::SeqCst);
    }
}

#[test]
fn native_receiver_stream_each_cloned_observer_receives_revocation_without_a_tick() {
    let (verifier, _, _) = configured();
    let mut first = lease(&verifier, Service::Daemon);
    let mut second = first.clone();
    let one = Arc::new(Counter::default());
    let two = Arc::new(Counter::default());
    let w1 = Waker::from(one.clone());
    let w2 = Waker::from(two.clone());
    let mut f1 = Box::pin(first.changed());
    let mut f2 = Box::pin(second.changed());
    assert_eq!(f1.as_mut().poll(&mut Context::from_waker(&w1)), Poll::Pending);
    assert_eq!(f2.as_mut().poll(&mut Context::from_waker(&w2)), Poll::Pending);
    verifier.clear_authority();
    assert_eq!(one.0.load(Ordering::SeqCst), 1);
    assert_eq!(two.0.load(Ordering::SeqCst), 1);
    assert_eq!(f1.as_mut().poll(&mut Context::from_waker(&w1)), Poll::Ready(()));
    assert_eq!(f2.as_mut().poll(&mut Context::from_waker(&w2)), Poll::Ready(()));
}

#[test]
fn native_receiver_stream_revocation_before_await_is_not_lost() {
    let (verifier, _, _) = configured();
    let mut stream = lease(&verifier, Service::Daemon);
    verifier.clear_authority();
    let waker = Waker::from(Arc::new(Counter::default()));
    assert_eq!(
        Box::pin(stream.changed()).as_mut().poll(&mut Context::from_waker(&waker)),
        Poll::Ready(())
    );
}

#[test]
fn native_receiver_stream_clock_rollback_closes_old_authority_until_fresh_policy() {
    let (verifier, clock, mut policy) = configured();
    let stream = lease(&verifier, Service::Daemon);
    clock.lock().unwrap().unix_ms -= 1;
    assert_eq!(
        verifier.verify(fixture()["token"].as_str().unwrap(), &expected(Service::Daemon)),
        Err(TokenRefused::Invalid)
    );
    assert!(stream.deadline().is_none());
    refresh(&clock, &mut policy, 2);
    assert_eq!(
        verifier.verify(fixture()["token"].as_str().unwrap(), &expected(Service::Daemon)),
        Err(TokenRefused::NoVerifier)
    );
    verifier.replace_authority(policy).unwrap();
    assert!(stream.deadline().is_none());
    assert_eq!(
        verifier.verify(fixture()["token"].as_str().unwrap(), &expected(Service::Daemon)),
        Err(TokenRefused::Replayed)
    );
}

#[test]
fn native_receiver_stream_canceling_one_observer_keeps_the_other_registered() {
    let (verifier, _, _) = configured();
    let mut first = lease(&verifier, Service::Daemon);
    let mut second = first.clone();
    let one = Arc::new(Counter::default());
    let two = Arc::new(Counter::default());
    let w1 = Waker::from(one.clone());
    let w2 = Waker::from(two.clone());
    let mut f1 = Box::pin(first.changed());
    let mut f2 = Box::pin(second.changed());
    assert_eq!(f1.as_mut().poll(&mut Context::from_waker(&w1)), Poll::Pending);
    assert_eq!(f2.as_mut().poll(&mut Context::from_waker(&w2)), Poll::Pending);
    drop(f1);
    verifier.clear_authority();
    assert_eq!(one.0.load(Ordering::SeqCst), 0);
    assert_eq!(two.0.load(Ordering::SeqCst), 1);
    assert_eq!(f2.as_mut().poll(&mut Context::from_waker(&w2)), Poll::Ready(()));
}

/// Exhaust all four-event histories of authenticate, revoke, refresh, expiry
/// and signing-key rotation. The model tracks only observable authority and
/// whether the one-use fixture has been spent, independently of verifier state.
#[test]
fn native_receiver_stream_model_preserves_revocation_expiry_and_single_use() {
    let f = fixture();
    let original = Keyset {
        version: "0000000000000001".into(),
        keys: [(
            f["kid"].as_str().unwrap().into(),
            URL_SAFE_NO_PAD.decode(f["public_key"].as_str().unwrap()).unwrap().try_into().unwrap(),
        )]
        .into(),
    };
    for history in 0..6u32.pow(4) {
        let (verifier, clock, mut policy) = configured();
        let (mut authority, mut key, mut spent) = (true, true, false);
        let mut expires = policy.expires_at_ms;
        let mut opened: Option<(StreamLease, bool, Instant)> = None;
        let mut events = history;
        for _ in 0..4 {
            let event = events % 6;
            events /= 6;
            let now = *clock.lock().unwrap();
            match event {
                0 => {
                    let result =
                        verifier.verify(f["token"].as_str().unwrap(), &expected(Service::Daemon));
                    let allowed = authority && key && !spent && now.unix_ms < expires;
                    assert_eq!(result.is_ok(), allowed, "history {history}, authenticate");
                    if let Ok(verified) = result {
                        spent = true;
                        opened = Some((
                            verified.lease.unwrap(),
                            true,
                            now.monotonic + Duration::from_millis(expires - now.unix_ms),
                        ));
                    }
                    if authority && now.unix_ms >= expires {
                        authority = false;
                    }
                }
                1 => {
                    verifier.clear_authority();
                    authority = false;
                    if let Some((_, live, _)) = &mut opened {
                        *live = false;
                    }
                }
                2 => {
                    refresh(&clock, &mut policy, 1);
                    verifier.replace_authority(policy.clone()).unwrap();
                    authority = true;
                    expires = policy.expires_at_ms;
                    if let Some((_, live, deadline)) = &mut opened {
                        *live = *live && key;
                        if *live {
                            *deadline = policy.request_started + Duration::from_secs(30);
                        }
                    }
                }
                3 => {
                    let mut now = clock.lock().unwrap();
                    now.unix_ms += 30_001;
                    now.monotonic += Duration::from_millis(30_001);
                }
                4 => {
                    verifier
                        .replace_keys(Keyset {
                            version: "0000000000000002".into(),
                            keys: [("replacement".into(), [7; 32])].into(),
                        })
                        .unwrap();
                    key = false;
                    if let Some((_, live, _)) = &mut opened {
                        *live = false;
                    }
                }
                5 => {
                    verifier.replace_keys(original.clone()).unwrap();
                    key = true;
                }
                _ => unreachable!(),
            }
            let now = *clock.lock().unwrap();
            if let Some((lease, live, deadline)) = &mut opened {
                *live = *live && now.monotonic < *deadline;
                assert_eq!(
                    lease.deadline().is_some_and(|at| at > now.monotonic),
                    *live,
                    "history {history}, event {event}"
                );
            }
        }
    }
}

/// A dropped transport lease leaves only a weak verifier handle. Its capacity
/// must be reusable immediately, without a policy refresh or advancing time.
#[test]
fn native_receiver_dropped_handshakes_do_not_exhaust_stream_capacity() {
    let (verifier, _clock, _policy) = configured();
    for _ in 0..5_000 {
        let pending =
            verifier.begin_handshake("host_00000000000000000002", 4, &[b'a'; 32]).unwrap();
        drop(pending);
    }
    let authenticated = lease(&verifier, Service::Ssh);
    assert!(authenticated.deadline().is_some());
    verifier.clear_authority();
    assert!(authenticated.deadline().is_none(), "cleanup must preserve revocation");
}
