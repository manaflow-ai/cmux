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
pub(crate) struct Forget {
    dir: String,
}

fn folder(dir: &str) -> Option<PathBuf> {
    (!dir.is_empty()).then(|| Path::new(dir).join(FOLDER))
}

/// `{"ok": bool}`: whether the list is now on disk.
pub(crate) fn save(request: &Save) -> Value {
    let ok = (|| {
        let folder = folder(&request.dir)?;
        let text = last_seen::encode(
            &request.user,
            request.team.as_deref(),
            request.at,
            &request.machines,
        )?;
        fs::create_dir_all(&folder).ok()?;
        let name = last_seen::file_name(&request.user, request.team.as_deref());
        let path = folder.join(&name);
        let temp = folder.join(format!("{name}.{}.tmp", std::process::id()));
        let written = (|| {
            let mut file = open_private(&temp)?;
            file.write_all(text.as_bytes())?;
            file.sync_all()?;
            fs::rename(&temp, &path)
        })();
        if written.is_err() {
            let _ = fs::remove_file(&temp);
        }
        written.ok()
    })()
    .is_some();
    json!({ "ok": ok })
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

/// Removes every kept list (sign-out), and only those files. `{"removed": n}`.
pub(crate) fn forget(request: &Forget) -> Value {
    let mut removed = 0;
    if let Some(entries) = folder(&request.dir).and_then(|folder| fs::read_dir(folder).ok()) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            if name.to_str().is_some_and(last_seen::is_file_name)
                && fs::remove_file(entry.path()).is_ok()
            {
                removed += 1;
            }
        }
    }
    json!({ "removed": removed })
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
        assert_eq!(saved, json!({"ok": true}));
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
            json!({"ok": false})
        );
        assert_eq!(
            save(&Save {
                dir: String::new(),
                user: "u".into(),
                team: None,
                at: NOW,
                machines: rows()
            }),
            json!({"ok": false})
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
}
