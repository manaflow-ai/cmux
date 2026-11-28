//! The daemon's background extension update check: with
//! `updates.checkExtensions` on (off by default), every
//! [`crate::apps::CHECK_EVERY`] it runs the supervisor's check
//! (`apps/update_offers.rs`) and posts one notification for the updates it
//! has not told the person about yet. Which update was told is kept in
//! `<state>/apps/update-offers-notified.json`, so a restart does not repeat
//! it. The check only offers; `cmux apps update` or the Extensions page
//! installs.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};

use crate::Mux;

/// The setting that turns the check on.
pub(crate) const SETTING: &str = "updates.checkExtensions";
/// How often the thread looks at the setting.
const WAKE_EVERY: Duration = Duration::from_secs(60 * 60);

/// Starts the check's thread; it ends with the daemon.
pub(crate) fn start(mux: &Arc<Mux>) {
    let weak = Arc::downgrade(mux);
    let _ =
        std::thread::Builder::new().name("cmux-extension-updates".into()).spawn(move || run(&weak));
}

fn run(weak: &Weak<Mux>) {
    std::thread::sleep(crate::apps::FIRST_CHECK_AFTER);
    let mut last: Option<Instant> = None;
    loop {
        let Some(mux) = weak.upgrade() else { return };
        if enabled(&mux) && last.is_none_or(|at| at.elapsed() >= crate::apps::CHECK_EVERY) {
            last = Some(Instant::now());
            check(&mux);
        }
        drop(mux);
        std::thread::sleep(WAKE_EVERY);
    }
}

fn enabled(mux: &Arc<Mux>) -> bool {
    mux.with_settings(|state| {
        state
            .get(&cmux_config::Target::Key(SETTING.to_string()))
            .row
            .and_then(|row| row.value)
            .and_then(|value| value.as_bool())
            .unwrap_or(false)
    })
}

fn check(mux: &Arc<Mux>) {
    let supervisor = mux.control_clients.apps.get_or_init(mux);
    let offers: BTreeMap<String, Offer> = supervisor
        .check_extension_updates_now()
        .into_values()
        .map(|row| {
            (
                row.app.clone(),
                Offer {
                    app: row.app,
                    name: row.name,
                    current: row.current_version,
                    version: row.version,
                    commit: row.commit,
                },
            )
        })
        .collect();
    let file = mux.session_state_directory().map(|dir| notified_file(&dir));
    let told = file.as_deref().map(read_told).unwrap_or_default();
    let (fresh, next) = new_offers(&offers, &told);
    if let Some((title, body)) = notification(&fresh) {
        let _ = mux.post_notification_as(
            &crate::workspace_registry::Actor::Daemon,
            title,
            body,
            crate::mux::NotificationLevel::Info,
            None,
            crate::mux::NotificationSource::Daemon,
        );
    }
    if next != told
        && let Some(file) = file
    {
        write_told(&file, &next);
    }
}

/// One offered update, as the notification names it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Offer {
    pub app: String,
    pub name: String,
    pub current: String,
    pub version: String,
    pub commit: String,
}

/// The offers not told yet, and the told record to keep (app → commit; an
/// app no longer offered is dropped, so a later update of it is told).
pub(super) fn new_offers<'a>(
    offers: &'a BTreeMap<String, Offer>,
    told: &BTreeMap<String, String>,
) -> (Vec<&'a Offer>, BTreeMap<String, String>) {
    let fresh = offers.values().filter(|o| told.get(&o.app) != Some(&o.commit)).collect();
    let next = offers.values().map(|o| (o.app.clone(), o.commit.clone())).collect();
    (fresh, next)
}

/// One notification for every new offer: the title counts them.
pub(super) fn notification(fresh: &[&Offer]) -> Option<(String, String)> {
    match fresh {
        [] => None,
        [one] => Some((
            "Extension update available".to_string(),
            format!(
                "{} {} is available (you have {}). Open Extensions to update it, or run `cmux apps update {}`.",
                one.name, one.version, one.current, one.app
            ),
        )),
        many => {
            let names: Vec<String> =
                many.iter().map(|o| format!("{} {}", o.name, o.version)).collect();
            Some((
                format!("{} extension updates available", many.len()),
                format!(
                    "{}. Open Extensions to update them, or run `cmux apps update <app>`.",
                    names.join(", ")
                ),
            ))
        }
    }
}

fn notified_file(state_dir: &Path) -> PathBuf {
    state_dir.join("apps").join("update-offers-notified.json")
}

fn read_told(file: &Path) -> BTreeMap<String, String> {
    std::fs::read(file).ok().and_then(|raw| serde_json::from_slice(&raw).ok()).unwrap_or_default()
}

fn write_told(file: &Path, told: &BTreeMap<String, String>) {
    let Some(dir) = file.parent() else { return };
    let Ok(raw) = serde_json::to_vec(told) else { return };
    let temp = file.with_extension("json.tmp");
    if std::fs::create_dir_all(dir).is_ok() && std::fs::write(&temp, raw).is_ok() {
        let _ = std::fs::rename(&temp, file);
    }
}

#[cfg(test)]
#[path = "extension_updates_tests.rs"]
mod tests;
