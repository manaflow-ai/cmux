//! The editor project sources (plans/cmux-next/projects.md section 3): a few
//! small files each editor keeps under its application-support folder (never a
//! privacy-protected folder), read into `(source, path, last_used_ms)` for the
//! project store's reducer. A missing or unreadable file reports nothing, so
//! the store never drops a source's projects because a file was mid-write.

mod vscode;
mod zed;

#[cfg(test)]
mod tests;

use std::path::{Path, PathBuf};

use crate::state::projects::Observation;

pub(crate) use vscode::scan_vscode_family;
pub(crate) use zed::scan_zed;

/// Everything one source currently lists (`project.observe` with `complete`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SourceScan {
    pub source: &'static str,
    pub entries: Vec<Observation>,
}

/// Where the editors keep their state on one OS.
#[derive(Clone, Debug)]
pub(crate) struct Layout {
    /// VS Code family root (`<root>/<product>/User`).
    config: PathBuf,
    /// Zed's data root (`<root>/<zed>/db/0-stable/db.sqlite`).
    data: PathBuf,
    zed: &'static str,
}

impl Layout {
    pub(crate) fn macos(home: &Path) -> Self {
        let support = home.join("Library").join("Application Support");
        Self { config: support.clone(), data: support, zed: "Zed" }
    }

    pub(crate) fn linux(home: &Path, xdg_config: Option<&Path>, xdg_data: Option<&Path>) -> Self {
        Self {
            config: xdg_config.map_or_else(|| home.join(".config"), Path::to_path_buf),
            data: xdg_data.map_or_else(|| home.join(".local").join("share"), Path::to_path_buf),
            zed: "zed",
        }
    }

    pub(crate) fn windows(roaming: &Path, local: &Path) -> Self {
        Self { config: roaming.to_path_buf(), data: local.to_path_buf(), zed: "Zed" }
    }

    /// This machine's layout, or none without a home folder.
    pub(crate) fn current() -> Option<Self> {
        let env = |name: &str| {
            std::env::var_os(name).filter(|value| !value.is_empty()).map(PathBuf::from)
        };
        if cfg!(windows) {
            return Some(Self::windows(&env("APPDATA")?, &env("LOCALAPPDATA")?));
        }
        let home = env("HOME")?;
        if cfg!(target_os = "macos") {
            return Some(Self::macos(&home));
        }
        Some(Self::linux(&home, env("XDG_CONFIG_HOME").as_deref(), env("XDG_DATA_HOME").as_deref()))
    }

    pub(crate) fn vscode_user_dir(&self, product: &str) -> PathBuf {
        self.config.join(product).join("User")
    }

    pub(crate) fn zed_db(&self) -> PathBuf {
        self.data.join(self.zed).join("db").join("0-stable").join("db.sqlite")
    }
}

/// Every editor source on this machine (daemon start, `project.sync`).
pub(crate) fn scan_all(layout: &Layout) -> Vec<SourceScan> {
    let mut scans = scan_vscode_family(layout);
    scans.extend(scan_zed(layout));
    scans
}

/// A file's modification time in ms since the epoch.
fn modified_ms(path: &Path) -> Option<i64> {
    let modified = std::fs::metadata(path).ok()?.modified().ok()?;
    let elapsed = modified.duration_since(std::time::UNIX_EPOCH).ok()?;
    i64::try_from(elapsed.as_millis()).ok()
}

/// Opens an editor's database read-only, never creating or locking it for
/// the editor (`immutable` would miss its WAL; read-only shares it).
fn open_read_only(path: &Path) -> Option<rusqlite::Connection> {
    if !path.is_file() {
        return None;
    }
    let flags =
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let connection = rusqlite::Connection::open_with_flags(path, flags).ok()?;
    connection.busy_timeout(std::time::Duration::from_millis(200)).ok()?;
    Some(connection)
}
