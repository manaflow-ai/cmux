//! The version store: `<state root>/apps/<slug>/state.json`, and each version's staged
//! directory `<state root>/apps/<slug>/v<n>/` (`src.tar`, the archive this machine's agent
//! copies, and `src/`, the tree it came from). The version runs from the agent's copy.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::io::Fs;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum VersionState {
    Starting,
    /// Probed, and promoted with no answer back: the next `versions` or `ls` settles it from
    /// the platform's own record. Its process keeps running.
    Pending,
    Live,
    Failed,
    Retired,
}

impl VersionState {
    /// The state as `state.json` and `--json` spell it.
    pub fn word(self) -> &'static str {
        match self {
            VersionState::Starting => "starting",
            VersionState::Pending => "pending",
            VersionState::Live => "live",
            VersionState::Failed => "failed",
            VersionState::Retired => "retired",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Version {
    /// Numbered from 1 per app on this machine; also the directory `v<n>`.
    pub n: u32,
    /// The platform's number for this version once it accepted it (a version that failed
    /// before the promote has none, so the two numberings can differ).
    #[serde(default)]
    pub platform_n: Option<u32>,
    pub commit: String,
    pub command: String,
    /// The directory the command runs in, relative to the repository's top level.
    pub path: String,
    pub port: u16,
    #[serde(default)]
    pub pid: Option<u32>,
    /// The process's start time (`/proc/<pid>/stat` field 22): a pid with another start
    /// time is another process.
    #[serde(default)]
    pub start_time: Option<u64>,
    /// The agent's run directory of this version (owned by the app user), with `app.log`.
    #[serde(default)]
    pub run_dir: Option<PathBuf>,
    /// The user the process runs as.
    #[serde(default)]
    pub run_as: Option<String>,
    pub state: VersionState,
    #[serde(default)]
    pub error: Option<String>,
    /// The last 64 KiB of the version's log, kept when it failed.
    #[serde(default)]
    pub log_tail: Option<String>,
    pub created_at_ms: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppState {
    pub name: String,
    pub slug: String,
    #[serde(default)]
    pub url: Option<String>,
    /// The local number of the live version.
    #[serde(default)]
    pub live: Option<u32>,
    #[serde(default)]
    pub versions: Vec<Version>,
}

impl AppState {
    pub fn new(name: &str, slug: &str) -> AppState {
        AppState {
            name: name.to_owned(),
            slug: slug.to_owned(),
            url: None,
            live: None,
            versions: vec![],
        }
    }

    pub fn next_n(&self) -> u32 {
        self.versions.iter().map(|v| v.n).max().unwrap_or(0).saturating_add(1)
    }

    pub fn version(&self, n: u32) -> Option<&Version> {
        self.versions.iter().find(|v| v.n == n)
    }

    pub fn version_mut(&mut self, n: u32) -> Option<&mut Version> {
        self.versions.iter_mut().find(|v| v.n == n)
    }

    /// Writes `version` over the one with its number, or adds it.
    pub fn put(&mut self, version: Version) {
        match self.version_mut(version.n) {
            Some(slot) => *slot = version,
            None => self.versions.push(version),
        }
    }

    /// `live` moves to `n`; the version that was live is retired (its process keeps running).
    pub fn make_live(&mut self, n: u32, url: &str) {
        for v in &mut self.versions {
            if v.state == VersionState::Live && v.n != n {
                v.state = VersionState::Retired;
            }
        }
        if let Some(v) = self.version_mut(n) {
            v.state = VersionState::Live;
            v.error = None;
        }
        self.live = Some(n);
        self.url = Some(url.to_owned());
    }

    /// Versions, newest first.
    pub fn newest_first(&self) -> Vec<&Version> {
        let mut out: Vec<&Version> = self.versions.iter().collect();
        out.sort_by_key(|v| std::cmp::Reverse(v.n));
        out
    }
}

/// An app's spec in a source tree, `.cmux/apps/<slug>/app.json`: part of the repository, not
/// state of this machine.
pub fn spec_file(tree: &Path, slug: &str) -> PathBuf {
    tree.join(".cmux/apps").join(slug).join("app.json")
}

/// `root` is the apps store: `apps` under cmux's state root (the binary resolves it).
pub fn app_dir(root: &Path, slug: &str) -> PathBuf {
    root.join(slug)
}

pub fn version_dir(root: &Path, slug: &str, n: u32) -> PathBuf {
    app_dir(root, slug).join(format!("v{n}"))
}

fn state_file(root: &Path, slug: &str) -> PathBuf {
    app_dir(root, slug).join("state.json")
}

/// The app's state, `None` when it was never published here.
pub fn load(fs: &dyn Fs, root: &Path, slug: &str) -> Result<Option<AppState>, String> {
    let path = state_file(root, slug);
    match fs.read(&path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|e| format!("{} is not an app state: {e}", path.display())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(format!("cannot read {}: {e}", path.display())),
    }
}

pub fn save(fs: &dyn Fs, root: &Path, state: &AppState) -> Result<(), String> {
    let path = state_file(root, &state.slug);
    let mut text = serde_json::to_vec_pretty(state).map_err(|e| e.to_string())?;
    text.push(b'\n');
    fs.write(&path, &text).map_err(|e| format!("cannot write {}: {e}", path.display()))
}

/// Every app published on this machine, by slug.
pub fn list(fs: &dyn Fs, root: &Path) -> Result<Vec<AppState>, String> {
    let mut names = match fs.list(root) {
        Ok(names) => names,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
        Err(e) => return Err(format!("cannot list {}: {e}", root.display())),
    };
    names.sort();
    let mut out = vec![];
    for name in names {
        if let Some(state) = load(fs, root, &name)? {
            out.push(state);
        }
    }
    Ok(out)
}

/// The last `max` bytes of `path`, as text; empty when it cannot be read.
pub fn tail(fs: &dyn Fs, path: &Path, max: usize) -> String {
    let bytes = fs.read(path).unwrap_or_default();
    let start = bytes.len().saturating_sub(max);
    String::from_utf8_lossy(bytes.get(start..).unwrap_or_default()).into_owned()
}
