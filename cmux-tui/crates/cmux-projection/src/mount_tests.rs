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

fn git(dir: &Path, home: &Path, args: &[&str]) -> std::process::Output {
    std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("HOME", home)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@example.com")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@example.com")
        .output()
        .unwrap()
}

/// RFD 0007, hard case 7, as Leo's `~/Projects` showed it: the repository's `.git/index` is
/// rewritten on the Mac (by rename, a new inode) after the manifest. Before, the Mac answered
/// CHANGED, the read failed, and `git status` on the machine died of SIGBUS on its mapped index.
/// Now the open re-lists the index, the kernel takes its new size, and `git status` reads the new
/// index: the Mac's unstaging shows.
#[test]
fn git_status_succeeds_over_an_index_rewritten_on_the_mac_after_the_manifest() {
    if !fuse_here() {
        println!("skipping: no FUSE here (no /dev/fuse or no fusermount3)");
        return;
    }
    let home = tempfile::tempdir().unwrap();
    let mac = tempfile::tempdir().unwrap();
    let repo = mac.path();
    assert!(git(repo, home.path(), &["init", "-q", "-b", "main"]).status.success());
    std::fs::write(repo.join("a.txt"), "alpha\n").unwrap();
    std::fs::write(repo.join("b.txt"), "beta\n").unwrap();
    assert!(git(repo, home.path(), &["add", "a.txt", "b.txt"]).status.success());
    assert!(git(repo, home.path(), &["commit", "-q", "-m", "one"]).status.success());
    let (manifest, source) = crate::test_mac::FolderMac::list(repo);
    let listed_index = std::fs::read(repo.join(".git/index")).unwrap();

    // On the Mac, after the manifest: git rewrites its index (unstages b.txt).
    std::thread::sleep(Duration::from_millis(20));
    assert!(git(repo, home.path(), &["rm", "--cached", "-q", "b.txt"]).status.success());
    let rewritten = std::fs::read(repo.join(".git/index")).unwrap();
    assert_ne!(rewritten.len(), listed_index.len());

    let state = tempfile::tempdir().unwrap();
    let at = tempfile::tempdir().unwrap();
    let owner = {
        use std::os::unix::fs::MetadataExt as _;
        let meta = std::fs::metadata(state.path()).unwrap();
        (meta.uid(), meta.gid())
    };
    let overlay = Arc::new(Overlay::open(manifest, state.path(), source.linked(), owner).unwrap());
    let mounted = match mount(overlay, at.path()) {
        Ok(mounted) => mounted,
        Err(error) => {
            println!("skipping: no FUSE here (mount failed: {error:#})");
            return;
        }
    };
    let status = git(at.path(), home.path(), &["status", "--porcelain"]);
    let out = String::from_utf8_lossy(&status.stdout).into_owned();
    let err = String::from_utf8_lossy(&status.stderr).into_owned();
    assert!(status.status.success(), "git status failed ({:?}): {out}{err}", status.status);
    assert!(out.contains("D  b.txt") && out.contains("?? b.txt"), "the Mac's new index: {out}");
    // The index's bytes and size through the mount are the Mac's new ones.
    assert_eq!(
        std::fs::metadata(at.path().join(".git/index")).unwrap().len(),
        rewritten.len() as u64
    );

    // The Mac rewrites it again; the machine read it already, so its copy stays the session's
    // base, and git keeps working.
    std::thread::sleep(Duration::from_millis(20));
    assert!(git(repo, home.path(), &["add", "b.txt"]).status.success());
    let again = git(at.path(), home.path(), &["status", "--porcelain"]);
    assert!(again.status.success(), "{}", String::from_utf8_lossy(&again.stderr));
    mounted.unmount();
}

/// The kernel never keeps a re-listed file's old size or pages: a plain read through the mount of
/// a file changed on the Mac returns all of its new bytes, longer or shorter, whether it was
/// written in place (the round-trip matrix's "remanifest" case) or replaced by a rename.
#[test]
fn a_file_changed_on_the_mac_after_the_manifest_reads_its_new_bytes_through_the_mount() {
    if !fuse_here() {
        println!("skipping: no FUSE here (no /dev/fuse or no fusermount3)");
        return;
    }
    let mac = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(mac.path().join("src")).unwrap();
    std::fs::write(mac.path().join("src/a.txt"), "alpha\n").unwrap();
    std::fs::write(mac.path().join("src/b.txt"), "a longer file, before\n").unwrap();
    let (manifest, source) = crate::test_mac::FolderMac::list(mac.path());
    // In place, as the matrix writes it: the same inode, a new size and mtime.
    std::thread::sleep(Duration::from_millis(20));
    std::fs::write(mac.path().join("src/a.txt"), "alpha, changed on the mac after the start\n")
        .unwrap();
    crate::test_mac::rewrite(&mac.path().join("src/b.txt"), b"short\n");
    let state = tempfile::tempdir().unwrap();
    let at = tempfile::tempdir().unwrap();
    let owner = {
        use std::os::unix::fs::MetadataExt as _;
        let meta = std::fs::metadata(state.path()).unwrap();
        (meta.uid(), meta.gid())
    };
    let overlay = Arc::new(Overlay::open(manifest, state.path(), source.linked(), owner).unwrap());
    let mounted = match mount(overlay, at.path()) {
        Ok(mounted) => mounted,
        Err(error) => {
            println!("skipping: no FUSE here (mount failed: {error:#})");
            return;
        }
    };
    // Stat before any read: the manifest's size (no fault yet).
    assert_eq!(std::fs::metadata(at.path().join("src/a.txt")).unwrap().len(), 6);
    assert_eq!(
        std::fs::read_to_string(at.path().join("src/a.txt")).unwrap(),
        "alpha, changed on the mac after the start\n"
    );
    assert_eq!(std::fs::metadata(at.path().join("src/a.txt")).unwrap().len(), 42);
    assert_eq!(std::fs::read_to_string(at.path().join("src/b.txt")).unwrap(), "short\n");
    mounted.unmount();
}
