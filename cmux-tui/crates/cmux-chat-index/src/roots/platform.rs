//! Default store dirs per harness and platform (macOS, Linux, Windows), and
//! the env vars that move them. Table-driven: one function per harness that
//! returns candidates in priority order (env overrides first). Every path is
//! built from the injected home and env, never from the process, so a Linux
//! host can test the Windows table.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::RootSource;
use crate::entry::AdapterKind;

/// The OS whose layout the default dirs follow.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Platform {
    MacOs,
    Linux,
    Windows,
}

impl Platform {
    pub const ALL: [Self; 3] = [Self::MacOs, Self::Linux, Self::Windows];

    /// The platform this binary was built for (other Unixes use Linux's layout).
    pub const fn current() -> Self {
        if cfg!(windows) {
            Self::Windows
        } else if cfg!(target_os = "macos") {
            Self::MacOs
        } else {
            Self::Linux
        }
    }
}

/// The base dirs a harness resolves its store from.
pub(crate) struct Bases<'a> {
    pub platform: Platform,
    pub home: &'a Path,
    env: &'a dyn Fn(&str) -> Option<String>,
    /// The caller's guarded-folder check, run before any index file is read.
    refuse: &'a dyn Fn(&Path) -> Option<String>,
}

impl<'a> Bases<'a> {
    pub fn new(
        platform: Platform,
        home: &'a Path,
        env: &'a dyn Fn(&str) -> Option<String>,
        refuse: &'a dyn Fn(&Path) -> Option<String>,
    ) -> Self {
        Self { platform, home, env, refuse }
    }

    /// True when `dir` may be read (it is not inside a guarded folder).
    pub fn readable(&self, dir: &Path) -> bool {
        (self.refuse)(dir).is_none()
    }

    /// A non-empty absolute env value as a path.
    pub fn var(&self, key: &str) -> Option<PathBuf> {
        (self.env)(key)
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .filter(|path| path.is_absolute())
    }

    pub fn home(&self, rel: &str) -> PathBuf {
        join(self.home, rel)
    }

    /// `$XDG_DATA_HOME` when set, else `~/.local/share`. Node's xdg-basedir
    /// and most Go/Python ports use this on every platform, Windows included.
    pub fn xdg_data(&self) -> PathBuf {
        self.var("XDG_DATA_HOME").unwrap_or_else(|| self.home(".local/share"))
    }

    /// `$XDG_CONFIG_HOME` when set, else `~/.config`.
    pub fn xdg_config(&self) -> PathBuf {
        self.var("XDG_CONFIG_HOME").unwrap_or_else(|| self.home(".config"))
    }

    /// Windows roaming app data (`%APPDATA%`, else `~\AppData\Roaming`).
    pub fn appdata(&self) -> PathBuf {
        self.var("APPDATA").unwrap_or_else(|| self.home("AppData/Roaming"))
    }

    /// Windows local app data (`%LOCALAPPDATA%`, else `~\AppData\Local`).
    pub fn local_appdata(&self) -> PathBuf {
        self.var("LOCALAPPDATA").unwrap_or_else(|| self.home("AppData/Local"))
    }

    /// Pi's `sessionDir` setting in `<agent dir>/settings.json` (v0.63.0+),
    /// absolute or `~/`-relative.
    pub fn pi_settings_session_dir(&self, agent_dir: PathBuf) -> Option<PathBuf> {
        if !self.readable(&agent_dir) {
            return None;
        }
        let settings: serde_json::Value =
            crate::store_file::read_json_bounded(&agent_dir.join("settings.json"), 1 << 20)?;
        let dir = settings.get("sessionDir")?.as_str()?.trim();
        if let Some(rest) = dir.strip_prefix("~/").or_else(|| dir.strip_prefix("~\\")) {
            return Some(join(self.home, &rest.replace('\\', "/")));
        }
        Some(PathBuf::from(dir)).filter(|path| path.is_absolute())
    }

    /// The OS config dir (`os.UserConfigDir`, `dirs::config_dir`):
    /// `~/Library/Application Support`, `$XDG_CONFIG_HOME`, `%APPDATA%`.
    pub fn os_config(&self) -> PathBuf {
        match self.platform {
            Platform::MacOs => self.home("Library/Application Support"),
            Platform::Linux => self.xdg_config(),
            Platform::Windows => self.appdata(),
        }
    }
}

/// Joins `/`-separated segments one by one, so the result uses the host's
/// separator and stays comparable with paths the host builds.
pub(crate) fn join(base: &Path, rel: &str) -> PathBuf {
    rel.split('/')
        .filter(|part| !part.is_empty())
        .fold(base.to_path_buf(), |path, part| path.join(part))
}

/// The candidate store roots of one harness, env overrides first.
pub fn default_roots(
    kind: AdapterKind,
    platform: Platform,
    home: &Path,
    env: &dyn Fn(&str) -> Option<String>,
) -> Vec<(PathBuf, RootSource)> {
    guarded_roots(kind, platform, home, env, &|_| None)
}

/// `default_roots` that reads no index file (Pi settings, Crush projects)
/// inside a folder `refuse` guards.
pub(crate) fn guarded_roots(
    kind: AdapterKind,
    platform: Platform,
    home: &Path,
    env: &dyn Fn(&str) -> Option<String>,
    refuse: &dyn Fn(&Path) -> Option<String>,
) -> Vec<(PathBuf, RootSource)> {
    let b = Bases::new(platform, home, env, refuse);
    let mut out: Vec<(PathBuf, RootSource)> = Vec::new();
    {
        let mut add = |path: Option<PathBuf>, source: RootSource| {
            if let Some(path) = path.filter(|path| path.is_absolute())
                && !out.iter().any(|(known, _)| known == &path)
            {
                out.push((path, source));
            }
        };
        super::table::roots(kind, &b, &mut add);
    }
    out
}
