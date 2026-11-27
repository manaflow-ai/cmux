use super::*;

#[test]
fn the_hosts_own_reason_wins_over_the_close() {
    let ended = serde_json::to_vec(&crate::wire::Control::Ended {
        reason: "failed: capture: no frame".into(),
    })
    .unwrap();
    let said = host_ended(&ended);
    assert_eq!(said.as_deref(), Some("failed: capture: no frame"));
    let started = serde_json::to_vec(&crate::wire::Control::Started { session: 1 }).unwrap();
    assert_eq!(host_ended(&started), None);
    assert_eq!(host_ended(b"not json"), None);
    assert_eq!(ended_line(said.as_deref(), None, None), "host: failed: capture: no frame");
    assert_eq!(
        ended_line(said.as_deref(), Some("timeout"), None),
        "host: failed: capture: no frame"
    );
    assert_eq!(ended_line(None, Some("timeout"), None), "link failed: timeout");
    assert_eq!(ended_line(None, None, None), "the host ended the session");
}

#[test]
fn a_failed_link_with_no_relay_because_billing_was_unread_says_so() {
    let note = Some("could not read your plan");
    assert_eq!(
        ended_line(None, Some("the secure handshake timed out"), note),
        "link failed: the secure handshake timed out; no relay: could not read your plan"
    );
    // The host's own reason still wins, and a link that closed cleanly needs no note.
    assert_eq!(ended_line(Some("stopped"), Some("timeout"), note), "host: stopped");
    assert_eq!(ended_line(None, None, note), "the host ended the session");
    let answer: Answer = serde_json::from_str(
        r#"{"session":"s","peer_key":"00","socket":"/tmp/x","relay_note":"could not read your plan"}"#,
    )
    .unwrap();
    assert_eq!(answer.relay_note.as_deref(), note);
}
