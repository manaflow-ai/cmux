//! What a Cloud machine should hold before a chat asks: "only what chats use is indeed what i
//! mean. but also what chats could possibly use" (Leo, 2026-11-25).
//!
//! Three pieces, split with cmux-bytes (cmux#56560), which ranks and measures:
//!
//! - [`candidates`]: the set the ranker picks from, each a [`Candidate`] (path, likelihood, size,
//!   reason): every folder selected for a chat in full, recently active folders and repos, repos
//!   the GitHub grant covers that were touched in the last [`Tuning::grant_within`], and the
//!   toolchain and dependency caches those need.
//! - cold-tier aging (`overlay::content::Content::age`): bytes nobody reads go cold, then are
//!   deleted unless pinned.
//! - [`held`]: one logical-bytes number for the person or team the machine belongs to: every
//!   blob its projections hold, counted once by hash however many chats share it.

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// Why a path is a candidate.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Reason {
    /// A folder selected for a chat: held in full.
    Selected,
    /// A folder a chat ran in lately.
    RecentFolder,
    /// A repo a chat ran in lately.
    RecentRepo,
    /// A repo the GitHub grant covers, pushed to lately.
    GrantRepo,
    /// A toolchain or dependency cache a candidate above builds with.
    Toolchain,
}

/// One path the machine could hold, as the ranker (cmux-bytes) consumes it.
#[derive(Clone, Debug, PartialEq, serde::Serialize)]
pub struct Candidate {
    /// A folder on the Mac or machine, or `github.com/OWNER/REPO` for a grant repo not on disk.
    pub path: String,
    /// How likely a chat reads it soon, 0 to 1.
    pub likelihood: f32,
    /// Its bytes (a grant repo's as GitHub sizes it).
    pub size: u64,
    pub reason: Reason,
}

/// A folder or repo a chat was active in.
#[derive(Clone, Debug)]
pub struct Recent {
    pub path: PathBuf,
    pub at: SystemTime,
    pub repo: bool,
}

/// A repo the GitHub grant covers.
#[derive(Clone, Debug)]
pub struct GrantRepo {
    /// `OWNER/REPO`.
    pub name: String,
    pub pushed_at: SystemTime,
    pub size: u64,
    /// The file names at its root (the toolchain markers: `Cargo.toml`, `package.json`, ...).
    pub root_files: Vec<String>,
}

/// What the candidates are built from.
#[derive(Clone, Debug, Default)]
pub struct Inputs {
    pub selected: Vec<PathBuf>,
    pub recent: Vec<Recent>,
    pub grant: Vec<GrantRepo>,
    /// The home folder the toolchain caches live under.
    pub home: PathBuf,
}

/// The likelihood curve.
#[derive(Clone, Copy, Debug)]
pub struct Tuning {
    /// A recent folder's likelihood halves every `recent_half_life`.
    pub recent_half_life: Duration,
    /// How far back a grant repo's last push counts.
    pub grant_within: Duration,
    /// A grant repo's likelihood when pushed just now (decaying as a recent one does).
    pub grant_weight: f32,
    /// A recent folder or repo's likelihood when active just now.
    pub recent_weight: f32,
}

impl Default for Tuning {
    fn default() -> Self {
        Self {
            recent_half_life: Duration::from_secs(3 * 24 * 60 * 60),
            grant_within: Duration::from_secs(14 * 24 * 60 * 60),
            grant_weight: 0.5,
            recent_weight: 0.9,
        }
    }
}

/// Reads sizes and markers; the disk ([`Disk`]) in the daemon, a table in tests.
pub trait Probe {
    /// The bytes under `path`, `None` when it is not there.
    fn size(&self, path: &Path) -> Option<u64>;
    fn exists(&self, path: &Path) -> bool;
}

/// The local disk, each size bounded to [`Disk::max_entries`] entries.
#[derive(Clone, Copy, Debug)]
pub struct Disk {
    pub max_entries: usize,
}

