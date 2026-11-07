//! The usage folder on this machine: the on-switch, the salt, and one bounded file per writer.
//!
//! ```text
//! <dir>/enabled          present while recording is on (the app writes it from the person's own yes)
//! <dir>/salt             32 random bytes (hex), made at the first switch-on; ids are hashed with it
//! <dir>/<stem>.jsonl     one Record per line, appended by one writer (app-nightly, daemon, acpmux)
//! <dir>/<stem>.jsonl.1   the previous generation, replaced at each roll
//! ```
//!
//! Each file rolls to `.1` once it passes [`MAX_FILE_BYTES`], so one writer never holds more than
//! twice that, and the folder holds at most [`MAX_FILE_BYTES`] × 2 × the writers that ever ran.
//! Nothing here starts a thread or a timer: a writer appends when it has records, and checks the
//! on-switch (one `stat`) per append, so switching off stops every writer at its next append.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::event::{Event, Record, Source, Token};

/// A file rolls to `.1` after it passes this size (4 MiB, about 30 000 records).
pub const MAX_FILE_BYTES: u64 = 4 * 1024 * 1024;

const ENABLED: &str = "enabled";
const SALT: &str = "salt";

/// The usage folder: `CMUX_USAGE_DIR`, else `~/Library/Application Support/cmux/usage` on macOS,
/// else `$XDG_STATE_HOME/cmux/usage` (`~/.local/state/cmux/usage`).
pub fn default_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("CMUX_USAGE_DIR").filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(dir));
    }
    let home = std::env::var_os("HOME").filter(|v| !v.is_empty()).map(PathBuf::from);
    if cfg!(target_os = "macos") {
        return home.map(|h| h.join("Library/Application Support/cmux/usage"));
    }
    let state = std::env::var_os("XDG_STATE_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| home.map(|h| h.join(".local/state")))?;
    Some(state.join("cmux/usage"))
}

/// Milliseconds since the Unix epoch.
pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}

/// The usage folder and what is in it.
#[derive(Debug, Clone)]
pub struct UsageDir {
    dir: PathBuf,
}

impl UsageDir {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
    }

    /// [`default_dir`], or `None` without a home folder.
    pub fn default_location() -> Option<Self> {
        default_dir().map(Self::new)
    }

    pub fn path(&self) -> &Path {
        &self.dir
    }

    /// Whether recording is on: the on-switch file exists.
    pub fn is_enabled(&self) -> bool {
        self.dir.join(ENABLED).is_file()
    }

    /// When recording was last switched on (Unix ms), if it is on.
    pub fn enabled_since(&self) -> Option<u64> {
        let text = fs::read_to_string(self.dir.join(ENABLED)).ok()?;
        serde_json::from_str::<serde_json::Value>(&text).ok()?.get("since")?.as_u64()
    }

    /// Switches recording on or off. On makes the folder and the salt if needed; off removes the
    /// on-switch and keeps what was recorded ([`UsageDir::clear`] deletes it).
    pub fn set_enabled(&self, on: bool) -> io::Result<()> {
        let marker = self.dir.join(ENABLED);
        if !on {
            return match fs::remove_file(marker) {
                Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
                other => other,
            };
        }
        if self.is_enabled() {
            return Ok(());
        }
        fs::create_dir_all(&self.dir)?;
        self.salt()?;
        fs::write(marker, format!("{{\"since\":{}}}\n", now_ms()))
    }

    /// This install's salt, made on first use.
    pub fn salt(&self) -> io::Result<Vec<u8>> {
        let path = self.dir.join(SALT);
        if let Ok(text) = fs::read_to_string(&path)
            && let Ok(bytes) = hex::decode(text.trim())
            && bytes.len() == 32
        {
            return Ok(bytes);
        }
        let mut bytes = [0u8; 32];
        getrandom::fill(&mut bytes).map_err(|e| io::Error::other(e.to_string()))?;
        fs::create_dir_all(&self.dir)?;
        fs::write(&path, hex::encode(bytes))?;
        Ok(bytes.to_vec())
    }

    /// Every usage file, current generations and rolled ones.
    pub fn files(&self) -> Vec<PathBuf> {
        let Ok(entries) = fs::read_dir(&self.dir) else { return Vec::new() };
        let mut files: Vec<PathBuf> = entries
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.ends_with(".jsonl") || n.ends_with(".jsonl.1"))
            })
            .collect();
        files.sort();
        files
    }

    /// Bytes the usage files take.
    pub fn bytes(&self) -> u64 {
        self.files().iter().filter_map(|p| fs::metadata(p).ok()).map(|m| m.len()).sum()
    }

    /// Every record at or after `since_ms`, in time order. Lines that do not parse (a torn write,
    /// a newer schema) are skipped.
    pub fn read(&self, since_ms: u64) -> Vec<Record> {
        let mut records = Vec::new();
        for file in self.files() {
            let Ok(text) = fs::read_to_string(&file) else { continue };
            records.extend(
                text.lines()
                    .filter_map(|line| serde_json::from_str::<Record>(line).ok())
                    .filter(|r| r.at >= since_ms),
            );
        }
        records.sort_by_key(|r| r.at);
        records
    }

    /// Deletes every usage file and the salt (the on-switch stays as it is).
    pub fn clear(&self) -> io::Result<()> {
        for file in self.files() {
            fs::remove_file(file)?;
        }
        match fs::remove_file(self.dir.join(SALT)) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
            other => other,
        }
    }
}

