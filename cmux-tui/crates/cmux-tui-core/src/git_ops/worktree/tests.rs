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

/// Writes the record that git keeps in the git folder `admin` of a work tree: the path of the
/// `.git` file of the work tree `root`.
fn record_of(admin: &Path, root: &Path) {
    std::fs::write(admin.join("gitdir"), format!("{}\n", root.join(".git").display())).unwrap();
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
    record_of(&admin, &root);

    let reply = setup_of(root, &common);

    let names = names_in(&common);
    std::fs::remove_dir_all(top).unwrap();
    assert_eq!(
        (&reply["state"], reply["port"].is_u64(), names),
        (&json!("none"), true, WITH_PORTS.map(String::from).to_vec())
    );
}

/// The same with a `worktrees` folder that is a link to a folder of a different place. The
/// folders are made by hand here. git did not make them: with such a link, `git worktree add`
/// of git 2.43.0 fails and makes no work tree.
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
    record_of(&admin, &root);

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

/// The `.git` file of a new work tree can name the git folder by a path that has a link in it.
/// The work tree gets its block of ports from the ports file in the repository's git folder,
/// and no folder of that path gets a file.
#[cfg(unix)]
#[test]
fn own_tree_the_ports_of_a_new_work_tree_are_in_the_git_folder_of_its_repository() {
    let top = new_folder("setup-ports-place");
    let (common, other, root) = (top.join("main/.git"), top.join("other"), top.join("new"));
    let admin = common.join("worktrees/new");
    for folder in [&admin, &other.join("worktrees"), &root] {
        std::fs::create_dir_all(folder).unwrap();
    }
    record_of(&admin, &root);
    let named = other.join("worktrees/new");
    std::os::unix::fs::symlink(&admin, &named).unwrap();
    std::fs::write(root.join(".git"), format!("gitdir: {}\n", named.display())).unwrap();

    let reply = setup_of(root, &common);

    let names = (names_in(&common), names_in(&other));
    std::fs::remove_dir_all(top).unwrap();
    assert_eq!(
        (&reply["state"], reply["port"].is_u64(), names),
        (
            &json!("none"),
            true,
            (WITH_PORTS.map(String::from).to_vec(), vec!["worktrees".to_string()])
        )
    );
}

/// The `worktrees` folder is a link, and the `.git` file names the git folder of the new work
/// tree by its real path, which has no `worktrees` name in it. The ports file is in the
/// repository's git folder then too, and the git folder of the work tree gets no ports file.
#[cfg(unix)]
#[test]
fn own_tree_a_setup_starts_in_a_linked_worktrees_folder_by_its_real_path() {
    let top = new_folder("setup-linked-real-place");
    let (common, kept, root) = (top.join("main/.git"), top.join("kept"), top.join("new"));
    let admin = kept.join("new");
    for folder in [&common, &admin, &root] {
        std::fs::create_dir_all(folder).unwrap();
    }
    std::os::unix::fs::symlink(&kept, common.join("worktrees")).unwrap();
    record_of(&admin, &root);
    std::fs::write(root.join(".git"), format!("gitdir: {}\n", admin.display())).unwrap();

    let reply = setup_of(root, &common);

    let names = (names_in(&common), names_in(&admin));
    std::fs::remove_dir_all(top).unwrap();
    assert_eq!(
        (&reply["state"], reply["port"].is_u64(), names),
        (&json!("none"), true, (WITH_PORTS.map(String::from).to_vec(), vec!["gitdir".to_string()]))
    );
}

/// The setup of a new work tree starts only in the git folder that names the work tree back:
/// git keeps in the git folder of a work tree the path of the `.git` file of that work tree. A
/// `.git` file that names the git folder of a different work tree of the repository, or a
/// folder of the `worktrees` folder that has no such record, gives no setup, and that folder
/// gets no file.
#[test]
fn own_tree_a_setup_starts_only_in_the_git_folder_that_names_the_work_tree() {
    let top = new_folder("setup-named-back");
    let (common, root, other) = (top.join("main/.git"), top.join("new"), top.join("other"));
    let (of_other, of_none) = (common.join("worktrees/other"), common.join("worktrees/none"));
    for folder in [&of_other, &of_none, &root, &other] {
        std::fs::create_dir_all(folder).unwrap();
    }
    record_of(&of_other, &other);

    let replies = [&of_other, &of_none].map(|admin| {
        std::fs::write(root.join(".git"), format!("gitdir: {}\n", admin.display())).unwrap();
        setup_of(root.clone(), &common)
    });

    let names = (names_in(&common), names_in(&of_other), names_in(&of_none));
    std::fs::remove_dir_all(top).unwrap();
    let none = json!({"state": "none"});
    assert_eq!(
        (replies, names),
        (
            [none.clone(), none],
            (vec!["worktrees".to_string()], vec!["gitdir".to_string()], Vec::new())
        )
    );
}

