//! The durable local store.
//!
//! ```text
//! <root>/
//!   .runner.lock              file lock: one runner per machine
//!   auto_…/automation.json    the definition (atomic replace)
//!   auto_…/state.json         the schedule cursor (atomic replace)
//!   auto_…/runs.jsonl         run history, append-only, locked while appending
//!   auto_…/logs/run_….log     each run's output
//!   .deleted/auto_…-<time>/   deleted automations, history kept
//! ```
//!
//! Every replace writes a temp file, fsyncs it, renames it over the old one
//! and fsyncs the folder, so a crash leaves the old or the new file. A crash
//! in the middle of an append leaves a torn last line, which readers skip.

use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::automation::{Automation, AutomationSpec, new_automation_id};
use crate::run::Run;
use crate::sys::{create_private_dir, private_file, sync_dir};

/// A store operation that failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StoreError {
    /// No automation matches.
    NotFound(String),
    /// More than one automation matches.
    Ambiguous(String),
    /// The definition is not valid (schedule, name).
    Invalid(String),
    /// The file system refused.
    Io(String),
}

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            StoreError::NotFound(q) => write!(f, "no automation matches \"{q}\""),
            StoreError::Ambiguous(q) => {
                write!(f, "more than one automation matches \"{q}\"; use more of the id")
            }
            StoreError::Invalid(why) => f.write_str(why),
            StoreError::Io(why) => write!(f, "automation store: {why}"),
        }
    }
}

impl std::error::Error for StoreError {}

impl From<std::io::Error> for StoreError {
    fn from(e: std::io::Error) -> Self {
        StoreError::Io(e.to_string())
    }
}

/// The schedule cursor of one automation.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AutomationState {
    /// Every scheduled time up to here has a run row (or was paused over).
    pub handled_through: i64,
}

/// The store at one root folder.
#[derive(Clone, Debug)]
pub struct Store {
    root: PathBuf,
}

/// The machine's runner lock; held until dropped.
#[derive(Debug)]
pub struct RunnerLock {
    _file: File,
}

impl RunnerLock {
    /// Take the lock, or `None` when another runner holds it.
    pub fn acquire(store: &Store) -> Result<Option<RunnerLock>, StoreError> {
        let file = private_file(OpenOptions::new().create(true).truncate(false).write(true))
            .open(store.root.join(".runner.lock"))?;
        // std's lock is flock on Unix (as runners before it took) and
        // LockFileEx on Windows.
        match file.try_lock() {
            Ok(()) => Ok(Some(RunnerLock { _file: file })),
            Err(fs::TryLockError::WouldBlock) => Ok(None),
            Err(fs::TryLockError::Error(e)) => Err(e.into()),
        }
    }
}

/// Holds a lock on a file until dropped.
struct Flock(File);

impl Flock {
    /// Blocking is fine: holders only append one line.
    fn exclusive(file: File) -> std::io::Result<Flock> {
        file.lock()?;
        Ok(Flock(file))
    }

    /// A reader's lock. Windows locks are mandatory, so a read must not
    /// overlap an append; on Unix it also never sees half a line.
    fn shared(file: File) -> std::io::Result<Flock> {
        file.lock_shared()?;
        Ok(Flock(file))
    }
}

impl Drop for Flock {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}

fn is_automation_id(name: &str) -> bool {
    name.len() == 25
        && name
            .strip_prefix("auto_")
            .is_some_and(|id| id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit()))
}

fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let dir = path.parent().unwrap_or(Path::new("."));
    let tmp = dir.join(format!(
        ".{}.tmp-{}",
        path.file_name().and_then(|n| n.to_str()).unwrap_or("file"),
        std::process::id()
    ));
    {
        let mut f =
            private_file(OpenOptions::new().create(true).truncate(true).write(true)).open(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }
    fs::rename(&tmp, path)?;
    sync_dir(dir)
}

impl Store {
    /// The default root: `$CMUX_AUTOMATIONS_DIR`, else `~/.config/cmux/automations`.
    pub fn default_root() -> Option<PathBuf> {
        if let Some(dir) = std::env::var_os("CMUX_AUTOMATIONS_DIR").filter(|d| !d.is_empty()) {
            return Some(PathBuf::from(dir));
        }
        let home = std::env::var_os("HOME").filter(|h| !h.is_empty())?;
        Some(PathBuf::from(home).join(".config/cmux/automations"))
    }

    /// Open (and make) the store at `root`.
    pub fn open(root: &Path) -> Result<Store, StoreError> {
        create_private_dir(root)?;
        Ok(Store { root: root.to_path_buf() })
    }