/// One writer's file: appends records while recording is on, drops them while it is off.
#[derive(Debug)]
pub struct Recorder {
    dir: UsageDir,
    stem: String,
    src: Source,
    salt: Option<Vec<u8>>,
}

impl Recorder {
    /// A writer of `src` records to `<stem>.jsonl` (`stem` is made a [`Token`], so it is a plain
    /// file name).
    pub fn new(dir: UsageDir, src: Source, stem: &str) -> Self {
        Self { dir, stem: Token::new(stem).as_str().to_owned(), src, salt: None }
    }

    pub fn dir(&self) -> &UsageDir {
        &self.dir
    }

    /// Appends `events`, each stamped with its time, as one write. Returns how many were written:
    /// 0 while recording is off. Ids are hashed with the salt first.
    pub fn append(&mut self, events: impl IntoIterator<Item = (u64, Event)>) -> io::Result<usize> {
        if !self.dir.is_enabled() {
            self.salt = None;
            return Ok(0);
        }
        let salt = match &self.salt {
            Some(salt) => salt.clone(),
            None => {
                let salt = self.dir.salt()?;
                self.salt = Some(salt.clone());
                salt
            }
        };
        let mut text = String::new();
        let mut count = 0;
        for (at, mut ev) in events {
            ev.hash_ids(&salt);
            let record = Record { at, src: self.src, ev };
            if let Ok(line) = serde_json::to_string(&record) {
                text.push_str(&line);
                text.push('\n');
                count += 1;
            }
        }
        if count == 0 {
            return Ok(0);
        }
        let path = self.dir.path().join(format!("{}.jsonl", self.stem));
        let mut file = OpenOptions::new().create(true).append(true).open(&path)?;
        file.write_all(text.as_bytes())?;
        if file.metadata().map(|m| m.len()).unwrap_or(0) > MAX_FILE_BYTES {
            fs::rename(&path, self.dir.path().join(format!("{}.jsonl.1", self.stem)))?;
        }
        Ok(count)
    }

    /// [`Recorder::append`] of events that happen now.
    pub fn record_now(&mut self, events: impl IntoIterator<Item = Event>) -> io::Result<usize> {
        let at = now_ms();
        self.append(events.into_iter().map(|e| (at, e)))
    }

    /// Appends a JSON array of `{"at": ms, "ev": {...}}` objects from a client (the app), refusing
    /// the whole batch if any element is not exactly that shape. Returns how many were written.
    pub fn append_json(&mut self, json: &str) -> io::Result<usize> {
        #[derive(serde::Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Item {
            at: u64,
            ev: Event,
        }
        let items: Vec<Item> = serde_json::from_str(json)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        self.append(items.into_iter().map(|i| (i.at, i.ev)))
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::event::{Id, Surface};

