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
mod tests {
    use super::*;

    const NOW: i64 = 1_800_000_000_000;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("cmux-last-seen-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn rows() -> Vec<Row> {
        vec![Row {
            id: "m1".into(),
            name: "box".into(),
            stage: "paused".into(),
            evict_at: None,
            size: None,
        }]
    }

    #[test]
    fn saves_loads_and_forgets() {
        let dir = temp_dir("roundtrip");
        let d = dir.to_string_lossy().into_owned();
        let saved = save(&Save {
            dir: d.clone(),
            user: "u".into(),
            team: Some("t".into()),
            at: NOW,
            machines: rows(),
        });
        assert_eq!(saved, json!({"ok": true, "written": true}));
        let loaded =
            load(&Load { dir: d.clone(), user: "u".into(), team: Some("t".into()), now: NOW + 1 });
        assert_eq!(loaded["snapshot"]["machines"][0]["id"], "m1");
        assert_eq!(loaded["snapshot"]["at"], NOW);
        // Another team reads nothing.
        let other =
            load(&Load { dir: d.clone(), user: "u".into(), team: Some("t2".into()), now: NOW });
        assert_eq!(other, json!({"snapshot": null}));
        // A file of someone else's beside the lists stays.
        fs::write(dir.join(FOLDER).join("keep.json"), "{}").unwrap();
        assert_eq!(forget(&Forget { dir: d.clone() }), json!({"removed": 1}));
        assert!(dir.join(FOLDER).join("keep.json").exists());
        let gone = load(&Load { dir: d, user: "u".into(), team: Some("t".into()), now: NOW });
        assert_eq!(gone, json!({"snapshot": null}));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn signed_out_or_no_folder_keeps_nothing() {
        let dir = temp_dir("signedout");
        let d = dir.to_string_lossy().into_owned();
        assert_eq!(
            save(&Save { dir: d, user: String::new(), team: None, at: NOW, machines: rows() }),
            json!({"ok": false, "written": false})
        );
        assert_eq!(
            save(&Save {
                dir: String::new(),
                user: "u".into(),
                team: None,
                at: NOW,
                machines: rows()
            }),
            json!({"ok": false, "written": false})
        );
        assert!(!dir.join(FOLDER).exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn the_file_is_private() {
        use std::os::unix::fs::PermissionsExt;
        let dir = temp_dir("mode");
        let d = dir.to_string_lossy().into_owned();
        save(&Save { dir: d, user: "u".into(), team: None, at: NOW, machines: rows() });
        let path = dir.join(FOLDER).join(last_seen::file_name("u", None));
        assert_eq!(fs::metadata(path).unwrap().permissions().mode() & 0o777, 0o600);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_unchanged_list_is_not_written_twice() {
        let dir = temp_dir("dedupe");
        let d = dir.to_string_lossy().into_owned();
        let save_at = |at: i64, machines: Vec<Row>| {
            save(&Save { dir: d.clone(), user: "u".into(), team: None, at, machines })
        };
        assert_eq!(save_at(NOW, rows()), json!({"ok": true, "written": true}));
        let path = dir.join(FOLDER).join(last_seen::file_name("u", None));
        let first = fs::read_to_string(&path).unwrap();
        // The same rows a minute later: on disk already, the file (and its time) unchanged.
        assert_eq!(save_at(NOW + 60_000, rows()), json!({"ok": true, "written": false}));
        assert_eq!(fs::read_to_string(&path).unwrap(), first);
        // A change is written; so is the same list an hour on.
        let mut changed = rows();
        changed[0].stage = "ready".into();
        assert_eq!(save_at(NOW + 120_000, changed.clone()), json!({"ok": true, "written": true}));
        assert_eq!(
            save_at(NOW + 120_000 + last_seen::REWRITE_AFTER_MS, changed),
            json!({"ok": true, "written": true})
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn forget_removes_leftover_temporary_files() {
        let dir = temp_dir("leftover");
        let d = dir.to_string_lossy().into_owned();
        let folder = dir.join(FOLDER);
        fs::create_dir_all(&folder).unwrap();
        let kept = last_seen::file_name("u", Some("t"));
        // A write interrupted between its write and its rename, by this process or an earlier one.
        fs::write(folder.join(format!("{kept}.4242.tmp")), "{").unwrap();
        fs::write(folder.join(format!("{kept}.{}.tmp", std::process::id())), "{").unwrap();
        // Someone else's temporary file stays.
        fs::write(folder.join("other.json.1.tmp"), "{").unwrap();
        assert_eq!(forget(&Forget { dir: d }), json!({"removed": 2}));
        assert!(folder.join("other.json.1.tmp").exists());
        assert_eq!(fs::read_dir(&folder).unwrap().count(), 1);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn refresh_due_backs_off() {
        let due = |failures: u32, since: Option<i64>| {
            refresh_due(&RefreshDue { failures, since_last_ms: since })
        };
        assert_eq!(due(0, None), json!({"due": true, "waitMs": 0}));
        assert_eq!(due(1, Some(1_000)), json!({"due": false, "waitMs": 2_000}));
        assert_eq!(due(1, Some(2_000)), json!({"due": true, "waitMs": 2_000}));
        assert_eq!(due(30, Some(60_000))["due"], false);
    }
}
