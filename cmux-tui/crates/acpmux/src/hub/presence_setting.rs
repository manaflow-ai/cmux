//! Part of `Hub`; see `hub/mod.rs`. The Live opt-in (`presence.live`, RFD 0141) as the settings
//! file says it: the app's Live button and Settings write the key ("the daemon reads the same
//! key", `SidebarView+Live.swift`), and this loop follows it into [`super::presence::Presence::set_live`],
//! so a teammate's daemon sees this Mac's presence only while its owner turned Live on.
//!
//! Off by default: a missing file, a missing key, or anything but `true` is off. A file that does
//! not parse (half written, a typo) changes nothing: Live stays as it was until the file reads
//! again. Only a change of the setting is applied, so a client's own `_acpmux/live` call stands
//! until the person changes the setting, and an edit to another key leaves it alone.
//!
//! No timer: it waits on the settings watch (`settings_watch.rs`, the hub's `settings_changes`)
//! and reads the file only when it changed. It ends when the daemon shuts down.

use super::Hub;
use serde_json::Value;
use std::sync::Weak;

/// The settings key the app's Live button writes.
pub const LIVE_KEY: &str = "presence.live";

/// Live as a parsed settings document says it: only `true` is on.
pub fn live_from_doc(doc: &Value) -> bool {
    matches!(crate::user_settings::value(doc, LIVE_KEY), Some(Value::Bool(true)))
}

/// Live as the settings file says it now; `None` when the file does not read, so a half-written
/// file never turns Live off (or on).
pub fn live_from(settings: &crate::user_settings::Settings) -> Option<bool> {
    use crate::user_settings::Settings;
    match settings {
        Settings::Parsed(doc) => Some(live_from_doc(doc)),
        Settings::Missing => Some(false),
        Settings::Unreadable(_) => None,
    }
}

/// What to apply after a read: the setting's value when it differs from the last one applied.
fn next(last: Option<bool>, read: Option<bool>) -> Option<bool> {
    read.filter(|now| last != Some(*now))
}

impl Hub {
    /// Follows `presence.live` into the presence table until the daemon shuts down.
    pub async fn presence_live_loop(hub: Weak<Hub>) {
        let Some(mut settings) = hub.upgrade().map(|h| h.settings_changes.subscribe()) else {
            return;
        };
        let mut last: Option<bool> = None;
        loop {
            {
                let Some(h) = hub.upgrade() else { return };
                if h.shutting_down() {
                    return;
                }
            }
            // Marked seen before the read: a change after it ends the wait below at once.
            settings.borrow_and_update();
            let read = tokio::task::spawn_blocking(|| live_from(&crate::user_settings::read()))
                .await
                .ok()
                .flatten();
            if let Some(live) = next(last, read) {
                last = Some(live);
                let Some(h) = hub.upgrade() else { return };
                if h.presence.set_live(live) != live {
                    tracing::info!(
                        "presence: Live {} ({LIVE_KEY})",
                        if live { "on" } else { "off" }
                    );
                }
            }
            if settings.changed().await.is_err() {
                return;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::user_settings::Settings;
    use serde_json::json;

    #[test]
    fn only_true_is_live() {
        assert!(live_from_doc(&json!({"presence": {"live": true}})));
        assert!(
            live_from_doc(&json!({"presence.live": true})),
            "the flat form the owner may write"
        );
        assert!(!live_from_doc(&json!({})), "off by default");
        assert!(!live_from_doc(&json!({"presence": {"live": false}})));
        assert!(!live_from_doc(&json!({"presence": {"live": "true"}})));
        assert!(!live_from_doc(&json!({"presence": {"live": 1}})));
    }

    #[test]
    fn a_missing_file_is_off_and_an_unreadable_one_changes_nothing() {
        assert_eq!(live_from(&Settings::Missing), Some(false));
        assert_eq!(live_from(&Settings::Unreadable("half written".into())), None);
        assert_eq!(live_from(&Settings::Parsed(json!({"presence": {"live": true}}))), Some(true));
    }

    #[test]
    fn only_a_change_of_the_setting_is_applied() {
        assert_eq!(next(None, Some(false)), Some(false), "the first read applies, off included");
        assert_eq!(next(Some(false), Some(true)), Some(true));
        assert_eq!(
            next(Some(true), Some(true)),
            None,
            "another key changed: a client's call stands"
        );
        assert_eq!(next(Some(true), None), None, "an unreadable file keeps Live as it was");
        assert_eq!(next(Some(true), Some(false)), Some(false));
    }

    #[tokio::test]
    async fn the_setting_drives_set_live() {
        let presence = super::super::presence::Presence::default();
        let mut last = None;
        for (doc, want) in [
            (json!({}), false),
            (json!({"presence": {"live": true}}), true),
            (json!({"presence": {"live": true}, "other": 1}), true),
            (json!({"presence": {"live": false}}), false),
        ] {
            if let Some(live) = next(last, live_from(&Settings::Parsed(doc))) {
                last = Some(live);
                presence.set_live(live);
            }
            assert_eq!(presence.is_live(), want);
        }
    }
}
