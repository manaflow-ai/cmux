//! The copy's install never makes a removed folder again.

use super::*;

/// A new empty folder for one test, removed when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        // Under /tmp, not under TMPDIR, so the root's anchor is its parent
        // (the fleet's macOS HOME is /Users/..., never / or /tmp).
        let path = PathBuf::from("/tmp").join(format!(
            "cmux-host-exe-{name}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// A small regular file to copy (the install copies any file).
fn source(scratch: &Scratch) -> PathBuf {
    let path = scratch.0.join("source");
    fs::write(&path, b"not an executable").unwrap();
    path
}

/// The probe's case on the fleet: a harness started an owner with its home
/// under a temporary root and removed the root while the owner's background
/// install hashed the executable. The install then made the removed tree
/// again (home, `Library/...`, the copy folder) and wrote the whole
/// executable into it, which nothing removes. A root whose folder is gone
/// is not made again: the install fails, and the daemon uses its own
/// executable.
#[test]
fn a_copy_root_whose_parent_was_removed_is_not_made_again() {
    let scratch = Scratch::new("removed");
    let source = source(&scratch);
    let removed = scratch.0.join("removed-root");
    let root = removed.join("host-exe");
    let installed = install(&root, &source, EXE_NAME);
    assert!(
        !removed.exists(),
        "the install made the removed {} again: {installed:?}",
        removed.display()
    );
    assert!(installed.is_err(), "the install used a root under a removed folder");
}

/// The usual case still installs: the root's folder exists.
#[test]
fn a_copy_root_under_an_existing_folder_is_made_and_used() {
    let scratch = Scratch::new("present");
    let source = source(&scratch);
    let root = scratch.0.join("host-exe");
    let installed = install(&root, &source, EXE_NAME).expect("install under an existing folder");
    assert!(installed.path.starts_with(&root));
    assert_eq!(fs::read(&installed.path).unwrap(), b"not an executable");
}

/// A root inside the home folder is made below the home folder, which must
/// exist; a removed home is never made again.
#[test]
fn a_root_in_a_removed_home_is_not_made_again() {
    let scratch = Scratch::new("home");
    let home = scratch.0.join("home");
    let root = home.join("Library/Application Support/cmux-tui/host-exe");
    assert!(create_root(&root, Some(&home)).is_err(), "made a root in a missing home");
    assert!(!home.exists(), "made the removed home {} again", home.display());
    fs::create_dir(&home).unwrap();
    create_root(&root, Some(&home)).expect("make the root in an existing home");
    assert!(root.is_dir());
}

/// The fleet race itself: the root is removed while the install hashes the
/// executable. The `<sha256>` folder is then made in a parent that must
/// exist, so the removed root is not made again.
#[test]
fn a_copy_folder_under_a_removed_root_is_not_made_again() {
    let scratch = Scratch::new("hash");
    let gone = scratch.0.join("host-exe");
    assert!(ensure_private_dir(&gone.join("0".repeat(64))).is_err());
    assert!(!gone.exists(), "made the removed root {} again", gone.display());
}
