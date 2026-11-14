use std::os::unix::fs::MetadataExt as _;

use super::{LocalFile, Source, local, open};

/// A checked file whose folder was swapped for a symlink to another
/// folder holding a file of the same name is never read.
#[test]
fn a_checked_file_reached_through_a_swapped_folder_is_not_read() {
    let dir = tempfile::tempdir().unwrap();
    let (inside, outside) = (dir.path().join("pick/docs"), dir.path().join("outside"));
    std::fs::create_dir_all(&inside).unwrap();
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(inside.join("app.toml"), "mine\n").unwrap();
    std::fs::write(outside.join("app.toml"), "secret\n").unwrap();
    let root = dir.path().join("pick");
    let (meta, top) =
        (std::fs::metadata(inside.join("app.toml")).unwrap(), std::fs::metadata(&root).unwrap());
    let file = LocalFile {
        source: Source::Checked(local::Checked {
            root,
            relative: "docs/app.toml".into(),
            root_identity: (top.dev(), top.ino()),
            identity: (meta.dev(), meta.ino()),
        }),
        permissions: 0o644,
        id: None,
    };
    assert!(open(&file).is_ok());
    std::fs::rename(&inside, dir.path().join("moved")).unwrap();
    std::os::unix::fs::symlink(&outside, &inside).unwrap();
    assert!(open(&file).is_err(), "the swapped folder's file was read");
}
