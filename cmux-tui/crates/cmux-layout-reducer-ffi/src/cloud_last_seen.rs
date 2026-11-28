//! The kept machine lists' files (`cloud_machine_last_seen_*`): the app hands its state folder,
//! the account and the rows; [`cmux_cloud_machine::last_seen`] says what the file holds and
//! whether it may be shown. Writes go to a temporary file renamed over the old one, so a crash
//! never leaves half a list; every failure is a quiet "nothing kept", never an error the person sees.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use cmux_cloud_machine::last_seen::{self, Row};
use serde::Deserialize;
use serde_json::{Value, json};

/// The folder under the app's state folder the lists live in.
const FOLDER: &str = "cloud-last-seen";

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Save {
    dir: String,
    user: String,
    #[serde(default)]
    team: Option<String>,
    at: i64,
    machines: Vec<Row>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Load {
    dir: String,
    user: String,
    #[serde(default)]
    team: Option<String>,
    now: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RefreshDue {
    #[serde(default)]
    failures: u32,
    #[serde(default)]
    since_last_ms: Option<i64>,
}

#[derive(Deserialize)]
pub(crate) struct Forget {
    dir: String,
}

fn folder(dir: &str) -> Option<PathBuf> {
    (!dir.is_empty()).then(|| Path::new(dir).join(FOLDER))
}

/// `{"ok": bool, "written": bool}`: whether the list is now on disk, and whether this call wrote
/// it. An unchanged list an earlier write already put there ([`last_seen::unchanged`]) is not
/// written again: `ok` without `written`.
pub(crate) fn save(request: &Save) -> Value {
    let user = request.user.as_str();
    let team = request.team.as_deref();
    let result = (|| {
        let folder = folder(&request.dir)?;
        let text = last_seen::encode(user, team, request.at, &request.machines)?;
        let name = last_seen::file_name(user, team);
        let path = folder.join(&name);
        if fs::read_to_string(&path).is_ok_and(|kept| {
            last_seen::unchanged(&kept, user, team, request.at, &request.machines)
        }) {
            return Some(false);
        }
        fs::create_dir_all(&folder).ok()?;
        let temp = folder.join(format!("{name}.{}{}", std::process::id(), last_seen::TEMP_SUFFIX));
        let written = (|| {
            let mut file = open_private(&temp)?;
            file.write_all(text.as_bytes())?;
            file.sync_all()?;
            fs::rename(&temp, &path)
        })();
        if written.is_err() {
            let _ = fs::remove_file(&temp);
        }
        written.ok().map(|()| true)
    })();
    json!({ "ok": result.is_some(), "written": result == Some(true) })
}

/// `{"snapshot": {version, user, team, at, machines} | null}`.
pub(crate) fn load(request: &Load) -> Value {
    let snapshot = folder(&request.dir).and_then(|folder| {
        let path = folder.join(last_seen::file_name(&request.user, request.team.as_deref()));
        let text = fs::read_to_string(path).ok()?;
        last_seen::decode(&text, &request.user, request.team.as_deref(), request.now)
    });
    json!({ "snapshot": snapshot })
}

/// Removes every kept list (sign-out) and the temporary files an interrupted write left
/// ([`last_seen::is_temp_file_name`]), and only those files. `{"removed": n}`.
pub(crate) fn forget(request: &Forget) -> Value {
    let mut removed = 0;
    if let Some(entries) = folder(&request.dir).and_then(|folder| fs::read_dir(folder).ok()) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            if name.to_str().is_some_and(|name| {
                last_seen::is_file_name(name) || last_seen::is_temp_file_name(name)
            }) && fs::remove_file(entry.path()).is_ok()
            {
                removed += 1;
            }
        }
    }
    json!({ "removed": removed })
}

/// `{"due": bool, "waitMs": n}`: whether a background refresh of a shown kept list may start now,
/// after `failures` failed refreshes in a row, the last started `sinceLastMs` ago
/// ([`last_seen::refresh_due`]); `waitMs` is the whole wait after that many failures.
pub(crate) fn refresh_due(request: &RefreshDue) -> Value {
    json!({
        "due": last_seen::refresh_due(request.failures, request.since_last_ms),
        "waitMs": last_seen::refresh_backoff_ms(request.failures),
    })
}

#[cfg(unix)]
fn open_private(path: &Path) -> std::io::Result<fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(path)
}

#[cfg(not(unix))]
fn open_private(path: &Path) -> std::io::Result<fs::File> {
    fs::File::create(path)
}

#[cfg(test)]
#[path = "cloud_last_seen_tests.rs"]
mod tests;