    /// The root folder.
    pub fn root(&self) -> &Path {
        &self.root
    }

    fn dir(&self, id: &str) -> PathBuf {
        self.root.join(id)
    }

    /// The output file of one run.
    pub fn log_path(&self, automation: &str, run: &str) -> PathBuf {
        self.dir(automation).join("logs").join(format!("{run}.log"))
    }

    fn check(&self, spec: &AutomationSpec, except: Option<&str>) -> Result<(), StoreError> {
        let name = spec.name.trim();
        if name.is_empty() {
            return Err(StoreError::Invalid("an automation needs a name".into()));
        }
        if name.len() > 120 {
            return Err(StoreError::Invalid("a name has at most 120 characters".into()));
        }
        spec.trigger.validate().map_err(|e| StoreError::Invalid(e.0))?;
        if spec.timeout_seconds == 0 {
            return Err(StoreError::Invalid("the timeout must be at least one second".into()));
        }
        let taken = self
            .list()?
            .into_iter()
            .any(|a| Some(a.id.as_str()) != except && a.name.eq_ignore_ascii_case(name));
        if taken {
            return Err(StoreError::Invalid(format!(
                "an automation named \"{name}\" already exists"
            )));
        }
        Ok(())
    }

    fn save(&self, a: &Automation) -> Result<(), StoreError> {
        let json = serde_json::to_vec_pretty(a).map_err(|e| StoreError::Io(e.to_string()))?;
        write_atomic(&self.dir(&a.id).join("automation.json"), &json)?;
        Ok(())
    }

    /// Make an automation. Its schedule counts from `now`.
    pub fn create(&self, spec: AutomationSpec, now: i64) -> Result<Automation, StoreError> {
        self.check(&spec, None)?;
        let id = new_automation_id()?;
        create_private_dir(&self.dir(&id).join("logs"))?;
        let a = Automation {
            id,
            name: spec.name.trim().to_string(),
            version: 1,
            enabled: spec.enabled,
            trigger: spec.trigger,
            body: spec.body,
            catch_up: spec.catch_up,
            timeout_seconds: spec.timeout_seconds,
            created_at: now,
            updated_at: now,
        };
        self.set_handled_through(&a.id, now)?;
        self.save(&a)?;
        Ok(a)
    }

    /// Replace the editable fields; the schedule restarts from `now`.
    pub fn update(
        &self,
        id: &str,
        spec: AutomationSpec,
        now: i64,
    ) -> Result<Automation, StoreError> {
        let old = self.get(id)?;
        self.check(&spec, Some(id))?;
        let a = Automation {
            name: spec.name.trim().to_string(),
            version: old.version + 1,
            enabled: spec.enabled,
            trigger: spec.trigger,
            body: spec.body,
            catch_up: spec.catch_up,
            timeout_seconds: spec.timeout_seconds,
            updated_at: now,
            ..old
        };
        self.set_handled_through(id, now)?;
        self.save(&a)?;
        Ok(a)
    }

    /// Pause or resume. Resuming does not catch up the paused time.
    pub fn set_enabled(&self, id: &str, enabled: bool, now: i64) -> Result<Automation, StoreError> {
        let mut a = self.get(id)?;
        if a.enabled == enabled {
            return Ok(a);
        }
        if enabled {
            self.set_handled_through(id, now)?;
        }
        a.enabled = enabled;
        a.updated_at = now;
        self.save(&a)?;
        Ok(a)
    }

    /// Move the automation to `.deleted/`, history included.
    pub fn delete(&self, id: &str) -> Result<(), StoreError> {
        let a = self.get(id)?;
        let trash = self.root.join(".deleted");
        create_private_dir(&trash)?;
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        fs::rename(self.dir(&a.id), trash.join(format!("{}-{stamp}", a.id)))?;
        Ok(())
    }

