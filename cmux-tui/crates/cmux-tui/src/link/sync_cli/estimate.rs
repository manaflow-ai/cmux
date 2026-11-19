//! What a Cloud start's folder copy will send and about how long it takes, known before any
//! machine is made, so the start decides "whole copy, first pass or seed" while nothing that
//! costs money exists yet, and says so ("copying 1.2 GB, about 20 s", or "starting now, 96 GB
//! stays on this Mac").
//!
//! On 2026-11-10 Leo started a Cloud chat at `~/Projects` and a 20 GB copy began after a machine
//! was already leased. A folder past the copy's limits never stops a start (Leo, 2026-11-15: "why
//! are you guys still blocking on these?"; [`super::size_cap`]); this adds the two things those
//! limits lacked:
//!
//! - **Order.** [`of_folder`] lists the folder by the copy's own rules ([`super::local::listed`])
//!   and decides before the lease, on every start surface: New Cloud chat and `cloud start-session
//!   --from-folder` (the app's `link start-chat preflight`), `cmux cloud start-chat --from-folder`
//!   (before its `cloud new-machine` or `cloud start-session`), and Move to Cloud (the app asks the
//!   same preflight before it picks or makes the machine). The listing stops at the copy's file
//!   limit or after [`LIST_BOUND`], whichever comes first; a listing cut short by time is a first
//!   pass (a folder that takes seconds just to list takes minutes to send). The decision is kept
//!   ([`recorded`]) so a second surface of the same start reads it instead of listing again, and
//!   the copy that follows sends what was said.
//! - **Time, not only size.** The limits are bytes and files; 19 GB on a slow uplink still went
//!   whole for many minutes with the person waiting. A fresh copy whose bytes take longer than
//!   [`BUDGET`] at this Mac's measured rate ([`rate`]: the median of its last copies, recorded by
//!   [`record_rate`]; [`DEFAULT_RATE`] before any) starts from a first pass instead, sized to the
//!   same budget ([`within_budget`]), and the chat starts at once. `--allow-large` keeps meaning
//!   "send it whole". A re-push (this Mac kept a base for the machine folder) is never cut to a
//!   first pass by time: it would delete what the whole copy left there.
//!
//! Why one minute: a Cloud start already spends tens of seconds on the machine itself; a copy
//! that adds up to a minute more keeps a start feeling like a start, and a person who chose a
//! huge folder gets the chat now and the rest on request (`cmux link access request PATH`).
//! What the content-addressed store already holds is not subtracted: knowing it takes every
//! file's hash, which is itself seconds per GB before the lease (a stat cache will make that
//! cheap; the estimate then counts only what is missing).

use std::io::Write as _;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest as _, Sha256};

use super::local::{self, LocalSet, Rules};
use super::size_cap;

/// The longest a start's copy may take before its chat starts: past it, a first pass.
pub(crate) const BUDGET: Duration = Duration::from_secs(60);
/// The link's rate before this Mac measured one: 1 MiB/s (about 8 Mbit/s), a slow home or
/// hotel uplink's, so a first guess never leaves a person waiting minutes. The first copy
/// records the real rate ([`record_rate`], `copy-rates.json`), which every later start uses: a
/// fast link is slow at most once.
///
/// It was 8 MiB/s. On 2026-11-17 a 64 GB folder from a Mac with no measured rate got a 256 MiB
/// first pass (8 MiB/s for a minute is more) on a 1.73 MB/s uplink: the "one minute" pass took
/// 155 s, and the chat waited for all of it.
pub(crate) const DEFAULT_RATE: u64 = 1024 * 1024;
/// The longest the estimate lists before any machine; past it the start goes from a first pass.
pub(crate) const LIST_BOUND: Duration = Duration::from_secs(5);
/// The smallest first pass by time: what a link that is slow for a moment still sends (a
/// project's sources, most often).
const FIRST_FLOOR: u64 = 8 * 1024 * 1024;
/// A copy shorter than this says more about the link's round trip than its rate: not recorded.
const SAMPLE_MIN_BYTES: u64 = 8 * 1024 * 1024;
/// How many copies' rates are kept.
const SAMPLES: usize = 8;
/// How long another surface of the same start reads a decision instead of listing again.
const REUSE: Duration = Duration::from_secs(120);
/// How long the copy after a start sends what that start said (a new machine boots first).
const HOLDS: Duration = Duration::from_secs(15 * 60);
/// A link rate in bytes a second that replaces the measured one (a bench, a slow-link test).
pub(crate) const RATE_ENV: &str = "CMUX_SYNC_COPY_RATE";

