//! Whether Conductor was used on this machine. Only paths are checked: the
//! database and the workspaces folder sit outside every privacy-protected
//! folder, and the app is looked for by its bundle path, not by asking
//! Launch Services.

use std::path::{Path, PathBuf};

use serde::Serialize;

/// What was found; empty when Conductor was never used here.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Found {
    /// `~/Library/Application Support/com.conductor.app/conductor.db`.
    pub database: Option<PathBuf>,
    /// `~/conductor/workspaces`, where Conductor makes its worktrees.
    pub workspaces: Option<PathBuf>,
    /// `Conductor.app` in `/Applications` or `~/Applications`.
    pub app: Option<PathBuf>,
}

impl Found {
    pub fn any(&self) -> bool {
        self.database.is_some() || self.workspaces.is_some() || self.app.is_some()
    }
}

/// Conductor's database under `home`.
pub fn database_path(home: &Path) -> PathBuf {
    home.join("Library").join("Application Support").join("com.conductor.app").join("conductor.db")
}

/// Conductor's worktrees folder under `home`.
pub fn workspaces_path(home: &Path) -> PathBuf {
    home.join("conductor").join("workspaces")
}

/// Conductor Cloud's own clones: never a local workspace to adopt.
pub fn cloud_workspaces_path(home: &Path) -> PathBuf {
    home.join("conductor").join("cloud-workspaces")
}

pub fn detect(home: &Path) -> Found {
    detect_with_apps(home, &[PathBuf::from("/Applications"), home.join("Applications")])
}

pub fn detect_with_apps(home: &Path, app_dirs: &[PathBuf]) -> Found {
    let database = Some(database_path(home)).filter(|path| path.is_file());
    let workspaces = Some(workspaces_path(home)).filter(|path| path.is_dir());
    let app = app_dirs.iter().map(|dir| dir.join("Conductor.app")).find(|path| path.is_dir());
    Found { database, workspaces, app }
}
