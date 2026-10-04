use std::time::{Duration, Instant};

use super::*;

const HOST: &str = "host_abc";

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
        "link_token": {"token": "secret-token", "expires_at": "2026-10-05T00:05:00Z"},
        "daemon": {"version": "1", "capabilities": []},
        "revision": revision,
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

/// RED (security): the link token is handed back for its one use and never
/// stays in the cache.
#[test]
fn the_cache_never_keeps_the_link_token() {
    let mut cache = ConnectInfoCache::default();
    let now = Instant::now();
    let token = cache.insert(info(1), now).expect("the token comes back once");
    assert_eq!(token.token, "secret-token");
    let cached = cache.get(HOST, now).unwrap();
    assert!(cached.link_token.is_none(), "a cached record must not carry the token");
    assert!(!format!("{token:?}").contains("secret-token"), "Debug must not print the token");
}

#[test]
fn records_expire_after_300_seconds_and_follow_revisions() {
    let mut cache = ConnectInfoCache::default();
    let now = Instant::now();
    cache.insert(info(5), now);
    assert!(cache.get(HOST, now + CACHE_TTL).is_some());
    assert!(cache.get(HOST, now + CACHE_TTL + Duration::from_secs(1)).is_none());
    // An older answer does not replace newer peer data.
    cache.insert(info(3), now);
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
