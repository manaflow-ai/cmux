use super::receiver::ReceiverSnapshot;
use super::receiver_read_tests::public_fixture;
use serde_json::{Value, json};
use std::time::{Duration, Instant};

#[test]
fn receiver_owner_reply_cap_keeps_counting_elapsed_time_after_publication() {
    use cmux_link::elapsed::Elapsed;
    use cmux_link::native_token::receiver::Owner;
    use std::sync::{Arc, Mutex};
    let (binding, keys, bytes) = public_fixture();
    let mut body: Value = serde_json::from_slice(&bytes).unwrap();
    let checked = body["value"]["policy"]["checked_at"].as_u64().unwrap();
    body["value"]["issuer_time_ms"] = (checked + 7_000).into();
    body["value"]["remaining_ms"] = 23_000.into();
    let active = Instant::now();
    let value = Arc::new(Mutex::new(Some(Duration::from_secs(10))));
    let source = value.clone();
    let elapsed = Elapsed::capture(move || *source.lock().unwrap()).unwrap();
    let owner = Owner::with_elapsed_clock(keys, move || Some(active), elapsed).unwrap();
    let read = owner.begin().unwrap();
    *value.lock().unwrap() = Some(Duration::from_secs(11));
    let snapshot = ReceiverSnapshot::from_public_reply_for_refresh(
        &serde_json::to_vec(&body).unwrap(),
        &binding,
        &read,
        active,
    )
    .unwrap();
    assert_eq!(snapshot.time(active).unwrap().unix_ms, checked + 7_000);
    *value.lock().unwrap() = Some(Duration::from_secs(12));
    assert_eq!(snapshot.time(active).unwrap().unix_ms, checked + 8_000);
    assert_eq!(snapshot.public_reply(active).unwrap()["value"]["remaining_ms"], 22_000);
}

#[test]
fn receiver_owner_reply_debits_root_work_once_and_bounds_socket_delay() {
    let (binding, _, bytes) = public_fixture();
    let mut body: Value = serde_json::from_slice(&bytes).unwrap();
    let checked = body["value"]["policy"]["checked_at"].as_u64().unwrap();
    let now = Instant::now();
    let started = now - Duration::from_secs(20);
    body["value"]["issuer_time_ms"] = (checked + 20_000).into();
    body["value"]["remaining_ms"] = 10_000.into();
    let snapshot = ReceiverSnapshot::from_public_reply(
        &serde_json::to_vec(&body).unwrap(),
        &binding,
        started,
        now,
    )
    .unwrap();
    assert_eq!(snapshot.expires(), now + Duration::from_secs(10));
    assert_eq!(snapshot.time(now).unwrap().unix_ms, checked + 20_000);
    let delayed = now + Duration::from_secs(2);
    let snapshot = ReceiverSnapshot::from_public_reply(
        &serde_json::to_vec(&body).unwrap(),
        &binding,
        started,
        delayed,
    )
    .unwrap();
    assert_eq!(snapshot.expires(), now + Duration::from_secs(10), "socket delay extended a lease");
    assert_eq!(snapshot.time(delayed).unwrap().unix_ms, checked + 22_000);
}

#[test]
fn receiver_owner_reply_stricter_report_does_not_rewrite_authenticated_dates() {
    let (binding, _, bytes) = public_fixture();
    let mut body: Value = serde_json::from_slice(&bytes).unwrap();
    let checked = body["value"]["policy"]["checked_at"].as_u64().unwrap();
    let expires = body["value"]["policy"]["expires_at"].as_i64().unwrap();
    body["value"]["issuer_time_ms"] = (checked + 23_000).into();
    body["value"]["remaining_ms"] = 7_000.into();
    let now = Instant::now();
    let started = now - Duration::from_secs(2);
    let snapshot = ReceiverSnapshot::from_public_reply(
        &serde_json::to_vec(&body).unwrap(),
        &binding,
        started,
        now,
    )
    .unwrap();
    assert_eq!(snapshot.policy().expires_at, expires);
    assert_eq!(snapshot.expires(), now + Duration::from_secs(7));
    assert!(snapshot.native_policy().request_started < started);
    assert_eq!(snapshot.time(now).unwrap().unix_ms, checked + 23_000);
}

#[test]
fn receiver_owner_reply_refuses_wrong_self_identity_and_environment() {
    for field in [
        "machine",
        "host",
        "epoch",
        "user",
        "install",
        "team",
        "wg_public_key",
        "install_public_key",
        "issuer",
    ] {
        let (binding, _, bytes) = public_fixture();
        let mut body: Value = serde_json::from_slice(&bytes).unwrap();
        if field == "issuer" {
            body["value"][field] = "cmux:cloud:production".into();
        } else if field == "epoch" {
            body["value"]["policy"][field] = 5.into();
        } else {
            body["value"]["policy"][field] = "different-original-identity".into();
        }
        let now = Instant::now();
        assert!(
            ReceiverSnapshot::from_public_reply(
                &serde_json::to_vec(&body).unwrap(),
                &binding,
                now,
                now
            )
            .is_err(),
            "{field}"
        );
    }
}

#[test]
fn receiver_owner_reply_refuses_bad_time_keys_and_expired_roundtrip() {
    for field in ["issuer_time_ms", "remaining_ms", "private_keyset", "false"] {
        let (binding, _, bytes) = public_fixture();
        let mut body: Value = serde_json::from_slice(&bytes).unwrap();
        match field {
            "issuer_time_ms" => body["value"][field] = 0.into(),
            "remaining_ms" => body["value"][field] = 30_001.into(),
            "private_keyset" => {
                body["value"]["keyset"]["keys"]["test-k1"]["d"] = "must-not-enter-owner".into();
            }
            "false" => body["ok"] = false.into(),
            _ => unreachable!(),
        }
        let now = Instant::now();
        assert!(
            ReceiverSnapshot::from_public_reply(
                &serde_json::to_vec(&body).unwrap(),
                &binding,
                now,
                now
            )
            .is_err(),
            "{field}"
        );
    }
    let (binding, _, bytes) = public_fixture();
    let now = Instant::now();
    assert!(
        ReceiverSnapshot::from_public_reply(&bytes, &binding, now - Duration::from_secs(30), now)
            .is_err()
    );
    assert!(
        ReceiverSnapshot::from_public_reply(&bytes, &binding, now, now - Duration::from_millis(1))
            .is_err()
    );
}

#[test]
fn receiver_owner_reply_refuses_duplicate_raw_fields_and_discards_extras() {
    let (binding, _, bytes) = public_fixture();
    let text = String::from_utf8(bytes).unwrap();
    let duplicate = text.replacen("\"ok\":true", "\"ok\":false,\"ok\":true", 1);
    assert!(duplicate.len() > text.len());
    let now = Instant::now();
    assert!(ReceiverSnapshot::from_public_reply(duplicate.as_bytes(), &binding, now, now).is_err());
    let mut body: Value = serde_json::from_str(&text).unwrap();
    body["value"]["policy"]["ignored_field"] = json!({"private":"not-forwarded"});
    let snapshot = ReceiverSnapshot::from_public_reply(
        &serde_json::to_vec(&body).unwrap(),
        &binding,
        now,
        now,
    )
    .unwrap();
    assert!(!snapshot.public_reply(now).unwrap().to_string().contains("not-forwarded"));
}
