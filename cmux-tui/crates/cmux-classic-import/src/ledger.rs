//! The version-stamped record of the classic migration, and its folder
//! (`Application Support/cmux-next/<bundle id>/classic-migration`): the
//! ledger and backup copies of the classic files a run read.
//!
//! The ledger is the only marker: classic's files are never written. Each
//! workspace is recorded before it is made, again once made and once done,
//! so a run cut off midway resumes without duplicates. A ledger with a newer
//! schema than this build knows stops automatic runs rather than guess. Its
//! JSON is the one earlier builds wrote, so either build reads the other's.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::source::Source;

/// The schema this build writes.
pub const CURRENT_SCHEMA: i64 = 1;
/// How many backup folders are kept, newest first.
pub const KEPT_BACKUPS: usize = 5;

/// Where a run is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum State {
    /// A run started and has not finished (the app quit or crashed midway).
    #[serde(rename = "inProgress")]
    InProgress,
    /// The last run finished.
    #[serde(rename = "completed")]
    Completed,
}

/// One classic workspace's progress.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Stage {
    /// About to be made; no cmux NEXT workspace yet.
    Pending,
    /// Its cmux NEXT workspace exists; its layout may be partial.
    Created,
    /// Fully made.
    Done,
    /// Never comes over (a Cloud VM workspace); `reason` says why.
    Skipped,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub stage: Stage,
    /// The cmux NEXT workspace made for it, once created.
    #[serde(rename = "nextWorkspace", default, skip_serializing_if = "Option::is_none")]
    pub next_workspace: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

