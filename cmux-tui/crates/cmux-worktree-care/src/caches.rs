//! A machine's regenerable and abandoned data outside any worktree, as a
//! table of families (see [`default_families`]): Xcode's DerivedData, the
//! package caches (SwiftPM, npm, Bun, pnpm, yarn, pip, uv, go build, cargo's
//! registry), the known build caches under `~/.cache`, build folders of
//! idle checkouts, idle files in the user's own `/tmp`, plain clones a lane
//! left behind, Docker images and the iOS simulators' leftovers; Tart/Lume
//! images and agent transcripts are only reported. Agents fill these as
//! fast as they fill worktrees, and nothing else empties them.
//!
//! Each family has a [`Kind`]: regenerable data is deleted (the ledger says
//! so); unique data is archived first and goes only when that succeeded.
//! Each has an idle age per disk pressure. Every entry is reported; one
//! goes only when the caller asks (`apply`), and only if, checked again
//! right before, it is still idle, no registered program works in it and no
//! program has it open. A link is never followed or removed. What cannot be
//! read whole (its activity unknown) stays, and so does what the
//! never-delete list names. Nothing outside the home folder (and the user's
//! own entries in `/tmp`) is ever touched.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, UNIX_EPOCH};

use serde::Serialize;

use crate::never_delete::NeverDelete;
use crate::policy::{Action, Pressure, Verdict};
use crate::procs::{self, Open, Uses};
use crate::store::Store;

const HOUR_MS: u64 = 60 * 60 * 1000;
const DAY_H: u64 = 24;

/// How deep the activity scan looks below an entry, and how many entries it
/// reads before it gives up (and the entry stays).
const SCAN_DEPTH: usize = 3;
const SCAN_LIMIT: usize = 20_000;
/// A build folder has far more entries: the scan reads only folders' own times
/// below the top, but still lists everything.
const BUILD_LIMIT: usize = 400_000;
/// How long measuring one entry may take.
const MEASURE: Duration = Duration::from_secs(5);

/// Whether a family's data can be made again.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    /// A build or download again makes it: deleted, and logged.
    Regenerable,
    /// May hold the only copy of something: archived first, deleted only
    /// when the archive succeeded.
    Unique,
}

/// How a family finds its entries and removes them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    /// `root`, or each folder in it (`per_child`).
    Fixed,
    /// The user's own idle files and folders directly in `root` (`/tmp`).
    TmpEntries,
    /// `target`, `.build`, `.zig-cache` and `node_modules` of checkouts under
    /// `search` (two levels deep), outside `exclude` (worktree roots).
    BuildDirs { search: Vec<PathBuf>, exclude: Vec<PathBuf> },
    /// Plain clones directly in each of `roots` (or in their children).
    Clones { roots: Vec<PathBuf> },
    /// Shown, never removed.
    ReportOnly,
    /// `docker image prune`, when docker answers.
    Docker,
    /// `xcrun simctl delete unavailable`, macOS only.
    Simulators,
}

/// A kind of data and where it lives.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Family {
    pub name: &'static str,
    pub root: PathBuf,
    /// Each folder directly in `root` is an entry (DerivedData's projects);
    /// otherwise `root` itself is the one entry.
    pub per_child: bool,
    /// Idle hours before an entry goes, per pressure (normal, high,
    /// critical); `None` keeps it at that pressure.
    pub idle_hours: [Option<u64>; 3],
    pub kind: Kind,
    #[serde(skip)]
    pub source: Source,
}

fn fixed(name: &'static str, root: PathBuf, per_child: bool, idle: [Option<u64>; 3]) -> Family {
    Family {
        name,
        root,
        per_child,
        idle_hours: idle,
        kind: Kind::Regenerable,
        source: Source::Fixed,
    }
}

/// The user's home and what decides where to look.
pub struct Layout<'a> {
    pub home: &'a Path,
    /// Folders agents' worktrees live under: build folders in them are the
    /// worktree pass's (trim), not this one's.
    pub worktree_roots: &'a [PathBuf],
    /// The folders whose plain clones are lane leftovers (`~/.wt/checkouts/*`).
    pub clone_roots: &'a [PathBuf],
}

