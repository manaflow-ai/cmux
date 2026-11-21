//! The classic save a run reads: the channels the [`Finder`] orders, newest
//! save first, trying each one's session file, `-previous` copy and newest
//! archive in turn until one decodes. A local folder that is gone opens the
//! home folder, and each terminal's scrollback is the text its new shell
//! prints ([`crate::replay`]).

use std::path::{Path, PathBuf};

use crate::decode::{self, Error, STABLE_BUNDLE_ID};
use crate::model::Snapshot;
use crate::source::{Finder, Source, is_regular};

/// Classic's session as read, the save it came from, and the files to back up.
#[derive(Debug, Clone, PartialEq)]
pub struct Save {
    pub snapshot: Snapshot,
    pub source: Source,
    /// The file read first, then the other candidates.
    pub backups: Vec<PathBuf>,
    /// Why earlier candidates did not read, file by file.
    pub skipped: Vec<(PathBuf, Error)>,
}

/// The save a run reads; `file` reads only that file (as stable's), else
/// every channel's candidates, newest channel first. None when classic saved nothing readable; an
/// error only when the one file there is could not be read, so a damaged
/// session with a good copy beside it still migrates.
pub fn read(finder: &Finder, file: Option<&Path>, home: &Path) -> Result<Option<Save>, Error> {
    let candidates = match file {
        Some(file) => vec![(file.to_path_buf(), STABLE_BUNDLE_ID.to_string())],
        None => finder.all_candidates(),
    };
    let home_text = home.to_string_lossy();
    let mut skipped = Vec::new();
    for (path, bundle) in &candidates {
        let snapshot = match decode::read_file(path, &home_text) {
            Ok(Some(snapshot)) => snapshot,
            Ok(None) => continue,
            Err(error) => {
                skipped.push((path.clone(), error));
                continue;
            }
        };
        let opened = snapshot
            .opening_missing_folders(&home_text, &|folder| Path::new(folder).is_dir())
            .replaying_scrollback();
        let Some(source) = finder.source(path, bundle, opened.created_at) else { continue };
        // Only the read channel's files are backed up: another channel's stale save may be huge.
        let mut backups = vec![path.clone()];
        backups.extend(
            candidates
                .iter()
                .filter(|(other, channel)| channel == bundle && other != path)
                .map(|(other, _)| other.clone()),
        );
        return Ok(Some(Save { snapshot: opened, source, backups, skipped }));
    }
    match skipped.pop() {
        Some((_, error)) if candidates.len() == 1 => Err(error),
        _ => Ok(None),
    }
}

/// The save a cut-off run started from, so a resume finishes what it
/// began: `source`'s file while it still holds that save, else the newest
/// copy the run backed up under `backups`. None when neither reads; the
/// caller then reads the newest save. Nothing is backed up again.
pub fn resume(finder: &Finder, source: &Source, backups: &Path, home: &Path) -> Option<Save> {
    let original = PathBuf::from(&source.path);
    let name = original.file_name()?;
    let mut copies: Vec<PathBuf> = std::fs::read_dir(backups)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|entry| !entry.file_name().to_string_lossy().starts_with('.'))
        .map(|entry| entry.path().join(name))
        .filter(|copy| is_regular(copy))
        .collect();
    // Stamps sort by time: the newest backup first.
    copies.sort_unstable_by(|a, b| b.cmp(a));
    let home_text = home.to_string_lossy();
    // The ledger's path is read only while it is still one of classic's own session files.
    let original = finder.is_session_file(&original).then_some(original);
    for path in original.into_iter().chain(copies) {
        let Ok(Some(snapshot)) = decode::read_file(&path, &home_text) else { continue };
        let Some(found) = finder.source(&path, &source.bundle_id, snapshot.created_at) else {
            continue;
        };
        // The file itself must still hold that save; a copy is that save
        // unless its own creation date says otherwise.
        let same = if path == Path::new(&source.path) {
            found.is_same_save(source)
        } else {
            source.created_at.is_none() || found.created_at == source.created_at
        };
        if !same {
            continue;
        }
        let opened = snapshot
            .opening_missing_folders(&home_text, &|folder| Path::new(folder).is_dir())
            .replaying_scrollback();
        return Some(Save {
            snapshot: opened,
            source: source.clone(),
            backups: Vec::new(),
            skipped: Vec::new(),
        });
    }
    None
}
