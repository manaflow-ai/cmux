//! A file rewritten on the Mac after the manifest (RFD 0007 hard case 7): a live repository's
//! `.git/index` is rewritten by every `git add` or `git status` there, so a read on the machine
//! finds it changed. The read lists the file again ([`crate::Fetch::relist`]) and serves its new
//! bytes, size and time instead of failing (`ESTALE`, which `git status` on the mapped index took
//! as SIGBUS). End to end over a real [`Link`] under an [`Overlay`].

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::link::{Link, Source};
use crate::manifest::{Item, Kind, Manifest};
use crate::offline_tests::attach;
use crate::overlay::{CHUNK, Overlay};
use crate::wire::{self, Part};

/// The Mac's files, which it rewrites, served only while they are what it last listed, as the
/// Mac's real server does (`cmux link project serve`).
#[derive(Default)]
struct Mac {
    /// Each file's bytes and modification time now.
    files: Mutex<HashMap<u32, (Vec<u8>, i64)>>,
    /// What it last listed for each file.
    listed: Mutex<HashMap<u32, (u64, i64)>>,
    /// Files it cannot list again (gone, say).
    frozen: HashSet<u32>,
}

impl Mac {
    fn rewrite(&self, entry: u32, bytes: Vec<u8>, mtime_ns: i64) {
        self.files.lock().unwrap().insert(entry, (bytes, mtime_ns));
    }

    /// The bytes, while they are what it listed.
    fn current(&self, entry: u32) -> Result<Vec<u8>, Part> {
        let files = self.files.lock().unwrap();
        let (bytes, mtime_ns) = files.get(&entry).ok_or(Part::status(wire::REFUSED))?;
        if self.listed.lock().unwrap().get(&entry) != Some(&(bytes.len() as u64, *mtime_ns)) {
            return Err(Part::status(wire::CHANGED));
        }
        Ok(bytes.clone())
    }
}

impl Source for Mac {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Part {
        match self.current(entry) {
            Ok(bytes) => {
                let start = (offset as usize).min(bytes.len());
                let end = (start + len as usize).min(bytes.len());
                Part::ok(bytes[start..end].to_vec())
            }
            Err(part) => part,
        }
    }

    fn whole(&self, entry: u32) -> Part {
        self.current(entry).map_or_else(|part| part, Part::ok)
    }

    fn relist(&self, entry: u32) -> Part {
        if self.frozen.contains(&entry) {
            return Part::status(wire::FAILED);
        }
        let files = self.files.lock().unwrap();
        let Some((bytes, mtime_ns)) = files.get(&entry) else { return Part::status(wire::FAILED) };
        let now = (bytes.len() as u64, *mtime_ns);
        self.listed.lock().unwrap().insert(entry, now);
        Part::ok(wire::stat_bytes(now.0, now.1))
    }
}

fn file(path: &str, size: usize) -> Item {
    Item {
        path: path.into(),
        kind: Kind::File,
        mode: 0o644,
        size: size as u64,
        mtime_ns: 1,
        link: None,
    }
}

fn ino(overlay: &Overlay, path: &str) -> u64 {
    path.split('/').fold(overlay.root(), |at, name| overlay.lookup(at, name).unwrap().ino)
}

const BIG: usize = CHUNK as usize + 100;

#[test]
fn a_file_rewritten_on_the_mac_is_listed_again_and_served_new() {
    let manifest = Arc::new(
        Manifest::build(
            1,
            vec![
                file("cmux/.git/index", 5000),
                file("cmux/.git/HEAD", 21),
                file("cmux/pack.bin", BIG),
                file("cmux/gone.rs", 8),
            ],
        )
        .unwrap(),
    );
    let at = |path: &str| manifest.resolve(path).unwrap();
    let (index, head, pack, gone) =
        (at("cmux/.git/index"), at("cmux/.git/HEAD"), at("cmux/pack.bin"), at("cmux/gone.rs"));
    let mut mac = Mac { frozen: HashSet::from([gone]), ..Mac::default() };
    for (entry, bytes) in [
        (index, vec![1u8; 5000]),
        (head, b"ref: refs/heads/main\n".to_vec()),
        (pack, (0..BIG).map(|at| (at % 251) as u8).collect()),
        (gone, b"fn g(){}".to_vec()),
    ] {
        mac.listed.get_mut().unwrap().insert(entry, (bytes.len() as u64, 1));
        mac.files.get_mut().unwrap().insert(entry, (bytes, 1));
    }
    let mac = Arc::new(mac);
    let source: Arc<dyn Source + Send + Sync> = mac.clone();
    let link = Arc::new(Link::new(Duration::from_secs(5)));
    let _stream = attach(&link, &source);
    let state = tempfile::tempdir().unwrap();
    let open =
        || Overlay::open(manifest.clone(), state.path(), link.clone(), (1000, 1000)).unwrap();
    let overlay = open();

    // git on the Mac rewrites its index (new size, new time) before the machine reads it.
    mac.rewrite(index, vec![2u8; 7000], 2);
    let got = overlay.read(ino(&overlay, "cmux/.git/index"), 0, 8192).unwrap();
    assert_eq!(got, vec![2u8; 7000], "the new index, not ESTALE");
    let attr = overlay.getattr(ino(&overlay, "cmux/.git/index")).unwrap();
    assert_eq!((attr.size, attr.mtime_ns), (7000, 2));
    // Files that did not change are as they were.
    assert_eq!(
        overlay.read(ino(&overlay, "cmux/.git/HEAD"), 0, 64).unwrap(),
        b"ref: refs/heads/main\n"
    );

    // A big file rewritten between two of its chunks: no read mixes the two versions.
    let pack_ino = ino(&overlay, "cmux/pack.bin");
    assert_eq!(overlay.read(pack_ino, 0, 4).unwrap(), [0, 1, 2, 3]);
    let new_pack: Vec<u8> = (0..BIG).map(|at| (at % 7) as u8).collect();
    mac.rewrite(pack, new_pack.clone(), 3);
    let tail = overlay.read(pack_ino, CHUNK, 100).unwrap();
    assert_eq!(tail, new_pack[CHUNK as usize..]);
    assert_eq!(overlay.read(pack_ino, 0, 4).unwrap(), new_pack[..4], "the old chunk was dropped");

    // A file the Mac cannot list again still fails as changed.
    mac.rewrite(gone, b"fn gone(){}".to_vec(), 4);
    assert_eq!(overlay.read(ino(&overlay, "cmux/gone.rs"), 0, 64), Err(116));

    // The new listing outlives the overlay: a remount serves the new index from its cache.
    drop(overlay);
    let overlay = open();
    let attr = overlay.getattr(ino(&overlay, "cmux/.git/index")).unwrap();
    assert_eq!((attr.size, attr.mtime_ns), (7000, 2));
    let reads = overlay.stats().remote_reads;
    assert_eq!(overlay.read(ino(&overlay, "cmux/.git/index"), 0, 8192).unwrap(), vec![2u8; 7000]);
    assert_eq!(overlay.stats().remote_reads, reads, "served from the cache");
}
