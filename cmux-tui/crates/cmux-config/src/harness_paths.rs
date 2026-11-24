//! The per-person harness folders. macOS imports Classic's profiles on request.
//! Standalone Linux and Windows installations keep their existing native folders.
use std::path::{Path, PathBuf};

/// The destination of an accepted Classic import on a Mac.
pub fn next(config_home: &Path) -> PathBuf {
    config_home.join("cmux-next/harnesses")
}

/// Imported TOML profiles belonging to an isolated NEXT settings file.
pub fn isolated(settings_directory: &Path) -> PathBuf {
    settings_directory.join("classic-harness-files")
}

/// The folder where this host reads and creates profiles.
pub fn user(config_home: &Path) -> PathBuf {
    if cfg!(target_os = "macos") { next(config_home) } else { config_home.join("cmux/harnesses") }
}

/// XDG_CONFIG_HOME when set, otherwise the home directory's .config folder.
pub fn config_home(home: &Path, xdg: Option<&Path>) -> PathBuf {
    xdg.filter(|path| !path.as_os_str().is_empty())
        .map_or_else(|| home.join(".config"), Path::to_path_buf)
}