/// The families on this machine, under `home`: the four of the first pass
/// first, so their positions stay. Roots that are absent are skipped by
/// [`entries`].
pub fn default_families(home: &Path) -> Vec<Family> {
    families(&Layout { home, worktree_roots: &[], clone_roots: &[] })
}

/// Every family's name, for the `care.families.<name>` switches.
pub fn family_names() -> Vec<&'static str> {
    let mut names: Vec<&'static str> = Vec::new();
    let home = Path::new("/");
    for f in families(&Layout { home, worktree_roots: &[], clone_roots: &[] }) {
        if !names.contains(&f.name) {
            names.push(f.name);
        }
    }
    names
}

/// [`default_families`] with the discovered families (build folders, clones).
pub fn families(layout: &Layout) -> Vec<Family> {
    let home = layout.home;
    let pressure_only = [None, Some(7 * DAY_H), Some(DAY_H)];
    let mut list = vec![
        fixed(
            "xcode-derived-data",
            home.join("Library/Developer/Xcode/DerivedData"),
            true,
            [Some(7 * DAY_H), Some(48), Some(12)],
        ),
        fixed("swiftpm-cache", home.join("Library/Caches/org.swift.swiftpm"), false, pressure_only),
        fixed("npm-cache", home.join(".npm/_cacache"), false, pressure_only),
        fixed("bun-cache", home.join(".bun/install/cache"), false, pressure_only),
    ];
    let more: [(&'static str, &[&str]); 6] = [
        ("pnpm-store", &[".local/share/pnpm/store", "Library/pnpm/store"]),
        ("yarn-cache", &[".cache/yarn", ".yarn/berry/cache", "Library/Caches/Yarn"]),
        ("pip-cache", &[".cache/pip", "Library/Caches/pip"]),
        ("uv-cache", &[".cache/uv", "Library/Caches/uv"]),
        ("go-build-cache", &[".cache/go-build", "Library/Caches/go-build"]),
        ("cargo-registry", &[".cargo/registry/cache", ".cargo/registry/src"]),
    ];
    for (name, roots) in more {
        for root in roots {
            list.push(fixed(name, home.join(root), false, pressure_only));
        }
    }
    for name in [
        "sccache",
        "ccache",
        "node-gyp",
        "electron",
        "zig",
        "bazel",
        "typescript",
        "esbuild",
        "turbo",
        "nx",
    ] {
        list.push(fixed("build-cache", home.join(".cache").join(name), false, pressure_only));
    }
    list.push(Family {
        name: "checkout-build-dirs",
        root: home.to_path_buf(),
        per_child: false,
        idle_hours: [Some(14 * DAY_H), Some(3 * DAY_H), Some(DAY_H)],
        kind: Kind::Regenerable,
        source: Source::BuildDirs {
            search: vec![home.to_path_buf()],
            exclude: layout.worktree_roots.to_vec(),
        },
    });
    list.push(Family {
        name: "tmp-files",
        root: PathBuf::from("/tmp"),
        per_child: true,
        idle_hours: [Some(7 * DAY_H), Some(DAY_H), Some(2)],
        kind: Kind::Regenerable,
        source: Source::TmpEntries,
    });
    list.push(Family {
        name: "lane-clones",
        root: home.join(".wt/checkouts"),
        per_child: true,
        idle_hours: [Some(14 * DAY_H), Some(3 * DAY_H), Some(DAY_H)],
        kind: Kind::Unique,
        source: Source::Clones { roots: layout.clone_roots.to_vec() },
    });
    list.push(Family {
        name: "docker-images",
        root: PathBuf::from("docker:images"),
        per_child: false,
        idle_hours: [None, Some(7 * DAY_H), Some(DAY_H)],
        kind: Kind::Regenerable,
        source: Source::Docker,
    });
    list.push(Family {
        name: "ios-simulators",
        root: PathBuf::from("simctl:unavailable"),
        per_child: false,
        idle_hours: [Some(7 * DAY_H), Some(DAY_H), Some(1)],
        kind: Kind::Regenerable,
        source: Source::Simulators,
    });
    for (name, root) in [
        ("tart-vms", home.join(".tart/vms")),
        ("lume-vms", home.join(".lume")),
        ("claude-transcripts", home.join(".claude/projects")),
        ("codex-transcripts", home.join(".codex/sessions")),
    ] {
        list.push(Family {
            name,
            root,
            per_child: false,
            idle_hours: [None; 3],
            kind: Kind::Unique,
            source: Source::ReportOnly,
        });
    }
    list
}

/// One cache folder and when it was last used.
#[derive(Debug, Clone)]
pub struct Entry {
    pub family: usize,
    pub path: PathBuf,
    /// The folder whose use matters (a build folder's checkout); the path
    /// itself otherwise.
    pub guard: PathBuf,
    /// Milliseconds since the epoch of the newest change in it; `None` when
    /// the scan could not read it whole.
    pub last_activity_ms: Option<u64>,
}

const BUILD_NAMES: [(&str, &str); 4] = [
    ("target", "Cargo.toml"),
    (".build", "Package.swift"),
    (".zig-cache", "build.zig"),
    ("node_modules", "package.json"),
];

/// The entries of `families`: real folders only, never a link.
pub fn entries(families: &[Family]) -> Vec<Entry> {
    let mut found = Vec::new();
    for (index, family) in families.iter().enumerate() {
        match &family.source {
            Source::Fixed | Source::ReportOnly => fixed_entries(index, family, &mut found),
            Source::TmpEntries => tmp_entries(index, family, &mut found),
            Source::BuildDirs { search, exclude } => {
                build_entries(index, search, exclude, &mut found);
            }
            Source::Clones { roots } => clone_entries(index, roots, &mut found),
            Source::Docker | Source::Simulators => {
                let present = match family.source {
                    Source::Docker => crate::external::docker_reclaimable().is_some(),
                    _ => cfg!(target_os = "macos"),
                };
                if !present {
                    continue;
                }
                found.push(Entry {
                    family: index,
                    path: family.root.clone(),
                    guard: family.root.clone(),
                    // A command, not a folder: its age is the pass's.
                    last_activity_ms: Some(0),
                });
            }
        }
    }
    found
}

fn fixed_entries(index: usize, family: &Family, found: &mut Vec<Entry>) {
    if !real_dir(&family.root) {
        return;
    }
    if family.per_child {
        let Ok(children) = std::fs::read_dir(&family.root) else { return };
        let mut paths: Vec<PathBuf> =
            children.flatten().map(|child| child.path()).filter(|p| real_dir(p)).collect();
        paths.sort();
        for path in paths {
            let last_activity_ms = last_activity(&path);
            found.push(Entry { family: index, guard: path.clone(), path, last_activity_ms });
        }
    } else {
        let last_activity_ms = last_activity(&family.root);
        found.push(Entry {
            family: index,
            path: family.root.clone(),
            guard: family.root.clone(),
            last_activity_ms,
        });
    }
}

#[cfg(unix)]
fn mine(meta: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    // SAFETY: geteuid has no preconditions and cannot fail.
    meta.uid() == unsafe { libc::geteuid() }
}

#[cfg(not(unix))]
fn mine(_meta: &std::fs::Metadata) -> bool {
    false
}

#[cfg(unix)]
fn is_special(meta: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::FileTypeExt;
    let t = meta.file_type();
    t.is_socket() || t.is_fifo() || t.is_block_device() || t.is_char_device()
}

#[cfg(not(unix))]
fn is_special(_meta: &std::fs::Metadata) -> bool {
    false
}

/// Names under `/tmp` that are live runtime state of tools, never entries.
fn tmp_protected(name: &str) -> bool {
    name.starts_with("acpmux")
        || name.starts_with("cmux")
        || name.starts_with(".")
        || name.starts_with("systemd-")
        || name.starts_with("tmux-")
        || name.starts_with("ssh-")
}

/// Whether `folder` holds a socket within [`SCAN_DEPTH`] (a live service's).
fn holds_socket(folder: &Path) -> bool {
    let mut stack = vec![(folder.to_path_buf(), 0usize)];
    let mut seen = 0usize;
    while let Some((dir, depth)) = stack.pop() {
        let Ok(read) = std::fs::read_dir(&dir) else { return true };
        for entry in read.flatten() {
            seen += 1;
            if seen > SCAN_LIMIT {
                return true;
            }
            let Ok(meta) = std::fs::symlink_metadata(entry.path()) else { return true };
            if is_special(&meta) {
                return true;
            }
            if meta.is_dir() && depth + 1 < SCAN_DEPTH {
                stack.push((entry.path(), depth + 1));
            }
        }
    }
    false
}

fn tmp_entries(index: usize, family: &Family, found: &mut Vec<Entry>) {
    let Ok(children) = std::fs::read_dir(&family.root) else { return };
    let mut paths: Vec<PathBuf> = children.flatten().map(|c| c.path()).collect();
    paths.sort();
    for path in paths {
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        if tmp_protected(&name) {
            continue;
        }
        let Ok(meta) = std::fs::symlink_metadata(&path) else { continue };
        if !mine(&meta) || is_special(&meta) || !(meta.is_dir() || meta.is_file()) {
            continue;
        }
        let last_activity_ms = if meta.is_dir() {
            if holds_socket(&path) { None } else { last_activity(&path) }
        } else {
            modified_ms(&meta)
        };
        found.push(Entry { family: index, guard: path.clone(), path, last_activity_ms });
    }
}

fn build_entries(index: usize, search: &[PathBuf], exclude: &[PathBuf], found: &mut Vec<Entry>) {
    for base in search {
        // Checkouts are the base's children and grandchildren, hidden and
        // system folders left out.
        let Ok(level1) = std::fs::read_dir(base) else { continue };
        let mut checkouts = Vec::new();
        for child in level1.flatten() {
            let path = child.path();
            let hidden = child.file_name().to_string_lossy().starts_with('.');
            if hidden || !real_dir(&path) {
                continue;
            }
            if path.join(".git").exists() {
                checkouts.push(path);
            } else if let Ok(level2) = std::fs::read_dir(&path) {
                checkouts.extend(
                    level2
                        .flatten()
                        .map(|e| e.path())
                        .filter(|p| real_dir(p) && p.join(".git").exists()),
                );
            }
        }
        checkouts.sort();
        for checkout in checkouts {
            if exclude.iter().any(|root| checkout.starts_with(root)) {
                continue;
            }
            for (dir, marker) in BUILD_NAMES {
                let build = checkout.join(dir);
                if !real_dir(&build) || !checkout.join(marker).is_file() {
                    continue;
                }
                let last_activity_ms = build_activity(&checkout, &build);
                found.push(Entry {
                    family: index,
                    path: build,
                    guard: checkout.clone(),
                    last_activity_ms,
                });
            }
        }
    }
}

/// The newer of the build folder's changes and the checkout's own git state.
fn build_activity(checkout: &Path, build: &Path) -> Option<u64> {
    let built = activity(build, SCAN_DEPTH, BUILD_LIMIT)?;
    let mut newest = built;
    for file in [".git/HEAD", ".git/index", ".git/FETCH_HEAD", ".git/logs/HEAD"] {
        if let Ok(meta) = std::fs::symlink_metadata(checkout.join(file)) {
            newest = newest.max(modified_ms(&meta).unwrap_or(0));
        }
    }
    Some(newest)
}

fn clone_entries(index: usize, roots: &[PathBuf], found: &mut Vec<Entry>) {
    for root in roots {
        let Ok(level1) = std::fs::read_dir(root) else { continue };
        let mut clones = Vec::new();
        for child in level1.flatten() {
            let path = child.path();
            if !real_dir(&path) {
                continue;
            }
            if is_plain_clone(&path) {
                clones.push(path);
            } else if let Ok(level2) = std::fs::read_dir(&path) {
                clones.extend(level2.flatten().map(|e| e.path()).filter(|p| is_plain_clone(p)));
            }
        }
        clones.sort();
        for path in clones {
            let last_activity_ms = clone_activity(&path);
            found.push(Entry { family: index, guard: path.clone(), path, last_activity_ms });
        }
    }
}

/// A real folder with a real `.git` folder: a clone, not a linked worktree
/// (whose `.git` is a file).
fn is_plain_clone(path: &Path) -> bool {
    real_dir(path) && real_dir(&path.join(".git"))
}

/// Top-level changes in the clone and its git state: huge trees are never walked.
fn clone_activity(clone: &Path) -> Option<u64> {
    let top = activity(clone, 1, SCAN_LIMIT)?;
    let mut newest = top;
    for file in [".git/HEAD", ".git/index", ".git/FETCH_HEAD", ".git/logs/HEAD", ".git/refs"] {
        if let Ok(meta) = std::fs::symlink_metadata(clone.join(file)) {
            newest = newest.max(modified_ms(&meta).unwrap_or(0));
        }
    }
    Some(newest)
}

fn real_dir(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok_and(|meta| meta.is_dir())
}

fn modified_ms(meta: &std::fs::Metadata) -> Option<u64> {
    let since = meta.modified().ok()?.duration_since(UNIX_EPOCH).ok()?;
    u64::try_from(since.as_millis()).ok()
}

/// The newest change in `folder` down to [`SCAN_DEPTH`], links not followed.
/// `None` when any folder in reach cannot be read or the scan passes
/// [`SCAN_LIMIT`] entries.
pub fn last_activity(folder: &Path) -> Option<u64> {
    activity(folder, SCAN_DEPTH, SCAN_LIMIT)
}

fn activity(folder: &Path, max_depth: usize, limit: usize) -> Option<u64> {
    let meta = std::fs::symlink_metadata(folder).ok()?;
    let mut newest = modified_ms(&meta)?;
    let mut seen = 0usize;
    let mut stack = vec![(folder.to_path_buf(), 0usize)];
    while let Some((dir, depth)) = stack.pop() {
        let entries = std::fs::read_dir(&dir).ok()?;
        for entry in entries {
            let entry = entry.ok()?;
            seen += 1;
            if seen > limit {
                return None;
            }
            let path = entry.path();
            let meta = std::fs::symlink_metadata(&path).ok()?;
            if let Some(ms) = modified_ms(&meta) {
                newest = newest.max(ms);
            }
            if meta.is_dir() && depth + 1 < max_depth {
                stack.push((path, depth + 1));
            }
        }
    }
    Some(newest)
}

fn verdict(action: Action, reason: impl Into<String>) -> Verdict {
    Verdict { action, reason: reason.into(), idle_ms: None }
}

/// The verdict for an entry of `family` at `now_ms`: [`Action::Reclaim`]
/// (its folder goes) or [`Action::Keep`].
pub fn decide(
    family: &Family,
    last_activity_ms: Option<u64>,
    pressure: Pressure,
    now_ms: u64,
) -> Verdict {
    if family.source == Source::ReportOnly {
        return verdict(Action::Keep, "reported only: care never removes it");
    }
    let Some(hours) = family.idle_hours.get(pressure as usize).copied().flatten() else {
        return verdict(
            Action::Keep,
            "shared package cache: goes only when the disk is nearly full",
        );
    };
    let Some(last) = last_activity_ms else {
        return verdict(Action::Keep, "its last use could not be read");
    };
    let idle = now_ms.saturating_sub(last);
    if idle < hours * HOUR_MS {
        return verdict(Action::Keep, format!("used in the last {hours} h"));
    }
    verdict(Action::Reclaim, format!("unused for {} h", idle / HOUR_MS))
}

/// What became of a removal.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Outcome {
    pub ok: bool,
    pub freed: u64,
    /// The archive id, for a unique entry archived first.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub archive: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// An entry, its verdict and what became of it.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub family: String,
    pub path: PathBuf,
    pub verdict: Verdict,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_activity_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub outcome: Option<Outcome>,
    #[serde(skip)]
    pub entry: Option<usize>,
}