/// The check of the git folder of a new work tree is a check of the folder that the setup
/// opened. The path of a place names a folder of a different place when the place opens it.
/// Then the path names a git folder in the repository's `worktrees` folder. The place is not
/// of the repository.
#[cfg(unix)]
#[test]
fn own_tree_the_check_of_a_setup_folder_is_of_the_folder_that_the_setup_opened() {
    let top = new_folder("setup-opened-place");
    let (common, elsewhere, root) = (top.join("main/.git"), top.join("elsewhere"), top.join("new"));
    let (admin, named) = (common.join("worktrees/new"), top.join("named"));
    for folder in [&admin, &elsewhere, &root] {
        std::fs::create_dir_all(folder).unwrap();
    }
    for folder in [&admin, &elsewhere] {
        record_of(folder, &root);
    }
    std::os::unix::fs::symlink(&elsewhere, &named).unwrap();
    let place = worktree_setup::Place::new(root, None, &named, &common);
    std::fs::remove_file(&named).unwrap();
    std::os::unix::fs::symlink(&admin, &named).unwrap();

    let of_the_repository = place.is_of(&common);

    drop(place);
    std::fs::remove_dir_all(top).unwrap();
    assert!(!of_the_repository, "the check was of the folder that the path names later");
}

/// The record of the git folder of a new work tree is read in the folder that the setup opened.
/// 2 folders in the repository's `worktrees` folder: the first has the record of a different
/// work tree, the second has the record of this work tree. The path of a place names the first
/// when the place opens it, and the second after that. The place is not of the repository. A
/// place that opened the second is of the repository.
#[cfg(unix)]
#[test]
fn own_tree_the_record_of_a_setup_folder_is_of_the_folder_that_the_setup_opened() {
    let top = new_folder("setup-opened-record");
    let (common, root, other) = (top.join("main/.git"), top.join("new"), top.join("other"));
    let (first, second) = (common.join("worktrees/first"), common.join("worktrees/second"));
    let named = common.join("worktrees/named");
    for folder in [&first, &second, &root, &other] {
        std::fs::create_dir_all(folder).unwrap();
    }
    record_of(&first, &other);
    record_of(&second, &root);
    std::os::unix::fs::symlink(&first, &named).unwrap();
    let opened_first = worktree_setup::Place::new(root.clone(), None, &named, &common);
    std::fs::remove_file(&named).unwrap();
    std::os::unix::fs::symlink(&second, &named).unwrap();
    let opened_second = worktree_setup::Place::new(root, None, &named, &common);

    let of_the_repository = (opened_first.is_of(&common), opened_second.is_of(&common));

    drop((opened_first, opened_second));
    std::fs::remove_dir_all(top).unwrap();
    assert_eq!(of_the_repository, (false, true), "the record was of the folder of the path");
}

