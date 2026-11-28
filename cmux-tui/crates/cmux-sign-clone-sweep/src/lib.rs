//! Removes the Chromium code-sign clones that cmux apps left behind.
//!
//! Chromium's code-sign clone (chrome/browser/mac/code_sign_clone_manager.mm)
//! copies the app bundle per launch to
//! `confstr(_CS_DARWIN_USER_TEMP_DIR)/../X/<bundle id>.code_sign_clone/code_sign_clone.XXXXXX/<App>.app.bundle`,
//! with the main executable as a hard link and every other file an APFS clone.
//! Only its destructor, near the end of `CefShutdown`, removes that copy; a quit
//! past the app's shutdown deadline, a skipped `CefShutdown`, a signal, a crash
//! or an update restart never gets there (Chromium's own TODO,
//! crbug.com/343784575). The clone itself stays on; this removes the leftovers.
//! The app runs one bounded pass at idle (cmux-app-ffi `cmux_sign_clone_sweep`);
//! `cmux sign-clones sweep [--dry-run]` runs a full pass on demand.
//!
//! Scope: only the clone roots of the cmux bundle-id family in that one `X`
//! folder, which must resolve under `/private/var/folders/`. The family is
//! `com.cmuxterm.app` and every plain `com.cmuxterm.app.*` id (release,
//! `.nightly`, `.debug` and `.debug.<tag>` dev builds), the rule cmux-link's
//! `sign_clone.rs` already uses. A clone is removed only when its one cloned
//! bundle's `Info.plist` names the same family id as its root, so another
//! Chromium app's clones beside ours are never touched.
//!
//! Liveness: a clone exists to run the helpers (GPU, network service,
//! renderers) of the browser that made it, and the browser keeps those running
//! from it for its whole life. A clone is in use while any of its executables is
//! open anywhere: Chromium's own `IsFileOpenMoreThanOnce` test
//! (`FSIOC_FD_ONLY_OPEN_ONCE`, kept for crbug.com/343784575); a running program
//! holds its executable open. That answers for every instance and channel, this
//! one included, without listing or reading any process
//! (plans/cmux-next/pty-holder.md, section 4). The hard-linked main executable
//! is skipped: it is the installed app's own file and is open whenever that app
//! runs, so it says nothing about the clone. An unknown answer keeps the clone.
//! Clones made after `started` are also kept, which closes the short window in
//! which a launching instance has made its clone but not yet started a helper.
//!
//! Callers keep every clone younger than `MIN_AGE` too (`cutoff`): Chromium
//! starts its GPU and network-service helpers from the clone at launch and
//! starts them again when one exits, so a browser that has run that long has a
//! helper open; one paused before its first helper for longer is the case this
//! cannot tell, and only a positive owner-exit record would.
//!
//! A clone whose owner is gone is removed for one of two reasons: `superseded`
//! when its main executable is no longer the executable of any installed copy of
//! the app (an update replaced it), else `leftover`. Removal is bound to the
//! folder that was checked (`at`): a folder put in its place is never removed.

use std::collections::HashMap;
use std::ffi::OsStr;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

pub mod at;
#[cfg(target_os = "macos")]
pub mod host;
mod plist;

use at::Ident;
pub use plist::plist_string;

/// Clones younger than this are kept whatever their helpers say.
pub const MIN_AGE: Duration = Duration::from_secs(10 * 60);

/// The start line for a pass at `now`: clones touched at or after it are kept.
/// The earlier of `started` (this process's start, for the app's own pass) and
/// `now - MIN_AGE`.
pub fn cutoff(started: SystemTime, now: SystemTime) -> SystemTime {
    started.min(now.checked_sub(MIN_AGE).unwrap_or(SystemTime::UNIX_EPOCH))
}

/// Every clone folder's name: this prefix and `SUFFIX_LEN` characters.
const CLONE_PREFIX: &str = "code_sign_clone.";
/// `mkdtemp`'s `XXXXXX` in Chromium's template.
const SUFFIX_LEN: usize = 6;
/// A clone root's name: `<bundle id>` and this suffix.
const ROOT_SUFFIX: &str = ".code_sign_clone";
/// The family's base bundle id (cmux.xcodeproj PRODUCT_BUNDLE_IDENTIFIER).
pub const FAMILY: &str = "com.cmuxterm.app";
/// Where macOS keeps per-user temp folders; an `X` folder elsewhere is refused.
pub const USER_FOLDERS_ROOT: &str = "/private/var/folders/";
/// The largest `Info.plist` read; an app's is a few kilobytes.
const MAX_INFO_PLIST: u64 = 1 << 20;

