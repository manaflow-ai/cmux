//! Chrome's automatic downloads count, from `AutomaticDownloadPolicy`'s doc comments.

use crate::download_policy::*;
use crate::ops;
use serde_json::json;

#[test]
fn the_first_download_since_a_gesture_goes_ahead() {
    let mut policy = AutomaticDownloadPolicy::default();
    assert!(policy.count_download("a.test"));
    assert!(!policy.count_download("a.test"));
    assert_eq!(policy.downloads_since_gesture, 2);
    // Another site starts a new count.
    assert!(policy.count_download("b.test"));
    assert_eq!(policy.site.as_deref(), Some("b.test"));
    // A gesture makes the next download the first again.
    policy.user_gesture();
    assert_eq!(policy, AutomaticDownloadPolicy::default());
    assert!(policy.count_download("b.test"));
}

#[test]
fn a_later_download_follows_the_site_setting() {
    for setting in
        [SitePermissionSetting::Allow, SitePermissionSetting::Block, SitePermissionSetting::Ask]
    {
        assert_eq!(AutomaticDownloadPolicy::decision(true, setting), DownloadDecision::Allow {});
    }
    assert_eq!(
        AutomaticDownloadPolicy::decision(false, SitePermissionSetting::Allow),
        DownloadDecision::Allow {}
    );
    assert_eq!(
        AutomaticDownloadPolicy::decision(false, SitePermissionSetting::Block),
        DownloadDecision::Refuse {}
    );
    assert_eq!(
        AutomaticDownloadPolicy::decision(false, SitePermissionSetting::Ask),
        DownloadDecision::Ask {}
    );
}

#[test]
fn the_ops_carry_the_count() {
    let first = ops::call("browser_rules_download_count", json!({"site": "a.test"})).unwrap();
    assert_eq!(
        first,
        json!({"policy": {"site": "a.test", "downloadsSinceGesture": 1}, "isFirst": true})
    );
    let second = ops::call(
        "browser_rules_download_count",
        json!({"policy": first["policy"], "site": "a.test"}),
    )
    .unwrap();
    assert_eq!(second["isFirst"], json!(false));
    let reset =
        ops::call("browser_rules_download_gesture", json!({"policy": second["policy"]})).unwrap();
    assert_eq!(reset, json!({"site": null, "downloadsSinceGesture": 0}));
    assert_eq!(
        ops::call("browser_rules_download_decision", json!({"isFirst": false, "setting": "block"})),
        Ok(json!({"refuse": {}}))
    );
    assert!(matches!(
        ops::call("browser_rules_download_count", json!({})),
        Err(ops::OpError::Invalid(_))
    ));
}
