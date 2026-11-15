//! Tests of `git.worktree.create`: the git folder that the setup of a new work tree gets.

use super::*;

/// A new folder of a test in the system's temporary folder.
fn new_folder(name: &str) -> PathBuf {
    let mut bytes = [0_u8; 6];
    getrandom::fill(&mut bytes).unwrap();
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    let top = std::env::temp_dir().join(format!("cmux-worktree-{name}-{hex}"));
    std::fs::create_dir_all(&top).unwrap();
    top
}

/// The setup of a new work tree starts only in a git folder of the repository that made the
/// work tree: a folder in the `worktrees` folder of the repository's git folder. A `.git` file
/// that names a folder of a different place gives no setup, and that folder gets no file.
#[test]
fn own_tree_a_setup_starts_only_in_a_folder_of_this_repository() {
    let top = new_folder("setup-place");
    let (common, elsewhere, root) = (top.join("main/.git"), top.join("elsewhere"), top.join("new"));
    for folder in [&common.join("worktrees"), &elsewhere, &root] {
        std::fs::create_dir_all(folder).unwrap();
    }
    std::fs::write(root.join(".git"), format!("gitdir: {}\n", elsewhere.display())).unwrap();
    let (branch, base) = ("cmux/new".to_string(), "main".to_string());
    let attempt = Attempt { root, branch, base, base_commit: String::new() };
    let mux = Mux::new("worktree-setup-place", crate::SurfaceOptions::default());

    let reply = setup(&mux, &attempt, &common);

    let name = |entry: std::fs::DirEntry| entry.file_name().to_string_lossy().into_owned();
    let mut names: Vec<String> = std::fs::read_dir(&elsewhere)
        .map(|entries| entries.flatten().map(name).collect())
        .unwrap_or_default();
    names.sort();
    std::fs::remove_dir_all(top).unwrap();
    assert_eq!((reply, names), (json!({"state": "none"}), Vec::new()));
}

/// The `.git` entry of a new work tree is read as a file that cmux keeps is read: a regular
/// file only, at most 1 MiB of it, with no wait. A named pipe, a file above the limit and a
/// link give no git folder.
///
/// The 2 ends of the pipe are open in the test, so an open of the pipe does not wait, and a
/// read of the pipe waits for the test's end. The read of the entry runs on a thread of its
/// own. `None`: it did not end in 10 s. The 10 s are not a time that the read is measured
/// against: they only make a failed test from a read that waits. The test closes its end
/// before the join, so a read that waits ends then.
#[cfg(unix)]
#[test]
fn own_tree_a_new_git_entry_is_read_with_a_limit_and_no_wait() {
    use std::os::unix::ffi::OsStrExt as _;
    let top = new_folder("git-entry");
    let (pipe, large, link) = (top.join("pipe"), top.join("large"), top.join("link"));
    for folder in [&top.join("admin"), &pipe, &large, &link] {
        std::fs::create_dir_all(folder).unwrap();
    }
    let entry = format!("gitdir: {}\n", top.join("admin").display());
    let name = std::ffi::CString::new(pipe.join(".git").as_os_str().as_bytes()).unwrap();
    // SAFETY: mkfifo(2) with a path that `name` keeps to the end of the call.
    let made = unsafe { libc::mkfifo(name.as_ptr(), 0o600) };
    assert_eq!(made, 0, "the test did not make the named pipe");
    // The entry of git, then line breaks to above the limit: a read of the whole file gives
    // the entry.
    let above_the_limit = "\n".repeat(1024 * 1024);
    std::fs::write(large.join(".git"), format!("{entry}{above_the_limit}")).unwrap();
    std::fs::write(top.join("entry"), &entry).unwrap();
    std::os::unix::fs::symlink(top.join("entry"), link.join(".git")).unwrap();
    let ends = std::fs::OpenOptions::new().read(true).write(true).open(pipe.join(".git")).unwrap();

    let (sender, receiver) = std::sync::mpsc::channel();
    let thread = std::thread::spawn(move || {
        let _ = sender.send(admin_dir(&pipe));
    });
    let of_the_pipe = receiver.recv_timeout(std::time::Duration::from_secs(10)).ok();
    drop(ends);
    let joined = thread.join().is_ok();
    let found = (of_the_pipe, admin_dir(&large), admin_dir(&link), joined);

    std::fs::remove_dir_all(top).unwrap();
    assert_eq!(found, (Some(None), None, None, true));
}
