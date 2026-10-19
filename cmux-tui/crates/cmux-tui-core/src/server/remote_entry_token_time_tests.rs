//! Token issue time, rather than delivery time, bounds offline access.

use super::*;

fn unix_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64
}

fn checked(at: u64) -> String {
    format!(
        r#"{{"link_peer":{{"install":"inst_9","user":"42","team":"team_a"}},"check":"link_token","check_issued_at_ms":{at}}}"#
    )
}

#[test]
fn delayed_delivery_keeps_the_tokens_original_issue_time() {
    let entry = entry_with(true, Arc::new(DenyAllGate), Some(true));
    let before = Instant::now();
    let (mut stream, mut reader) = connect_as_link(&entry);
    send(&mut stream, &checked(unix_ms() - 90_000));
    send_racing_close(&mut stream, r#"{"id":1,"cmd":"ping"}"#);
    assert_eq!(response(&mut reader)["error_code"], json!(REMOTE_DENIED));
    let recorded = good_check_time(&entry.mux, "inst_9").expect("the token check was recorded");
    let age = before.saturating_duration_since(recorded);
    assert!(age >= Duration::from_secs(89), "delivery must not renew the token: {age:?}");
    assert!(age <= Duration::from_secs(91), "the original issue time must be retained: {age:?}");

    // Less than 24 h after delivery, but more than 24 h after issuance.
    entry
        .mux
        .set_remote_revocation_clock(Arc::new(FixedClock(
            recorded + crate::remote_relay_state::REFUSE_NEW_STREAMS_AFTER + Duration::from_secs(1),
        )))
        .unwrap();
    let (mut later, mut later_reader) = connect_as_link(&entry);
    send(&mut later, &stamp_inst_9(false));
    send_racing_close(&mut later, r#"{"id":2,"cmd":"ping"}"#);
    assert!(closed(&mut later_reader), "the issue-time offline deadline must refuse a new stream");
}

#[test]
fn a_legacy_checked_stamp_cannot_renew_offline_access() {
    let entry = entry_with(true, Arc::new(DenyAllGate), Some(true));
    let (mut stream, mut reader) = connect_as_link(&entry);
    send(&mut stream, &stamp_inst_9(true));
    send_racing_close(&mut stream, r#"{"id":1,"cmd":"ping"}"#);
    assert!(closed(&mut reader), "a check without token issue time is incomplete");
    assert_eq!(good_check_time(&entry.mux, "inst_9"), None);
}

#[test]
fn future_issue_time_is_refused_without_recording_a_check() {
    let entry = entry_with(true, Arc::new(DenyAllGate), Some(true));
    let (mut stream, mut reader) = connect_as_link(&entry);
    send(&mut stream, &checked(unix_ms() + 60_000));
    send_racing_close(&mut stream, r#"{"id":1,"cmd":"ping"}"#);
    assert!(closed(&mut reader));
    assert_eq!(good_check_time(&entry.mux, "inst_9"), None);
}
