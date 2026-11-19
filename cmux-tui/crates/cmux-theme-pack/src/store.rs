//! Packs on disk: where they install, the history, and writing a step's
//! theme file. Picking the theme file (`appearance.themeFile`) is a settings
//! write the caller makes through the daemon, as `cmux theme use` does; the
//! running app then repaints from the file it already watches.

use std::path::{Path, PathBuf};

use cmux_config::theme_file;
use serde_json::{Map, Value};

use crate::history::{Generation, History, Step};
use crate::load::{self, Context, LoadError, Pack, PackDiagnostic};

/// The folder beside cmux-next.json that holds installed packs.
pub const FOLDER_NAME: &str = "packs";
const HISTORY_FILE: &str = ".history.json";

pub struct Store {
    config_dir: PathBuf,
}

/// Why a store operation did nothing.
#[derive(Debug)]
pub enum StoreError {
    Load(LoadError),
    Io(std::io::Error),
    /// `edit` with no pack applied.
    NothingApplied,
    /// `edit` of a value the pack may not set: nothing changed, no undo step.
    Refused(Vec<PackDiagnostic>),
    /// Undo or redo with nowhere to go.
    NothingToUndo,
    NothingToRedo,
}

impl std::fmt::Display for StoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StoreError::Load(error) => error.fmt(f),
            StoreError::Io(error) => error.fmt(f),
            StoreError::NothingApplied => {
                f.write_str("no pack is applied: `cmux pack use DIR` applies one")
            }
            StoreError::Refused(diagnostics) => {
                let lines: Vec<String> = diagnostics.iter().map(PackDiagnostic::display).collect();
                write!(f, "not applied: {}", lines.join("; "))
            }
            StoreError::NothingToUndo => f.write_str("nothing to undo"),
            StoreError::NothingToRedo => f.write_str("nothing to redo"),
        }
    }
}

impl std::error::Error for StoreError {}

impl From<std::io::Error> for StoreError {
    fn from(error: std::io::Error) -> Self {
        StoreError::Io(error)
    }
}

impl From<LoadError> for StoreError {
    fn from(error: LoadError) -> Self {
        StoreError::Load(error)
    }
}

impl Store {
    pub fn new(config_dir: &Path) -> Store {
        Store { config_dir: config_dir.to_path_buf() }
    }

    pub fn folder(&self) -> PathBuf {
        self.config_dir.join(FOLDER_NAME)
    }

    fn history_path(&self) -> PathBuf {
        self.folder().join(HISTORY_FILE)
    }

    pub fn history(&self) -> History {
        History::read(&self.history_path())
    }

    /// The folder `spec` names: a path to a pack folder, else an installed
    /// pack's folder name.
    pub fn resolve(&self, spec: &str) -> PathBuf {
        let path = PathBuf::from(spec);
        if path.join(load::MANIFEST).exists() || spec.contains('/') || spec.starts_with('.') {
            return path;
        }
        self.folder().join(spec)
    }

    /// Reads the pack in `dir` and makes it the applied generation. With
    /// `live`, it replaces the applied generation of the same pack instead of
    /// adding an undo step (saving a pack being worked on).
    pub fn apply(
        &self,
        dir: &Path,
        in_use: Option<String>,
        live: bool,
        context: &Context<'_>,
    ) -> Result<(Pack, Step), StoreError> {
        let dir = std::path::absolute(dir)?;
        let dir = dir.as_path();
        let mut history = self.history();
        let edits = match history.current() {
            Some(current) if live && current.dir == dir => current.edits.clone(),
            _ => Map::new(),
        };
        let pack = load::load(dir, &edits, context)?;
        let generation = generation(&pack, edits);
        let step = if live {
            history.replace(generation, in_use)
        } else {
            history.push(generation, in_use)
        };
        self.write_step(&step)?;
        history.write(&self.history_path())?;
        self.prune(&history);
        Ok((pack, step))
    }

