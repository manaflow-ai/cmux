//! What auto-clean would take from a paused agent machine's disk (cmuxterm-hq RFD 0144 piece 10),
//! as a plan: it deletes nothing. RFD 0144: auto-clean runs on paused disks, so it costs no awake
//! time, and takes build outputs a workload can remake and caches older than a week; never the
//! checkout, never untracked files in it.
//!
//! [`plan`] walks one checkout and any cache folders it is given, once, links not followed:
//! - build output: a folder named in [`BUILD_OUTPUT`] with its marker beside it, and only when
//!   git says it is ignored and holds no tracked file (an untracked `dist/` is the person's);
//! - stale cache: an entry directly under a cache folder whose newest change is older than
//!   [`Options::cache_idle_ms`] (a week by default).
//!
//! The plan also says how much the checkout uses against RFD 0144's disk limit: [`INCLUDED_BYTES`]
//! included, [`CAP_BYTES`] at most. Applying a plan (on the paused disk, by whoever holds it) is
//! a later step; this one is the shadow that says what it would free.

use crate::inventory::BUILD_OUTPUT;
use serde::Serialize;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// The disk an agent machine includes (RFD 0144).
pub const INCLUDED_BYTES: u64 = 20 << 30;
/// The most disk an agent machine may grow to.
pub const CAP_BYTES: u64 = 64 << 30;
/// A cache entry this long unchanged is stale.
pub const WEEK_MS: u64 = 7 * 24 * 60 * 60 * 1000;

#[derive(Debug, Clone)]
pub struct Options {
    /// Folders whose direct entries are caches (`~/.cache`, `~/.npm/_cacache`, ...).
    pub cache_roots: Vec<PathBuf>,
    pub cache_idle_ms: u64,
    pub now_ms: u64,
    /// The walk stops past this many entries; the plan then says it is partial.
    pub max_entries: usize,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            cache_roots: Vec::new(),
            cache_idle_ms: WEEK_MS,
            now_ms: now_ms(),
            max_entries: 2_000_000,
        }
    }
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Why {
    BuildOutput,
    StaleCache,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub path: PathBuf,
    pub bytes: u64,
    pub why: Why,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub items: Vec<Item>,
    pub reclaim_bytes: u64,
    /// Bytes under the checkout, build output included.
    pub checkout_bytes: u64,
    pub included_bytes: u64,
    pub cap_bytes: u64,
    /// What the checkout uses past the included disk after the plan's build output went.
    pub over_included_after: u64,
    pub entries: usize,
    /// The walk stopped at [`Options::max_entries`], or git could not be asked: the plan is a
    /// lower bound.
    pub partial: bool,
    /// Why build output was not planned (`notGit`, `gitFailed`), when it was not.
    pub build_output_skipped: Option<&'static str>,
    pub elapsed_ms: u64,
}

struct Walk {
    entries: usize,
    max: usize,
    stopped: bool,
}

/// Bytes and newest change under `path`, links not followed.
fn measure(path: &Path, walk: &mut Walk) -> (u64, u64) {
    let mut bytes = 0u64;
    let mut newest = 0u64;
    let mut stack = vec![path.to_path_buf()];
    while let Some(p) = stack.pop() {
        let Ok(meta) = std::fs::symlink_metadata(&p) else { continue };
        walk.entries += 1;
        if walk.entries > walk.max {
            walk.stopped = true;
            break;
        }
        if let Some(ms) = meta.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()) {
            newest = newest.max(ms.as_millis() as u64);
        }
        if meta.is_dir() {
            if let Ok(rd) = std::fs::read_dir(&p) {
                stack.extend(rd.flatten().map(|e| e.path()));
            }
        } else if meta.is_file() {
            bytes = bytes.saturating_add(meta.len());
        }
    }
    (bytes, newest)
}

fn git(root: &Path, args: &[&str]) -> Option<Vec<u8>> {
    let out = Command::new("git")
        .args(["-c", "core.fsmonitor=false"])
        .args(args)
        .current_dir(root)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    // check-ignore exits 1 when nothing is ignored; that is an answer too.
    (out.status.success() || out.status.code() == Some(1)).then_some(out.stdout)
}

/// `git <args> -- <paths>` in chunks that keep each command line short, outputs joined.
fn git_paths(root: &Path, args: &[&str], paths: &[String]) -> Option<Vec<u8>> {
    let mut all = Vec::new();
    for chunk in paths.chunks(256) {
        let mut argv: Vec<&str> = args.to_vec();
        argv.push("--");
        argv.extend(chunk.iter().map(String::as_str));
        all.extend(git(root, &argv)?);
    }
    Some(all)
}

fn nul_set(bytes: &[u8]) -> BTreeSet<String> {
    bytes
        .split(|b| *b == 0)
        .filter(|s| !s.is_empty())
        .map(|s| String::from_utf8_lossy(s).trim_end_matches('/').to_owned())
        .collect()
}

