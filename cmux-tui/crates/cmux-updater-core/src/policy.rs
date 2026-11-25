//! The updater's small policies and its watch of the installed build (the app's
//! `InstalledBuildWatch`, `DeltaWaitPolicy`, `UpdateNetworkPolicy`, `UpdateSnooze`, the pulled list
//! and the post-update health report): facts in, decisions out.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::numeric;

/// Whether build `candidate` is newer than build `base` (`InstalledBuildWatch.isNewer`): an update
/// already on disk while the old build runs. Builds are dotted (`1.2.3`) or one plain number
/// (`4487759453601`): parts split on `.`, `-` and `+`, a missing part is `0`, digit runs compare by
/// length after leading zeros, then text; other parts by the numeric order. Equal, blank or
/// non-comparable builds are not newer.
pub fn installed_is_newer(candidate: &str, base: &str) -> bool {
    let new = candidate.trim();
    let old = base.trim();
    if new.is_empty() || old.is_empty() || new == old {
        return false;
    }
    let split = |build: &str| -> Vec<String> {
        build.split(['.', '-', '+']).filter(|part| !part.is_empty()).map(str::to_owned).collect()
    };
    let (new_parts, old_parts) = (split(new), split(old));
    let zero = "0".to_owned();
    for index in 0..new_parts.len().max(old_parts.len()) {
        let lhs = new_parts.get(index).unwrap_or(&zero);
        let rhs = old_parts.get(index).unwrap_or(&zero);
        if lhs == rhs {
            continue;
        }
        return part_order(lhs, rhs) == std::cmp::Ordering::Greater;
    }
    false
}

fn part_order(lhs: &str, rhs: &str) -> std::cmp::Ordering {
    let digits = |text: &str| !text.is_empty() && text.bytes().all(|byte| byte.is_ascii_digit());
    if !(digits(lhs) && digits(rhs)) {
        return numeric::compare(lhs, rhs);
    }
    let a = lhs.trim_start_matches('0');
    let b = rhs.trim_start_matches('0');
    a.len().cmp(&b.len()).then_with(|| a.cmp(b))
}

/// The longest a pushed build's download waits for its deltas (`DeltaWaitPolicy.window`).
pub const DELTA_WAIT_SECONDS: f64 = 300.0;

/// Whether a pushed NIGHTLY build downloads now (true) or waits for its `sparkle:deltas`: a
/// person's click never waits, a listed delta never waits, and nothing waits past the window.
pub fn delta_downloads_now(lists_deltas: bool, user_asked: bool, waited_seconds: f64) -> bool {
    user_asked || lists_deltas || waited_seconds >= DELTA_WAIT_SECONDS
}

/// `updates.meteredNetwork`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum MeteredMode {
    DeferLowData,
    DeferExpensive,
    Download,
}

/// Whether found updates download by themselves right now (`UpdateNetworkPolicy`).
pub fn downloads_automatically(
    setting: bool,
    mode: MeteredMode,
    constrained: bool,
    expensive: bool,
) -> bool {
    if !setting {
        return false;
    }
    match mode {
        MeteredMode::Download => true,
        MeteredMode::DeferLowData => !constrained,
        MeteredMode::DeferExpensive => !constrained && !expensive,
    }
}

/// What the update cards' x remembers (`UpdateSnooze`); times are seconds since 1970.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Snooze {
    #[serde(default)]
    pub closed_version: Option<String>,
    #[serde(default)]
    pub remind_after: Option<f64>,
}

impl Snooze {
    /// Whether the card for update `version` stays hidden at `now`.
    pub fn hides(&self, version: Option<&str>, now: f64) -> bool {
        if self.remind_after.is_some_and(|remind_after| now < remind_after) {
            return true;
        }
        self.closed_version.as_deref().is_some_and(|closed| closed == version.unwrap_or(""))
    }

    /// The same state without a reminder that ended at `now`.
    pub fn expired(&self, now: f64) -> Snooze {
        match self.remind_after {
            Some(remind_after) if now >= remind_after => {
                Snooze { closed_version: self.closed_version.clone(), remind_after: None }
            }
            _ => self.clone(),
        }
    }
}

/// One entry of a feed's `pulled.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Pulled {
    pub build: String,
    pub reason: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pulled_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub serve: Option<String>,
}

fn text(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).map(str::to_owned)
}

/// `Foundation`'s `as? Bool` of a JSON value: `true`/`false`, and the numbers 0 and 1.
fn flag(value: Option<&Value>) -> Option<bool> {
    match value? {
        Value::Bool(flag) => Some(*flag),
        Value::Number(number) => match number.as_f64() {
            Some(0.0) => Some(false),
            Some(1.0) => Some(true),
            _ => None,
        },
        _ => None,
    }
}

/// Reads `pulled.json`: an array of objects; one without a string `build` is skipped, a missing
/// reason is empty. Anything else reads as no entries (`PulledBuild.decode`).
pub fn pulled_list(json: &str) -> Vec<Pulled> {
    let Ok(Value::Array(items)) = serde_json::from_str::<Value>(json) else { return Vec::new() };
    items
        .iter()
        .filter_map(|item| {
            let entry = item.as_object()?;
            Some(Pulled {
                build: text(entry.get("build"))?,
                reason: text(entry.get("reason")).unwrap_or_default(),
                pulled_at: text(entry.get("pulledAt")),
                serve: text(entry.get("serve")),
            })
        })
        .collect()
}