/// What a start's copy sends before its chat starts.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Mode {
    /// The folder, all of it.
    Whole,
    /// A first pass of it ([`local::first_pass`]); the rest stays on this Mac.
    FirstPass,
    /// The machine clones the folder's GitHub remote and this Mac sends one bundle of what it
    /// lacks; `copy_mode` is the copy if the machine refuses the seed.
    Seed,
}

/// Why a copy is a first pass.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Why {
    /// More bytes than a copy sends whole ([`size_cap::MAX_BYTES`]).
    Size,
    /// More files than a copy sends whole ([`size_cap::MAX_FILES`]).
    Files,
    /// Longer than [`BUDGET`] at the link's rate.
    Time,
    /// The listing itself took longer than [`LIST_BOUND`].
    ListingBound,
}

/// The estimate: `{"mode","files","bytes","seconds",...}` in a start's answers.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Estimate {
    pub mode: Mode,
    /// What goes before the chat starts (for a seed: the copy it falls back to).
    pub files: u64,
    pub bytes: u64,
    /// About how long that takes at [`Estimate::rate`]; none for a seed (its bundle is what the
    /// remote lacks, known only once it is made).
    pub seconds: Option<u64>,
    /// What the folder holds that a copy sends; at least this when the listing stopped
    /// (`complete` false).
    pub folder_files: u64,
    pub folder_bytes: u64,
    pub complete: bool,
    /// What stays on this Mac until the chat asks for it (at least, when not `complete`).
    pub left_files: u64,
    pub left_bytes: u64,
    pub why: Option<Why>,
    /// A seed's fallback: the copy that goes if the machine refuses the seed.
    pub copy_mode: Option<Mode>,
    /// The link's rate in bytes a second, and whether it was measured (or the default).
    pub rate: u64,
    pub measured: bool,
    pub budget_seconds: u64,
    /// How long the listing took.
    pub listing_ms: u64,
}

impl Estimate {
    /// What a copy sends: `copy_mode` for a seed, else `mode`.
    pub(crate) fn copy(&self) -> Mode {
        if self.mode == Mode::Seed { self.copy_mode.unwrap_or(Mode::Whole) } else { self.mode }
    }

    pub(crate) fn json(&self) -> Value {
        serde_json::to_value(self).unwrap_or(Value::Null)
    }

    /// One line for a person (the CLI's human output; the app words its own).
    pub(crate) fn words(&self) -> String {
        let size = super::bytes_text(self.bytes);
        let about = |seconds: u64| {
            if seconds < 90 {
                format!("about {seconds} s")
            } else {
                format!("about {} min", seconds.div_ceil(60))
            }
        };
        let left = || {
            let at_least = if self.complete { "" } else { "at least " };
            format!(
                "{at_least}{} stays on this Mac until the chat asks for it",
                super::bytes_text(self.left_bytes)
            )
        };
        match self.mode {
            Mode::Seed => "The machine clones the folder's GitHub repository; this Mac sends only what it lacks".to_owned(),
            Mode::Whole => format!("Copying {size} ({}), {}", super::files_text(self.files), about(self.seconds.unwrap_or(0))),
            Mode::FirstPass => format!("Starting now with {size} ({}); {}", super::files_text(self.files), left()),
        }
    }
}

/// The estimate of a start from `folder`, before any machine: listed by the copy's rules for at
/// most [`LIST_BOUND`], decided, and kept for the copy ([`recorded`]). A start of the same folder
/// that decided within [`REUSE`] is read back instead of listed again.
pub(crate) fn of_folder(folder: &Path) -> anyhow::Result<Estimate> {
    use anyhow::Context as _;
    let folder = std::fs::canonicalize(folder)
        .with_context(|| format!("cannot open {}", folder.display()))?;
    // An `--allow-large` given since changes the answer: decided again.
    let allowed = size_cap::allowed(&folder);
    if !allowed && let Some(kept) = recorded(&folder, REUSE) {
        return Ok(kept);
    }
    let started = Instant::now();
    let (mut set, stopped) =
        local::listed(&folder, Rules::Copy, Some(size_cap::Cap::until(started + LIST_BOUND)))?;
    let listing_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
    let mut estimate = decide(&mut set, stopped, allowed);
    estimate.listing_ms = listing_ms;
    if crate::link::seed::plan::seedable(&folder).is_ok() {
        estimate.copy_mode = Some(estimate.mode);
        estimate.mode = Mode::Seed;
        estimate.seconds = None;
    }
    keep(&folder, &estimate);
    Ok(estimate)
}

