//! A home put back as it was before a daemon read it, so the chat size sweep can open the same
//! chat cold more than once. One cold open is one sample whose time moves by tens of ms between
//! runs on the same runner, which was enough to set the sweep's worst ratio on its own.

use std::collections::BTreeMap;
use std::fs::OpenOptions;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// Files at most this big are copied whole, so a daemon's rewrite of one can be undone.
const KEEP_BYTES: u64 = 4 << 20;

/// What one file was: its bytes, its modification time and, when small, its contents.
struct Was {
    len: u64,
    modified: Option<SystemTime>,
    contents: Option<Vec<u8>>,
}

impl Was {
    /// Give `path` back its old modification time, so the next restore sees it unchanged.
    fn keep_time(&self, path: &Path) -> Result<(), String> {
        let Some(modified) = self.modified else { return Ok(()) };
        OpenOptions::new()
            .write(true)
            .open(path)
            .and_then(|f| f.set_modified(modified))
            .map_err(|e| format!("{}: {e}", path.display()))
    }
}

/// The files and folders of a home at one moment.
pub struct HomeSnapshot {
    root: PathBuf,
    files: BTreeMap<PathBuf, Was>,
    dirs: Vec<PathBuf>,
}

fn walk(dir: &Path, files: &mut Vec<PathBuf>, dirs: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for e in entries.flatten() {
        let path = e.path();
        match path.symlink_metadata() {
            Ok(m) if m.is_dir() => {
                dirs.push(path.clone());
                walk(&path, files, dirs);
            }
            Ok(m) if m.is_file() => files.push(path),
            _ => {}
        }
    }
}

impl HomeSnapshot {
    pub fn take(root: &Path) -> Self {
        let (mut paths, mut dirs) = (vec![], vec![]);
        walk(root, &mut paths, &mut dirs);
        let files = paths
            .into_iter()
            .filter_map(|p| {
                let m = p.symlink_metadata().ok()?;
                let contents = (m.len() <= KEEP_BYTES).then(|| std::fs::read(&p).ok()).flatten();
                Some((p, Was { len: m.len(), modified: m.modified().ok(), contents }))
            })
            .collect();
        Self { root: root.to_path_buf(), files, dirs }
    }

    /// Put the home back: remove what is new, rewrite small files that changed and cut appends
    /// off large ones. A large file that shrank or was rewritten can't be put back: the error
    /// names it, and the caller takes no further sample from this home.
    pub fn restore(&self) -> Result<(), String> {
        let (mut paths, mut dirs) = (vec![], vec![]);
        walk(&self.root, &mut paths, &mut dirs);
        for path in paths {
            let Some(was) = self.files.get(&path) else {
                std::fs::remove_file(&path).map_err(|e| format!("{}: {e}", path.display()))?;
                continue;
            };
            let Ok(now) = path.symlink_metadata() else { continue };
            if now.len() == was.len && now.modified().ok() == was.modified {
                continue;
            }
            if let Some(contents) = &was.contents {
                std::fs::write(&path, contents).map_err(|e| format!("{}: {e}", path.display()))?;
                was.keep_time(&path)?;
            } else if now.len() > was.len {
                let file = OpenOptions::new()
                    .write(true)
                    .open(&path)
                    .map_err(|e| format!("{}: {e}", path.display()))?;
                file.set_len(was.len).map_err(|e| format!("{}: {e}", path.display()))?;
                was.keep_time(&path)?;
            } else {
                return Err(format!(
                    "{}: {} bytes, was {} (a large file shrank or was rewritten)",
                    path.display(),
                    now.len(),
                    was.len
                ));
            }
        }
        // Deepest first, so a new folder's new subfolders go before it.
        dirs.sort_by_key(|d| std::cmp::Reverse(d.components().count()));
        for dir in dirs.iter().filter(|d| !self.dirs.contains(d)) {
            std::fs::remove_dir(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        }
        // A file the daemon removed can't come back unless it was small.
        for (path, was) in &self.files {
            if path.symlink_metadata().is_ok() {
                continue;
            }
            match &was.contents {
                Some(contents) => {
                    if let Some(parent) = path.parent() {
                        std::fs::create_dir_all(parent)
                            .map_err(|e| format!("{}: {e}", parent.display()))?;
                    }
                    std::fs::write(path, contents)
                        .map_err(|e| format!("{}: {e}", path.display()))?;
                    was.keep_time(path)?;
                }
                None => return Err(format!("{}: removed, {} bytes", path.display(), was.len)),
            }
        }
        Ok(())
    }
}

#[test]
fn restore_puts_a_home_back_as_it_was() {
    let root = std::env::temp_dir().join(format!("cold-home-{}", std::process::id()));
    let events = root.join("sessions/c/events");
    std::fs::create_dir_all(&events).unwrap();
    let big = events.join("0001.jsonl");
    std::fs::write(&big, vec![b'x'; (KEEP_BYTES + 1) as usize]).unwrap();
    std::fs::write(root.join("sessions/c/meta.json"), b"{\"a\":1}").unwrap();
    let snapshot = HomeSnapshot::take(&root);
    let listing = |root: &Path| {
        let (mut files, mut dirs) = (vec![], vec![]);
        walk(root, &mut files, &mut dirs);
        let mut all: Vec<_> = files
            .iter()
            .map(|p| (p.clone(), std::fs::read(p).unwrap()))
            .chain(dirs.iter().map(|d| (d.clone(), vec![])))
            .collect();
        all.sort();
        all
    };
    let before = listing(&root);
    for _ in 0..2 {
        // What a daemon's first read leaves: new folders and files, an append, a rewrite.
        std::fs::create_dir_all(root.join("sessions/c/kinds/x")).unwrap();
        std::fs::write(root.join("sessions/c/kinds/x/copy"), b"copy").unwrap();
        let mut log = OpenOptions::new().append(true).open(&big).unwrap();
        std::io::Write::write_all(&mut log, b"\n{\"seq\":9}").unwrap();
        std::fs::write(root.join("sessions/c/meta.json"), b"{\"a\":2,\"b\":3}").unwrap();
        snapshot.restore().unwrap();
        assert_eq!(listing(&root), before);
    }
    std::fs::remove_dir_all(&root).unwrap();
}