    /// Sets one look value over the applied pack, as one undo step. The value
    /// passes the same capability and schema checks as the pack's own.
    pub fn edit(
        &self,
        key: &str,
        value: Value,
        context: &Context<'_>,
    ) -> Result<(Pack, Step), StoreError> {
        let mut history = self.history();
        let current = history
            .current()
            .filter(|current| !current.is_off())
            .cloned()
            .ok_or(StoreError::NothingApplied)?;
        let mut edits = current.edits.clone();
        edits.insert(key.to_string(), value);
        let pack = load::load(&current.dir, &edits, context)?;
        let refused: Vec<PackDiagnostic> =
            pack.diagnostics.iter().filter(|d| d.key.as_deref() == Some(key)).cloned().collect();
        if !refused.is_empty() {
            return Err(StoreError::Refused(refused));
        }
        let step = history.push(generation(&pack, edits), Some(current.theme));
        self.write_step(&step)?;
        history.write(&self.history_path())?;
        self.prune(&history);
        Ok((pack, step))
    }

    pub fn undo(&self) -> Result<Step, StoreError> {
        self.move_cursor(History::undo, StoreError::NothingToUndo)
    }

    pub fn redo(&self) -> Result<Step, StoreError> {
        self.move_cursor(History::redo, StoreError::NothingToRedo)
    }

    pub fn off(&self) -> Result<Step, StoreError> {
        self.move_cursor(History::off, StoreError::NothingApplied)
    }

    fn move_cursor(
        &self,
        motion: impl FnOnce(&mut History) -> Option<Step>,
        none: StoreError,
    ) -> Result<Step, StoreError> {
        let mut history = self.history();
        let step = motion(&mut history).ok_or(none)?;
        self.write_step(&step)?;
        history.write(&self.history_path())?;
        self.prune(&history);
        Ok(step)
    }

    /// Writes a step's theme file (atomically: the app never reads half a pack).
    pub fn write_step(&self, step: &Step) -> std::io::Result<()> {
        if let Step::Apply { theme, text } = step {
            replace(&theme_file::path(&self.config_dir, theme), text.as_bytes())?;
        }
        Ok(())
    }

    /// Removes compiled pack files no generation in `history` names, so the
    /// themes folder holds at most one file per kept generation.
    fn prune(&self, history: &History) {
        let Ok(entries) = std::fs::read_dir(theme_file::folder(&self.config_dir)) else { return };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let Some(stem) = name.strip_suffix(".json") else { continue };
            if stem.starts_with("pack-") && !history.generations.iter().any(|g| g.theme == stem) {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
}

fn generation(pack: &Pack, edits: Map<String, Value>) -> Generation {
    Generation {
        pack: pack.id.clone(),
        dir: pack.dir.clone(),
        theme: generation_name(pack),
        text: pack.theme_text(),
        edits,
    }
}

/// `pack-OWNER-NAME-HASH`: each generation's compiled file under its own
/// name, so a file a past generation (or the settings history) names keeps
/// that generation's look. Undoing `appearance.themeFile` in the settings
/// history then brings back the look it had, not a later edit of it.
fn generation_name(pack: &Pack) -> String {
    let hash = pack.theme_text().bytes().fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
    });
    format!("{}-{:012x}", pack.theme_name(), hash & 0xffff_ffff_ffff)
}

/// Writes `bytes` to `path` through a temporary file and a rename, so a
/// reader (the app's watcher) sees the old file or the new one, never half
/// of one. No fsync: a look lost to a power cut comes back as the one before
/// it, and two fsyncs per file are most of a swap's time on a busy disk.
pub(crate) fn replace(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let directory =
        path.parent().filter(|dir| !dir.as_os_str().is_empty()).unwrap_or(Path::new("."));
    std::fs::create_dir_all(directory)?;
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let temporary = directory.join(format!(".{name}.{}.tmp", std::process::id()));
    let result = std::fs::write(&temporary, bytes).and_then(|()| std::fs::rename(&temporary, path));
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}