impl Default for Disk {
    fn default() -> Self {
        Self { max_entries: 200_000 }
    }
}

impl Probe for Disk {
    fn size(&self, path: &Path) -> Option<u64> {
        let meta = fs::symlink_metadata(path).ok()?;
        if !meta.is_dir() {
            return Some(meta.len());
        }
        let (mut bytes, mut seen, mut stack) = (0, 0, vec![path.to_path_buf()]);
        while let Some(dir) = stack.pop() {
            for entry in fs::read_dir(&dir).into_iter().flatten().filter_map(Result::ok) {
                seen += 1;
                if seen > self.max_entries {
                    return Some(bytes);
                }
                let Ok(meta) = entry.metadata() else { continue };
                if meta.is_dir() {
                    stack.push(entry.path());
                } else {
                    bytes += meta.len();
                }
            }
        }
        Some(bytes)
    }

    fn exists(&self, path: &Path) -> bool {
        path.exists()
    }
}

/// The caches a folder with `marker` at its root builds with, under `home`.
pub fn toolchain_caches(marker: &str, home: &Path) -> Vec<PathBuf> {
    let under = |parts: &[&str]| parts.iter().fold(home.to_path_buf(), |at, part| at.join(part));
    match marker {
        "Cargo.toml" => vec![under(&[".cargo", "registry"]), under(&[".rustup", "toolchains"])],
        "package.json" => vec![under(&[".npm", "_cacache"]), under(&[".bun", "install", "cache"])],
        "pnpm-lock.yaml" => vec![under(&[".local", "share", "pnpm", "store"])],
        "go.mod" => vec![under(&["go", "pkg", "mod"])],
        "pyproject.toml" | "requirements.txt" | "uv.lock" => {
            vec![under(&[".cache", "pip"]), under(&[".cache", "uv"])]
        }
        "Package.swift" => vec![under(&[".swiftpm"])],
        "Gemfile" => vec![under(&[".gem"])],
        _ => Vec::new(),
    }
}

/// The markers [`toolchain_caches`] knows.
pub const MARKERS: &[&str] = &[
    "Cargo.toml",
    "package.json",
    "pnpm-lock.yaml",
    "go.mod",
    "pyproject.toml",
    "requirements.txt",
    "uv.lock",
    "Package.swift",
    "Gemfile",
];

fn decay(weight: f32, at: SystemTime, now: SystemTime, half_life: Duration) -> f32 {
    let age = now.duration_since(at).unwrap_or_default().as_secs_f64();
    let halves = age / half_life.as_secs_f64().max(1.0);
    (f64::from(weight) * 0.5f64.powf(halves)) as f32
}

