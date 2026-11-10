//! Opt-in usage patterns: how a person uses cmux, in counters, never content.
//!
//! Off by default. Nothing is counted until the person turns on
//! `diagnostics.usagePatterns` (Settings > Privacy and Security > Usage
//! Patterns, `cmux settings set diagnostics.usagePatterns true`, or the
//! palette). Nothing here leaves the machine: each process that counts (a
//! session's daemon, acpmux) keeps one small JSON file under
//! [`default_dir`], and `cmux usage` and the Stats page read them back.
//!
//! What a count may name: a code-defined family (`command`, `surface`,
//! `layout`, `connection`, ...) and a key that is an identifier the program
//! defines (a wire command name, an operation id, a transport, a harness
//! kind). [`clean_key`] refuses anything else, so no prompt, terminal text,
//! URL, file path or title can become a key. Free text never reaches this
//! crate's callers' keys.
//!
//! Cost stays constant as use grows: a count is one atomic load when off, and
//! one mutex and two map increments when on. Each family keeps at most
//! [`MAX_KEYS_PER_FAMILY`] keys (the rest count as [`OTHER`]), the per-day
//! rollup keeps the newest [`KEEP_DAYS`] days, and the hour histogram has 24
//! slots, so a file never grows past a fixed size. One thread per process
//! rereads the setting every [`GATE_EVERY`] and writes the file at most every
//! [`FLUSH_EVERY`] when something changed; it lives as long as the process.
//!
//! Reset: `cmux usage reset` deletes the files. A recorder that wrote its file
//! and finds it gone drops what it holds instead of writing it back.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// The setting that turns counting on (a toggle, default off).
pub const SETTING_KEY: &str = "diagnostics.usagePatterns";
/// `CMUX_USAGE_PATTERNS=on|off` overrides the setting (tests, a person who
/// wants it off everywhere regardless of the file).
pub const ENV_OVERRIDE: &str = "CMUX_USAGE_PATTERNS";
/// `CMUX_USAGE_PATTERNS_DIR` moves the files (tests).
pub const ENV_DIR: &str = "CMUX_USAGE_PATTERNS_DIR";
/// Days the per-day rollup keeps.
pub const KEEP_DAYS: usize = 90;
/// Distinct keys one family keeps; later new keys count as [`OTHER`].
pub const MAX_KEYS_PER_FAMILY: usize = 200;
/// Longest key kept; a longer one counts as [`OTHER`].
pub const MAX_KEY_BYTES: usize = 64;
/// Files one read merges (one per counting process).
pub const MAX_WRITERS: usize = 64;
/// The key a refused or overflowing key counts under.
pub const OTHER: &str = "other";
/// How often the background thread rereads the setting.
pub const GATE_EVERY: Duration = Duration::from_secs(5);
/// How often a changed rollup is written.
pub const FLUSH_EVERY: Duration = Duration::from_secs(30);
const VERSION: u32 = 1;
const FILE_SUFFIX: &str = ".json";

/// One process's counters, as stored and as merged for a readout.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Rollup {
    #[serde(default)]
    pub version: u32,
    /// Unix ms of the first count kept (0: none yet).
    #[serde(default)]
    pub since: u64,
    /// Unix ms of the newest count.
    #[serde(default)]
    pub updated: u64,
    /// family -> key -> count, since `since`.
    #[serde(default)]
    pub counts: BTreeMap<String, BTreeMap<String, u64>>,
    /// UTC day (`YYYY-MM-DD`) -> family -> count, the newest [`KEEP_DAYS`].
    #[serde(default)]
    pub days: BTreeMap<String, BTreeMap<String, u64>>,
    /// Every count by its UTC hour of day (24 slots).
    #[serde(default)]
    pub hours: Vec<u64>,
    /// name -> the highest value seen (connections open at once).
    #[serde(default)]
    pub peaks: BTreeMap<String, u64>,
}

