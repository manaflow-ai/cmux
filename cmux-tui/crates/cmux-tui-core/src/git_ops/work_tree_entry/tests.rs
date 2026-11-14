use super::*;

/// A new folder, by its real path.
fn fresh_folder() -> std::path::PathBuf {
    let mut bytes = [0_u8; 6];
    getrandom::fill(&mut bytes).unwrap();
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    let folder = std::env::temp_dir().join(format!("cmux-work-tree-entry-{hex}"));
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::canonicalize(folder).unwrap()
}

fn kind(tree: &mut Tree, path: &str) -> Result<Option<Kind>, NoEntry> {
    tree.entry(Path::new(path)).map(|entry| entry.kind())
}

fn text(tree: &mut Tree, path: &str) -> Option<String> {
    let mut file = tree.entry(Path::new(path)).ok()?.open_file().ok()?;
    let mut text = String::new();
    std::io::Read::read_to_string(&mut file, &mut text).ok()?;
    Some(text)
}

#[test]
fn work_tree_entry_reaches_a_name_through_real_folders_only() {
    let top = fresh_folder();
    let root = top.join("root");
    let outside = top.join("outside");
    std::fs::create_dir_all(root.join("real/deep")).unwrap();
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(root.join("real/deep/file"), "inside").unwrap();
    std::fs::write(outside.join("file"), "outside").unwrap();
    std::os::unix::fs::symlink(&outside, root.join("link")).unwrap();
    std::os::unix::fs::symlink(outside.join("file"), root.join("real/file-link")).unwrap();
    let mut tree = Tree::open(&root).unwrap();

    assert_eq!(kind(&mut tree, "real/deep/file"), Ok(Some(Kind::File)));
    assert_eq!(kind(&mut tree, "real/deep"), Ok(Some(Kind::Folder)));
    assert_eq!(kind(&mut tree, "real/none"), Ok(None));
    assert_eq!(kind(&mut tree, "link"), Ok(Some(Kind::Link)));
    assert_eq!(kind(&mut tree, "real/file-link"), Ok(Some(Kind::Link)));
    // No entry below a link, below nothing or below a file, and the result says which.
    assert_eq!(kind(&mut tree, "link/file"), Err(NoEntry::Link));
    assert_eq!(kind(&mut tree, "none/file"), Err(NoEntry::Nothing));
    assert_eq!(kind(&mut tree, "real/deep/file/below"), Err(NoEntry::NotFolder));
    // A path is a list of names: no `..`, no path from the root, no empty path.
    assert_eq!(kind(&mut tree, "real/../link"), Err(NoEntry::Nothing));
    assert_eq!(kind(&mut tree, &outside.join("file").to_string_lossy()), Err(NoEntry::Nothing));
    assert_eq!(kind(&mut tree, ""), Err(NoEntry::Nothing));

    assert_eq!(text(&mut tree, "real/deep/file").as_deref(), Some("inside"));
    assert_eq!(text(&mut tree, "real/file-link"), None, "a link is not opened");
    assert_eq!(text(&mut tree, "real/deep"), None, "a folder is no file");
    assert_eq!(text(&mut tree, "link/file"), None, "no file below a link");

    // `real` becomes a link to a folder with a `deep/file` of its own. The tree holds
    // the folder that it opened, so it reads the old file; a new tree refuses the link.
    std::fs::create_dir_all(outside.join("deep")).unwrap();
    std::fs::write(outside.join("deep/file"), "outside").unwrap();
    assert_eq!(kind(&mut tree, "real/deep/file"), Ok(Some(Kind::File)));
    std::fs::rename(root.join("real"), top.join("real-away")).unwrap();
    std::os::unix::fs::symlink(&outside, root.join("real")).unwrap();
    assert_eq!(text(&mut tree, "real/deep/file").as_deref(), Some("inside"));
    let mut again = Tree::open(&root).unwrap();
    assert_eq!(kind(&mut again, "real/deep/file"), Err(NoEntry::Link));
    assert_eq!(text(&mut again, "real/deep/file"), None);

    std::fs::remove_dir_all(top).unwrap();
}

#[test]
fn work_tree_entry_waits_for_no_writer_of_a_named_pipe_in_the_place_of_a_folder() {
    let top = fresh_folder();
    let root = top.join("root");
    std::fs::create_dir_all(&root).unwrap();
    for pipe in [top.join("pipe"), root.join("pipe")] {
        use std::os::unix::ffi::OsStrExt as _;
        let name = std::ffi::CString::new(pipe.as_os_str().as_bytes()).unwrap();
        // SAFETY: a NUL-terminated path; the result is checked.
        let made = unsafe { libc::mkfifo(name.as_ptr(), 0o600) };
        assert_eq!(made, 0, "mkfifo {}", pipe.display());
    }
    // Nothing has a pipe open for a write: an open that waits for a writer does not end.
    assert!(Tree::open(&top.join("pipe")).is_none(), "a named pipe is no work tree");
    let mut tree = Tree::open(&root).unwrap();
    assert_eq!(kind(&mut tree, "pipe"), Ok(Some(Kind::Other)));
    assert_eq!(kind(&mut tree, "pipe/below"), Err(NoEntry::NotFolder));
    assert_eq!(text(&mut tree, "pipe"), None, "a named pipe is no file");

    std::fs::remove_dir_all(top).unwrap();
}