/// The candidate set, most likely first (then smallest): one row per path, at its highest
/// likelihood; a path under a selected folder is left out (the folder covers it).
pub fn candidates(
    inputs: &Inputs,
    now: SystemTime,
    tuning: &Tuning,
    probe: &dyn Probe,
) -> Vec<Candidate> {
    let mut rows: BTreeMap<String, Candidate> = BTreeMap::new();
    let mut needs: HashMap<PathBuf, f32> = HashMap::new();
    fn add(rows: &mut BTreeMap<String, Candidate>, row: Candidate) {
        if rows.get(&row.path).is_none_or(|have| have.likelihood < row.likelihood) {
            rows.insert(row.path.clone(), row);
        }
    }
    let mut local =
        |rows: &mut BTreeMap<String, Candidate>, path: &Path, likelihood: f32, reason| {
            let Some(size) = probe.size(path) else { return };
            for marker in MARKERS {
                if probe.exists(&path.join(marker)) {
                    for cache in toolchain_caches(marker, &inputs.home) {
                        let need = needs.entry(cache).or_default();
                        *need = need.max(likelihood);
                    }
                }
            }
            add(rows, Candidate { path: path.display().to_string(), likelihood, size, reason });
        };
    for path in &inputs.selected {
        local(&mut rows, path, 1.0, Reason::Selected);
    }
    for recent in &inputs.recent {
        let likelihood = decay(tuning.recent_weight, recent.at, now, tuning.recent_half_life);
        let reason = if recent.repo { Reason::RecentRepo } else { Reason::RecentFolder };
        local(&mut rows, &recent.path, likelihood, reason);
    }
    let since = now.checked_sub(tuning.grant_within).unwrap_or(SystemTime::UNIX_EPOCH);
    for repo in inputs.grant.iter().filter(|repo| repo.pushed_at >= since) {
        let likelihood = decay(tuning.grant_weight, repo.pushed_at, now, tuning.recent_half_life);
        for marker in &repo.root_files {
            for cache in toolchain_caches(marker, &inputs.home) {
                let need = needs.entry(cache).or_default();
                *need = need.max(likelihood);
            }
        }
        let path = format!("github.com/{}", repo.name);
        add(&mut rows, Candidate { path, likelihood, size: repo.size, reason: Reason::GrantRepo });
    }
    for (cache, likelihood) in needs {
        let Some(size) = probe.size(&cache) else { continue };
        let path = cache.display().to_string();
        add(&mut rows, Candidate { path, likelihood, size, reason: Reason::Toolchain });
    }
    let selected: Vec<String> =
        inputs.selected.iter().map(|path| format!("{}/", path.display())).collect();
    let mut out: Vec<Candidate> = rows
        .into_values()
        .filter(|row| {
            row.reason == Reason::Selected || !selected.iter().any(|s| row.path.starts_with(s))
        })
        .collect();
    out.sort_by(|a, b| b.likelihood.total_cmp(&a.likelihood).then(a.size.cmp(&b.size)));
    out
}

/// What the machine's projections hold, for its person or team.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize)]
pub struct Held {
    /// Each distinct blob's bytes once, hot or cold: what the chats can read without a fetch.
    pub logical_bytes: u64,
    /// The disk the blobs take: hot bytes, plus cold files as compressed.
    pub stored_bytes: u64,
    /// Bytes held more than once (the same blob in two projections' stores).
    pub duplicate_bytes: u64,
    pub blobs: u64,
    pub cold_blobs: u64,
    pub projections: u64,
}

impl Held {
    /// A team's number: its machines' numbers added (blobs on two machines count twice; each
    /// machine holds its own copy).
    #[must_use]
    pub fn merge(self, other: Self) -> Self {
        Self {
            logical_bytes: self.logical_bytes + other.logical_bytes,
            stored_bytes: self.stored_bytes + other.stored_bytes,
            duplicate_bytes: self.duplicate_bytes + other.duplicate_bytes,
            blobs: self.blobs + other.blobs,
            cold_blobs: self.cold_blobs + other.cold_blobs,
            projections: self.projections + other.projections,
        }
    }
}