impl Rollup {
    /// Adds `n` to `family`/`key` at `now_ms`. `key` must already be clean.
    pub fn add(&mut self, family: &str, key: &str, n: u64, now_ms: u64) {
        if n == 0 {
            return;
        }
        self.version = VERSION;
        if self.since == 0 {
            self.since = now_ms;
        }
        self.updated = self.updated.max(now_ms);
        let keys = self.counts.entry(family.to_string()).or_default();
        let key =
            if keys.contains_key(key) || keys.len() < MAX_KEYS_PER_FAMILY { key } else { OTHER };
        bump(keys.entry(key.to_string()).or_default(), n);
        let day = utc_day(now_ms);
        bump(self.days.entry(day).or_default().entry(family.to_string()).or_default(), n);
        self.trim_days();
        if self.hours.len() != 24 {
            self.hours.resize(24, 0);
        }
        if let Some(slot) = self.hours.get_mut(utc_hour(now_ms)) {
            bump(slot, n);
        }
    }

    /// Raises `name`'s peak to `value`.
    pub fn peak(&mut self, name: &str, value: u64, now_ms: u64) {
        let slot = self.peaks.entry(name.to_string()).or_default();
        if value > *slot {
            *slot = value;
            self.version = VERSION;
            if self.since == 0 {
                self.since = now_ms;
            }
            self.updated = self.updated.max(now_ms);
        }
    }

    /// Folds `other` in: counts add, peaks take the higher, the range widens.
    pub fn merge(&mut self, other: &Rollup) {
        self.version = VERSION;
        if other.since != 0 && (self.since == 0 || other.since < self.since) {
            self.since = other.since;
        }
        self.updated = self.updated.max(other.updated);
        for (family, keys) in &other.counts {
            let mine = self.counts.entry(family.clone()).or_default();
            for (key, n) in keys {
                let key = if mine.contains_key(key) || mine.len() < MAX_KEYS_PER_FAMILY {
                    key.as_str()
                } else {
                    OTHER
                };
                bump(mine.entry(key.to_string()).or_default(), *n);
            }
        }
        for (day, families) in &other.days {
            let mine = self.days.entry(day.clone()).or_default();
            for (family, n) in families {
                bump(mine.entry(family.clone()).or_default(), *n);
            }
        }
        self.trim_days();
        if self.hours.len() != 24 {
            self.hours.resize(24, 0);
        }
        for (slot, n) in self.hours.iter_mut().zip(other.hours.iter()) {
            bump(slot, *n);
        }
        for (name, value) in &other.peaks {
            let slot = self.peaks.entry(name.clone()).or_default();
            *slot = (*slot).max(*value);
        }
    }

    /// Whether nothing was counted.
    pub fn is_empty(&self) -> bool {
        self.counts.is_empty() && self.peaks.is_empty()
    }

    fn trim_days(&mut self) {
        while self.days.len() > KEEP_DAYS {
            let oldest = self.days.keys().next().cloned();
            match oldest {
                Some(day) => self.days.remove(&day),
                None => break,
            };
        }
    }
}

/// `key` when it is an identifier this crate keeps (ASCII letters, digits and
/// `.`, `_`, `-`, `:`, `/`, at most [`MAX_KEY_BYTES`]), else [`OTHER`]. A
/// space, a quote, `@`, `?`, `=`, `~` or `\` never passes, so a sentence, an
/// address with a query, an email or a home path is never a key; a key holds
/// at most one `/`, never first, and no `..`, `//` or `:/` (so no URL or path).
pub fn clean_key(key: &str) -> &str {
    let ok = !key.is_empty()
        && key.len() <= MAX_KEY_BYTES
        && key
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-' | b':' | b'/'))
        && !key.starts_with('/')
        && !key.contains("..")
        && !key.contains("//")
        && !key.contains(":/")
        && key.bytes().filter(|b| *b == b'/').count() <= 1;
    if ok { key } else { OTHER }
}