/// A caches pass.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub applied: bool,
    pub items: Vec<Item>,
    /// Bytes the entries that may go take (measured ones only).
    pub reclaimable: u64,
    pub freed: u64,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub errors: Vec<String>,
}

/// What a caches pass runs with.
pub struct Options<'a> {
    pub families: Vec<Family>,
    pub pressure: Pressure,
    pub now_ms: u64,
    /// Remove what may go; otherwise only report.
    pub apply: bool,
    pub uses: &'a Uses,
    pub open: &'a Open,
    /// Measure each entry's bytes (a bounded walk each).
    pub measure: bool,
    /// The user's home: nothing outside it goes (but `/tmp` entries of the user's).
    pub home: &'a Path,
    pub never: &'a NeverDelete,
    /// Where unique entries are archived; without it they are kept.
    pub store: Option<&'a Store>,
    /// Families switched off (`care.families.<name>`).
    pub off: &'a [String],
}

fn bytes_of(path: &Path) -> Option<u64> {
    let sizes = crate::disk::sizes(path, &[], Instant::now() + MEASURE);
    Some(sizes.total)
}

/// What a family's entry takes: a folder's walk; a file's length.
fn bytes_at(family: &Family, path: &Path) -> Option<u64> {
    match &family.source {
        Source::Docker => crate::external::docker_reclaimable(),
        Source::Simulators => None,
        _ => match std::fs::symlink_metadata(path) {
            Ok(meta) if meta.is_file() => Some(meta.len()),
            Ok(_) => bytes_of(path),
            Err(_) => None,
        },
    }
}