/// [`Held`] of every projection's content store under `projections` (the daemon's
/// `projections/`: `<name>/content/{blobs,cold}`), read from file names and sizes alone.
pub fn held(projections: &Path) -> Held {
    use crate::overlay::content::{parse_cold, unhex};
    let mut seen = std::collections::HashSet::new();
    let mut out = Held::default();
    for state in fs::read_dir(projections).into_iter().flatten().filter_map(Result::ok) {
        let content = state.path().join("content");
        if !content.is_dir() {
            continue;
        }
        out.projections += 1;
        for (tier, cold) in [("blobs", false), ("cold", true)] {
            for entry in
                fs::read_dir(content.join(tier)).into_iter().flatten().filter_map(Result::ok)
            {
                let name = entry.file_name();
                let Some(name) = name.to_str() else { continue };
                let parsed =
                    if cold { parse_cold(name) } else { unhex(name).map(|hash| (hash, u64::MAX)) };
                let Some((hash, bytes)) = parsed else { continue };
                let Ok(meta) = entry.metadata() else { continue };
                let bytes = if cold { bytes } else { meta.len() };
                out.stored_bytes += meta.len();
                out.blobs += 1;
                out.cold_blobs += u64::from(cold);
                if seen.insert(hash) {
                    out.logical_bytes += bytes;
                } else {
                    out.duplicate_bytes += bytes;
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Table(HashMap<PathBuf, u64>);

    impl Probe for Table {
        fn size(&self, path: &Path) -> Option<u64> {
            self.0.get(path).copied()
        }

        fn exists(&self, path: &Path) -> bool {
            self.0.contains_key(path)
        }
    }

    const DAY: Duration = Duration::from_secs(24 * 60 * 60);

    #[test]
    fn every_source_lands_with_its_reason_most_likely_first() {
        let now = SystemTime::now();
        let home = PathBuf::from("/home/me");
        let probe = Table(
            [
                ("/w/app", 500),
                ("/w/app/Cargo.toml", 1),
                ("/w/app/sub", 10),
                ("/w/old", 300),
                ("/w/web", 200),
                ("/w/web/package.json", 1),
                ("/home/me/.cargo/registry", 9000),
                ("/home/me/.npm/_cacache", 4000),
            ]
            .into_iter()
            .map(|(path, size)| (PathBuf::from(path), size))
            .collect(),
        );
        let inputs = Inputs {
            selected: vec!["/w/app".into()],
            recent: vec![
                Recent { path: "/w/web".into(), at: now - DAY, repo: true },
                Recent { path: "/w/old".into(), at: now - 9 * DAY, repo: false },
                Recent { path: "/w/app/sub".into(), at: now, repo: false },
            ],
            grant: vec![
                GrantRepo {
                    name: "o/fresh".into(),
                    pushed_at: now - 2 * DAY,
                    size: 70,
                    root_files: vec!["go.mod".into()],
                },
                GrantRepo {
                    name: "o/stale".into(),
                    pushed_at: now - 40 * DAY,
                    size: 1,
                    root_files: vec![],
                },
            ],
            home,
        };
        let rows = candidates(&inputs, now, &Tuning::default(), &probe);
        let got: Vec<(&str, Reason)> =
            rows.iter().map(|row| (row.path.as_str(), row.reason)).collect();
        assert_eq!(
            got,
            [
                ("/w/app", Reason::Selected),
                ("/home/me/.cargo/registry", Reason::Toolchain),
                ("/w/web", Reason::RecentRepo),
                ("/home/me/.npm/_cacache", Reason::Toolchain),
                ("github.com/o/fresh", Reason::GrantRepo),
                ("/w/old", Reason::RecentFolder),
            ]
        );
        assert!((rows[0].likelihood - 1.0).abs() < f32::EPSILON);
        assert_eq!(rows[0].size, 500);
        // Half-life three days: a day-old repo at 0.9 * 2^(-1/3).
        assert!((rows[2].likelihood - 0.714).abs() < 0.01, "{}", rows[2].likelihood);
        assert!(rows.windows(2).all(|w| w[0].likelihood >= w[1].likelihood));
    }

    #[test]
    fn logical_bytes_count_a_shared_blob_once() {
        let dir = tempfile::tempdir().unwrap();
        let hash = "ab".repeat(32);
        let other = "cd".repeat(32);
        for (name, files) in [("p1", vec![&hash, &other]), ("p2", vec![&hash])] {
            let blobs = dir.path().join(name).join("content/blobs");
            fs::create_dir_all(&blobs).unwrap();
            for file in files {
                fs::write(blobs.join(file), [0u8; 100]).unwrap();
            }
        }
        let cold = dir.path().join("p2/content/cold");
        fs::create_dir_all(&cold).unwrap();
        fs::write(cold.join(format!("{}-5000.zst", "ef".repeat(32))), [0u8; 40]).unwrap();
        let held = held(dir.path());
        assert_eq!(held.logical_bytes, 100 + 100 + 5000);
        assert_eq!(held.duplicate_bytes, 100);
        assert_eq!(held.stored_bytes, 300 + 40);
        assert_eq!((held.blobs, held.cold_blobs, held.projections), (4, 1, 2));
    }
}
