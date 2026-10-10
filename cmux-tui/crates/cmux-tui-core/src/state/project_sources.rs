//! The editor project sources (plans/cmux-next/projects.md section 3): a few
//! small files each editor keeps under its application-support folder (never a
//! privacy-protected folder), read into `(source, path, last_used_ms)` for the
//! project store's reducer. A missing or unreadable file reports nothing, so
//! the store never drops a source's projects because a file was mid-write.

mod app_stores;
mod vscode;
mod zed;

use std::path::{Path, PathBuf};

use crate::state::projects::Observation;

pub(crate) use app_stores::{scan_codex_app, scan_conductor, scan_t3code};
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
    /// The user's home folder (`~/.t3`).
    home: PathBuf,
    /// `CODEX_HOME`, else `~/.codex` (the Codex CLI and desktop app share it).
    codex_home: PathBuf,
}

impl Layout {
    pub(crate) fn macos(home: &Path) -> Self {
        let support = home.join("Library").join("Application Support");
        Self::with_home(support.clone(), support, "Zed", home)
    }

    fn with_home(config: PathBuf, data: PathBuf, zed: &'static str, home: &Path) -> Self {
        let codex_home = home.join(".codex");
        Self { config, data, zed, home: home.to_path_buf(), codex_home }
    }

    /// `CODEX_HOME` when set.
    pub(crate) fn with_codex_home(mut self, codex_home: Option<PathBuf>) -> Self {
        if let Some(codex_home) = codex_home {
            self.codex_home = codex_home;
        }
        self
    }

    pub(crate) fn linux(home: &Path, xdg_config: Option<&Path>, xdg_data: Option<&Path>) -> Self {
        Self::with_home(
            xdg_config.map_or_else(|| home.join(".config"), Path::to_path_buf),
            xdg_data.map_or_else(|| home.join(".local").join("share"), Path::to_path_buf),
            "zed",
            home,
        )
    }

    pub(crate) fn windows(home: &Path, roaming: &Path, local: &Path) -> Self {
        Self::with_home(roaming.to_path_buf(), local.to_path_buf(), "Zed", home)
    }

    /// This machine's layout, or none without a home folder.
    pub(crate) fn current() -> Option<Self> {
        let env = |name: &str| {
            std::env::var_os(name).filter(|value| !value.is_empty()).map(PathBuf::from)
        };
        let layout = if cfg!(windows) {
            Self::windows(&env("USERPROFILE")?, &env("APPDATA")?, &env("LOCALAPPDATA")?)
        } else if cfg!(target_os = "macos") {
            Self::macos(&env("HOME")?)
        } else {
            let home = env("HOME")?;
            Self::linux(&home, env("XDG_CONFIG_HOME").as_deref(), env("XDG_DATA_HOME").as_deref())
        };
        Some(layout.with_codex_home(env("CODEX_HOME")))
    }

    pub(crate) fn vscode_user_dir(&self, product: &str) -> PathBuf {
        self.config.join(product).join("User")
    }

    pub(crate) fn codex_global_state(&self) -> PathBuf {
        self.codex_home.join(".codex-global-state.json")
    }

    /// t3code's stores, newest generation first.
    pub(crate) fn t3code_dbs(&self) -> [PathBuf; 2] {
        let userdata = self.home.join(".t3").join("userdata");
        [userdata.join("statev2.sqlite"), userdata.join("state.sqlite")]
    }

    pub(crate) fn conductor_db(&self) -> PathBuf {
        self.config.join("com.conductor.app").join("conductor.db")
    }

    pub(crate) fn zed_db(&self) -> PathBuf {
        self.data.join(self.zed).join("db").join("0-stable").join("db.sqlite")
    }
}

/// Every editor source on this machine (daemon start, `project.sync`).
pub(crate) fn scan_all(layout: &Layout) -> Vec<SourceScan> {
    let mut scans = scan_vscode_family(layout);
    scans.extend(scan_zed(layout));
    scans.extend(scan_codex_app(layout));
    scans.extend(scan_t3code(layout));
    scans.extend(scan_conductor(layout));
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

/// `YYYY-MM-DD HH:MM:SS` or ISO `...T...Z` (UTC, optional fraction) as ms
/// since the epoch.
pub(super) fn utc_ms(text: &str) -> Option<i64> {
    let (date, time) = text.trim().split_once([' ', 'T'])?;
    let mut date = date.split('-').map(str::parse::<i64>);
    let (year, month, day) = (date.next()?.ok()?, date.next()?.ok()?, date.next()?.ok()?);
    let mut time = time.trim_end_matches('Z').split(':');
    let hour: i64 = time.next()?.parse().ok()?;
    let minute: i64 = time.next()?.parse().ok()?;
    let seconds = time.next().unwrap_or("0");
    let (whole, fraction) = seconds.split_once('.').unwrap_or((seconds, ""));
    let second: i64 = whole.parse().ok()?;
    // Milliseconds from the first three fraction digits, padded.
    let millis: i64 = format!("{fraction:0<3}").get(..3)?.parse().ok()?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    // Days from the civil date (Howard Hinnant's algorithm).
    let shifted = if month <= 2 { year - 1 } else { year };
    let era = shifted.div_euclid(400);
    let year_of_era = shifted - era * 400;
    let day_of_year = (153 * ((month + 9) % 12) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days = era * 146_097 + day_of_era - 719_468;
    Some((((days * 24 + hour) * 60 + minute) * 60 + second) * 1000 + millis)
}
