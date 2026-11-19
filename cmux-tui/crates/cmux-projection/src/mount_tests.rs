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