/// Why a clone whose owner is gone is removed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reason {
    /// Its main executable is no installed copy's executable any more.
    Superseded,
    /// It matches an installed copy, but nothing runs from it.
    Leftover,
}

impl Reason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Superseded => "superseded",
            Self::Leftover => "leftover",
        }
    }
}

/// What a pass did with one clone, with its evidence.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Verdict {
    /// Removed (or, in a dry run, would be): its owner is gone.
    Removed { reason: Reason, dry_run: bool },
    /// Kept: this executable is open elsewhere, so its owner is alive.
    InUse { open: PathBuf },
    /// Kept: liveness could not be read at this path.
    Unknown { at: PathBuf },
    /// Kept: its bundle is not its root's family id (`found`: the bundle's id).
    Foreign { found: Option<String> },
    /// Kept: made after the pass's start line, so it may still be starting.
    TooNew,
    /// Not checked: the pass reached its budget first.
    NotReached,
    /// Its owner is gone but removing it failed.
    RemoveFailed { error: String },
}

impl Verdict {
    /// One word for the row: `removed`, `would-remove`, `in-use`, `unknown`,
    /// `foreign`, `too-new`, `not-reached` or `remove-failed`.
    pub fn word(&self) -> &'static str {
        match self {
            Self::Removed { dry_run: false, .. } => "removed",
            Self::Removed { dry_run: true, .. } => "would-remove",
            Self::InUse { .. } => "in-use",
            Self::Unknown { .. } => "unknown",
            Self::Foreign { .. } => "foreign",
            Self::TooNew => "too-new",
            Self::NotReached => "not-reached",
            Self::RemoveFailed { .. } => "remove-failed",
        }
    }

    /// The owner's liveness and the evidence for it, in words.
    pub fn evidence(&self) -> String {
        match self {
            Self::Removed { reason, .. } => {
                format!("owner gone: no executable open; {}", reason.as_str())
            }
            Self::InUse { open } => format!("owner alive: {} is open", open.display()),
            Self::Unknown { at } => format!("owner unknown: cannot read {}", at.display()),
            Self::Foreign { found: Some(id) } => format!("not ours: Info.plist says {id}"),
            Self::Foreign { found: None } => "not ours: no single bundle with an Info.plist".into(),
            Self::TooNew => "made after the pass started: may still be starting".into(),
            Self::NotReached => "not checked: the pass reached its budget".into(),
            Self::RemoveFailed { error } => format!("owner gone; could not remove it: {error}"),
        }
    }
}

/// One clone folder, as a pass saw it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub path: PathBuf,
    /// The family id its root is named for.
    pub root_id: String,
    pub verdict: Verdict,
    /// `st_blocks * 512` of its folders and of its files with no name outside
    /// the clones this pass removes (0 when not walked).
    pub reclaimable_bytes: u64,
}

/// One pass's totals (`CmuxSignCloneSweepReport` in cmux-app-ffi's header).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Report {
    /// `st_blocks * 512` of the removed clones' folders and of their files with
    /// no name left once those clones are gone: what the removal frees, short of
    /// APFS clone blocks still shared with an installed app. A dry run counts
    /// the same bytes the real pass would.
    pub reclaimed_bytes: u64,
    /// The volume's free space after the pass minus before it (set by the caller).
    pub free_space_delta_bytes: i64,
    /// Clones removed (or, in a dry run, that would be).
    pub removed: u32,
    /// Of `removed`, those whose build an update replaced.
    pub removed_superseded: u32,
    /// Clones kept because their owner is alive or cannot be read.
    pub kept_in_use: u32,
    /// Clones kept because their bundle is not their root's family id.
    pub kept_foreign: u32,
    /// Whether the pass stopped at its budget with clones left to check.
    pub more: bool,
}

/// One pass's limits.
#[derive(Clone, Copy, Debug)]
pub struct Budget {
    pub max_bytes: u64,
    pub max_clones: u32,
}

impl Budget {
    pub const UNLIMITED: Self = Self { max_bytes: u64::MAX, max_clones: u32::MAX };
}

