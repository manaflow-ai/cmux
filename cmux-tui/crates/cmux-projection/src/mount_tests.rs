use std::collections::HashMap;
use std::sync::Arc;

use super::*;
use crate::manifest::{Item, Manifest};
use crate::{Fetch, FetchError};

struct Files(HashMap<u32, Vec<u8>>);

impl Fetch for Files {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Result<Vec<u8>, FetchError> {
        let bytes = self.0.get(&entry).ok_or(FetchError::Failed)?;
        let start = (offset as usize).min(bytes.len());
        let end = (start + len as usize).min(bytes.len());
        Ok(bytes[start..end].to_vec())
    }

    fn batch(&self, entries: &[u32]) -> Vec<Result<Vec<u8>, FetchError>> {
        entries.iter().map(|entry| self.0.get(entry).cloned().ok_or(FetchError::Failed)).collect()
    }
}

fn fuse_here() -> bool {
    Path::new("/dev/fuse").exists()
        && std::process::Command::new("fusermount3")
            .arg("--version")
            .output()
            .is_ok_and(|output| output.status.success())
}

#[test]
fn a_mounted_projection_reads_writes_and_deletes_with_plain_file_calls() {
    if !fuse_here() {
        println!("skipping: no FUSE here (no /dev/fuse or no fusermount3)");
        return;
    }
    let files =
        [("README.md", b"hello from the mac".to_vec()), ("src/main.rs", b"fn main() {}".to_vec())];
    let items = files
        .iter()
        .map(|(path, bytes)| Item {
            path: (*path).into(),
            kind: Kind::File,
            mode: 0o644,
            size: bytes.len() as u64,
            mtime_ns: 1_700_000_000_000_000_000,
            link: None,
        })
        .collect();
    let manifest = Arc::new(Manifest::build(1, items).unwrap());
    let bytes = files
        .iter()
        .map(|(path, bytes)| (manifest.resolve(path).unwrap(), bytes.clone()))
        .collect();
    let state = tempfile::tempdir().unwrap();
    let at = tempfile::tempdir().unwrap();
    let uid = std::fs::metadata(state.path()).map(|meta| {
        use std::os::unix::fs::MetadataExt as _;
        (meta.uid(), meta.gid())
    });
    let overlay = Arc::new(
        Overlay::open(manifest, state.path(), Arc::new(Files(bytes)), uid.unwrap()).unwrap(),
    );
    let mounted = match mount(overlay.clone(), at.path()) {
        Ok(mounted) => mounted,
        Err(error) => {
            println!("skipping: no FUSE here (mount failed: {error:#})");
            return;
        }
    };
    let root = at.path();
    let mut names: Vec<String> = std::fs::read_dir(root)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    assert_eq!(names, ["README.md", "src"]);
    assert_eq!(std::fs::read_to_string(root.join("README.md")).unwrap(), "hello from the mac");
    assert_eq!(std::fs::read_to_string(root.join("src/main.rs")).unwrap(), "fn main() {}");
    std::fs::write(root.join("src/new.rs"), "fn new() {}").unwrap();
    assert_eq!(std::fs::read_to_string(root.join("src/new.rs")).unwrap(), "fn new() {}");
    std::fs::write(root.join("README.md"), "edited on the machine").unwrap();
    assert_eq!(std::fs::read_to_string(root.join("README.md")).unwrap(), "edited on the machine");
    std::fs::remove_file(root.join("src/main.rs")).unwrap();
    assert!(!root.join("src/main.rs").exists());
    assert_eq!(overlay.whiteouts(), ["src/main.rs"]);
    mounted.unmount();
    println!("mounted, read, wrote and deleted through FUSE");
}

/// A Mac that does not answer (a stalled link) until released.
struct Stalled {
    released: Mutex<bool>,
    changed: std::sync::Condvar,
}

impl Stalled {
    fn wait(&self) {
        let mut released = self.released.lock().unwrap();
        while !*released {
            released = self.changed.wait(released).unwrap();
        }
    }

    fn release(&self) {
        *self.released.lock().unwrap() = true;
        self.changed.notify_all();
    }
}

impl Fetch for Stalled {
    fn read(&self, _entry: u32, _offset: u64, len: u32) -> Result<Vec<u8>, FetchError> {
        self.wait();
        Ok(vec![b'x'; len as usize])
    }

    fn batch(&self, entries: &[u32]) -> Vec<Result<Vec<u8>, FetchError>> {
        self.wait();
        entries.iter().map(|_| Ok(b"x".to_vec())).collect()
    }
}

/// Every fetch thread held by a stalled link (more cold reads at once than threads) does not
/// hold the agent's own files: writing and reading back a file it made answers at once. It
/// waited for the link (up to its stall wait, two minutes before that existed).
#[test]
fn a_stalled_link_holding_every_fetch_does_not_hold_the_agents_own_writes() {
    if !fuse_here() {
        println!("skipping: no FUSE here (no /dev/fuse or no fusermount3)");
        return;
    }
    let cold = 3 * WORKERS;
    let items = (0..cold)
        .map(|at| Item {
            path: format!("d{at}/cold.txt"),
            kind: Kind::File,
            mode: 0o644,
            size: 1,
            mtime_ns: 1_700_000_000_000_000_000,
            link: None,
        })
        .collect();
    let manifest = Arc::new(Manifest::build(1, items).unwrap());
    let state = tempfile::tempdir().unwrap();
    let at = tempfile::tempdir().unwrap();
    let owner = {
        use std::os::unix::fs::MetadataExt as _;
        let meta = std::fs::metadata(state.path()).unwrap();
        (meta.uid(), meta.gid())
    };
    let stalled = Arc::new(Stalled { released: Mutex::new(false), changed: Default::default() });
    let overlay = Arc::new(Overlay::open(manifest, state.path(), stalled.clone(), owner).unwrap());
    let mounted = match mount(overlay, at.path()) {
        Ok(mounted) => mounted,
        Err(error) => {
            println!("skipping: no FUSE here (mount failed: {error:#})");
            return;
        }
    };
    let root = at.path().to_path_buf();
    std::fs::write(root.join("mine.txt"), "draft").unwrap();
    // Let the link go after a while whatever happens, so a failing run ends.
    let watchdog = {
        let stalled = stalled.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(5));
            stalled.release();
        })
    };
    let readers: Vec<_> = (0..cold)
        .map(|at| {
            let path = root.join(format!("d{at}/cold.txt"));
            std::thread::spawn(move || std::fs::read(path).map(|bytes| bytes.len()))
        })
        .collect();
    std::thread::sleep(Duration::from_millis(300));
    let started = std::time::Instant::now();
    std::fs::write(root.join("mine.txt"), "saved while the link is stalled").unwrap();
    assert_eq!(
        std::fs::read_to_string(root.join("mine.txt")).unwrap(),
        "saved while the link is stalled"
    );
    let took = started.elapsed();
    stalled.release();
    for reader in readers {
        assert_eq!(reader.join().unwrap().unwrap(), 1);
    }
    watchdog.join().unwrap();
    mounted.unmount();
    assert!(took < Duration::from_secs(2), "the agent's own write waited {took:?} for the link");
}