/// A git folder that is there and that the place cannot open keeps the kind of the error of its
/// open. The folder here has the rights to search it and to write to it, and no right to read
/// it. A user that has each right (root) opens it, and then there is no error to keep. A folder
/// that is not there keeps that it was not found.
#[cfg(unix)]
#[test]
fn own_tree_a_setup_folder_that_is_not_opened_keeps_the_error_of_its_open() {
    use std::os::unix::fs::PermissionsExt as _;
    let top = new_folder("setup-not-opened");
    let (common, root) = (top.join("main/.git"), top.join("new"));
    let (closed, none) = (common.join("worktrees/closed"), common.join("worktrees/none"));
    for folder in [&closed, &root] {
        std::fs::create_dir_all(folder).unwrap();
    }
    std::fs::set_permissions(&closed, std::fs::Permissions::from_mode(0o300)).unwrap();
    let is_read = std::fs::read_dir(&closed).is_ok();

    let kinds = [&closed, &none].map(|git_dir| {
        worktree_setup::Place::new(root.clone(), None, git_dir, &common).not_opened()
    });

    // The old rights, before the result is looked at: the folder can be removed.
    std::fs::set_permissions(&closed, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::remove_dir_all(top).unwrap();
    let of_closed = (!is_read).then_some(std::io::ErrorKind::PermissionDenied);
    assert_eq!(kinds, [of_closed, Some(std::io::ErrorKind::NotFound)]);
}

/// `git ARGUMENTS` in `folder`, with no configuration of the user or of the system. git starts
/// no maintenance of its own: a maintenance that a commit starts can write to the git folder
/// when the test removes it.
fn git(folder: &Path, arguments: &[&str]) {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(folder)
        .args(["-c", "user.email=t@example.com", "-c", "user.name=t", "-c", "commit.gpgsign=false"])
        .args(["-c", "maintenance.auto=false", "-c", "gc.auto=0"])
        .args(arguments)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env_remove("GIT_DIR")
        .env_remove("GIT_INDEX_FILE")
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(output.status.success(), "git {arguments:?}: {stderr}");
}

/// A folder that a run before made is the work tree of a create only when it is a work tree of
/// the repository of the create. 2 repositories, made by git: each has a work tree on the
/// branch of the create. For the first repository its own work tree is made, and the work tree
/// of the second repository is not.
#[test]
fn own_tree_a_made_work_tree_is_a_work_tree_of_the_repository_of_the_create() {
    let top = new_folder("made-place");
    let (main, other) = (top.join("main"), top.join("other"));
    let (own, of_other) = (top.join("own"), top.join("of-other"));
    for (repository, work_tree) in [(&main, &own), (&other, &of_other)] {
        std::fs::create_dir_all(repository).unwrap();
        git(repository, &["init", "-q", "-b", "main"]);
        git(repository, &["commit", "-q", "--allow-empty", "-m", "first"]);
        let work_tree = work_tree.to_string_lossy();
        git(repository, &["worktree", "add", "-q", "-b", "cmux/new", &*work_tree]);
    }
    let attempt = |root: PathBuf| {
        let (branch, base) = ("cmux/new".to_string(), "main".to_string());
        Attempt { root, branch, base, base_commit: String::new() }
    };
    let common = main.join(".git");

    let found = (made(&attempt(own), &common), made(&attempt(of_other), &common));

    std::fs::remove_dir_all(top).unwrap();
    assert_eq!(found, (true, false), "the made work tree is of a different repository");
}

/// A work tree of the repository of the create that git keeps locked is not a made work tree:
/// `git worktree add` keeps its lock while it checks the files out. After the unlock, the same
/// work tree is a made work tree.
#[test]
fn own_tree_a_locked_work_tree_is_not_a_made_work_tree() {
    let top = new_folder("made-locked");
    let (main, own) = (top.join("main"), top.join("own"));
    std::fs::create_dir_all(&main).unwrap();
    git(&main, &["init", "-q", "-b", "main"]);
    git(&main, &["commit", "-q", "--allow-empty", "-m", "first"]);
    let work_tree = own.to_string_lossy();
    git(&main, &["worktree", "add", "-q", "-b", "cmux/new", &*work_tree]);
    let (branch, base) = ("cmux/new".to_string(), "main".to_string());
    let attempt = Attempt { root: own.clone(), branch, base, base_commit: String::new() };
    let common = main.join(".git");

    git(&main, &["worktree", "lock", &*work_tree]);
    let locked = made(&attempt, &common);
    git(&main, &["worktree", "unlock", &*work_tree]);
    let unlocked = made(&attempt, &common);

    std::fs::remove_dir_all(top).unwrap();
    assert_eq!((locked, unlocked), (false, true), "a locked work tree is a made work tree");
}

/// What a create gives in a repository whose `post-checkout` hook writes, in the new work tree,
/// a `.git` file that names the git folder of a work tree of a second repository, and then ends
/// with the code `end`: the path of the new work tree, whether the hook wrote the file, and the
/// details of the error of the create.
#[cfg(unix)]
fn create_with_a_hook_that_writes_the_git_entry(
    name: &str,
    end: u8,
) -> (PathBuf, bool, Option<Value>) {
    use std::os::unix::fs::PermissionsExt as _;
    let top = new_folder(name);
    let (main, other) = (top.join("main"), top.join("other"));
    let (root, of_other) = (top.join("root"), top.join("of-other"));
    for repository in [&main, &other] {
        std::fs::create_dir_all(repository).unwrap();
        git(repository, &["init", "-q", "-b", "main"]);
        git(repository, &["commit", "-q", "--allow-empty", "-m", "first"]);
    }
    git(&other, &["worktree", "add", "-q", "-b", "cmux/new", &*of_other.to_string_lossy()]);
    let entry = format!("gitdir: {}", other.join(".git/worktrees/of-other").display());
    let hooks = top.join("hooks");
    std::fs::create_dir_all(&hooks).unwrap();
    let git_entry = root.join(".git");
    let hook =
        format!("#!/bin/sh\nprintf '%s\\n' '{entry}' > '{}'\nexit {end}\n", git_entry.display());
    std::fs::write(hooks.join("post-checkout"), hook).unwrap();
    let mode = std::fs::Permissions::from_mode(0o755);
    std::fs::set_permissions(hooks.join("post-checkout"), mode).unwrap();
    git(&main, &["config", "core.hooksPath", &*hooks.to_string_lossy()]);
    let repository = Repository::open(&main).unwrap();
    let base_commit = repository.commit("main").unwrap();
    let (branch, base) = ("cmux/new".to_string(), "main".to_string());
    let attempt = Attempt { root: root.clone(), branch, base, base_commit };
    let user_git = UserGit { root: &repository.root, deadline: deadline() };

    let created = create(&repository, &user_git, &attempt, &main.join(".git"));

    let written = std::fs::read_to_string(git_entry).unwrap_or_default();
    std::fs::remove_dir_all(top).unwrap();
    (root, written.trim_end() == entry, created.err().map(|error| error.details))
}

/// A create gives a work tree only when the repository of the create keeps it, also when
/// `git worktree add` ends with a success. The hook of the test ends with a success, so git
/// does too. The create is refused with `git_failed`, and the whole message is compared: it
/// names the folder and the branch that git made, each in its place.
#[cfg(unix)]
#[test]
fn own_tree_a_create_gives_only_a_work_tree_that_its_repository_keeps() {
    let (root, written, details) = create_with_a_hook_that_writes_the_git_entry("create-kept", 0);

    assert!(written, "the hook of the test did not write the `.git` file");
    let reason = details.as_ref().map(|details| details["reason"].clone());
    let message = "the create gave a work tree that its repository does not keep";
    assert_eq!(reason, Some(json!("git_failed")), "{message}");
    // A failure of `git worktree add` has the same reason: the message says which refusal it
    // is. The folder and the branch that git made stay: the message names them.
    let text = details.as_ref().and_then(|details| details["extra"]["message"].as_str());
    let wanted = format!(
        "git worktree add ended, and {} is not a worktree that this repository keeps; the \
         folder and the branch cmux/new stay",
        root.to_string_lossy()
    );
    assert_eq!(text, Some(wanted.as_str()));
}

/// The same hook, which now ends with a failure: `git worktree add` fails after the hook wrote
/// the `.git` file. The create is refused with `git_failed` here too. Its message is the one
/// of a failure of git, not the one of a work tree that the repository does not keep.
#[cfg(unix)]
#[test]
fn own_tree_a_create_whose_git_fails_gives_the_message_of_that_failure() {
    let (_, written, details) = create_with_a_hook_that_writes_the_git_entry("create-failed", 1);

    assert!(written, "the hook of the test did not write the `.git` file");
    let reason = details.as_ref().map(|details| details["reason"].clone());
    assert_eq!(reason, Some(json!("git_failed")), "the create gave a work tree");
    let text = details.as_ref().and_then(|details| details["extra"]["message"].as_str());
    assert_eq!(text, Some("git worktree add failed"));
}

/// No setup starts in a folder that is not directly in the `worktrees` folder of the
/// repository's git folder: a folder in the `worktrees` folder of a different repository, the
/// repository's git folder, its `worktrees` folder, a folder below the git folder of a work
/// tree, and a path that goes out of the git folder of a work tree with `..`. Each of these
/// folders has the record that names the work tree, and no ports file is made.
#[test]
fn own_tree_a_setup_starts_in_no_folder_outside_the_worktrees_folder_of_this_repository() {
    let top = new_folder("setup-other-places");
    let (common, other, root) = (top.join("main/.git"), top.join("other/.git"), top.join("new"));
    let admin = common.join("worktrees/new");
    let places = [
        other.join("worktrees/new"),
        common.clone(),
        common.join("worktrees"),
        admin.join("below"),
        admin.join("../../.."),
    ];
    std::fs::create_dir_all(&root).unwrap();
    for place in &places {
        std::fs::create_dir_all(place).unwrap();
        record_of(place, &root);
    }

    let replies = places.map(|place| {
        std::fs::write(root.join(".git"), format!("gitdir: {}\n", place.display())).unwrap();
        setup_of(root.clone(), &common)
    });

    let names = (names_in(&common), names_in(&other));
    std::fs::remove_dir_all(top).unwrap();
    let none: [Value; 5] = std::array::from_fn(|_| json!({"state": "none"}));
    assert_eq!(
        (replies, names),
        (
            none,
            (vec!["gitdir".to_string(), "worktrees".to_string()], vec!["worktrees".to_string()])
        )
    );
}

/// The `.git` file of a new work tree and the record in its git folder can each name their
/// folder by a path from their own folder. The setup starts, and the ports file is in the
/// repository's git folder.
#[test]
fn own_tree_a_setup_starts_with_a_git_entry_that_names_its_folder_from_the_work_tree() {
    let top = new_folder("setup-relative-place");
    let (common, root) = (top.join("main/.git"), top.join("new"));
    let admin = common.join("worktrees/new");
    for folder in [&admin, &root] {
        std::fs::create_dir_all(folder).unwrap();
    }
    std::fs::write(root.join(".git"), "gitdir: ../main/.git/worktrees/new\n").unwrap();
    std::fs::write(admin.join("gitdir"), "../../../../new/.git\n").unwrap();

    let reply = setup_of(root, &common);

    let names = names_in(&common);
    std::fs::remove_dir_all(top).unwrap();
    assert_eq!(
        (&reply["state"], reply["port"].is_u64(), names),
        (&json!("none"), true, WITH_PORTS.map(String::from).to_vec())
    );
}

/// The read of the `.git` entry of a new work tree at its limit: a file of 1 MiB is read, and a
/// file of 1 MiB and 1 byte is not. A `.git` entry that is a folder gives no git folder. A
/// named pipe that has no open end gives no git folder, and its open does not wait.
///
/// The read of the pipe's entry runs on a thread of its own. `None`: it did not end in 10 s.
/// The 10 s are not a time that the read is measured against: they only make a failed test
/// from an open that waits. The test then opens the other end of the pipe and closes it, so an
/// open that waits ends before the join.
#[cfg(unix)]
#[test]
fn own_tree_a_new_git_entry_is_read_to_its_limit_and_a_pipe_with_no_end_is_not_waited_for() {
    use std::os::unix::ffi::OsStrExt as _;
    use std::os::unix::fs::OpenOptionsExt as _;
    let top = new_folder("git-entry-limit");
    let (admin, pipe, folder) = (top.join("admin"), top.join("pipe"), top.join("folder"));
    let (at_the_limit, above_the_limit) = (top.join("at"), top.join("above"));
    for folder in [&admin, &pipe, &folder.join(".git"), &at_the_limit, &above_the_limit] {
        std::fs::create_dir_all(folder).unwrap();
    }
    let name = std::ffi::CString::new(pipe.join(".git").as_os_str().as_bytes()).unwrap();
    // SAFETY: mkfifo(2) with a path that `name` keeps to the end of the call.
    let made = unsafe { libc::mkfifo(name.as_ptr(), 0o600) };
    assert_eq!(made, 0, "the test did not make the named pipe");
    // The entry of git, then line breaks to the given length of the file.
    let entry = format!("gitdir: {}\n", admin.display());
    let of_length = |length: usize| format!("{entry}{}", "\n".repeat(length - entry.len()));
    std::fs::write(at_the_limit.join(".git"), of_length(1024 * 1024)).unwrap();
    std::fs::write(above_the_limit.join(".git"), of_length(1024 * 1024 + 1)).unwrap();

    let (sender, receiver) = std::sync::mpsc::channel();
    let thread = {
        let pipe = pipe.clone();
        std::thread::spawn(move || {
            let _ = sender.send(admin_dir(&pipe));
        })
    };
    let of_the_pipe = receiver.recv_timeout(std::time::Duration::from_secs(10)).ok();
    let mut other_end = std::fs::OpenOptions::new();
    drop(other_end.write(true).custom_flags(libc::O_NONBLOCK).open(pipe.join(".git")));
    let joined = thread.join().is_ok();
    let found =
        (of_the_pipe, admin_dir(&at_the_limit), admin_dir(&above_the_limit), admin_dir(&folder));

    std::fs::remove_dir_all(top).unwrap();
    assert_eq!((found, joined), ((Some(None), Some(admin), None, None), true));
}
