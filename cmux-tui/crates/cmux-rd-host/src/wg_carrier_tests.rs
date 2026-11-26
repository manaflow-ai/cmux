use super::*;
#[test]
fn retry_needs_matching_peer_ack_and_delivery() {
    let now = Instant::now();
    let mut a = Retry::default();
    let mut b = Retry::default();
    let mut a_out = VecDeque::new();
    let mut b_out = VecDeque::new();
    a.receive(&Control::WgFallbackAck { reason: WgFallbackReason::Timeout }, now, &mut a_out);
    assert!(a.ready(true).is_none());
    a.request(WgFallbackReason::Timeout, now, &mut a_out);
    let proposal = a_out.pop_front().unwrap();
    b.receive(&proposal, now, &mut b_out);
    b.receive(&proposal, now, &mut b_out);
    assert_eq!(b_out.len(), 2);
    assert!(a.ready(true).is_none());
    assert!(b.ready(true).is_none());
    while let Some(record) = b_out.pop_front() {
        a.receive(&record, now, &mut a_out);
    }
    assert!(a.ready(false).is_none());
    assert_eq!(a.ready(true), Some(WgFallbackReason::Timeout));
    while let Some(record) = a_out.pop_front() {
        b.receive(&record, now, &mut b_out);
    }
    assert_eq!(b.ready(true), Some(WgFallbackReason::Timeout));
}
#[test]
fn no_retry_after_ready_or_for_authorization_reasons() {
    let mut n = Negotiation::new(Role::Host).unwrap();
    let now = Instant::now();
    n.begin(now);
    n.commit();
    assert!(n.accept(br#"{"t":"wg_fallback","reason":"timeout"}"#, now));
    assert_eq!(n.state(true), State::Failed);
    for reason in ["revoked", "consent_denied", "peer_mismatch"] {
        assert!(serde_json::from_value::<Control>(
            serde_json::json!({"t":"wg_fallback","reason":reason})
        )
        .is_err());
    }
}
#[test]
fn missing_ack_expires_and_wrong_ack_never_authorizes_retry() {
    let now = Instant::now();
    let mut retry = Retry::default();
    let mut out = VecDeque::new();
    retry.request(WgFallbackReason::Timeout, now, &mut out);
    retry.receive(&Control::WgFallbackAck { reason: WgFallbackReason::Unsupported }, now, &mut out);
    assert!(retry.ready(true).is_none());
    assert!(!retry.expired(now + RETRY_TIMEOUT - Duration::from_millis(1)));
    assert!(retry.expired(now + RETRY_TIMEOUT));
}
#[test]
fn invalid_retry_reason_fails_closed_before_ready() {
    for reason in ["revoked", "consent_denied", "peer_mismatch"] {
        let mut n = Negotiation::new(Role::Host).unwrap();
        let now = Instant::now();
        n.begin(now);
        let record = serde_json::json!({"t":"wg_fallback","reason":reason}).to_string();
        assert!(n.accept(record.as_bytes(), now));
        assert_eq!(n.state(true), State::Failed);
    }
}
#[test]
fn key_and_address_offer_is_public_only() {
    let mut host = Negotiation::new(Role::Host).unwrap();
    host.begin(Instant::now());
    host.begin(Instant::now());
    assert_eq!(host.outgoing.len(), 1);
    let text = serde_json::to_string(&host.outgoing[0]).unwrap();
    assert!(text.contains("10.253.0.1"));
    assert!(!text.contains(&crate::serve::hex(&*host.private)));
    assert!(usize::from(MTU) + 32 <= OUTER_MAX);
}