/// Every entry with its verdict and, when `measure` or it may go, its bytes.
/// Acts on nothing.
pub fn scan(options: &Options) -> Report {
    let mut report = Report { applied: options.apply, ..Report::default() };
    for entry in entries(&options.families) {
        let Some(family) = options.families.get(entry.family) else { continue };
        if options.off.iter().any(|name| name == family.name) {
            continue;
        }
        let mut decided = decide(family, entry.last_activity_ms, options.pressure, options.now_ms);
        if let Some(glob) = options.never.holds(options.home, &entry.path) {
            decided = verdict(Action::Keep, format!("never-delete: {glob}"));
        }
        let goes = decided.action == Action::Reclaim;
        let reportable = matches!(family.source, Source::ReportOnly);
        let bytes = if options.measure || goes || reportable {
            bytes_at(family, &entry.path)
        } else {
            None
        };
        if goes {
            report.reclaimable += bytes.unwrap_or(0);
        }
        report.items.push(Item {
            family: family.name.to_string(),
            path: entry.path.clone(),
            verdict: decided,
            last_activity_ms: entry.last_activity_ms,
            bytes,
            outcome: None,
            entry: Some(report.items.len()),
        });
        let _ = entry.guard;
    }
    report
}

/// Reports every entry and, with `apply`, removes those that may go.
pub fn run(options: &Options) -> Report {
    let mut report = scan(options);
    if options.apply {
        for index in 0..report.items.len() {
            apply(options, &mut report, index);
        }
    }
    report
}

