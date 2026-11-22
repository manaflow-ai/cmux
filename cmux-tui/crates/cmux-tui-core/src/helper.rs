//! cmux Helper's daemon state (`helper-v1`; docs/cmux-helper.md). The build's
//! one helper app (`<app> Screen Sharing.app`, `<app id>.screen-sharing`)
//! holds macOS's Screen Recording and Accessibility for Screen Sharing and
//! Computer Use (`computer_use_host/macos.rs` runs the Computer Use worker
//! in it). The daemon keeps the helper's grants as the verified app last read
//! them from the helper (`helper-config`), for `helper-status` and
//! `cmux helper grants`.

use std::sync::{Mutex, PoisonError};

use serde_json::{Value, json};

/// Advertised by `identify` once `helper-status` and `helper-config` exist.
pub(crate) const HELPER_CAPABILITY: &str = "helper-v1";

/// cmux Helper's macOS grants, as the verified app read them from the helper.
/// Kept in memory only, never on disk: the app reports them again at each
/// connect and when it becomes active.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Deserialize)]
pub(crate) struct HelperPermissions {
    #[serde(default)]
    pub(crate) screen_recording: Option<bool>,
    #[serde(default)]
    pub(crate) accessibility: Option<bool>,
}

impl HelperPermissions {
    /// `helper-status`'s `permissions`.
    pub(crate) fn status(&self) -> Value {
        json!({
            "screen_recording": self.screen_recording,
            "accessibility": self.accessibility,
        })
    }
}

/// What the daemon knows for `helper-status`.
#[derive(Default)]
pub(crate) struct HelperState {
    report: Mutex<Report>,
}

#[derive(Default)]
struct Report {
    permissions: Option<HelperPermissions>,
    /// The name System Settings lists the helper under (`<app> Screen Sharing`).
    name: Option<String>,
}

impl HelperState {
    /// The verified app's latest read of the helper (memory only). A field the
    /// app left out keeps its last value.
    pub(crate) fn report(
        &self,
        permissions: Option<HelperPermissions>,
        name: Option<String>,
    ) -> Value {
        {
            let mut report = self.report.lock().unwrap_or_else(PoisonError::into_inner);
            if permissions.is_some() {
                report.permissions = permissions;
            }
            if let Some(name) = name.filter(|name| !name.is_empty() && name.len() <= 256) {
                report.name = Some(name);
            }
        }
        self.status()
    }

    /// `helper-status`: the helper's grants and name once the app reported them.
    pub(crate) fn status(&self) -> Value {
        let report = self.report.lock().unwrap_or_else(PoisonError::into_inner);
        let mut status = serde_json::Map::new();
        if let Some(permissions) = report.permissions {
            status.insert("permissions".into(), permissions.status());
        }
        if let Some(name) = &report.name {
            status.insert("name".into(), json!(name));
        }
        Value::Object(status)
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{HelperPermissions, HelperState};

    #[test]
    fn status_shows_the_helper_grants_only_once_reported() {
        let state = HelperState::default();
        assert_eq!(state.status(), json!({}));
        let granted =
            HelperPermissions { screen_recording: Some(true), accessibility: Some(false) };
        let status = state.report(Some(granted), Some("cmux Screen Sharing".into()));
        assert_eq!(
            status,
            json!({
                "permissions": {"screen_recording": true, "accessibility": false},
                "name": "cmux Screen Sharing",
            })
        );
        // A report without the name keeps the last one.
        assert_eq!(state.report(Some(granted), None)["name"], "cmux Screen Sharing");
        assert_eq!(state.status(), status);
    }
}