/// What a pass needs from the machine.
pub trait Probe {
    /// Whether the file at `path` is open anywhere besides this check
    /// (`None`: cannot tell).
    fn open_elsewhere(&mut self, path: &Path) -> Option<bool>;
    /// The installed copies of an app whose bundle folder is named `app_name`
    /// (`cmux NIGHTLY.app`) that a clone may come from.
    fn installed_apps(&mut self, app_name: &OsStr) -> Vec<PathBuf>;
}

/// Whether `bundle_id` may name a folder: letters, digits, `.`, `-` and `_`,
/// no empty part. A path separator or `..` never passes.
fn plain_bundle_id(bundle_id: &str) -> bool {
    !bundle_id.is_empty()
        && bundle_id.split('.').all(|part| {
            !part.is_empty()
                && part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        })
}

/// Whether `bundle_id` is a cmux app: `com.cmuxterm.app` or a plain
/// `com.cmuxterm.app.*` id.
pub fn in_family(bundle_id: &str) -> bool {
    plain_bundle_id(bundle_id)
        && (bundle_id == FAMILY
            || bundle_id.strip_prefix(FAMILY).is_some_and(|rest| rest.starts_with('.')))
}

/// Whether `name` is a clone folder's name: `code_sign_clone.` and six
/// characters of the portable filename set `mkdtemp` draws from.
pub fn is_clone_name(name: &OsStr) -> bool {
    name.to_str().and_then(|name| name.strip_prefix(CLONE_PREFIX)).is_some_and(|suffix| {
        suffix.len() == SUFFIX_LEN
            && suffix.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
    })
}

/// The `X` folder beside `user_temp` (`confstr(_CS_DARWIN_USER_TEMP_DIR)`),
/// with every link and `..` resolved. `None` when it does not exist or does not
/// resolve under `allowed_root` (`USER_FOLDERS_ROOT` on a Mac).
pub fn x_dir(user_temp: &Path, allowed_root: &Path) -> Option<PathBuf> {
    let x = user_temp.join("..").join("X").canonicalize().ok()?;
    let allowed_root = allowed_root.canonicalize().ok()?;
    (x != allowed_root && x.starts_with(&allowed_root) && x.is_dir()).then_some(x)
}

/// The family's clone roots in `x`: real folders named `<family id>.code_sign_clone`.
pub fn family_roots(x: &Path) -> Vec<(String, PathBuf)> {
    let Ok(entries) = std::fs::read_dir(x) else {
        return Vec::new();
    };
    let mut roots: Vec<(String, PathBuf)> = entries
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name();
            let id = name.to_str()?.strip_suffix(ROOT_SUFFIX)?;
            let real_dir = entry.file_type().ok()?.is_dir();
            (real_dir && in_family(id)).then(|| (id.to_owned(), x.join(&name)))
        })
        .collect();
    roots.sort();
    roots
}

/// The clone's one bundle (`*.app.bundle`, a real folder) and its `Info.plist`
/// bytes; `None` when there is not exactly one or its plist cannot be read.
fn clone_bundle(clone: &Path) -> Option<(PathBuf, Vec<u8>)> {
    let bundles: Vec<PathBuf> = std::fs::read_dir(clone)
        .ok()?
        .flatten()
        .filter(|entry| {
            entry.file_type().is_ok_and(|t| t.is_dir())
                && entry.file_name().to_str().is_some_and(|name| name.ends_with(".app.bundle"))
        })
        .map(|entry| entry.path())
        .collect();
    let [bundle] = bundles.as_slice() else {
        return None;
    };
    let plist = bundle.join("Contents/Info.plist");
    let meta = std::fs::symlink_metadata(&plist).ok()?;
    if !meta.is_file() || meta.len() > MAX_INFO_PLIST {
        return None;
    }
    Some((bundle.clone(), std::fs::read(&plist).ok()?))
}

/// What a clone's walk found: the bytes its folders and single-name files hold,
/// and its files with more than one name, which free their blocks only when
/// their last name goes.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Scan {
    pub bytes: u64,
    /// Each: the file's identity, its link count and its bytes.
    pub shared: Vec<(Ident, u64, u64)>,
}

