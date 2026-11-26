//! The cookie backups' rules, pinned to `CookieBackups`'s behavior.

use crate::cookie_backups::*;
use crate::ops;
use serde_json::json;

const HEX: &str = "0123456789abcdef0123456789abcdef";

#[test]
fn a_backup_must_fit_the_count_and_the_bytes() {
    assert_eq!(full(&[], 0, 1, FILE_OVERHEAD), None);
    assert!(full(&[], 1, 1, FILE_OVERHEAD).is_some());
    assert!(
        full(&[1], 0, 1, u64::MAX / 2)
            .unwrap()
            .starts_with("cookie backups are full (1 backups, 0.0 MiB)")
    );
    let message = full(&[3 * 1_048_576 / 2], 0, 50, 1_048_576).unwrap();
    assert!(message.contains("(1 backups, 1.5 MiB)"));
    assert!(
        message
            .ends_with("restore a backup with cookies.restore or ask the person to purge backups")
    );
}

#[test]
fn restore_ids_name_their_files() {
    assert_eq!(restore_id(HEX), format!("app:{HEX}"));
    assert_eq!(file_hex(&restore_id(HEX)), Ok(HEX));
    for bad in ["", HEX, "app:", "app:0123", "host:0123456789abcdef0123456789abcdef"] {
        let error = file_hex(bad).unwrap_err();
        assert_eq!(error, format!("{bad} is not an app cookie restore id (app:<32 hex>)"));
    }
}

#[test]
fn a_backup_expires_when_every_cookie_has() {
    assert_eq!(
        record_expired(&json!({"cookies": [{"expires": 1}, {"expires": 2}]}), 2.0),
        Some(true)
    );
    assert_eq!(
        record_expired(&json!({"cookies": [{"expires": 1}, {"expires": -1}]}), 2.0),
        Some(false)
    );
    assert_eq!(record_expired(&json!({"cookies": []}), 2.0), Some(true));
    assert_eq!(record_expired(&json!({"cookies": [1]}), 2.0), None);
    assert_eq!(record_expired(&json!({}), 2.0), None);
    // JSON booleans are `NSNumber`s to `JSONSerialization`.
    assert!(expired(&json!({"expires": true}), 1.0));
    assert!(!expired(&json!({"expires": "1"}), 1.0));
}

#[test]
fn summaries_are_newest_first_and_an_unreadable_backup_is_listed() {
    let files = vec![
        BackupFile {
            hex: "a".into(),
            record: Some(json!({"site": "a.test", "createdAt": 2000})),
            modified: 0.0,
        },
        BackupFile { hex: "b".into(), record: None, modified: 5.0 },
        BackupFile { hex: "c".into(), record: Some(json!({"createdAt": 1000})), modified: 0.0 },
        BackupFile { hex: "d".into(), record: Some(json!([1])), modified: 3.0 },
    ];
    let list = summaries(&files);
    let order: Vec<(&str, Option<&str>, f64)> =
        list.iter().map(|s| (s.restore_id.as_str(), s.site.as_deref(), s.created_at)).collect();
    assert_eq!(
        order,
        vec![
            ("app:b", None, 5.0),
            ("app:d", None, 3.0),
            ("app:a", Some("a.test"), 2.0),
            ("app:c", Some(""), 1.0)
        ]
    );
}

#[test]
fn backup_ops_answer_in_the_apps_shape() {
    let call = |op: &str, request| ops::call(op, request).unwrap();
    assert_eq!(
        call("browser_rules_automation_backups_full", json!({"fileSizes": [1], "plainBytes": 1})),
        json!(null)
    );
    assert_eq!(
        call(
            "browser_rules_automation_backup_file_hex",
            json!({"restoreId": format!("app:{HEX}")})
        ),
        json!({"hex": HEX})
    );
    assert!(
        call("browser_rules_automation_backup_file_hex", json!({"restoreId": "x"}))["error"]
            .is_string()
    );
    assert_eq!(
        call(
            "browser_rules_automation_backups_expired",
            json!({"cookie": {"expires": 1}, "now": 2})
        ),
        json!(true)
    );
    assert_eq!(
        call("browser_rules_automation_backups_expired", json!({"record": {}, "now": 2})),
        json!(null)
    );
    assert_eq!(
        call(
            "browser_rules_automation_backup_summaries",
            json!({"files": [{"hex": "a", "modified": 1.5}]})
        ),
        json!([{"restoreId": "app:a", "site": null, "createdAt": 1.5}])
    );
    assert!(matches!(
        ops::call("browser_rules_automation_backups_expired", json!({"now": 1})),
        Err(ops::OpError::Invalid(_))
    ));
    assert!(matches!(
        ops::call("browser_rules_automation_nope", json!({})),
        Err(ops::OpError::UnknownOp(_))
    ));
}
