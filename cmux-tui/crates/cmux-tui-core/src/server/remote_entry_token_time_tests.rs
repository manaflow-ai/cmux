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

struct IssueClock(Instant, u64);

impl crate::remote_relay_state::RevocationClock for IssueClock {
    fn now(&self) -> Instant {
        self.0
    }
    fn unix_time_ms(&self) -> Option<u64> {
        Some(self.1)
    }
}

#[test]
fn delayed_delivery_keeps_the_tokens_original_issue_time() {
    let entry = entry_with(true, Arc::new(DenyAllGate), Some(true));
    let before = Instant::now();
    let wall = unix_ms();
    entry.mux.set_remote_revocation_clock(Arc::new(IssueClock(before, wall))).unwrap();
    let (mut stream, mut reader) = connect_as_link(&entry);
    send(&mut stream, &checked(wall - 90_000));
    send_racing_close(&mut stream, r#"{"id":1,"cmd":"ping"}"#);
    assert_eq!(response(&mut reader)["error_code"], json!(REMOTE_DENIED));
    let recorded = good_check_time(&entry.mux, "inst_9").expect("the token check was recorded");
    assert_eq!(recorded, before - Duration::from_secs(90));

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
    send(
        &mut stream,
        r#"{"link_peer":{"install":"inst_9","user":"42","team":"team_a"},"check":"link_token"}"#,
    );
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

#[test]
fn a_timestamped_check_under_deny_all_cannot_record_or_bind() {
    let entry = entry(true, Arc::new(DenyAllGate));
    let (mut stream, mut reader) = connect_as_link(&entry);
    send(&mut stream, &checked(unix_ms() - 1_000));
    send_racing_close(&mut stream, r#"{"id":1,"cmd":"ping"}"#);
    assert!(closed(&mut reader));
    assert!(remote_clients(&entry.mux).is_empty());
    assert_eq!(good_check_time(&entry.mux, "inst_9"), None);
}

#[test]
fn poisoned_revocation_state_refuses_a_timestamped_check() {
    let entry = entry_with(true, Arc::new(DenyAllGate), Some(true));
    let mux = entry.mux.clone();
    let poisoned = std::thread::spawn(move || {
        let _guard = mux.remote_relay().revocation.lock().unwrap();
        panic!("poison the revocation lock");
    });
    assert!(poisoned.join().is_err());
    let (mut stream, mut reader) = connect_as_link(&entry);
    send(&mut stream, &checked(unix_ms() - 1_000));
    send_racing_close(&mut stream, r#"{"id":1,"cmd":"ping"}"#);
    assert!(closed(&mut reader));
    assert!(remote_clients(&entry.mux).is_empty());
}
