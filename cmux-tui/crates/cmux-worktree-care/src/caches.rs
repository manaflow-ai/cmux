//! A machine's build caches outside any worktree: Xcode's DerivedData (one
//! folder per project) and the SwiftPM, npm and Bun package caches. Agents
//! fill them as fast as they fill worktrees, and nothing else empties them.
//!
//! Each family has an idle age per disk pressure: a DerivedData folder nobody
//! built in for a week goes, sooner as the disk fills. A package cache is
//! shared by every project, so it goes only under pressure. Every entry is
//! reported; one goes only when the caller asks (`apply`, the setting
//! `worktrees.cleanBuildCaches`), and only if, checked again right before,
//! it is still idle, no registered program works in it and no program has
//! it open. A link is never followed or removed. What cannot be read whole
//! (its activity unknown) stays.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, UNIX_EPOCH};

use serde::Serialize;

use crate::policy::{Action, Pressure, Verdict};
use crate::procs::{self, Open, Uses};

const HOUR_MS: u64 = 60 * 60 * 1000;

/// How deep the activity scan looks below an entry, and how many entries it
/// reads before it gives up (and the entry stays).
const SCAN_DEPTH: usize = 3;
const SCAN_LIMIT: usize = 20_000;
/// How long measuring one entry may take.
const MEASURE: Duration = Duration::from_secs(5);

/// A kind of build cache and where it lives.
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
}

/// The families on this machine, under `home`. Roots that are absent are
/// skipped by [`entries`].
pub fn default_families(home: &Path) -> Vec<Family> {
    let pressure_only = [None, Some(7 * 24), Some(24)];
    vec![
        Family {
            name: "xcode-derived-data",
            root: home.join("Library/Developer/Xcode/DerivedData"),
            per_child: true,
            idle_hours: [Some(7 * 24), Some(48), Some(12)],
        },
        Family {
            name: "swiftpm-cache",
            root: home.join("Library/Caches/org.swift.swiftpm"),
            per_child: false,
            idle_hours: pressure_only,
        },
        Family {
            name: "npm-cache",
            root: home.join(".npm/_cacache"),
            per_child: false,
            idle_hours: pressure_only,
        },
        Family {
            name: "bun-cache",
            root: home.join(".bun/install/cache"),
            per_child: false,
            idle_hours: pressure_only,
        },
    ]
}

/// One cache folder and when it was last used.
#[derive(Debug, Clone)]
pub struct Entry {
    pub family: usize,
    pub path: PathBuf,
    /// Milliseconds since the epoch of the newest change in it; `None` when
    /// the scan could not read it whole.
    pub last_activity_ms: Option<u64>,
}

/// The entries of `families`: real folders only, never a link.
pub fn entries(families: &[Family]) -> Vec<Entry> {
    let mut found = Vec::new();
    for (index, family) in families.iter().enumerate() {
        if !real_dir(&family.root) {
            continue;
        }
        if family.per_child {
            let Ok(children) = std::fs::read_dir(&family.root) else { continue };
            let mut paths: Vec<PathBuf> =
                children.flatten().map(|child| child.path()).filter(|p| real_dir(p)).collect();
            paths.sort();
            for path in paths {
                let last_activity_ms = last_activity(&path);
                found.push(Entry { family: index, path, last_activity_ms });
            }
        } else {
            let last_activity_ms = last_activity(&family.root);
            found.push(Entry { family: index, path: family.root.clone(), last_activity_ms });
        }
    }
    found
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
    let meta = std::fs::symlink_metadata(folder).ok()?;
    let mut newest = modified_ms(&meta)?;
    let mut seen = 0usize;
    let mut stack = vec![(folder.to_path_buf(), 0usize)];
    while let Some((dir, depth)) = stack.pop() {
        let entries = std::fs::read_dir(&dir).ok()?;
        for entry in entries {
            let entry = entry.ok()?;
            seen += 1;
            if seen > SCAN_LIMIT {
                return None;
            }
            let path = entry.path();
            let meta = std::fs::symlink_metadata(&path).ok()?;
            if let Some(ms) = modified_ms(&meta) {
                newest = newest.max(ms);
            }
            if meta.is_dir() && depth + 1 < SCAN_DEPTH {
                stack.push((path, depth + 1));
            }
        }
    }
    Some(newest)
}

