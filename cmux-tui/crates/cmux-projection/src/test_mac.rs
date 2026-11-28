//! Tests' Mac: a folder on this disk listed as a manifest and served over a real [`Link`] by the
//! rule `cmux link project serve` keeps (RFD 0007, hard case 7): every read checks the file
//! against the manifest, and a file that changed is answered [`crate::wire::RESTATED`] with its
//! stat now and its bytes as they are now.

use std::fs;
use std::os::unix::fs::{FileExt as _, MetadataExt as _};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::link::{Link, Source, answer_asks};
use crate::manifest::{Item, Kind, Manifest};
use crate::wire::{self, Part, Restat};

/// A folder served as a Mac serves one.
pub(crate) struct FolderMac {
    root: PathBuf,
    /// By manifest entry: the file's path and its size and mtime in the manifest.
    files: Vec<Option<(String, u64, i64)>>,
}

fn mtime_of(meta: &fs::Metadata) -> i64 {
    meta.mtime() * 1_000_000_000 + meta.mtime_nsec()
}

fn walk(root: &Path, at: &Path, items: &mut Vec<Item>) {
    for entry in fs::read_dir(at).unwrap() {
        let path = entry.unwrap().path();
        let meta = fs::symlink_metadata(&path).unwrap();
        let relative = path.strip_prefix(root).unwrap().to_str().unwrap().to_owned();
        if meta.is_dir() {
            walk(root, &path, items);
        } else if meta.is_file() {
            items.push(Item {
                path: relative,
                kind: Kind::File,
                mode: meta.mode() & 0o7777,
                size: meta.len(),
                mtime_ns: mtime_of(&meta),
                link: None,
            });
        }
    }
}

impl FolderMac {
    /// Lists every file below `root` (no links) as a manifest.
    pub(crate) fn list(root: &Path) -> (Arc<Manifest>, Arc<Self>) {
        let mut items = Vec::new();
        walk(root, root, &mut items);
        let manifest = Manifest::build(1, items.clone()).unwrap();
        let mut files = vec![None; manifest.len()];
        for item in items {
            let index = manifest.resolve(&item.path).unwrap();
            files[index as usize] = Some((item.path, item.size, item.mtime_ns));
        }
        (Arc::new(manifest), Arc::new(Self { root: root.to_path_buf(), files }))
    }

    /// A link the machine asks through, answered by this Mac on a stream of its own.
    pub(crate) fn linked(self: &Arc<Self>) -> Arc<Link> {
        let link = Arc::new(Link::new(Duration::from_secs(2)));
        let (machine, mac) = UnixStream::pair().unwrap();
        let served = link.clone();
        let writer = machine.try_clone().unwrap();
        std::thread::spawn(move || served.serve(machine, writer));
        let source = self.clone();
        std::thread::spawn(move || {
            let writer = mac.try_clone().unwrap();
            let _ = answer_asks(mac, writer, source.as_ref());
        });
        let start = Instant::now();
        while !link.attached() {
            assert!(start.elapsed() < Duration::from_secs(5));
            std::thread::yield_now();
        }
        link
    }
}

impl Source for FolderMac {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Part {
        let Some(Some((relative, size, mtime_ns))) = self.files.get(entry as usize) else {
            return Part::status(wire::REFUSED);
        };
        let Ok(file) = fs::File::open(self.root.join(relative)) else {
            return Part::status(wire::FAILED);
        };
        let meta = file.metadata().unwrap();
        let end = meta.len().min(offset + u64::from(len));
        let mut bytes = vec![0u8; end.saturating_sub(offset) as usize];
        file.read_exact_at(&mut bytes, offset).unwrap();
        if (meta.len(), mtime_of(&meta)) == (*size, *mtime_ns) {
            Part::ok(bytes)
        } else {
            let stat =
                Restat { size: meta.len(), mtime_ns: mtime_of(&meta), mode: meta.mode() & 0o7777 };
            Part::restated(stat, &bytes)
        }
    }

    fn whole(&self, entry: u32) -> Part {
        let mut part = self.read(entry, 0, wire::MAX_READ);
        if part.restat().is_some_and(|(stat, _)| stat.size > u64::from(wire::MAX_READ)) {
            part.keep_stat_only();
        }
        part
    }
}

/// Replaces `path`'s bytes the way git writes its index: a new file renamed over it.
pub(crate) fn rewrite(path: &Path, bytes: &[u8]) {
    // A later mtime than the manifest's, whatever the clock's grain.
    std::thread::sleep(Duration::from_millis(20));
    let temp = path.with_extension("lock");
    fs::write(&temp, bytes).unwrap();
    fs::rename(&temp, path).unwrap();
}
