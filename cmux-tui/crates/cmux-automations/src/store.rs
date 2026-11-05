//! The durable local store.
//!
//! ```text
//! <root>/
//!   .runner.lock              file lock: one runner per machine
//!   auto_…/automation.json    the definition (atomic replace)
//!   auto_…/state.json         the schedule cursor (atomic replace)
//!   auto_…/runs.jsonl         run history, append-only, locked while appending
//!   auto_…/logs/run_….log     each run's output
//!   auto_…/moved.json         a tombstone: it moved away (teleport) and never fires
//!   .imports/tp_….json        imported handoffs (import is idempotent by handoff id)
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

use crate::automation::{
    Automation, AutomationSpec, Handoff, LOCAL_HOME, Origin, Tombstone, new_automation_id,
    new_handoff_id,
};
use crate::run::Run;
use crate::sys::{create_private_dir, private_file, sync_dir};
use crate::teleport::{ImportHandoff, Imported};

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

/// How long `moved` lists a tombstone, in milliseconds (30 days).
pub const TOMBSTONE_MS: i64 = 30 * 86_400 * 1000;

/// The store at one root folder.
#[derive(Clone, Debug)]
pub struct Store {
    root: PathBuf,
    /// The `home` new automations get (`mac:<machine id>`).
    home: String,
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
        Ok(Store { root: root.to_path_buf(), home: LOCAL_HOME.to_string() })
    }

    /// The same store, naming this machine `home` (`mac:<machine id>`) on
    /// what it creates or imports.
    pub fn with_home(mut self, home: impl Into<String>) -> Store {
        self.home = home.into();
        self
    }

    /// The `home` this store gives its automations.
    pub fn home(&self) -> &str {
        &self.home
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
        self.create_as(new_automation_id()?, spec, now, 1, None, now)
    }

    fn create_as(
        &self,
        id: String,
        spec: AutomationSpec,
        now: i64,
        epoch: u64,
        last_slot: Option<i64>,
        handled_through: i64,
    ) -> Result<Automation, StoreError> {
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
            home: self.home.clone(),
            epoch,
            last_slot,
            handoff: None,
            origin: None,
        };
        self.set_handled_through(&a.id, handled_through)?;
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
        if let Some(h) = &old.handoff {
            return Err(moving(&old, h));
        }
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
            if !is_automation_id(name) || entry.path().join("moved.json").exists() {
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

    // ---------------------------------------------------------------- teleport

    /// Fence `id` for a move to `to`: it stops firing here until the move is
    /// released or aborted. A pending move to the same place answers the same
    /// handoff (a re-run resumes it); one to another place is refused.
    pub fn fence(&self, id: &str, to: &str, now_ms: i64) -> Result<Handoff, StoreError> {
        let mut a = self.get(id)?;
        if let Some(h) = &a.handoff {
            return if h.to == to { Ok(h.clone()) } else { Err(moving(&a, h)) };
        }
        let h =
            Handoff { id: new_handoff_id()?, to: to.to_string(), epoch: a.epoch + 1, at: now_ms };
        a.handoff = Some(h.clone());
        self.save(&a)?;
        Ok(h)
    }

    /// Abort a pending move: the automation fires here again.
    pub fn clear_fence(&self, id: &str) -> Result<Automation, StoreError> {
        let mut a = self.get(id)?;
        if a.handoff.take().is_some() {
            self.save(&a)?;
        }
        Ok(a)
    }

    /// Release a move the destination accepted: the automation becomes a
    /// tombstone naming `moved_id`. A second release answers the first one's.
    pub fn release(
        &self,
        id: &str,
        handoff: &str,
        moved_to: &str,
        moved_id: &str,
        now_ms: i64,
    ) -> Result<Tombstone, StoreError> {
        if let Some(t) = self.tombstone(id)? {
            return Ok(t);
        }
        let a = self.get(id)?;
        let Some(h) = a.handoff.as_ref().filter(|h| h.id == handoff) else {
            return Err(StoreError::Invalid(format!(
                "\"{}\" has no pending move {handoff}",
                a.name
            )));
        };
        let t = Tombstone {
            id: a.id.clone(),
            name: a.name.clone(),
            moved_to: moved_to.to_string(),
            moved_id: moved_id.to_string(),
            epoch: h.epoch,
            moved_at: now_ms,
        };
        let json = serde_json::to_vec_pretty(&t).map_err(|e| StoreError::Io(e.to_string()))?;
        write_atomic(&self.dir(id).join("moved.json"), &json)?;
        fs::rename(
            self.dir(id).join("automation.json"),
            self.dir(id).join("automation.moved.json"),
        )?;
        sync_dir(&self.dir(id))?;
        Ok(t)
    }

    fn tombstone(&self, id: &str) -> Result<Option<Tombstone>, StoreError> {
        if !is_automation_id(id) {
            return Ok(None);
        }
        match fs::read(self.dir(id).join("moved.json")) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map(Some)
                .map_err(|e| StoreError::Io(format!("{id}: {e}"))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    fn tombstones(&self) -> Result<Vec<Tombstone>, StoreError> {
        let mut out = Vec::new();
        for entry in fs::read_dir(&self.root)? {
            let name = entry?.file_name();
            if let Some(name) = name.to_str()
                && let Ok(Some(t)) = self.tombstone(name)
            {
                out.push(t);
            }
        }
        out.sort_by(|a, b| (a.moved_at, &a.id).cmp(&(b.moved_at, &b.id)));
        Ok(out)
    }

    /// The automations that moved away in the 30 days before `now_ms`.
    pub fn moved(&self, now_ms: i64) -> Result<Vec<Tombstone>, StoreError> {
        Ok(self.tombstones()?.into_iter().filter(|t| now_ms - t.moved_at <= TOMBSTONE_MS).collect())
    }

    /// A tombstone by id or name (any case), however old.
    pub fn find_moved(&self, query: &str) -> Result<Option<Tombstone>, StoreError> {
        let q = query.trim();
        Ok(self
            .tombstones()?
            .into_iter()
            .rev()
            .find(|t| t.id == q || t.name.eq_ignore_ascii_case(q)))
    }

    /// Move tombstones older than 30 days to `.deleted/`. Returns how many.
    pub fn prune_moved(&self, now_ms: i64) -> Result<usize, StoreError> {
        let mut n = 0;
        for t in self.tombstones()? {
            if now_ms - t.moved_at > TOMBSTONE_MS {
                let trash = self.root.join(".deleted");
                create_private_dir(&trash)?;
                fs::rename(self.dir(&t.id), trash.join(format!("{}-moved-{}", t.id, t.moved_at)))?;
                n += 1;
            }
        }
        Ok(n)
    }

    /// Accept an automation another store sends (teleport). The handoff id
    /// is the idempotency key: a retried import answers the first one's
    /// automation. The copy keeps the handoff's epoch and `last_slot`, and
    /// its schedule continues after `last_slot` (else from `now`), so the
    /// catch-up policy decides a slot that fell inside the move.
    pub fn import(
        &self,
        spec: AutomationSpec,
        handoff: &ImportHandoff,
        now: i64,
    ) -> Result<Imported, StoreError> {
        let key = &handoff.id;
        if key.is_empty()
            || key.len() > 64
            || !key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        {
            return Err(StoreError::Invalid("a handoff id is 1 to 64 of A-Z a-z 0-9 _ -".into()));
        }
        let ledger = self.root.join(".imports");
        create_private_dir(&ledger)?;
        let entry = ledger.join(format!("{key}.json"));
        let id = match fs::read(&entry) {
            Ok(bytes) => {
                let v: serde_json::Value =
                    serde_json::from_slice(&bytes).map_err(|e| StoreError::Io(e.to_string()))?;
                let id = v
                    .get("automation")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                if let Ok(a) = self.get(&id) {
                    return Ok(Imported { automation: a, replayed: true });
                }
                if let Some(t) = self.tombstone(&id)? {
                    return Err(StoreError::Invalid(format!(
                        "handoff {key} was imported as {id}, which moved on to {}",
                        t.moved_to
                    )));
                }
                id
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                self.check(&spec, None)?;
                let id = new_automation_id()?;
                let json = serde_json::to_vec(&serde_json::json!({"automation": id, "from": handoff.from, "source_id": handoff.source_id}))
                    .map_err(|e| StoreError::Io(e.to_string()))?;
                write_atomic(&entry, &json)?;
                id
            }
            Err(e) => return Err(e.into()),
        };
        self.check(&spec, Some(&id))?;
        let since = handoff.last_slot.map(|ms| ms.div_euclid(1000)).unwrap_or(now);
        let mut a = self.create_as(id, spec, now, handoff.epoch, handoff.last_slot, since)?;
        a.origin = Some(Origin {
            handoff: handoff.id.clone(),
            from: handoff.from.clone(),
            source_id: handoff.source_id.clone(),
        });
        self.save(&a)?;
        Ok(Imported { automation: a, replayed: false })
    }

    /// Record that the scheduled time `t` (seconds) got a run row.
    pub(crate) fn note_slot(&self, id: &str, t: i64) -> Result<(), StoreError> {
        let mut a = self.get(id)?;
        let ms = t.saturating_mul(1000);
        if a.last_slot.is_none_or(|old| old < ms) {
            a.last_slot = Some(ms);
            self.save(&a)?;
        }
        Ok(())
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

/// The refusal for changing an automation that is moving.
pub(crate) fn moving(a: &Automation, h: &Handoff) -> StoreError {
    StoreError::Invalid(format!(
        "\"{}\" is moving to {} (handoff {}); finish it with `cmux automation teleport {} --to {}`, or cancel it with `--abort`",
        a.name, h.to, h.id, a.id, h.to
    ))
}