fn verdict(action: Action, reason: impl Into<String>) -> Verdict {
    Verdict { action, reason: reason.into() }
}

/// The verdict for an entry of `family` at `now_ms`: [`Action::Reclaim`]
/// (its folder goes) or [`Action::Keep`].
pub fn decide(
    family: &Family,
    last_activity_ms: Option<u64>,
    pressure: Pressure,
    now_ms: u64,
) -> Verdict {
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
}

fn bytes_of(path: &Path) -> Option<u64> {
    let sizes = crate::disk::sizes(path, &[], Instant::now() + MEASURE);
    Some(sizes.total)
}

/// Reports every entry and, with `apply`, removes those that may go.
pub fn run(options: &Options) -> Report {
    let mut report = Report { applied: options.apply, ..Report::default() };
    for entry in entries(&options.families) {
        let Some(family) = options.families.get(entry.family) else { continue };
        let decided = decide(family, entry.last_activity_ms, options.pressure, options.now_ms);
        let goes = decided.action == Action::Reclaim;
        let bytes =
            if options.measure || (goes && options.apply) { bytes_of(&entry.path) } else { None };
        if goes {
            report.reclaimable += bytes.unwrap_or(0);
        }
        let mut item = Item {
            family: family.name.to_string(),
            path: entry.path.clone(),
            verdict: decided,
            last_activity_ms: entry.last_activity_ms,
            bytes,
            outcome: None,
        };
        if goes && options.apply {
            let outcome = remove(options, family, &entry.path, bytes.unwrap_or(0));
            match &outcome {
                Ok(Some(outcome)) => {
                    report.freed += outcome.freed;
                    if let Some(error) = &outcome.error {
                        report.errors.push(format!("{}: {error}", entry.path.display()));
                    }
                    item.outcome = Some(outcome.clone());
                }
                Ok(None) => {}
                Err(keep) => item.verdict = keep.clone(),
            }
        }
        report.items.push(item);
    }
    report
}