/// Liveness of the clone at `clone`: `Err` with the verdict that keeps it (an
/// executable with one name that `open_elsewhere` does not answer `Some(false)`
/// for, or an entry that cannot be read), else what it holds (`Scan`). Links are
/// never followed; files with more than one name (the hard-linked main
/// executable) are never asked.
pub fn scan_clone(
    clone: &Path,
    mut open_elsewhere: impl FnMut(&Path) -> Option<bool>,
) -> Result<Scan, Verdict> {
    let unknown = |at: &Path| Verdict::Unknown { at: at.to_path_buf() };
    let mut scan = Scan::default();
    let mut folders = vec![clone.to_path_buf()];
    while let Some(folder) = folders.pop() {
        let entries = std::fs::read_dir(&folder).map_err(|_| unknown(&folder))?;
        for entry in entries {
            let path = entry.map_err(|_| unknown(&folder))?.path();
            let meta = std::fs::symlink_metadata(&path).map_err(|_| unknown(&path))?;
            let bytes = meta.blocks().saturating_mul(512);
            if meta.is_dir() || meta.nlink() == 1 {
                scan.bytes = scan.bytes.saturating_add(bytes);
            } else {
                scan.shared.push((Ident::of(&meta), meta.nlink(), bytes));
            }
            if meta.is_dir() {
                folders.push(path);
            } else if meta.is_file() && meta.nlink() == 1 && meta.permissions().mode() & 0o111 != 0
            {
                match open_elsewhere(&path) {
                    Some(false) => {}
                    Some(true) => return Err(Verdict::InUse { open: path }),
                    None => return Err(unknown(&path)),
                }
            }
        }
    }
    Ok(scan)
}

/// Whether the clone's bundle at `bundle` (its `Info.plist` in `plist`) was
/// superseded: its main executable is the executable of none of `installed`.
pub fn superseded(bundle: &Path, plist: &[u8], installed: &[PathBuf]) -> bool {
    let Some(executable) = plist_string(plist, "CFBundleExecutable") else {
        return true;
    };
    if executable.is_empty() || executable.contains('/') {
        return true;
    }
    let main = Path::new("Contents/MacOS").join(&executable);
    let Ok(clone_main) = std::fs::metadata(bundle.join(&main)) else {
        return true;
    };
    !installed.iter().any(|app| {
        std::fs::metadata(app.join(&main))
            .is_ok_and(|meta| meta.dev() == clone_main.dev() && meta.ino() == clone_main.ino())
    })
}

/// When the folder `meta` describes was created (its change time on a file
/// system without birth times) or last changed, whichever is later.
fn last_touched(meta: &std::fs::Metadata) -> Option<SystemTime> {
    let modified = meta.modified().ok()?;
    let created = meta.created().unwrap_or(modified);
    Some(created.max(modified))
}

/// One pass over the family's clones in `x` (a resolved `x_dir`), oldest first:
/// removes each clone made before `started` whose bundle is its root's family
/// id and whose owner is gone, within `budget`; with `dry_run`, removes nothing
/// and reports what it would do. Returns every clone it saw and the totals
/// (`free_space_delta_bytes` is the caller's).
pub fn pass(
    x: &Path,
    started: SystemTime,
    budget: Budget,
    dry_run: bool,
    probe: &mut dyn Probe,
) -> (Vec<Row>, Report) {
    let mut found = Vec::new();
    let mut rows = Vec::new();
    let mut report = Report::default();
    // A folder that cannot be read is a row, not an empty folder.
    let mut unreadable = |at: &Path, root_id: &str, report: &mut Report| {
        report.kept_in_use = report.kept_in_use.saturating_add(1);
        rows.push(Row {
            path: at.to_path_buf(),
            root_id: root_id.to_owned(),
            verdict: Verdict::Unknown { at: at.to_path_buf() },
            reclaimable_bytes: 0,
        });
    };
    if std::fs::read_dir(x).is_err() {
        unreadable(x, FAMILY, &mut report);
    }
    for (id, root) in family_roots(x) {
        let Ok(entries) = std::fs::read_dir(&root) else {
            unreadable(&root, &id, &mut report);
            continue;
        };
        for entry in entries.flatten() {
            if !is_clone_name(&entry.file_name()) {
                continue;
            }
            let path = entry.path();
            // symlink_metadata: a link named like a clone is never followed.
            let Ok(meta) = std::fs::symlink_metadata(&path) else {
                continue;
            };
            if let (true, Some(touched)) = (meta.is_dir(), last_touched(&meta)) {
                found.push((touched, id.clone(), path));
            }
        }
    }
    found.sort();
    rows.reserve(found.len());
    // A dry run's names of multi-name files in the clones it would remove: a
    // file's blocks count once all its names are among them, as the real pass
    // counts them when it removes the last one.
    let mut planned: HashMap<Ident, u64> = HashMap::new();
    for (touched, root_id, path) in found {
        let mut row = Row { path, root_id, verdict: Verdict::NotReached, reclaimable_bytes: 0 };
        if report.removed >= budget.max_clones || report.reclaimed_bytes >= budget.max_bytes {
            report.more = true;
            rows.push(row);
            continue;
        }
        let context = Pass { started, dry_run, planned: &mut planned };
        row.verdict = judge(&mut row, touched, context, probe, &mut report);
        rows.push(row);
    }
    (rows, report)
}