/// A short opaque stand-in for an identifier that must be counted as distinct
/// but not kept (a paired machine's id): 12 hex digits of a fixed-key hash. The
/// number of distinct stand-ins is the number of distinct ids, up to
/// [`MAX_KEYS_PER_FAMILY`].
pub fn opaque_id(id: &str) -> String {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    "cmux-usage-patterns".hash(&mut hasher);
    id.hash(&mut hasher);
    format!("{:012x}", hasher.finish() & 0xffff_ffff_ffff)
}

/// What a readout shows: the merged rollup, each writer's own range, and
/// whether counting is on now.
#[derive(Debug, Clone, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Readout {
    pub enabled: bool,
    pub dir: String,
    pub writers: Vec<WriterSummary>,
    pub rollup: Rollup,
}

#[derive(Debug, Clone, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct WriterSummary {
    pub name: String,
    pub since: u64,
    pub updated: u64,
}

/// Every writer's file in `dir`, merged (the [`MAX_WRITERS`] most recently
/// written; an unreadable one is skipped).
pub fn read_dir(dir: &Path) -> Readout {
    let mut readout = Readout { dir: dir.display().to_string(), ..Readout::default() };
    let Ok(entries) = std::fs::read_dir(dir) else {
        return readout;
    };
    // The newest MAX_WRITERS files: a machine with many short-lived sessions (tagged builds)
    // keeps one file each, and the readout stays bounded by reading the most recent.
    let mut files: Vec<(SystemTime, PathBuf)> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
        .map(|path| {
            let modified =
                std::fs::metadata(&path).and_then(|m| m.modified()).unwrap_or(UNIX_EPOCH);
            (modified, path)
        })
        .collect();
    files.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
    files.truncate(MAX_WRITERS);
    for (_, path) in files {
        let Some(rollup) = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Rollup>(&bytes).ok())
        else {
            continue;
        };
        let name =
            path.file_stem().map(|stem| stem.to_string_lossy().into_owned()).unwrap_or_default();
        readout.writers.push(WriterSummary { name, since: rollup.since, updated: rollup.updated });
        readout.rollup.merge(&rollup);
    }
    readout
}

/// The default readout: [`default_dir`] merged, with the setting's state.
pub fn read() -> Readout {
    let Some(dir) = default_dir() else {
        return Readout {
            enabled: setting_enabled(&cmux_config::config_path()),
            ..Readout::default()
        };
    };
    let mut readout = read_dir(&dir);
    readout.enabled = setting_enabled(&cmux_config::config_path());
    readout
}

/// Deletes every writer's file in `dir` (the running recorders drop what they
/// hold at their next flush). Returns how many files went.
pub fn reset_dir(dir: &Path) -> std::io::Result<usize> {
    let mut removed: usize = 0;
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(0),
        Err(error) => return Err(error),
    };
    for entry in entries.filter_map(Result::ok) {
        let path = entry.path();
        if path.extension().is_some_and(|ext| ext == "json") {
            std::fs::remove_file(&path)?;
            removed = removed.saturating_add(1);
        }
    }
    Ok(removed)
}

/// Where the files live: `$CMUX_USAGE_PATTERNS_DIR`, else `usage-patterns`
/// beside the daemons' `sessions` state directory
/// (`~/Library/Application Support/cmux-tui/usage-patterns` on a Mac,
/// `~/.local/state/cmux-tui/usage-patterns` on Linux).
pub fn default_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os(ENV_DIR).filter(|dir| !dir.is_empty()) {
        return Some(PathBuf::from(dir));
    }
    let sessions = cmux_tui_platform::platform::workspace_state_dir()?;
    Some(
        sessions
            .parent()
            .map_or_else(|| sessions.join("usage-patterns"), |root| root.join("usage-patterns")),
    )
}