/// [`of_folder`]'s answer as a start's JSON, `null` when the folder could not be read: an
/// estimate never stops a start (the copy then decides as it lists).
pub(crate) fn answer(folder: &Path) -> Value {
    of_folder(folder).map_or(Value::Null, |estimate| estimate.json())
}

/// The decision for a listing `set` (counted against its cap; `stopped` at its file limit or
/// time bound), applying the first pass to `set` when it is one. `allowed`: `--allow-large`.
fn decide(set: &mut LocalSet, stopped: bool, allowed: bool) -> Estimate {
    let (rate, measured) = rate();
    let cap = set.cap.clone().unwrap_or_else(size_cap::Cap::new);
    let (folder_files, folder_bytes) = cap.listed();
    let why = if allowed {
        None
    } else if stopped && cap.timed_out() {
        Some(Why::ListingBound)
    } else if stopped || (cap.past() && !cap.past_bytes()) {
        Some(Why::Files)
    } else if cap.past() {
        Some(Why::Size)
    } else if seconds_for(folder_bytes, rate) > BUDGET.as_secs() {
        Some(Why::Time)
    } else {
        None
    };
    let (mode, files, bytes) = if why.is_some() {
        local::first_pass(set, stopped);
        let bytes =
            set.files.keys().map(|relative| cap.size_of(relative)).fold(0, u64::saturating_add);
        (Mode::FirstPass, set.files.len() as u64, bytes)
    } else {
        (Mode::Whole, folder_files, folder_bytes)
    };
    Estimate {
        mode,
        files,
        bytes,
        seconds: Some(seconds_for(bytes, rate)),
        folder_files,
        folder_bytes,
        complete: !stopped,
        left_files: folder_files.saturating_sub(files),
        left_bytes: folder_bytes.saturating_sub(bytes),
        why,
        copy_mode: None,
        rate,
        measured,
        budget_seconds: BUDGET.as_secs(),
        listing_ms: 0,
    }
}

/// A fresh copy's time rule (`push_inner`, after its listing `set` of `folder`): the copy a start
/// decided within [`HOLDS`] goes as decided; with none, one whose bytes take longer than
/// [`BUDGET`] goes as a first pass. Answers the estimate the copy goes by, or none when it is no
/// longer counted (`--allow-large`, or already a first pass by size).
pub(super) fn for_copy(folder: &Path, set: &mut LocalSet) -> Option<Estimate> {
    // A listing past the limits was made a first pass as it was collected, and `--allow-large`
    // counts nothing: either way there is no cap left to decide by.
    set.cap.as_ref()?;
    if let Some(kept) = recorded(folder, HOLDS) {
        if kept.copy() == Mode::FirstPass {
            local::first_pass(set, false);
        }
        return Some(kept);
    }
    // Under the limits (`collect` made it no first pass), so only time can make it one here.
    Some(decide(set, false, false))
}

/// Seconds `bytes` take at `rate` bytes a second, rounded up.
fn seconds_for(bytes: u64, rate: u64) -> u64 {
    bytes.div_ceil(rate.max(1))
}

/// What goes within [`BUDGET`] at the link's rate, at most `most` and at least [`FIRST_FLOOR`]
/// (the first pass's bytes on a slow link, [`size_cap::first_limits`]).
pub(crate) fn within_budget(most: u64) -> u64 {
    let (rate, _) = rate();
    most.min(rate.saturating_mul(BUDGET.as_secs()).max(FIRST_FLOOR))
}

/// One copy's rate, as kept.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Sample {
    bytes: u64,
    ms: u64,
}

impl Sample {
    fn rate(self) -> u64 {
        self.bytes.saturating_mul(1000) / self.ms.max(1)
    }
}

