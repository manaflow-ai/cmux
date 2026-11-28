use super::*;

#[test]
fn session_unavailable_keeps_its_wire_form() {
    // Clients from before the capacity rejection parse this exact form.
    assert_eq!(
        serde_json::to_string(&LinkRejected::session_unavailable()).unwrap(),
        r#"{"rejected":"session-unavailable"}"#
    );
}

#[test]
fn too_many_clients_carries_the_limit_and_parses_as_a_rejection() {
    let encoded = serde_json::to_vec(&LinkRejected::too_many_clients(64)).unwrap();
    assert_eq!(encoded, br#"{"rejected":"too-many-clients","limit":64}"#);
    let decoded: LinkHandshakeResponse = serde_json::from_slice(&encoded).unwrap();
    assert!(matches!(
        decoded,
        LinkHandshakeResponse::Rejected(LinkRejected {
            rejected: LinkRejection::TooManyClients,
            limit: Some(64),
        })
    ));
}

#[test]
fn daemon_at_capacity_is_retryable_and_says_why() {
    let error = ConnectionError::DaemonAtCapacity { limit: Some(64) };
    assert!(error.is_retryable_carrier_failure());
    let message = error.to_string();
    assert!(message.contains("too many connected clients"), "{message}");
    assert!(message.contains("64"), "{message}");
    assert!(!message.contains("expired"), "{message}");
}

/// A daemon that ends the link after the Noise handshake, before
/// link-ready, without a word: the resume names that step
/// (`no_link_ready`), not the plain `link is closed`.
#[tokio::test]
async fn a_link_ended_before_link_ready_names_the_step() {
    let (ours, theirs) = tokio::io::duplex(1024);
    drop(theirs);
    let (reader, writer) = tokio::io::split(ours);
    let link = crate::provider::LengthDelimitedLink::new("memory://test", 1024, reader, writer);
    let error = receive_control::<LinkHandshakeResponse>(&link).await.err().unwrap();
    assert!(error.to_string().contains("the daemon closed the link before link-ready"), "{error}");
}