/// The last-moment checks, then the removal. `Err` is the keep verdict a
/// check turned up; `Ok(None)` means nothing was tried.
fn remove(
    options: &Options,
    family: &Family,
    path: &Path,
    bytes: u64,
) -> Result<Option<Outcome>, Verdict> {
    let inside_root = if family.per_child {
        path.parent() == Some(family.root.as_path())
    } else {
        path == family.root
    };
    if !inside_root || !real_dir(path) {
        return Err(verdict(Action::Keep, "no longer a real folder of its cache"));
    }
    let again = decide(family, last_activity(path), options.pressure, crate::inventory::now_ms());
    if again.action != Action::Reclaim {
        return Err(again);
    }
    match (options.uses)() {
        Ok(processes) => {
            if let Some(process) = procs::inside(&processes, path) {
                return Err(verdict(Action::Keep, format!("in use by pid {}", process.pid)));
            }
        }
        Err(error) => {
            return Err(verdict(Action::Keep, format!("could not check its users: {error}")));
        }
    }
    match (options.open)(path) {
        Ok(Some(pid)) => return Err(verdict(Action::Keep, format!("open in pid {pid}"))),
        Ok(None) => {}
        Err(error) => {
            return Err(verdict(Action::Keep, format!("could not check open files: {error}")));
        }
    }
    Ok(Some(match std::fs::remove_dir_all(path) {
        Ok(()) => Outcome { ok: true, freed: bytes, error: None },
        Err(error) => {
            // A partial removal frees part of it; the rest goes next pass.
            let left = if path.exists() { bytes_of(path).unwrap_or(bytes) } else { 0 };
            Outcome { ok: false, freed: bytes.saturating_sub(left), error: Some(error.to_string()) }
        }
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::procs::Process;
    use crate::store::care_tests::scratch;

    const DAY_MS: u64 = 24 * HOUR_MS;

    fn families(home: &Path) -> Vec<Family> {
        default_families(home)
    }

    fn no_uses() -> Result<Vec<Process>, String> {
        Ok(Vec::new())
    }

    fn not_open(_: &Path) -> Result<Option<u32>, String> {
        Ok(None)
    }

    fn options<'a>(
        home: &Path,
        pressure: Pressure,
        now_ms: u64,
        apply: bool,
        uses: &'a Uses,
        open: &'a Open,
    ) -> Options<'a> {
        Options { families: families(home), pressure, now_ms, apply, uses, open, measure: true }
    }

    fn derived(home: &Path, name: &str) -> PathBuf {
        let path = home.join("Library/Developer/Xcode/DerivedData").join(name);
        std::fs::create_dir_all(path.join("Build/Products")).unwrap();
        std::fs::write(path.join("Build/Products/app.o"), vec![0u8; 4096]).unwrap();
        path
    }

    #[test]
    fn derived_data_waits_shrink_with_pressure() {
        let family = &default_families(Path::new("/h"))[0];
        let now = 30 * DAY_MS;
        let three_days = Some(now - 3 * DAY_MS);
        assert_eq!(decide(family, three_days, Pressure::Normal, now).action, Action::Keep);
        assert_eq!(decide(family, three_days, Pressure::High, now).action, Action::Reclaim);
        assert_eq!(
            decide(family, Some(now - 8 * DAY_MS), Pressure::Normal, now).action,
            Action::Reclaim
        );
        assert_eq!(
            decide(family, Some(now - 6 * HOUR_MS), Pressure::Critical, now).action,
            Action::Keep
        );
        assert_eq!(
            decide(family, Some(now - 13 * HOUR_MS), Pressure::Critical, now).action,
            Action::Reclaim
        );
    }

    #[test]
    fn a_package_cache_goes_only_under_pressure() {
        let npm = &default_families(Path::new("/h"))[2];
        let now = 300 * DAY_MS;
        let old = Some(now - 100 * DAY_MS);
        assert_eq!(decide(npm, old, Pressure::Normal, now).action, Action::Keep);
        assert_eq!(decide(npm, old, Pressure::High, now).action, Action::Reclaim);
        assert_eq!(decide(npm, Some(now - HOUR_MS), Pressure::Critical, now).action, Action::Keep);
    }

    #[test]
    fn unknown_activity_and_future_times_keep() {
        let family = &default_families(Path::new("/h"))[0];
        assert_eq!(decide(family, None, Pressure::Critical, DAY_MS).action, Action::Keep);
        assert_eq!(
            decide(family, Some(10 * DAY_MS), Pressure::Critical, DAY_MS).action,
            Action::Keep
        );
    }

    #[test]
    fn a_report_only_pass_removes_nothing() {
        let home = scratch("caches-report");
        let project = derived(&home, "App-abc");
        let later = crate::inventory::now_ms() + 30 * DAY_MS;
        let report = run(&options(&home, Pressure::Normal, later, false, &no_uses, &not_open));
        assert!(project.exists());
        assert_eq!(report.items.len(), 1);
        assert_eq!(report.items[0].family, "xcode-derived-data");
        assert_eq!(report.items[0].verdict.action, Action::Reclaim);
        assert!(report.reclaimable > 0);
        assert_eq!(report.freed, 0);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn apply_rechecks_the_clock_and_keeps_a_fresh_folder() {
        // The pass is told it is a month later, so the verdict is Reclaim;
        // the check right before removal reads the real clock and keeps it.
        let home = scratch("caches-recheck");
        let project = derived(&home, "App-abc");
        let later = crate::inventory::now_ms() + 30 * DAY_MS;
        let report = run(&options(&home, Pressure::Normal, later, true, &no_uses, &not_open));
        assert!(project.exists());
        assert_eq!(report.items[0].verdict.action, Action::Keep);
        assert_eq!(report.freed, 0);
        let _ = std::fs::remove_dir_all(&home);
    }

    fn age(path: &Path, days: u64) {
        let when = std::time::SystemTime::now() - Duration::from_millis(days * DAY_MS);
        let mut stack = vec![path.to_path_buf()];
        while let Some(dir) = stack.pop() {
            for entry in std::fs::read_dir(&dir).unwrap().flatten() {
                let child = entry.path();
                if std::fs::symlink_metadata(&child).unwrap().is_dir() {
                    stack.push(child.clone());
                }
                let file = std::fs::File::options().read(true).open(&child).unwrap();
                file.set_modified(when).unwrap();
            }
        }
        std::fs::File::open(path).unwrap().set_modified(when).unwrap();
    }

    #[test]
    fn apply_removes_an_idle_project_and_keeps_a_used_one() {
        let home = scratch("caches-apply");
        let idle = derived(&home, "Old-abc");
        let used = derived(&home, "New-def");
        age(&idle, 10);
        let now = crate::inventory::now_ms();
        let report = run(&options(&home, Pressure::Normal, now, true, &no_uses, &not_open));
        assert!(!idle.exists());
        assert!(used.exists());
        assert!(report.freed > 0);
        let gone = report.items.iter().find(|item| item.path == idle).unwrap();
        assert!(gone.outcome.as_ref().unwrap().ok);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn a_held_folder_stays() {
        let home = scratch("caches-held");
        let idle = derived(&home, "Old-abc");
        age(&idle, 10);
        let now = crate::inventory::now_ms();
        let held = idle.clone();
        let uses = move || Ok(vec![Process { pid: 1, cwd: held.join("Build"), session_id: None }]);
        let report = run(&options(&home, Pressure::Normal, now, true, &uses, &not_open));
        assert!(idle.exists());
        assert!(report.items[0].verdict.reason.contains("in use"));
        let open = |_: &Path| Ok(Some(42));
        let report = run(&options(&home, Pressure::Normal, now, true, &no_uses, &open));
        assert!(idle.exists());
        assert!(report.items[0].verdict.reason.contains("open in pid 42"));
        let failing = |_: &Path| Err("lsof: timed out".to_string());
        run(&options(&home, Pressure::Normal, now, true, &no_uses, &failing));
        assert!(idle.exists());
        let _ = std::fs::remove_dir_all(&home);
    }

    #[cfg(unix)]
    #[test]
    fn a_link_is_never_an_entry() {
        let home = scratch("caches-link");
        let elsewhere = scratch("caches-link-target");
        std::fs::write(elsewhere.join("keep"), b"x").unwrap();
        age(&elsewhere, 30);
        let root = home.join("Library/Developer/Xcode/DerivedData");
        std::fs::create_dir_all(&root).unwrap();
        std::os::unix::fs::symlink(&elsewhere, root.join("Linked-abc")).unwrap();
        std::fs::create_dir_all(home.join(".npm")).unwrap();
        std::os::unix::fs::symlink(&elsewhere, home.join(".npm/_cacache")).unwrap();
        let report = run(&options(
            &home,
            Pressure::Critical,
            crate::inventory::now_ms(),
            true,
            &no_uses,
            &not_open,
        ));
        assert!(report.items.is_empty());
        assert!(elsewhere.join("keep").exists());
        let _ = std::fs::remove_dir_all(&home);
        let _ = std::fs::remove_dir_all(&elsewhere);
    }

    #[test]
    fn absent_roots_report_nothing() {
        let home = scratch("caches-absent");
        let report = run(&options(
            &home,
            Pressure::Critical,
            crate::inventory::now_ms(),
            true,
            &no_uses,
            &not_open,
        ));
        assert!(report.items.is_empty());
        let _ = std::fs::remove_dir_all(&home);
    }
}