    /// Every automation, oldest first.
    pub fn list(&self) -> Result<Vec<Automation>, StoreError> {
        let mut out = Vec::new();
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            if !is_automation_id(name) {
                continue;
            }
            if let Ok(bytes) = fs::read(entry.path().join("automation.json"))
                && let Ok(a) = serde_json::from_slice::<Automation>(&bytes)
            {
                out.push(a);
            }
        }
        out.sort_by(|a, b| (a.created_at, &a.id).cmp(&(b.created_at, &b.id)));
        Ok(out)
    }

    /// The automation with exactly this id.
    pub fn get(&self, id: &str) -> Result<Automation, StoreError> {
        if !is_automation_id(id) {
            return Err(StoreError::NotFound(id.into()));
        }
        let bytes = fs::read(self.dir(id).join("automation.json"))
            .map_err(|_| StoreError::NotFound(id.into()))?;
        serde_json::from_slice(&bytes).map_err(|e| StoreError::Io(format!("{id}: {e}")))
    }

    /// By id, by name (any case), or by a unique id prefix.
    pub fn find(&self, query: &str) -> Result<Automation, StoreError> {
        let all = self.list()?;
        if let Some(a) = all.iter().find(|a| a.id == query) {
            return Ok(a.clone());
        }
        if let Some(a) = all.iter().find(|a| a.name.eq_ignore_ascii_case(query.trim())) {
            return Ok(a.clone());
        }
        let prefixed: Vec<&Automation> =
            all.iter().filter(|a| query.len() >= 6 && a.id.starts_with(query)).collect();
        match prefixed.as_slice() {
            [one] => Ok((*one).clone()),
            [] => Err(StoreError::NotFound(query.into())),
            _ => Err(StoreError::Ambiguous(query.into())),
        }
    }

    /// The schedule cursor.
    pub fn state(&self, id: &str) -> Result<AutomationState, StoreError> {
        match fs::read(self.dir(id).join("state.json")) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(|e| StoreError::Io(e.to_string())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(AutomationState::default()),
            Err(e) => Err(e.into()),
        }
    }

    /// Move the schedule cursor.
    pub fn set_handled_through(&self, id: &str, t: i64) -> Result<(), StoreError> {
        create_private_dir(&self.dir(id))?;
        let json = serde_json::to_vec(&AutomationState { handled_through: t })
            .map_err(|e| StoreError::Io(e.to_string()))?;
        write_atomic(&self.dir(id).join("state.json"), &json)?;
        Ok(())
    }

    fn runs_file(&self, id: &str) -> std::io::Result<File> {
        private_file(OpenOptions::new().create(true).read(true).append(true))
            .open(self.dir(id).join("runs.jsonl"))
    }

    fn parse_runs(text: &str) -> Vec<Run> {
        let mut out: Vec<Run> = Vec::new();
        for line in text.lines() {
            let Ok(run) = serde_json::from_str::<Run>(line) else { continue };
            match out.iter_mut().find(|r| r.id == run.id) {
                Some(slot) => *slot = run,
                None => out.push(run),
            }
        }
        out
    }

    /// The run history of one automation, in the order runs were made.
    pub fn runs(&self, id: &str) -> Result<Vec<Run>, StoreError> {
        let file = match File::open(self.dir(id).join("runs.jsonl")) {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e.into()),
        };
        let mut lock = Flock::shared(file)?;
        let mut text = String::new();
        lock.0.read_to_string(&mut text)?;
        Ok(Self::parse_runs(&text))
    }

    /// One run by id.
    pub fn run(&self, automation: &str, run: &str) -> Result<Option<Run>, StoreError> {
        Ok(self.runs(automation)?.into_iter().find(|r| r.id == run))
    }

    fn append_locked(lock: &mut Flock, run: &Run) -> Result<(), StoreError> {
        let file = &mut lock.0;
        let len = file.seek(SeekFrom::End(0))?;
        let mut line = Vec::new();
        if len > 0 {
            let mut last = [0u8; 1];
            file.seek(SeekFrom::Start(len - 1))?;
            file.read_exact(&mut last)?;
            if last[0] != b'\n' {
                line.push(b'\n');
            }
        }
        serde_json::to_writer(&mut line, run).map_err(|e| StoreError::Io(e.to_string()))?;
        line.push(b'\n');
        file.write_all(&line)?;
        file.sync_data()?;
        Ok(())
    }

    /// Record a new run unless its id is already there. `true` when written.
    pub fn insert_run(&self, run: &Run) -> Result<bool, StoreError> {
        let mut lock = Flock::exclusive(self.runs_file(&run.automation)?)?;
        let mut text = String::new();
        lock.0.seek(SeekFrom::Start(0))?;
        lock.0.read_to_string(&mut text)?;
        if Self::parse_runs(&text).iter().any(|r| r.id == run.id) {
            return Ok(false);
        }
        Self::append_locked(&mut lock, run)?;
        Ok(true)
    }

    /// Record a run's new state.
    pub fn put_run(&self, run: &Run) -> Result<(), StoreError> {
        let mut lock = Flock::exclusive(self.runs_file(&run.automation)?)?;
        Self::append_locked(&mut lock, run)
    }
}
