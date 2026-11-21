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
    assert_eq!(ended_line(said.as_deref(), None), "host: failed: capture: no frame");
    assert_eq!(ended_line(said.as_deref(), Some("timeout")), "host: failed: capture: no frame");
    assert_eq!(ended_line(None, Some("timeout")), "link failed: timeout");
    assert_eq!(ended_line(None, None), "the host ended the session");
}
