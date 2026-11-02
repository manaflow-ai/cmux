use std::time::{Duration, Instant};

use super::*;

const HOST: &str = "host_abc";

/// The API and generated Cloud wire type return integer Unix milliseconds.
#[test]
fn cloud_token_grant_decodes_backend_millisecond_expiry() {
    let wire = serde_json::json!({
        "token": "one-dial-token", "expires_at": 1_792_430_000_000_u64,
        "host": HOST, "epoch": 4, "services": ["ssh"], "future_field": true
    });
    let grant: LinkTokenGrant = serde_json::from_value(wire).unwrap();
    assert!(grant.covers(HOST, Service::Ssh));
    assert_eq!(serde_json::to_value(&grant).unwrap()["expires_at"], 1_792_430_000_000_u64);
    assert!(!format!("{grant:?}").contains("one-dial-token"));
}

#[test]
fn cloud_token_grant_refuses_non_integer_expiry() {
    for expiry in [
        serde_json::json!("2026-10-05T00:05:00Z"),
        serde_json::json!("1792430000000"),
        serde_json::json!(1.5),
        serde_json::Value::Null,
    ] {
        assert!(
            serde_json::from_value::<LinkTokenGrant>(serde_json::json!({
                "token": "one-dial-token", "expires_at": expiry,
                "host": HOST, "epoch": 4, "services": ["ssh"]
            }))
            .is_err()
        );
    }
}

fn info(revision: u64) -> ConnectInfo {
    serde_json::from_value(serde_json::json!({
        "machine": "vm_1",
        "host": HOST,
        "epoch": 4,
        "state": "running",
        "peer": {
            "wg_public_key": STANDARD.encode([7u8; 32]),
            "overlay_address": overlay_address(HOST).to_string(),
            "vpc_endpoint": "[fd00::5]:4101",
            "public_ipv6": null
        },
        "gateway": null,
        "services": ["daemon", "ssh"],
        "daemon": {"version": "1", "capabilities": []},
        "revision": revision.to_string(),
        "future_field": true
    }))
    .unwrap()
}

/// RED (security): a record whose overlay address is not our derivation of
/// the host id, or that names another host, is never used.
#[test]
fn a_record_for_another_host_or_overlay_address_is_refused() {
    assert_eq!(info(1).validate(HOST), Ok([7u8; 32]));
    assert_eq!(info(1).validate("host_other"), Err(InvalidInfo::HostMismatch));
    let mut moved = info(1);
    moved.peer.overlay_address = overlay_address("host_other");
    assert_eq!(moved.validate(HOST), Err(InvalidInfo::OverlayMismatch));
    let mut short = info(1);
    short.peer.wg_public_key = STANDARD.encode([7u8; 16]);
    assert_eq!(short.validate(HOST), Err(InvalidInfo::BadKey));
}

/// The token grant never prints its secret, and covers only its host and
/// services.
#[test]
fn a_token_grant_is_scoped_and_never_printed() {
    let grant: LinkTokenGrant = serde_json::from_value(serde_json::json!({
        "token": "secret-token", "expires_at": 1_790_000_301_000_u64,
        "host": HOST, "epoch": 4, "services": ["ssh"]
    }))
    .unwrap();
    assert!(!format!("{grant:?}").contains("secret-token"));
    assert!(grant.covers(HOST, Service::Ssh));
    assert!(!grant.covers(HOST, Service::Daemon));
    assert!(!grant.covers("host_other", Service::Ssh));
}

#[test]
fn records_expire_after_300_seconds_and_follow_revisions() {
    let mut cache = ConnectInfoCache::default();
    let now = Instant::now();
    cache.insert(info(5), now);
    assert_eq!(cache.get(HOST, now).unwrap().revision, 5, "a decimal-string revision parses");
    assert!(cache.get(HOST, now + CACHE_TTL).is_some());
    assert!(cache.get(HOST, now + CACHE_TTL + Duration::from_secs(1)).is_none());
    // An older answer does not replace newer peer data, and the newer one
    // is what the caller gets.
    assert_eq!(cache.insert(info(3), now).revision, 5);
    assert_eq!(cache.get(HOST, now).unwrap().revision, 5);
    // An announced newer revision drops the record; an older one does not.
    assert!(!cache.observe_revision(HOST, 5));
    assert!(cache.observe_revision(HOST, 6));
    assert!(cache.get(HOST, now).is_none());
    cache.insert(info(6), now);
    assert!(cache.remove(HOST));
    assert!(!cache.remove(HOST));
}

#[test]
fn backend_errors_map_to_dial_errors() {
    use crate::dial::DialError;
    let map = |code| ConnectInfoError::from_code(code, "m").dial_error();
    assert_eq!(map("cloud.machine.not_found"), DialError::UnknownHost);
    assert_eq!(map("auth.forbidden"), DialError::NotAuthorized);
    assert_eq!(map("cloud.machine.not_bound"), DialError::Unreachable);
    assert_eq!(map("internal"), DialError::Unreachable);
    assert!(is_cloud_host(HOST));
    assert!(!is_cloud_host("inst_1"));
    assert!(info(1).allows(Service::Ssh));
}