impl Entry {
    pub fn new(stage: Stage, next_workspace: Option<&str>, reason: Option<&str>) -> Self {
        Self {
            stage,
            next_workspace: next_workspace.map(str::to_string),
            reason: reason.map(str::to_string),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Ledger {
    pub schema: i64,
    pub state: State,
    /// The classic save the last run read.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<Source>,
    /// Progress by classic workspace key.
    pub workspaces: BTreeMap<String, Entry>,
    /// cmux NEXT group id by classic group id.
    pub groups: BTreeMap<String, String>,
    /// How many runs started (first migration, resumes and merges).
    pub runs: i64,
    /// The cmux NEXT version that wrote it last.
    #[serde(rename = "appVersion", default, skip_serializing_if = "Option::is_none")]
    pub app_version: Option<String>,
    #[serde(rename = "updatedAt")]
    pub updated_at: f64,
}

impl Default for Ledger {
    fn default() -> Self {
        Self::new(State::InProgress)
    }
}

impl Ledger {
    pub fn new(state: State) -> Self {
        Self {
            schema: CURRENT_SCHEMA,
            state,
            source: None,
            workspaces: BTreeMap::new(),
            groups: BTreeMap::new(),
            runs: 0,
            app_version: None,
            updated_at: 0.0,
        }
    }
}

/// What the ledger file held.
#[derive(Debug, Clone, PartialEq)]
pub enum Load {
    /// No run happened on this Mac for this build's channel.
    None,
    Ledger(Ledger),
    /// A newer schema's ledger; it is left as it is.
    Newer(i64),
    /// A ledger that does not decode; it was moved aside.
    Unreadable,
    /// A ledger that is there but could not be read (permissions, I/O); it
    /// is left as it is and nothing runs, so its runs are never recorded over.
    Failed(String),
}

impl Load {
    /// The ledger, if one was read.
    pub fn ledger(&self) -> Option<Ledger> {
        match self {
            Load::Ledger(ledger) => Some(ledger.clone()),
            _ => None,
        }
    }

    pub fn name(&self) -> &'static str {
        match self {
            Load::None => "none",
            Load::Ledger(_) => "ledger",
            Load::Newer(_) => "newer",
            Load::Unreadable => "unreadable",
            Load::Failed(_) => "failed",
        }
    }
}

/// The migration's own folder. Classic's files are only ever read and
/// copied into it. Writes are atomic, so a crash leaves the old ledger or
/// the new one.
#[derive(Debug, Clone)]
pub struct Folder {
    pub directory: PathBuf,
}

impl Folder {
    pub fn new(directory: PathBuf) -> Self {
        Self { directory }
    }

    pub fn ledger_path(&self) -> PathBuf {
        self.directory.join("ledger.json")
    }

    pub fn backups_path(&self) -> PathBuf {
        self.directory.join("backups")
    }

    /// The ledger, if any. One that does not decode is moved aside as
    /// `ledger.unreadable-<ms>.json`; a newer schema's is left alone.
    pub fn load(&self) -> Load {
        let data = match std::fs::read(self.ledger_path()) {
            Ok(data) => data,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Load::None,
            Err(error) => return Load::Failed(error.to_string()),
        };
        let schema = serde_json::from_slice::<serde_json::Value>(&data)
            .ok()
            .and_then(|value| value.get("schema").and_then(serde_json::Value::as_i64));
        if let Some(schema) = schema.filter(|schema| *schema > CURRENT_SCHEMA) {
            return Load::Newer(schema);
        }
        if let Ok(ledger) = serde_json::from_slice::<Ledger>(&data) {
            return Load::Ledger(ledger);
        }
        let millis = (crate::source::seconds(std::time::SystemTime::now()) * 1000.0) as i64;
        let aside = self.directory.join(format!("ledger.unreadable-{millis}.json"));
        let _ = std::fs::rename(self.ledger_path(), aside);
        Load::Unreadable
    }

    /// Writes `ledger` atomically.
    pub fn save(&self, ledger: &Ledger) -> std::io::Result<()> {
        std::fs::create_dir_all(&self.directory)?;
        let mut data = serde_json::to_vec_pretty(&serde_json::to_value(ledger)?)?;
        data.push(b'\n');
        let temporary = self.directory.join(format!(".ledger.{}.tmp", std::process::id()));
        std::fs::write(&temporary, &data)?;
        std::fs::rename(&temporary, self.ledger_path()).inspect_err(|_| {
            let _ = std::fs::remove_file(&temporary);
        })
    }

    /// Copies the `files` that exist into a new `backups/<stamp>` folder and
    /// returns it; none when none exists. Folders beyond [`KEPT_BACKUPS`]
    /// are removed, oldest first (only the migration's own copies).
    pub fn backup(&self, files: &[PathBuf], stamp: &str) -> std::io::Result<Option<PathBuf>> {
        match self.stage(files, stamp)? {
            Some(staged) => self.keep(&staged, stamp).map(Some),
            None => Ok(None),
        }
    }

    /// Copies the `files` that exist into a hidden `backups/.staging-<name>`
    /// folder, which neither counts as a backup nor is read as one until
    /// [`Folder::keep`] names it; none when none exists. A caller copies
    /// big files here with no lock held, then keeps them only when its step
    /// really runs (a replayed step removes the staged copy instead).
    pub fn stage(&self, files: &[PathBuf], name: &str) -> std::io::Result<Option<PathBuf>> {
        let existing: Vec<&PathBuf> = files.iter().filter(|file| file.is_file()).collect();
        if existing.is_empty() {
            return Ok(None);
        }
        let folder = self.backups_path().join(format!(".staging-{}", one_folder(name)?));
        let _ = std::fs::remove_dir_all(&folder);
        std::fs::create_dir_all(&folder)?;
        for file in existing {
            let Some(file_name) = file.file_name() else { continue };
            std::fs::copy(file, folder.join(file_name))
                .inspect_err(|_| drop(std::fs::remove_dir_all(&folder)))?;
        }
        Ok(Some(folder))
    }

    /// Names the `staged` copies `backups/<stamp>` and removes the folders
    /// beyond [`KEPT_BACKUPS`], oldest first (only the migration's own copies).
    pub fn keep(&self, staged: &Path, stamp: &str) -> std::io::Result<PathBuf> {
        let folder = self.backups_path().join(one_folder(stamp)?);
        if folder.exists() {
            let _ = std::fs::remove_dir_all(staged);
        } else {
            std::fs::rename(staged, &folder)?;
        }
        let mut all: Vec<String> = self.backup_folders();
        all.sort_by(|a, b| b.cmp(a));
        for old in all.iter().skip(KEPT_BACKUPS) {
            let _ = std::fs::remove_dir_all(self.backups_path().join(old));
        }
        Ok(folder)
    }

    /// The kept backup folders' names (staged copies left out).
    pub fn backup_folders(&self) -> Vec<String> {
        std::fs::read_dir(self.backups_path())
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|entry| entry.file_name().into_string().ok())
            .filter(|name| !name.starts_with('.'))
            .collect()
    }
}

/// `name` when it is one plain folder name.
fn one_folder(name: &str) -> std::io::Result<&str> {
    if name.is_empty() || name.contains('/') || name.starts_with('.') {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "a backup stamp is one folder name",
        ));
    }
    Ok(name)
}

