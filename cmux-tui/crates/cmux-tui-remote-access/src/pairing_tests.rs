use super::*;

#[test]
fn only_one_request_per_peer_can_be_pending() {
    let broker = PairingBroker::new();
    let peer = "127.0.0.1".parse().unwrap();
    let (challenge, _rx) = broker.begin(peer).unwrap();
    assert!(matches!(broker.begin(peer), Err(PairingError::AlreadyPending)));
    broker.cancel(challenge.id);
    assert!(broker.begin(peer).is_ok());
}

#[test]
fn approval_issues_an_authenticating_credential() {
    let broker = PairingBroker::new();
    let (challenge, rx) = broker.begin("127.0.0.1".parse().unwrap()).unwrap();
    assert!(broker.respond(challenge.id, true));
    let PairingDecision::Approved { credential } = rx.recv().unwrap() else {
        panic!("expected approval");
    };
    assert!(broker.authenticate(&credential));
    assert!(!broker.authenticate("wrong"));
}

#[test]
fn challenge_is_six_grouped_digits() {
    let broker = PairingBroker::new();
    let (challenge, _rx) = broker.begin("127.0.0.1".parse().unwrap()).unwrap();
    assert_eq!(challenge.code.len(), 7);
    assert_eq!(challenge.code.as_bytes()[3], b' ');
    assert!(challenge.code.chars().filter(|ch| *ch != ' ').all(|ch| ch.is_ascii_digit()));
}

#[test]
fn repeated_requests_from_one_address_are_rate_limited() {
    let broker = PairingBroker::new();
    let peer = "127.0.0.1".parse().unwrap();
    for _ in 0..MAX_REQUESTS_PER_WINDOW {
        let (challenge, _rx) = broker.begin(peer).unwrap();
        assert!(broker.cancel(challenge.id));
    }
    assert!(matches!(broker.begin(peer), Err(PairingError::RateLimited)));
}

#[test]
fn a_page_bound_credential_expires_after_two_minutes() {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU64, Ordering};
    let start = Instant::now();
    let elapsed = Arc::new(AtomicU64::new(0));
    let clock = elapsed.clone();
    let broker = PairingBroker::with_clock(move || {
        start + Duration::from_secs(clock.load(Ordering::SeqCst))
    });
    let (fresh, ttl) = broker.issue_for_page("home-channels").unwrap();
    assert_eq!(ttl, 120);
    let (stale, _) = broker.issue_for_page("home-channels").unwrap();
    elapsed.store(119, Ordering::SeqCst);
    assert_eq!(broker.authenticate_for(&fresh, Some("home-channels")), CredentialMatch::Page);
    elapsed.store(121, Ordering::SeqCst);
    assert_eq!(broker.authenticate_for(&stale, Some("home-channels")), CredentialMatch::None);
}