/// Whether counting is on: `CMUX_USAGE_PATTERNS` when set, else
/// `diagnostics.usagePatterns` in the settings file at `config` (nested or as
/// one dotted key) is `true`. A missing or unreadable file is off.
pub fn setting_enabled(config: &Path) -> bool {
    if let Some(forced) = env_override() {
        return forced;
    }
    let Some(root) =
        std::fs::read_to_string(config).ok().and_then(|text| cmux_config::jsonc::parse(&text).ok())
    else {
        return false;
    };
    let nested = cmux_config::value::value_at(&root, &["diagnostics", "usagePatterns"]);
    let flat = root.get(SETTING_KEY);
    nested.or(flat).and_then(serde_json::Value::as_bool) == Some(true)
}

fn env_override() -> Option<bool> {
    let value = std::env::var(ENV_OVERRIDE).ok()?;
    match value.trim().to_ascii_lowercase().as_str() {
        "1" | "on" | "true" | "yes" => Some(true),
        "0" | "off" | "false" | "no" => Some(false),
        _ => None,
    }
}

/// One process's counter: the rollup in memory, its file, and the gate.
pub struct Recorder {
    path: PathBuf,
    config: PathBuf,
    enabled: AtomicBool,
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    rollup: Rollup,
    dirty: bool,
    /// The file was written (or loaded) by this recorder: its absence means a reset.
    written: bool,
    config_stamp: Option<(Option<SystemTime>, u64)>,
    last_flush: Option<Instant>,
}

impl Recorder {
    /// A recorder writing `dir/<writer>.json`, gated by the settings file at
    /// `config`. It loads the file's earlier counts. No thread is started:
    /// call [`Recorder::tick`] (or use [`install`]).
    pub fn open(dir: &Path, writer: &str, config: PathBuf) -> Self {
        let writer = clean_key(writer).replace(['/', ':'], "-");
        let path = dir.join(format!("{writer}{FILE_SUFFIX}"));
        let loaded = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Rollup>(&bytes).ok());
        let recorder = Self {
            path,
            config,
            enabled: AtomicBool::new(false),
            state: Mutex::new(State {
                written: loaded.is_some(),
                rollup: loaded.unwrap_or_default(),
                ..State::default()
            }),
        };
        recorder.refresh_gate();
        recorder
    }

    /// The file this recorder writes.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Whether counting is on (one atomic load).
    pub fn enabled(&self) -> bool {
        self.enabled.load(Ordering::Relaxed)
    }

    /// Counts one `family`/`key` (the key is cleaned first).
    pub fn count(&self, family: &str, key: &str) {
        self.count_n(family, key, 1);
    }

    /// Counts `n` of `family`/`key`.
    pub fn count_n(&self, family: &str, key: &str, n: u64) {
        if !self.enabled() {
            return;
        }
        let key = clean_key(key);
        let now = now_ms();
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        state.rollup.add(family, key, n, now);
        state.dirty = true;
    }

    /// Raises the peak `name` to `value`.
    pub fn peak(&self, name: &str, value: u64) {
        if !self.enabled() {
            return;
        }
        let now = now_ms();
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let before = state.rollup.peaks.get(name).copied().unwrap_or(0);
        state.rollup.peak(clean_key(name), value, now);
        if value > before {
            state.dirty = true;
        }
    }

    /// A copy of what this recorder holds now.
    pub fn snapshot(&self) -> Rollup {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner).rollup.clone()
    }

    /// Rereads the setting when its file changed (size or modification
    /// time). Returns whether counting is on.
    pub fn refresh_gate(&self) -> bool {
        let stamp =
            std::fs::metadata(&self.config).ok().map(|meta| (meta.modified().ok(), meta.len()));
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let forced = env_override();
        if forced.is_none() && state.config_stamp.is_some() && state.config_stamp == stamp {
            return self.enabled();
        }
        state.config_stamp = stamp;
        drop(state);
        let on = forced.unwrap_or_else(|| setting_enabled(&self.config));
        self.enabled.store(on, Ordering::Relaxed);
        on
    }

    /// Writes the rollup when it changed. A file this recorder wrote that is
    /// gone now was reset: the rollup is dropped, not written back.
    pub fn flush(&self) -> std::io::Result<()> {
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        state.last_flush = Some(Instant::now());
        if state.written && !self.path.exists() {
            state.rollup = Rollup::default();
            state.dirty = false;
            state.written = false;
            return Ok(());
        }
        if !state.dirty {
            return Ok(());
        }
        let bytes = serde_json::to_vec(&state.rollup).map_err(std::io::Error::other)?;
        state.dirty = false;
        state.written = true;
        drop(state);
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = self.path.with_extension("json.tmp");
        std::fs::write(&tmp, bytes)?;
        std::fs::rename(&tmp, &self.path)
    }

    /// One pass of the background thread: the gate, then a flush when
    /// [`FLUSH_EVERY`] passed since the last one (or counting just stopped).
    pub fn tick(&self) {
        let was = self.enabled();
        let on = self.refresh_gate();
        let due = {
            let state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            state.last_flush.is_none_or(|last| last.elapsed() >= FLUSH_EVERY)
        };
        if due || (was && !on) {
            let _ = self.flush();
        }
    }
}