/// A backup folder's name: the UTC time (`20261108T101500Z`) and `suffix`,
/// so folders sort by time and two runs in one second do not share one.
pub fn backup_stamp(seconds_since_1970: i64, suffix: &str) -> String {
    let days = seconds_since_1970.div_euclid(86_400);
    let second = seconds_since_1970.rem_euclid(86_400);
    // Civil date from days since 1970 (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}{month:02}{day:02}T{:02}{:02}{:02}Z-{suffix}",
        second / 3_600,
        second % 3_600 / 60,
        second % 60
    )
}

/// `Application Support/cmux-next/<bundle id>/classic-migration` under
/// `home`'s Application Support. None for a bundle id that is not a plain
/// reverse-DNS name, so a caller can only ever name one folder of this kind.
pub fn default_directory(home: &Path, bundle_id: &str) -> Option<PathBuf> {
    let plain = !bundle_id.is_empty()
        && bundle_id.len() <= 255
        && !bundle_id.starts_with('.')
        && !bundle_id.contains("..")
        && bundle_id.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'));
    plain.then(|| {
        home.join("Library/Application Support/cmux-next").join(bundle_id).join("classic-migration")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_ledger_round_trips() {
        let root = tempfile::tempdir().unwrap();
        let folder = Folder::new(root.path().join("m"));
        assert_eq!(folder.load(), Load::None);
        let mut ledger = Ledger::new(State::Completed);
        ledger.groups.insert("g".into(), "grp_1".into());
        ledger.runs = 2;
        ledger.workspaces.insert("k".into(), Entry::new(Stage::Done, Some("w"), None));
        folder.save(&ledger).unwrap();
        assert_eq!(folder.load(), Load::Ledger(ledger));
    }

    /// A ledger an earlier build wrote reads here, and this build's reads there.
    #[test]
    fn the_earlier_builds_ledger_json_reads_and_is_written_the_same_way() {
        let earlier = r#"{
          "appVersion" : "0.70.1",
          "groups" : { "11111111-1111-4111-8111-111111111111" : "grp_1" },
          "runs" : 1,
          "schema" : 1,
          "source" : { "bundleID" : "com.cmuxterm.app", "createdAt" : 1761000000.5, "modifiedAt" : 1761000001.75,
                       "path" : "/s/session-com.cmuxterm.app.json", "size" : 4096 },
          "state" : "inProgress",
          "updatedAt" : 1761000002.25,
          "workspaces" : {
            "a" : { "nextWorkspace" : "ws_1", "stage" : "done" },
            "b" : { "stage" : "pending" },
            "c" : { "reason" : "cloud-vm", "stage" : "skipped" }
          }
        }"#;
        let ledger: Ledger = serde_json::from_str(earlier).unwrap();
        assert_eq!(ledger.state, State::InProgress);
        assert_eq!(ledger.source.as_ref().unwrap().bundle_id, "com.cmuxterm.app");
        assert_eq!(ledger.workspaces["c"], Entry::new(Stage::Skipped, None, Some("cloud-vm")));
        let written = serde_json::to_value(&ledger).unwrap();
        assert_eq!(written, serde_json::from_str::<serde_json::Value>(earlier).unwrap());
    }

    /// A newer cmux NEXT's ledger is left as it is; this build only stops.
    #[test]
    fn a_newer_ledger_is_left_alone() {
        let root = tempfile::tempdir().unwrap();
        let folder = Folder::new(root.path().join("m"));
        std::fs::create_dir_all(&folder.directory).unwrap();
        std::fs::write(folder.ledger_path(), r#"{"schema":7,"future":true}"#).unwrap();
        assert_eq!(folder.load(), Load::Newer(7));
        assert_eq!(
            std::fs::read_to_string(folder.ledger_path()).unwrap(),
            r#"{"schema":7,"future":true}"#
        );
    }

    /// A ledger that is there but cannot be read is not a first run.
    #[test]
    fn a_ledger_that_cannot_be_read_is_not_a_first_run() {
        let root = tempfile::tempdir().unwrap();
        let folder = Folder::new(root.path().join("m"));
        std::fs::create_dir_all(folder.ledger_path()).unwrap();
        assert!(matches!(folder.load(), Load::Failed(_)));
        assert!(folder.ledger_path().is_dir());
    }

    #[test]
    fn a_damaged_ledger_is_moved_aside() {
        let root = tempfile::tempdir().unwrap();
        let folder = Folder::new(root.path().join("m"));
        std::fs::create_dir_all(&folder.directory).unwrap();
        std::fs::write(folder.ledger_path(), "{not json").unwrap();
        assert_eq!(folder.load(), Load::Unreadable);
        let names: Vec<String> = std::fs::read_dir(&folder.directory)
            .unwrap()
            .flatten()
            .map(|entry| entry.file_name().into_string().unwrap())
            .collect();
        assert!(!names.contains(&"ledger.json".to_string()));
        assert!(names.iter().any(|name| name.starts_with("ledger.unreadable-")), "{names:?}");
    }

    /// Backups copy classic's files; the originals keep their bytes and dates.
    #[test]
    fn backups_copy_and_never_touch_classic_files() {
        let root = tempfile::tempdir().unwrap();
        let session = root.path().join("support/cmux/session-com.cmuxterm.app.json");
        std::fs::create_dir_all(session.parent().unwrap()).unwrap();
        std::fs::write(&session, "{\"windows\":[]}").unwrap();
        let date = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000);
        std::fs::File::options().write(true).open(&session).unwrap().set_modified(date).unwrap();
        let folder = Folder::new(root.path().join("m"));
        for index in 0..7 {
            let made = folder
                .backup(
                    &[session.clone(), root.path().join("missing.json")],
                    &format!("2026101{index}"),
                )
                .unwrap()
                .unwrap();
            assert_eq!(
                std::fs::read(made.join("session-com.cmuxterm.app.json")).unwrap(),
                b"{\"windows\":[]}"
            );
        }
        assert_eq!(std::fs::read(&session).unwrap(), b"{\"windows\":[]}");
        assert_eq!(std::fs::metadata(&session).unwrap().modified().unwrap(), date);
        let mut kept: Vec<String> = std::fs::read_dir(folder.backups_path())
            .unwrap()
            .flatten()
            .map(|entry| entry.file_name().into_string().unwrap())
            .collect();
        kept.sort();
        assert_eq!(kept, (2..7).map(|index| format!("2026101{index}")).collect::<Vec<_>>());
        assert_eq!(folder.backup(&[root.path().join("missing.json")], "x").unwrap(), None);
    }

    #[test]
    fn a_backup_stamp_is_the_utc_time_then_its_suffix() {
        assert_eq!(backup_stamp(0, "ab12"), "19700101T000000Z-ab12");
        assert_eq!(backup_stamp(1_794_133_715, "x"), "20261108T102835Z-x");
        assert_eq!(backup_stamp(951_782_400, "x"), "20000229T000000Z-x");
    }

    #[test]
    fn the_folder_is_named_only_by_a_plain_bundle_id() {
        let home = Path::new("/Users/me");
        assert_eq!(
            default_directory(home, "com.cmuxterm.app.nightly.cmux-next").unwrap(),
            home.join("Library/Application Support/cmux-next/com.cmuxterm.app.nightly.cmux-next/classic-migration")
        );
        for bad in ["", "../x", "a/b", ".hidden", "a..b"] {
            assert_eq!(default_directory(home, bad), None, "{bad}");
        }
    }
}