/// What `judge` carries from its pass.
struct Pass<'a> {
    started: SystemTime,
    dry_run: bool,
    planned: &'a mut HashMap<Ident, u64>,
}

/// The verdict on one clone; removes it unless `dry_run`.
fn judge(
    row: &mut Row,
    touched: SystemTime,
    pass: Pass<'_>,
    probe: &mut dyn Probe,
    report: &mut Report,
) -> Verdict {
    let Some((bundle, plist)) = clone_bundle(&row.path) else {
        report.kept_foreign = report.kept_foreign.saturating_add(1);
        return Verdict::Foreign { found: None };
    };
    let id = plist_string(&plist, "CFBundleIdentifier");
    if id.as_deref() != Some(row.root_id.as_str()) || !in_family(&row.root_id) {
        report.kept_foreign = report.kept_foreign.saturating_add(1);
        return Verdict::Foreign { found: id };
    }
    if touched >= pass.started {
        return Verdict::TooNew;
    }
    // The folder the checks below read, by identity; removal is bound to it.
    let identity = |path: &Path| std::fs::symlink_metadata(path).ok().map(|m| Ident::of(&m));
    let Some(checked) = identity(&row.path) else {
        report.kept_in_use = report.kept_in_use.saturating_add(1);
        return Verdict::Unknown { at: row.path.clone() };
    };
    match scan_clone(&row.path, |file| probe.open_elsewhere(file)) {
        Err(kept) => {
            report.kept_in_use = report.kept_in_use.saturating_add(1);
            kept
        }
        Ok(_) if identity(&row.path) != Some(checked) => {
            report.kept_in_use = report.kept_in_use.saturating_add(1);
            Verdict::Unknown { at: row.path.clone() }
        }
        Ok(scan) => {
            let mut bytes = scan.bytes;
            if pass.dry_run {
                for (file, links, file_bytes) in &scan.shared {
                    let names = pass.planned.entry(*file).or_insert(0);
                    *names = names.saturating_add(1);
                    if *names == *links {
                        bytes = bytes.saturating_add(*file_bytes);
                    }
                }
            }
            row.reclaimable_bytes = bytes;
            let installed = bundle
                .file_name()
                .and_then(|name| name.to_str())
                .and_then(|name| name.strip_suffix(".bundle"))
                .map(|app_name| probe.installed_apps(OsStr::new(app_name)))
                .unwrap_or_default();
            let reason = if superseded(&bundle, &plist, &installed) {
                Reason::Superseded
            } else {
                Reason::Leftover
            };
            if !pass.dry_run
                && let Err(error) = at::remove_checked(&row.path, checked)
            {
                // In words, not an OS error number: "permission denied", or why
                // the folder was left ("the folder changed after it was checked").
                let words = match error.kind() {
                    std::io::ErrorKind::Other => error.to_string(),
                    kind => kind.to_string(),
                };
                return Verdict::RemoveFailed { error: words };
            }
            let dry_run = pass.dry_run;
            report.removed = report.removed.saturating_add(1);
            if reason == Reason::Superseded {
                report.removed_superseded = report.removed_superseded.saturating_add(1);
            }
            report.reclaimed_bytes = report.reclaimed_bytes.saturating_add(bytes);
            Verdict::Removed { reason, dry_run }
        }
    }
}

#[cfg(test)]
mod tests;