    pub(crate) fn temp_dir(name: &str) -> UsageDir {
        let dir = std::env::temp_dir().join(format!(
            "cmux-usage-{name}-{}-{}",
            std::process::id(),
            now_ms()
        ));
        let _ = fs::remove_dir_all(&dir);
        UsageDir::new(dir)
    }

    #[test]
    fn nothing_is_written_while_off() {
        let dir = temp_dir("off");
        let mut rec = Recorder::new(dir.clone(), Source::App, "app-dev");
        assert_eq!(rec.record_now([Event::Active { on: true }]).expect("append"), 0);
        assert!(!dir.path().exists());
        assert!(dir.files().is_empty());
    }

    #[test]
    fn writes_while_on_and_stops_when_switched_off() {
        let dir = temp_dir("onoff");
        dir.set_enabled(true).expect("on");
        let mut rec = Recorder::new(dir.clone(), Source::App, "app-dev");
        assert_eq!(rec.record_now([Event::Active { on: true }]).expect("append"), 1);
        dir.set_enabled(false).expect("off");
        assert_eq!(rec.record_now([Event::Active { on: false }]).expect("append"), 0);
        assert_eq!(dir.read(0).len(), 1);
        let _ = fs::remove_dir_all(dir.path());
    }

    #[test]
    fn ids_are_hashed_on_disk() {
        let dir = temp_dir("hash");
        dir.set_enabled(true).expect("on");
        let mut rec = Recorder::new(dir.clone(), Source::App, "app-dev");
        rec.record_now([Event::Focus { surface: Surface::Chat, tab: Some(Id::new("TAB-RAW-ID")) }])
            .expect("append");
        let text = fs::read_to_string(dir.path().join("app-dev.jsonl")).expect("file");
        assert!(!text.contains("TAB-RAW-ID"));
        let _ = fs::remove_dir_all(dir.path());
    }

    #[test]
    fn the_file_rolls_and_stays_bounded() {
        let dir = temp_dir("roll");
        dir.set_enabled(true).expect("on");
        let mut rec = Recorder::new(dir.clone(), Source::App, "app-dev");
        let batch: Vec<Event> = (0..4096).map(|_| Event::Active { on: true }).collect();
        for _ in 0..80 {
            rec.record_now(batch.clone()).expect("append");
        }
        let current = fs::metadata(dir.path().join("app-dev.jsonl")).map(|m| m.len()).unwrap_or(0);
        let rolled = fs::metadata(dir.path().join("app-dev.jsonl.1")).expect("rolled").len();
        assert!(current <= MAX_FILE_BYTES);
        assert!(rolled <= MAX_FILE_BYTES + 4096 * 64);
        assert!(dir.bytes() <= 2 * MAX_FILE_BYTES + 4096 * 64);
        let _ = fs::remove_dir_all(dir.path());
    }

    #[test]
    fn a_client_batch_with_an_extra_field_is_refused_whole() {
        let dir = temp_dir("json");
        dir.set_enabled(true).expect("on");
        let mut rec = Recorder::new(dir.clone(), Source::App, "app-dev");
        let good = r#"[{"at":5,"ev":{"t":"active","on":true}}]"#;
        assert_eq!(rec.append_json(good).expect("good"), 1);
        let bad = r#"[{"at":6,"ev":{"t":"active","on":true}},{"at":7,"ev":{"t":"active","on":true},"url":"x"}]"#;
        assert!(rec.append_json(bad).is_err());
        assert_eq!(dir.read(0).len(), 1);
        let _ = fs::remove_dir_all(dir.path());
    }

    #[test]
    fn clear_deletes_files_and_salt() {
        let dir = temp_dir("clear");
        dir.set_enabled(true).expect("on");
        let salt = dir.salt().expect("salt");
        let mut rec = Recorder::new(dir.clone(), Source::App, "app-dev");
        rec.record_now([Event::Active { on: true }]).expect("append");
        dir.clear().expect("clear");
        assert!(dir.files().is_empty());
        assert_ne!(dir.salt().expect("new salt"), salt);
        let _ = fs::remove_dir_all(dir.path());
    }
}