/// Removes item `index` of `report` when its verdict says so, after the
/// last-moment checks; records the outcome (or the keep verdict a check
/// turned up).
pub fn apply(options: &Options, report: &mut Report, index: usize) {
    let Some(item) = report.items.get(index) else { return };
    if item.verdict.action != Action::Reclaim {
        return;
    }
    let (path, name, bytes) = (item.path.clone(), item.family.clone(), item.bytes.unwrap_or(0));
    let Some(family) = options.families.iter().find(|f| f.name == name && same_root(f, &path))
    else {
        return;
    };
    let result = remove(options, family, &path, bytes);
    let Some(item) = report.items.get_mut(index) else { return };
    match result {
        Ok(Some(outcome)) => {
            report.freed += outcome.freed;
            if let Some(error) = &outcome.error {
                report.errors.push(format!("{}: {error}", path.display()));
            }
            item.outcome = Some(outcome);
        }
        Ok(None) => {}
        Err(keep) => item.verdict = keep,
    }
}

/// Whether `path` is an entry the family could have produced (several
/// families share a name).
fn same_root(family: &Family, path: &Path) -> bool {
    match &family.source {
        Source::Fixed | Source::ReportOnly | Source::TmpEntries => {
            path == family.root || path.starts_with(&family.root)
        }
        Source::BuildDirs { .. } => path.starts_with(&family.root),
        Source::Clones { roots } => roots.iter().any(|r| path.starts_with(r)),
        Source::Docker | Source::Simulators => path == family.root,
    }
}

