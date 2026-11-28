use sha2::{Digest as _, Sha256};

use super::*;

fn sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// A file edited here after the plan read it (between the last check
/// and its move) is never replaced or deleted: the edit stays.
#[test]
fn a_file_edited_after_the_plan_is_never_replaced_or_deleted() {
    let top = tempfile::tempdir().unwrap();
    let (root, staging) = (top.path().join("root"), top.path().join("staging"));
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(&staging).unwrap();
    std::fs::write(root.join("a.txt"), "edited\n").unwrap();
    std::fs::write(root.join("b.txt"), "edited\n").unwrap();
    std::fs::write(staging.join("file-1"), "machine\n").unwrap();
    let planned = Expected { sha256: sha256(b"planned\n"), permissions: 0o644 };

    let mut transaction = Transaction::new(&root, &staging).unwrap();
    let error = transaction.write("a.txt", "file-1", Some(&planned)).unwrap_err();
    assert!(error.downcast_ref::<Changed>().is_some(), "{error:#}");
    let error = transaction.delete("b.txt", &planned).unwrap_err();
    assert!(error.downcast_ref::<Changed>().is_some(), "{error:#}");
    // A file made after the plan saw none is not replaced either.
    std::fs::write(root.join("c.txt"), "made here\n").unwrap();
    let error = transaction.write("c.txt", "file-1", None).unwrap_err();
    assert!(error.downcast_ref::<Changed>().is_some(), "{error:#}");
    let _ = transaction.roll_back();

    assert_eq!(std::fs::read_to_string(root.join("a.txt")).unwrap(), "edited\n");
    assert_eq!(std::fs::read_to_string(root.join("b.txt")).unwrap(), "edited\n");
    assert_eq!(std::fs::read_to_string(root.join("c.txt")).unwrap(), "made here\n");
}

/// A symlink made, replaced or removed by a pull is put back exactly by
/// a roll back, and one that changed after the plan stays.
#[test]
fn symlinks_are_placed_and_put_back_and_a_changed_one_stays() {
    let top = tempfile::tempdir().unwrap();
    let (root, staging) = (top.path().join("root"), top.path().join("staging"));
    std::fs::create_dir_all(root.join("src")).unwrap();
    std::fs::create_dir_all(&staging).unwrap();
    std::os::unix::fs::symlink("src", root.join("old")).unwrap();
    std::os::unix::fs::symlink("edited", root.join("mine")).unwrap();

    let mut transaction = Transaction::new(&root, &staging).unwrap();
    transaction.remove_link("old", "src").unwrap();
    transaction.link("old", "src/a").unwrap();
    transaction.link("deep/new", "../src").unwrap();
    assert_eq!(std::fs::read_link(root.join("old")).unwrap(), Path::new("src/a"));
    assert_eq!(std::fs::read_link(root.join("deep/new")).unwrap(), Path::new("../src"));
    let error = transaction.remove_link("mine", "planned").unwrap_err();
    assert!(error.downcast_ref::<Changed>().is_some(), "{error:#}");
    assert_eq!(std::fs::read_link(root.join("mine")).unwrap(), Path::new("edited"));
    transaction.roll_back().unwrap();

    assert_eq!(std::fs::read_link(root.join("old")).unwrap(), Path::new("src"));
    assert!(!root.join("deep").exists());
    assert_eq!(std::fs::read_link(root.join("mine")).unwrap(), Path::new("edited"));
}

#[test]
fn ten_thousand_three_way_races_keep_the_local_edit() {
    let top = tempfile::tempdir().unwrap();
    let root = top.path().join("root");
    let staging = top.path().join("staging");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(&staging).unwrap();
    let planned = Expected { sha256: sha256(b"planned\n"), permissions: 0o644 };
    let mut seed = 0x7072_6f6a_6563_7465u64;
    let mut cases = [0usize; 4];
    for trial in 0..10_000 {
        // Reproducible edit schedules: a local write after planning races a
        // remote replacement, deletion, creation, or symlink replacement.
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        let case = (seed % 4) as usize;
        cases[case] += 1;
        let local = format!("local-{trial}-{seed}\n");
        let incoming = format!("machine-{trial}-{seed}\n");
        std::fs::write(staging.join("incoming"), &incoming).unwrap();
        if case == 3 {
            std::os::unix::fs::symlink(&local, root.join("race.txt")).unwrap();
        } else {
            std::fs::write(root.join("race.txt"), &local).unwrap();
        }
        let mut transaction = Transaction::new(&root, &staging).unwrap();
        let result = match case {
            0 => transaction.write("race.txt", "incoming", Some(&planned)),
            1 => transaction.delete("race.txt", &planned),
            2 => transaction.write("race.txt", "incoming", None),
            _ => transaction.remove_link("race.txt", "planned"),
        };
        let error = result.unwrap_err();
        assert!(error.downcast_ref::<Changed>().is_some(), "trial {trial}: {error:#}");
        transaction.roll_back().unwrap();
        if case == 3 {
            assert_eq!(std::fs::read_link(root.join("race.txt")).unwrap(), Path::new(&local));
        } else {
            assert_eq!(std::fs::read_to_string(root.join("race.txt")).unwrap(), local);
        }
        assert_eq!(std::fs::read_to_string(staging.join("incoming")).unwrap(), incoming);
        std::fs::remove_file(root.join("race.txt")).unwrap();
    }
    assert!(cases.iter().all(|count| *count > 2000), "seeded coverage: {cases:?}");
}

/// The chain answers each path as `parent_of` does (the same folder, a
/// missing folder as None, a symlinked folder as an error) while it keeps
/// the folders paths share open between them, in git's sorted order.
#[test]
fn the_chain_reaches_each_files_folder_as_parent_of_does() {
    use std::os::unix::fs::MetadataExt as _;
    let top = tempfile::tempdir().unwrap();
    let root = top.path();
    for folder in ["a/b/c", "a/b/d", "a/e", "f"] {
        std::fs::create_dir_all(root.join(folder)).unwrap();
    }
    std::os::unix::fs::symlink("f", root.join("link")).unwrap();
    let dir = Dir::open(root).unwrap();
    let mut chain = Chain::default();
    let identity = |dir: &Dir| dir.identity().unwrap();
    for path in [
        "a/b/c/one",
        "a/b/c/two",
        "a/b/d/three",
        "a/b/four",
        "a/e/five",
        "a/gone/six",
        "a/gone/seven",
        "f/eight",
        "link/nine",
        "ten",
        "a/b/c/eleven",
    ] {
        let expected = parent_of(&dir, path);
        let got = chain.parent_of(&dir, path);
        match (expected, got) {
            (Ok(Some((want, want_name))), Ok(Some((have, name)))) => {
                assert_eq!(identity(have), identity(&want), "{path}");
                assert_eq!(name, want_name, "{path}");
                let folder = path.rsplit_once('/').map_or("", |(folder, _)| folder);
                assert_eq!(identity(have).1, std::fs::metadata(root.join(folder)).unwrap().ino());
            }
            (Ok(None), Ok(None)) | (Err(_), Err(_)) => {}
            (want, have) => panic!(
                "{path}: parent_of {:?}, chain {:?}",
                want.map(|o| o.is_some()),
                have.map(|o| o.is_some())
            ),
        }
    }
}
