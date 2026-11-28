//! Cookie backup rules (`CookieBackups`, the record types).

use crate::cookie_backups::*;

fn cookie(name: &str, expires: f64) -> BackedUpCookie {
    BackedUpCookie {
        name: name.into(),
        value: "v".into(),
        domain: ".example.com".into(),
        path: "/".into(),
        expires,
        http_only: false,
        secure: false,
        same_site: None,
    }
}

#[test]
fn restore_ids_are_app_prefixed_lowercase_hex() {
    let mut bytes = [0u8; 16];
    bytes[0] = 0xab;
    bytes[1] = 0x01;
    bytes[15] = 0xff;
    let id = restore_id(&bytes);
    assert_eq!(id, format!("app:ab01{}ff", "00".repeat(13)));
    assert_eq!(backup_file_name(&id).unwrap(), format!("{}.bin", &id[4..]));
}

#[test]
fn restore_ids_that_are_not_ours_are_refused() {
    for bad in [
        "",
        "app:",
        "app:abc",
        "chrome:00000000000000000000000000000000",
        "app:0000000000000000000000000000000G",
        "app:0000000000000000000000000000000A",
        "app:000000000000000000000000000000000",
    ] {
        assert_eq!(
            backup_file_name(bad).unwrap_err(),
            format!("{bad} is not an app cookie restore id (app:<32 hex>)")
        );
    }
}

#[test]
fn names_fall_back_to_the_next_bundle() {
    assert_eq!(bundle_name(None), "com.cmuxterm.app.next");
    assert_eq!(bundle_name(Some("")), "com.cmuxterm.app.next");
    assert_eq!(key_service(Some("dev.x")), "dev.x.cookie-backup-key");
}

#[test]
fn the_bound_counts_backups_and_bytes() {
    assert_eq!(full(&[], 10, 50, 1000), None);
    // 8 magic + 12 nonce + 16 tag = 36 of overhead.
    assert_eq!(full(&[100], 864, 50, 1000), None);
    assert!(full(&[100], 865, 50, 1000).is_some());
    let text = full(&[1_048_576; 2], 1, 2, u64::MAX).unwrap();
    assert_eq!(
        text,
        "cookie backups are full (2 backups, 2.0 MiB); restore a backup with cookies.restore or \
         ask the person to purge backups"
    );
}

#[test]
fn expiry_needs_a_positive_past_time() {
    assert!(!expired(None, 100.0));
    assert!(!expired(Some(-1.0), 100.0));
    assert!(!expired(Some(0.0), 100.0));
    assert!(expired(Some(100.0), 100.0));
    assert!(expired(Some(99.0), 100.0));
    assert!(!expired(Some(101.0), 100.0));
}

#[test]
fn pruning_removes_only_readable_backups_with_every_cookie_expired() {
    let entries: Vec<PruneEntry> = serde_json::from_value(serde_json::json!([
        {"file": "a", "cookies": [10.0, 20.0]},
        {"file": "session", "cookies": [10.0, -1.0]},
        {"file": "noexpiry", "cookies": [10.0, null]},
        {"file": "unreadable"},
        {"file": "live", "cookies": [10.0, 500.0]},
        {"file": "empty", "cookies": []},
    ]))
    .unwrap();
    assert_eq!(prune_selection(&entries, 100.0), vec!["a", "empty"]);
}

#[test]
fn summaries_list_newest_first_and_hide_unreadable_sites() {
    let entries: Vec<SummaryEntry> = serde_json::from_value(serde_json::json!([
        {"stem": "old", "readable": true, "site": "a.com", "createdAtMs": 1000.0},
        {"stem": "bad", "readable": false, "modified": 0.5},
        {"stem": "new", "readable": true, "site": "b.com", "createdAtMs": 9000.0},
        {"stem": "nosite", "readable": true},
    ]))
    .unwrap();
    let list = summaries(&entries);
    let order: Vec<&str> = list.iter().map(|s| s.restore_id.as_str()).collect();
    assert_eq!(order, ["app:new", "app:old", "app:bad", "app:nosite"]);
    assert_eq!(list[0].created_at, 9.0);
    assert_eq!(list[2].site, None);
    assert_eq!(list[3].site.as_deref(), Some(""));
}

#[test]
fn the_record_keeps_swifts_codable_shape() {
    let record = CookieBackupRecord {
        site: "example.com".into(),
        profile: "P".into(),
        created_at: 1700000000000.0,
        cookies: vec![BackedUpCookie { same_site: Some("lax".into()), ..cookie("a", -1.0) }],
    };
    let value = serde_json::to_value(&record).unwrap();
    assert_eq!(value["cookies"][0]["httpOnly"], false);
    assert_eq!(value["cookies"][0]["sameSite"], "lax");
    assert!(serde_json::to_value(cookie("b", 1.0)).unwrap().get("sameSite").is_none());
    let back: CookieBackupRecord = serde_json::from_value(value).unwrap();
    assert_eq!(back, record);
}

#[test]
fn properties_follow_httpcookie() {
    let mut c = cookie("a", 5.0);
    c.secure = true;
    c.same_site = Some("STRICT".into());
    let p = c.properties();
    assert_eq!((p.expires, p.secure, p.same_site_policy), (Some(5.0), true, Some("strict")));
    c.expires = -1.0;
    c.same_site = Some("none".into());
    let p = c.properties();
    assert_eq!((p.expires, p.same_site_policy), (None, None));
}

#[test]
fn restore_leaves_out_expired_and_keeps_the_ones_set_since() {
    let cookies = [
        cookie("gone", 50.0),
        cookie("same", -1.0),
        cookie("back", 500.0),
        cookie("session", -1.0),
    ];
    let existing = [("same".to_owned(), ".example.com".to_owned(), "/".to_owned())];
    assert_eq!(
        restore_plan(&cookies, &existing, 100.0),
        [
            RestoreAction::Expired,
            RestoreAction::Kept,
            RestoreAction::Restore,
            RestoreAction::Restore
        ]
    );
}