static GLOBAL: OnceLock<Arc<Recorder>> = OnceLock::new();

/// Installs this process's recorder as `writer` (once; later calls return
/// the first) in [`default_dir`], gated by the settings file, and starts its
/// thread. None when there is no state directory.
pub fn install(writer: &str) -> Option<Arc<Recorder>> {
    if let Some(recorder) = GLOBAL.get() {
        return Some(Arc::clone(recorder));
    }
    let dir = default_dir()?;
    let recorder = Arc::new(Recorder::open(&dir, writer, cmux_config::config_path()));
    if GLOBAL.set(Arc::clone(&recorder)).is_err() {
        return GLOBAL.get().cloned();
    }
    let worker = Arc::clone(&recorder);
    // Lives as long as the process: one stat every GATE_EVERY, a write at
    // most every FLUSH_EVERY and only after a count.
    let _ = std::thread::Builder::new().name("usage-patterns".into()).spawn(move || {
        loop {
            std::thread::sleep(GATE_EVERY);
            worker.tick();
        }
    });
    Some(recorder)
}

/// This process's recorder, when [`install`] ran.
pub fn global() -> Option<&'static Arc<Recorder>> {
    GLOBAL.get()
}

/// Counts one `family`/`key` on this process's recorder (nothing when none is
/// installed or counting is off).
pub fn count(family: &str, key: &str) {
    if let Some(recorder) = GLOBAL.get() {
        recorder.count(family, key);
    }
}

/// Raises the peak `name` on this process's recorder.
pub fn peak(name: &str, value: u64) {
    if let Some(recorder) = GLOBAL.get() {
        recorder.peak(name, value);
    }
}

/// Whether this process counts now (one atomic load; false without a recorder).
pub fn enabled() -> bool {
    GLOBAL.get().is_some_and(|recorder| recorder.enabled())
}

/// Writes this process's rollup now (a graceful shutdown).
pub fn flush() {
    if let Some(recorder) = GLOBAL.get() {
        let _ = recorder.flush();
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
}

fn utc_hour(ms: u64) -> usize {
    usize::try_from(ms.checked_div(3_600_000).unwrap_or(0).checked_rem(24).unwrap_or(0))
        .unwrap_or(0)
}

/// Adds `n` to a counter, saturating at `u64::MAX`.
fn bump(slot: &mut u64, n: u64) {
    *slot = slot.saturating_add(n);
}

/// `YYYY-MM-DD` of the UTC day holding `ms`.
pub fn utc_day(ms: u64) -> String {
    i64::try_from(ms)
        .ok()
        .and_then(chrono::DateTime::from_timestamp_millis)
        .map_or_else(|| "1970-01-01".to_string(), |at| at.format("%Y-%m-%d").to_string())
}

#[cfg(test)]
mod tests;