/// One check of `cmux app health --json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HealthCheck {
    pub name: String,
    pub ok: bool,
    pub reason: String,
    pub detail: String,
}

/// The report of `cmux app health --json`: every check and the running build's commit.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HealthReport {
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
    pub checks: Vec<HealthCheck>,
}

/// Reads the health report (`UpdateHealthCheck.parse`); none when it is not one.
pub fn health_report(json: &str) -> Option<HealthReport> {
    let object = serde_json::from_str::<Value>(json).ok()?;
    let object = object.as_object()?;
    let ok = flag(object.get("ok"))?;
    let rows = object.get("checks")?.as_array()?;
    if !rows.iter().all(Value::is_object) {
        return None;
    }
    let checks = rows
        .iter()
        .filter_map(|row| {
            let row = row.as_object()?;
            Some(HealthCheck {
                name: text(row.get("name"))?,
                ok: flag(row.get("ok"))?,
                reason: text(row.get("reason")).unwrap_or_default(),
                detail: text(row.get("detail")).unwrap_or_default(),
            })
        })
        .collect();
    let commit =
        object.get("app").and_then(Value::as_object).and_then(|app| text(app.get("commit")));
    Some(HealthReport { ok, commit, checks })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn installed_build_order() {
        assert!(installed_is_newer("1205", "1204"));
        assert!(installed_is_newer("4487759453601", "999999999999"));
        assert!(installed_is_newer("1.2.10", "1.2.9"));
        assert!(installed_is_newer("1.2.1", "1.2"));
        assert!(!installed_is_newer("1.2.0", "1.2"));
        assert!(!installed_is_newer("1204", "1204"));
        assert!(!installed_is_newer(" 1204\n", "1204"));
        assert!(!installed_is_newer("", "1204"));
        assert!(!installed_is_newer("1203", "1204"));
        assert!(!installed_is_newer("007", "7"));
        assert!(installed_is_newer("1.0-b2", "1.0-b1"));
        assert!(installed_is_newer("1.0+10", "1.0+9"));
        assert!(installed_is_newer("1.a10", "1.a9"));
    }

    #[test]
    fn delta_wait() {
        assert!(delta_downloads_now(false, true, 0.0));
        assert!(delta_downloads_now(true, false, 0.0));
        assert!(!delta_downloads_now(false, false, 299.0));
        assert!(delta_downloads_now(false, false, 300.0));
    }

    #[test]
    fn metered_network() {
        assert!(!downloads_automatically(false, MeteredMode::Download, false, false));
        assert!(downloads_automatically(true, MeteredMode::Download, true, true));
        assert!(!downloads_automatically(true, MeteredMode::DeferLowData, true, false));
        assert!(downloads_automatically(true, MeteredMode::DeferLowData, false, true));
        assert!(!downloads_automatically(true, MeteredMode::DeferExpensive, false, true));
        assert!(downloads_automatically(true, MeteredMode::DeferExpensive, false, false));
        assert_eq!(
            serde_json::from_str::<MeteredMode>("\"defer-low-data\"").ok(),
            Some(MeteredMode::DeferLowData)
        );
    }

    #[test]
    fn snooze() {
        let reminder = Snooze { closed_version: None, remind_after: Some(100.0) };
        assert!(reminder.hides(Some("1.0"), 50.0));
        assert!(!reminder.hides(Some("1.0"), 100.0));
        let closed = Snooze { closed_version: Some("1.0".into()), remind_after: None };
        assert!(closed.hides(Some("1.0"), 0.0));
        assert!(!closed.hides(Some("1.1"), 0.0));
        assert!(
            Snooze { closed_version: Some(String::new()), remind_after: None }.hides(None, 0.0)
        );
        assert_eq!(reminder.expired(100.0), Snooze::default());
        assert_eq!(reminder.expired(99.0), reminder);
    }

    #[test]
    fn pulled() {
        let list = pulled_list(
            r#"[{"build": "1204", "reason": "crash", "pulledAt": "2026-11-20"}, {"reason": "x"}, 3, {"build": "1203", "serve": "1202", "reason": 7}]"#,
        );
        assert_eq!(
            list,
            vec![
                Pulled {
                    build: "1204".into(),
                    reason: "crash".into(),
                    pulled_at: Some("2026-11-20".into()),
                    serve: None
                },
                Pulled {
                    build: "1203".into(),
                    reason: String::new(),
                    pulled_at: None,
                    serve: Some("1202".into())
                },
            ]
        );
        assert!(pulled_list("{}").is_empty());
        assert!(pulled_list("nope").is_empty());
    }

    #[test]
    fn health() {
        let report = health_report(
            r#"{"ok": false, "app": {"commit": "abc"}, "checks": [{"name": "chat", "ok": true}, {"name": "relay", "ok": false, "reason": "timeout", "detail": "5 s"}, {"ok": true}]}"#,
        )
        .unwrap();
        assert!(!report.ok);
        assert_eq!(report.commit.as_deref(), Some("abc"));
        assert_eq!(report.checks.len(), 2);
        assert_eq!(report.checks[1].reason, "timeout");
        assert_eq!(health_report(r#"{"ok": 1, "checks": []}"#).map(|report| report.ok), Some(true));
        assert_eq!(health_report(r#"{"ok": true}"#), None);
        assert_eq!(health_report(r#"{"ok": true, "checks": [3]}"#), None);
        assert_eq!(health_report("[]"), None);
    }
}
