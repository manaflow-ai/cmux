//! The classic save a run reads: the channel the [`Finder`] picks, trying
//! its session file, `-previous` copy and newest archive in turn until one
//! decodes. A local folder that is gone opens the home folder.

use std::path::{Path, PathBuf};

use crate::decode::{self, Error, STABLE_BUNDLE_ID};
use crate::model::Snapshot;
use crate::source::{Finder, Source};

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
/// the finder's candidates. None when classic saved nothing readable; an
/// error only when the one file there is could not be read, so a damaged
/// session with a good copy beside it still migrates.
pub fn read(finder: &Finder, file: Option<&Path>, home: &Path) -> Result<Option<Save>, Error> {
    let candidates = match file {
        Some(file) => vec![(file.to_path_buf(), STABLE_BUNDLE_ID.to_string())],
        None => finder.candidates(None),
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
        let opened =
            snapshot.opening_missing_folders(&home_text, &|folder| Path::new(folder).is_dir());
        let Some(source) = finder.source(path, bundle, opened.created_at) else { continue };
        let mut backups = vec![path.clone()];
        backups.extend(
            candidates.iter().map(|(other, _)| other.clone()).filter(|other| other != path),
        );
        return Ok(Some(Save { snapshot: opened, source, backups, skipped }));
    }
    match skipped.pop() {
        Some((_, error)) if candidates.len() == 1 => Err(error),
        _ => Ok(None),
    }
}