/// Build-output folders under `root` by name and marker, relative, not descending into one.
fn build_output_candidates(root: &Path, walk: &mut Walk) -> (Vec<String>, u64) {
    let mut found = Vec::new();
    let mut other_bytes = 0u64;
    let mut stack = vec![(root.to_path_buf(), String::new())];
    while let Some((dir, rel)) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&dir) else { continue };
        for e in rd.flatten() {
            walk.entries += 1;
            if walk.entries > walk.max {
                walk.stopped = true;
                return (found, other_bytes);
            }
            let Ok(kind) = e.file_type() else { continue };
            let Some(name) = e.file_name().to_str().map(str::to_owned) else { continue };
            let path = if rel.is_empty() { name.clone() } else { format!("{rel}/{name}") };
            if kind.is_file() {
                other_bytes = other_bytes.saturating_add(e.metadata().map_or(0, |m| m.len()));
                continue;
            }
            if !kind.is_dir() || name == ".git" {
                continue;
            }
            let is_output = BUILD_OUTPUT.iter().any(|(n, markers)| {
                *n == name && (markers.is_empty() || markers.iter().any(|m| dir.join(m).exists()))
            });
            if is_output {
                found.push(path);
            } else {
                stack.push((e.path(), path));
            }
        }
    }
    (found, other_bytes)
}

/// The plan for the checkout at `root` and `options.cache_roots`. Blocking; reads only.
pub fn plan(root: &Path, options: &Options) -> Plan {
    let started = Instant::now();
    let mut walk = Walk { entries: 0, max: options.max_entries, stopped: false };
    let mut items = Vec::new();
    let mut skipped = None;
    let mut git_partial = false;

    let (candidates, other_bytes) = build_output_candidates(root, &mut walk);
    let mut checkout_bytes = other_bytes;
    let inside = git(root, &["rev-parse", "--is-inside-work-tree"])
        .is_some_and(|b| b.trim_ascii() == b"true");
    let (ignored, tracked) = if !inside {
        skipped = Some("notGit");
        (BTreeSet::new(), BTreeSet::new())
    } else {
        // The slash makes `dir/` patterns match without git guessing the kind.
        let dirs: Vec<String> = candidates.iter().map(|c| format!("{c}/")).collect();
        // `-z` needs `--stdin` here; a name git would quote does not match, so it stays.
        let ignored = git_paths(root, &["check-ignore"], &dirs).map(|b| {
            let text = String::from_utf8_lossy(&b).replace('\n', "\0");
            nul_set(text.as_bytes())
        });
        // Any tracked file inside a candidate keeps it: that folder is part of the checkout.
        let tracked = git_paths(root, &["ls-files", "-z"], &candidates);
        match (ignored, tracked) {
            (Some(i), Some(t)) => (i, nul_set(&t)),
            _ => {
                skipped = Some("gitFailed");
                git_partial = true;
                (BTreeSet::new(), BTreeSet::new())
            }
        }
    };
    for c in &candidates {
        let (bytes, _) = measure(&root.join(c), &mut walk);
        checkout_bytes = checkout_bytes.saturating_add(bytes);
        let has_tracked = tracked.iter().any(|t| t.starts_with(&format!("{c}/")) || t == c);
        if ignored.contains(c) && !has_tracked {
            items.push(Item { path: root.join(c), bytes, why: Why::BuildOutput });
        }
    }
    for cache in &options.cache_roots {
        let Ok(rd) = std::fs::read_dir(cache) else { continue };
        let mut entries: Vec<_> = rd.flatten().map(|e| e.path()).collect();
        entries.sort();
        for entry in entries {
            if std::fs::symlink_metadata(&entry).map_or(true, |m| m.file_type().is_symlink()) {
                continue;
            }
            let (bytes, newest) = measure(&entry, &mut walk);
            if options.now_ms.saturating_sub(newest) >= options.cache_idle_ms {
                items.push(Item { path: entry, bytes, why: Why::StaleCache });
            }
        }
    }
    items.sort_by(|a, b| b.bytes.cmp(&a.bytes).then_with(|| a.path.cmp(&b.path)));
    let reclaim_bytes = items.iter().map(|i| i.bytes).sum::<u64>();
    let build_bytes: u64 =
        items.iter().filter(|i| i.why == Why::BuildOutput).map(|i| i.bytes).sum();
    Plan {
        items,
        reclaim_bytes,
        checkout_bytes,
        included_bytes: INCLUDED_BYTES,
        cap_bytes: CAP_BYTES,
        over_included_after: checkout_bytes
            .saturating_sub(build_bytes)
            .saturating_sub(INCLUDED_BYTES),
        entries: walk.entries,
        partial: walk.stopped || git_partial,
        build_output_skipped: skipped,
        elapsed_ms: u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
    }
}

/// How long a plan of a 20,000-file tree may take (the duress test's bound).
pub const PLAN_BOUND: Duration = Duration::from_secs(5);

#[cfg(all(test, unix))]
#[path = "paused_clean_tests.rs"]
mod tests;