/// The folder whose use matters for `path`.
fn guard_of(family: &Family, path: &Path) -> PathBuf {
    match family.source {
        Source::BuildDirs { .. } => {
            path.parent().map(Path::to_path_buf).unwrap_or_else(|| path.to_path_buf())
        }
        _ => path.to_path_buf(),
    }
}

/// The checks that the path is still what the family listed.
fn still_an_entry(options: &Options, family: &Family, path: &Path) -> Result<(), Verdict> {
    let gone = || verdict(Action::Keep, "no longer a real entry of its family");
    let Ok(meta) = std::fs::symlink_metadata(path) else { return Err(gone()) };
    if meta.file_type().is_symlink() {
        return Err(gone());
    }
    match &family.source {
        Source::Fixed => {
            let inside = if family.per_child {
                path.parent() == Some(family.root.as_path())
            } else {
                path == family.root
            };
            if !inside || !meta.is_dir() || !path.starts_with(options.home) {
                return Err(gone());
            }
        }
        Source::TmpEntries => {
            let direct = path.parent() == Some(family.root.as_path());
            if !direct || !mine(&meta) || is_special(&meta) || !(meta.is_dir() || meta.is_file()) {
                return Err(gone());
            }
            if meta.is_dir() && holds_socket(path) {
                return Err(verdict(Action::Keep, "a socket in it: a live service's"));
            }
        }
        Source::BuildDirs { exclude, .. } => {
            let name =
                path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            let marker = BUILD_NAMES.iter().find(|(dir, _)| *dir == name).map(|(_, m)| *m);
            let checkout = path.parent();
            let ok = meta.is_dir()
                && path.starts_with(options.home)
                && marker.is_some_and(|m| {
                    checkout.is_some_and(|c| c.join(m).is_file() && c.join(".git").exists())
                })
                && !exclude.iter().any(|root| path.starts_with(root));
            if !ok {
                return Err(gone());
            }
        }
        Source::Clones { roots } => {
            if !roots.iter().any(|r| path.starts_with(r))
                || !is_plain_clone(path)
                || !path.starts_with(options.home)
            {
                return Err(gone());
            }
        }
        Source::Docker | Source::Simulators | Source::ReportOnly => {}
    }
    Ok(())
}

