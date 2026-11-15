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

/// The names of the entries of `folder`, in their order.
fn names_in(folder: &Path) -> Vec<String> {
    let name = |entry: std::fs::DirEntry| entry.file_name().to_string_lossy().into_owned();
    let mut names: Vec<String> = std::fs::read_dir(folder)
        .map(|entries| entries.flatten().map(name).collect())
        .unwrap_or_default();
    names.sort();
    names
}

/// What `setup` answers for the new work tree `root` of the repository whose git folder is
/// `common`. No recipe is saved and the repository has none, so a setup that starts gives the
/// work tree its block of ports only.
fn setup_of(root: PathBuf, common: &Path) -> Value {
    let (branch, base) = ("cmux/new".to_string(), "main".to_string());
    let attempt = Attempt { root, branch, base, base_commit: String::new() };
    let mux = Mux::new("worktree-setup-place", crate::SurfaceOptions::default());
    setup(&mux, &attempt, common)
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

/// The names that the git folder of a repository has after the setup of a work tree gave the
/// work tree its block of ports.
const WITH_PORTS: [&str; 3] = ["cmux-worktree-ports.json", "cmux-worktree-ports.lock", "worktrees"];

/// The setup of a new work tree starts in the git folder that git makes for it: a folder in
/// the `worktrees` folder of the repository's git folder. The work tree gets its block of
/// ports, and the ports file is in the repository's git folder.
#[test]
fn own_tree_a_setup_starts_in_the_git_folder_of_a_new_work_tree() {
    let top = new_folder("setup-own-place");
    let (common, root) = (top.join("main/.git"), top.join("new"));
    let admin = common.join("worktrees/new");
    for folder in [&admin, &root] {
        std::fs::create_dir_all(folder).unwrap();
    }
    std::fs::write(root.join(".git"), format!("gitdir: {}\n", admin.display())).unwrap();

    let reply = setup_of(root, &common);

    let names = names_in(&common);
    std::fs::remove_dir_all(top).unwrap();
    assert_eq!(
        (&reply["state"], reply["port"].is_u64(), names),
        (&json!("none"), true, WITH_PORTS.map(String::from).to_vec())
    );
}

/// The same with a `worktrees` folder that is a link to a folder of a different place: a
/// person can keep the folder so, and git then makes the git folder of a new work tree in the
/// folder that the link names.
#[cfg(unix)]
#[test]
fn own_tree_a_setup_starts_in_a_worktrees_folder_that_is_a_link() {
    let top = new_folder("setup-linked-place");
    let (common, kept, root) = (top.join("main/.git"), top.join("kept"), top.join("new"));
    for folder in [&common, &kept.join("new"), &root] {
        std::fs::create_dir_all(folder).unwrap();
    }
    std::os::unix::fs::symlink(&kept, common.join("worktrees")).unwrap();
    let admin = common.join("worktrees/new");
    std::fs::write(root.join(".git"), format!("gitdir: {}\n", admin.display())).unwrap();

    let reply = setup_of(root, &common);

    let names = names_in(&common);
    std::fs::remove_dir_all(top).unwrap();
    assert_eq!(
        (&reply["state"], reply["port"].is_u64(), names),
        (&json!("none"), true, WITH_PORTS.map(String::from).to_vec())
    );
}

/// The `.git` entry of a new work tree names its git folder by a path from the root of the
/// file system, or by a path from the work tree. An entry that names no folder gives no git
/// folder.
#[test]
fn own_tree_a_new_git_entry_names_the_git_folder_of_the_work_tree() {
    let top = new_folder("git-entry-names");
    let (admin, whole, part, none) =
        (top.join("admin"), top.join("whole"), top.join("part"), top.join("none"));
    for folder in [&admin, &whole, &part, &none] {
        std::fs::create_dir_all(folder).unwrap();
    }
    std::fs::write(whole.join(".git"), format!("gitdir: {}\n", admin.display())).unwrap();
    std::fs::write(part.join(".git"), "gitdir: ../admin\n").unwrap();
    std::fs::write(none.join(".git"), "gitdir: ../not-there\n").unwrap();

    let found = (admin_dir(&whole), admin_dir(&part), admin_dir(&none));

    std::fs::remove_dir_all(&top).unwrap();
    assert_eq!(found, (Some(admin), Some(top.join("part/../admin")), None));
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