/// The link's rate in bytes a second and whether it was measured: [`RATE_ENV`], else the median
/// of this Mac's last copies, else [`DEFAULT_RATE`].
pub(crate) fn rate() -> (u64, bool) {
    #[cfg(test)]
    if let Some(rate) = TEST_RATE.with(std::cell::Cell::get) {
        return (rate, true);
    }
    if let Some(rate) = std::env::var(RATE_ENV)
        .ok()
        .and_then(|text| text.trim().parse::<u64>().ok())
        .filter(|rate| *rate > 0)
    {
        return (rate, true);
    }
    let mut rates: Vec<u64> =
        samples().into_iter().map(Sample::rate).filter(|rate| *rate > 0).collect();
    rates.sort_unstable();
    match rates.get(rates.len() / 2) {
        Some(median) => (*median, true),
        None => (DEFAULT_RATE, false),
    }
}

/// Records a copy that sent `bytes` in `took` (its send, after the listing): the next starts'
/// [`rate`]. A copy too small to say anything is not recorded; a failure to record changes
/// nothing.
pub(super) fn record_rate(bytes: u64, took: Duration) {
    let ms = u64::try_from(took.as_millis()).unwrap_or(u64::MAX);
    if bytes < SAMPLE_MIN_BYTES || ms == 0 {
        return;
    }
    let mut kept = samples();
    kept.push(Sample { bytes, ms });
    let skip = kept.len().saturating_sub(SAMPLES);
    let kept: Vec<Sample> = kept.into_iter().skip(skip).collect();
    if let (Some(path), Ok(bytes)) = (rate_path(), serde_json::to_vec(&kept)) {
        let _ = write_private(&path, &bytes);
    }
}

fn samples() -> Vec<Sample> {
    rate_path()
        .and_then(|path| std::fs::read(path).ok())
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

/// A decision kept for a folder: which folder (a hash that matched another never counts) and when.
#[derive(Serialize, Deserialize)]
struct Kept {
    folder: String,
    at_ms: u64,
    estimate: Estimate,
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| u64::try_from(since.as_millis()).unwrap_or(u64::MAX))
}

/// Keeps `estimate` for `folder` (canonical).
fn keep(folder: &Path, estimate: &Estimate) {
    let kept = Kept {
        folder: folder.to_string_lossy().into_owned(),
        at_ms: now_ms(),
        estimate: estimate.clone(),
    };
    if let (Some(path), Ok(bytes)) = (decision_path(folder), serde_json::to_vec(&kept)) {
        let _ = write_private(&path, &bytes);
    }
}

/// The decision a start made for `folder` (canonical) within `within`, if any.
pub(crate) fn recorded(folder: &Path, within: Duration) -> Option<Estimate> {
    let bytes = std::fs::read(decision_path(folder)?).ok()?;
    let kept: Kept = serde_json::from_slice(&bytes).ok()?;
    let age = now_ms().checked_sub(kept.at_ms)?;
    let fresh = u128::from(age) < within.as_millis();
    (fresh && kept.folder == folder.to_string_lossy()).then_some(kept.estimate)
}

/// `<state>/link-sync`, where the rates and decisions are kept (none in a test that set none).
fn state() -> Option<PathBuf> {
    #[cfg(test)]
    let state = TEST_STATE.with(|state| state.borrow().clone());
    #[cfg(not(test))]
    let state = cmux_tui_core::platform::workspace_state_dir();
    state.map(|state| state.join("link-sync"))
}

fn rate_path() -> Option<PathBuf> {
    state().map(|state| state.join("copy-rates.json"))
}

fn decision_path(folder: &Path) -> Option<PathBuf> {
    let digest = Sha256::digest(folder.as_os_str().as_encoded_bytes());
    let name: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
    state().map(|state| state.join("estimates").join(format!("{name}.json")))
}

/// Writes `bytes` to `path` (0600, its folder 0700) through a temporary name.
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let dir = path.parent().ok_or(std::io::ErrorKind::NotFound)?;
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    let part = path.with_extension(format!("{}.part", std::process::id()));
    let _ = std::fs::remove_file(&part);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&part)?;
    file.write_all(bytes)?;
    std::fs::rename(&part, path)
}

#[cfg(test)]
thread_local! {
    /// A test's own link rate.
    pub(super) static TEST_RATE: std::cell::Cell<Option<u64>> = const { std::cell::Cell::new(None) };
    /// A test's own state folder (none: nothing is read or kept).
    pub(super) static TEST_STATE: std::cell::RefCell<Option<PathBuf>> = const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
#[path = "estimate_tests.rs"]
mod tests;