/// The last-moment checks, then the removal. `Err` is the keep verdict a
/// check turned up; `Ok(None)` means nothing was tried.
fn remove(
    options: &Options,
    family: &Family,
    path: &Path,
    bytes: u64,
) -> Result<Option<Outcome>, Verdict> {
    if let Some(glob) = options.never.holds(options.home, path) {
        return Err(verdict(Action::Keep, format!("never-delete: {glob}")));
    }
    still_an_entry(options, family, path)?;
    let command = matches!(family.source, Source::Docker | Source::Simulators);
    let again = if command {
        verdict(Action::Reclaim, "a command, not a folder")
    } else {
        let fresh = match &family.source {
            Source::BuildDirs { .. } => build_activity(&guard_of(family, path), path),
            Source::Clones { .. } => clone_activity(path),
            _ if std::fs::symlink_metadata(path).is_ok_and(|m| m.is_file()) => {
                std::fs::symlink_metadata(path).ok().and_then(|m| modified_ms(&m))
            }
            Source::TmpEntries => {
                if holds_socket(path) {
                    None
                } else {
                    last_activity(path)
                }
            }
            _ => last_activity(path),
        };
        decide(family, fresh, options.pressure, crate::inventory::now_ms())
    };
    if again.action != Action::Reclaim {
        return Err(again);
    }
    if !command {
        let guard = guard_of(family, path);
        match (options.uses)() {
            Ok(processes) => {
                if let Some(process) = procs::inside(&processes, &guard) {
                    return Err(verdict(Action::Keep, format!("in use by pid {}", process.pid)));
                }
            }
            Err(error) => {
                return Err(verdict(Action::Keep, format!("could not check its users: {error}")));
            }
        }
        // A folder is checked through its guard; a lone file by itself.
        let target = if real_dir(path) { guard } else { path.to_path_buf() };
        match (options.open)(&target) {
            Ok(Some(pid)) => return Err(verdict(Action::Keep, format!("open in pid {pid}"))),
            Ok(None) => {}
            Err(error) => {
                return Err(verdict(Action::Keep, format!("could not check open files: {error}")));
            }
        }
    }
    let mut archived = None;
    let mut clone_refs = None;
    if family.kind == Kind::Unique {
        let Some(store) = options.store else {
            return Err(verdict(Action::Keep, "no archive store: unique data stays"));
        };
        clone_refs = Some(crate::clones::references(path).map_err(|error| {
            verdict(Action::Keep, format!("cannot read clone references: {error}"))
        })?);
        match crate::clones::archive(path, store, crate::inventory::now_ms()) {
            Ok(id) => archived = id,
            Err(error) => return Err(verdict(Action::Keep, format!("not archived: {error}"))),
        }
    }
    if !command && let Some(why) = options.never.holds_tree(options.home, path) {
        return Err(verdict(Action::Keep, format!("never-delete: {why}")));
    }
    if let Some(before) = clone_refs {
        crate::clones::work(path)
            .map_err(|error| verdict(Action::Keep, format!("clone changed: {error}")))?;
        let after = crate::clones::references(path).map_err(|error| {
            verdict(Action::Keep, format!("cannot recheck clone references: {error}"))
        })?;
        if before != after {
            return Err(verdict(Action::Keep, "clone references changed during archival"));
        }
    }
    let result = match &family.source {
        Source::Docker => crate::external::docker_prune(options.pressure).map(|freed| (freed, 0u8)),
        Source::Simulators => crate::external::simulators_prune().map(|freed| (freed, 0u8)),
        _ if std::fs::symlink_metadata(path).is_ok_and(|m| m.is_file()) => {
            std::fs::remove_file(path).map(|()| (bytes, 0u8)).map_err(|e| e.to_string())
        }
        _ => match std::fs::remove_dir_all(path) {
            Ok(()) => Ok((bytes, 0u8)),
            Err(error) => {
                // A partial removal frees part of it; the rest goes next pass.
                let left = if path.exists() { bytes_of(path).unwrap_or(bytes) } else { 0 };
                Err(format!("{error}\u{0}{}", bytes.saturating_sub(left)))
            }
        },
    };
    Ok(Some(match result {
        Ok((freed, _)) => Outcome { ok: true, freed, archive: archived, error: None },
        Err(message) => {
            let (error, freed) = match message.split_once('\u{0}') {
                Some((error, freed)) => (error.to_string(), freed.parse().unwrap_or(0)),
                None => (message, 0),
            };
            Outcome { ok: false, freed, archive: archived, error: Some(error) }
        }
    }))
}

#[cfg(test)]
#[path = "caches_tests.rs"]
mod tests;
