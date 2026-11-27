use super::*;

/// The scratch git dir a plan build's diff stages files into is the owner's alone, even under
/// a umask that leaves new folders readable by everyone, and it is never an existing folder.
#[cfg(unix)]
#[test]
fn a_scratch_git_dir_is_readable_only_by_its_owner() {
    use std::os::unix::fs::PermissionsExt as _;
    let dir = std::env::temp_dir().join(format!("acpmux-private-{}", uuid::Uuid::now_v7()));
    private_dir(&dir).unwrap();
    let mode = std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o700, "{mode:o}");
    assert!(private_dir(&dir).is_err(), "an existing folder is refused");
    std::fs::remove_dir(&dir).unwrap();
}

#[cfg(unix)]
#[test]
fn git_output_deadline_covers_a_descendant_holding_the_pipe() {
    let mut command = Command::new("sh");
    command.args(["-c", "sleep 10 & exit 0"]);
    let by = Instant::now() + std::time::Duration::from_millis(200);
    let result = output_by(command, None, Some(by));
    assert!(result.is_err(), "a still-open output must time out: {result:?}");
    assert!(by.elapsed() < std::time::Duration::from_secs(5));
}

#[test]
fn slug_matches_the_worktree_names() {
    assert_eq!(slug("Fix the flaky upload test!"), "fix-the-flaky-upload-test");
    assert_eq!(slug("  --  "), "");
    assert_eq!(slug(&"a".repeat(80)).len(), 48);
}

/// A scratch folder removed on drop.
struct Scratch(PathBuf);

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn sh(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// A repository `proj` with commits `first` (on `main`) and `second`
/// (on `next`), and a home folder beside it.
fn repo() -> (Scratch, PathBuf, PathBuf) {
    let top = std::env::temp_dir().join(format!("acpmux-ensure-{}", uuid::Uuid::now_v7()));
    let (repo, home) = (top.join("proj"), top.join("home"));
    std::fs::create_dir_all(repo.join("sub")).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    sh(&repo, &["init", "-q", "-b", "main"]);
    std::fs::write(repo.join("sub/a.txt"), "first\n").unwrap();
    sh(&repo, &["add", "."]);
    sh(&repo, &["commit", "-q", "-m", "first"]);
    sh(&repo, &["checkout", "-q", "-b", "next"]);
    std::fs::write(repo.join("sub/a.txt"), "second\n").unwrap();
    sh(&repo, &["commit", "-q", "-am", "second"]);
    sh(&repo, &["checkout", "-q", "main"]);
    (Scratch(top), repo, home)
}

/// Whether `dir`'s repository has branch `cmux/<name>`.
fn branch_in(dir: &Path, name: &str) -> bool {
    let refname = format!("refs/heads/cmux/{name}");
    let status = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["rev-parse", "--verify", "--quiet", &refname])
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()
        .unwrap()
        .status;
    status.success()
}

/// A sub-session's checked folder, held open, is renamed away and another repository takes
/// its path before the worktree is made: the worktree is of the folder held, never of the
/// one at its path now, and its removal leaves that one alone too.
#[cfg(unix)]
#[test]
fn a_held_folder_makes_its_worktree_from_itself_wherever_its_path_leads() {
    let (scratch, repo, home) = repo();
    let held = std::fs::File::open(repo.join("sub")).unwrap();
    let moved = scratch.0.join("proj-moved");
    std::fs::rename(&repo, &moved).unwrap();
    std::fs::create_dir_all(repo.join("sub")).unwrap();
    sh(&repo, &["init", "-q", "-b", "main"]);
    std::fs::write(repo.join("sub/a.txt"), "unchecked\n").unwrap();
    sh(&repo, &["add", "."]);
    sh(&repo, &["commit", "-q", "-m", "unchecked"]);

    let path = repo.join("sub");
    let at = Dir::held(&path, Some(&held));
    let made = make_worktree_under(at, "Task", &home).unwrap();
    assert_eq!(std::fs::read_to_string(made.cwd.join("a.txt")).unwrap(), "first\n");
    assert_eq!(sh(&moved, &["rev-parse", "cmux/task"]), sh(&moved, &["rev-parse", "main"]));
    assert!(!branch_in(&repo, "task"), "no branch in the repository now at the path");

    remove_worktree(at, &made);
    assert!(!made.root.exists(), "removed");
    assert!(!branch_in(&moved, "task"), "its branch removed from the folder held");
}

/// The worktree made is proven to be the one at its path; a folder renamed into its place
/// (here with a copy of its `.git` file, so git takes it for the same worktree) is not.
#[cfg(unix)]
#[test]
fn a_folder_that_took_a_made_worktrees_place_is_not_it() {
    let (scratch, repo, home) = repo();
    let made = make_worktree_under(repo.as_path().into(), "Task", &home).unwrap();
    let held = std::fs::File::open(&made.cwd).unwrap();
    let at = Dir::held(&made.cwd, Some(&held));
    assert_eq!(verify_made(repo.as_path().into(), &made, at), Ok(()));

    let impostor = scratch.0.join("impostor");
    std::fs::create_dir_all(&impostor).unwrap();
    std::fs::copy(made.root.join(".git"), impostor.join(".git")).unwrap();
    std::fs::rename(&made.root, scratch.0.join("made-moved")).unwrap();
    std::fs::rename(&impostor, &made.root).unwrap();
    let held = std::fs::File::open(&made.root).unwrap();
    let at = Dir::held(&made.root, Some(&held));
    let refused = verify_made(repo.as_path().into(), &made, at).unwrap_err();
    assert!(refused.contains("not the worktree that was made"), "{refused}");
}

/// A folder that takes the new worktree's place while git adds it (here as soon as it is
/// added, with a copy of its `.git` file) is not the one made either.
#[cfg(unix)]
#[test]
fn a_folder_that_took_the_worktrees_place_as_git_added_it_is_not_it() {
    let (scratch, repo, home) = repo();
    let at_scratch = scratch.0.clone();
    AFTER_ADD.with(|h| {
        *h.borrow_mut() = Some(Box::new(move |root: &Path| {
            let impostor = at_scratch.join("impostor");
            std::fs::create_dir_all(&impostor).unwrap();
            std::fs::copy(root.join(".git"), impostor.join(".git")).unwrap();
            std::fs::rename(root, at_scratch.join("made-moved")).unwrap();
            std::fs::rename(&impostor, root).unwrap();
        }))
    });
    let made = make_worktree_under(repo.as_path().into(), "Task", &home).unwrap();
    let held = std::fs::File::open(&made.cwd).unwrap();
    let at = Dir::held(&made.cwd, Some(&held));
    let refused = verify_made(repo.as_path().into(), &made, at).unwrap_err();
    assert!(refused.contains("not the worktree that was made"), "{refused}");
}

/// A held impostor is not the worktree made even while the made folder is put back at its
/// path for the identity check and swapped out again before git looks: the held start
/// folder itself must be in the folder made.
#[cfg(unix)]
#[test]
fn a_held_impostor_is_refused_though_the_made_folder_is_back_at_its_path_for_a_moment() {
    let (scratch, repo, home) = repo();
    let made = make_worktree_under(repo.as_path().into(), "Task", &home).unwrap();
    let (aside, impostor) = (scratch.0.join("made-aside"), scratch.0.join("impostor"));
    std::fs::create_dir_all(&impostor).unwrap();
    std::fs::copy(made.root.join(".git"), impostor.join(".git")).unwrap();
    std::fs::rename(&made.root, &aside).unwrap();
    std::fs::rename(&impostor, &made.root).unwrap();
    let held = std::fs::File::open(&made.root).unwrap();
    // The made folder back at its path for the identity check...
    std::fs::rename(&made.root, &impostor).unwrap();
    std::fs::rename(&aside, &made.root).unwrap();
    let (moved_aside, moved_impostor) = (aside.clone(), impostor.clone());
    AFTER_ROOT_CHECK.with(|h| {
        *h.borrow_mut() = Some(Box::new(move |root: &Path| {
            // ...and the impostor back before git looks.
            std::fs::rename(root, &moved_aside).unwrap();
            std::fs::rename(&moved_impostor, root).unwrap();
        }))
    });
    let at = Dir::held(&made.root, Some(&held));
    let refused = verify_made(repo.as_path().into(), &made, at).unwrap_err();
    assert!(refused.contains("not the worktree that was made"), "{refused}");
}

/// The folder made is held: one that takes its place after it is deleted never gets its
/// inode (a file system reuses a freed one at once), so it is refused.
#[cfg(unix)]
#[test]
fn a_folder_made_after_the_worktree_was_deleted_never_passes_for_it() {
    let (scratch, repo, home) = repo();
    let made = make_worktree_under(repo.as_path().into(), "Task", &home).unwrap();
    let git_file = std::fs::read(made.root.join(".git")).unwrap();
    let gone = scratch.0.join("gone");
    std::fs::rename(&made.root, &gone).unwrap();
    std::fs::remove_dir_all(&gone).unwrap();
    std::fs::create_dir(&made.root).unwrap();
    std::fs::write(made.root.join(".git"), git_file).unwrap();
    let held = std::fs::File::open(&made.root).unwrap();
    let at = Dir::held(&made.root, Some(&held));
    let refused = verify_made(repo.as_path().into(), &made, at).unwrap_err();
    assert!(refused.contains("not the worktree that was made"), "{refused}");
}

/// Removing a worktree whose path another folder took leaves that folder alone.
#[cfg(unix)]
#[test]
fn removing_a_worktree_leaves_a_folder_that_took_its_place_alone() {
    let (scratch, repo, home) = repo();
    let made = make_worktree_under(repo.as_path().into(), "Task", &home).unwrap();
    let (aside, impostor) = (scratch.0.join("made-aside"), scratch.0.join("impostor"));
    std::fs::create_dir_all(&impostor).unwrap();
    std::fs::copy(made.root.join(".git"), impostor.join(".git")).unwrap();
    std::fs::write(impostor.join("sentinel"), "theirs\n").unwrap();
    std::fs::rename(&made.root, &aside).unwrap();
    std::fs::rename(&impostor, &made.root).unwrap();

    remove_worktree(repo.as_path().into(), &made);
    assert!(made.root.join("sentinel").exists(), "the folder at its path is not removed");
    assert!(branch_in(&repo, "task"), "its branch stays with its registration");
}

/// A folder that takes the worktree's place while it is being removed is left alone too:
/// nothing is removed by path but an empty folder.
#[cfg(unix)]
#[test]
fn a_folder_that_takes_the_worktrees_place_during_its_removal_is_left_alone() {
    let (scratch, repo, home) = repo();
    let made = make_worktree_under(repo.as_path().into(), "Task", &home).unwrap();
    let git_file = std::fs::read(made.root.join(".git")).unwrap();
    let (aside, impostor) = (scratch.0.join("made-aside"), scratch.0.join("impostor"));
    BEFORE_PATH_REMOVAL.with(|h| {
        *h.borrow_mut() = Some(Box::new(move |root: &Path| {
            std::fs::create_dir_all(&impostor).unwrap();
            std::fs::write(impostor.join(".git"), git_file).unwrap();
            std::fs::write(impostor.join("sentinel"), "theirs\n").unwrap();
            std::fs::rename(root, &aside).unwrap();
            std::fs::rename(&impostor, root).unwrap();
        }))
    });
    remove_worktree(repo.as_path().into(), &made);
    assert!(made.root.join("sentinel").exists(), "the folder at its path is not removed");
    assert!(branch_in(&repo, "task"), "its branch stays with its registration");
}

/// Removing a worktree removes its own registration only: another worktree of the same
/// repository whose folder is away for now keeps its own (its index, its HEAD).
#[cfg(unix)]
#[test]
fn removing_a_worktree_keeps_another_worktrees_registration_while_its_folder_is_away() {
    let (scratch, repo, home) = repo();
    let other = scratch.0.join("other");
    sh(&repo, &["worktree", "add", "-q", "-b", "other", &other.to_string_lossy()]);
    std::fs::write(other.join("staged.txt"), "staged\n").unwrap();
    sh(&other, &["add", "staged.txt"]);
    let away = scratch.0.join("other-away");
    std::fs::rename(&other, &away).unwrap();

    let made = make_worktree_under(repo.as_path().into(), "Task", &home).unwrap();
    remove_worktree(repo.as_path().into(), &made);
    assert!(!made.root.exists(), "removed");
    assert!(!branch_in(&repo, "task"), "its branch removed");

    std::fs::rename(&away, &other).unwrap();
    let staged = sh(&other, &["diff", "--cached", "--name-only"]);
    assert_eq!(staged.trim(), "staged.txt", "the other worktree keeps its index");
}

/// A registration that takes the removed worktree's registration's place while it is being
/// removed is left alone, with its branch.
#[cfg(unix)]
#[test]
fn a_registration_that_takes_the_removed_ones_place_is_left_alone() {
    let (scratch, repo, home) = repo();
    let other = scratch.0.join("other");
    sh(&repo, &["worktree", "add", "-q", "-b", "other", &other.to_string_lossy()]);
    let worktrees = std::fs::canonicalize(repo.join(".git/worktrees")).unwrap();
    let made = make_worktree_under(repo.as_path().into(), "Task", &home).unwrap();
    let aside = scratch.0.join("registration-aside");
    let others = worktrees.join("other");
    BEFORE_REGISTRATION_REMOVAL.with(|h| {
        *h.borrow_mut() = Some(Box::new(move |admin: &Path| {
            std::fs::rename(admin, &aside).unwrap();
            std::fs::rename(&others, admin).unwrap();
        }))
    });
    remove_worktree(repo.as_path().into(), &made);
    let admin = worktrees.join(made.root.file_name().unwrap());
    assert!(admin.join("HEAD").exists(), "the registration that took its place stays");
    assert_ne!(sh(&repo, &["branch", "--list", "other"]), "", "its branch stays");
}

/// The emptied root stays at its path until its registration and branch are gone, so
/// nothing is recreated there meanwhile; a folder that takes its place before it is removed
/// keeps its files.
#[cfg(unix)]
#[test]
fn the_emptied_root_holds_its_path_until_last_and_a_folder_that_takes_it_stays() {
    let (scratch, repo, home) = repo();
    let made = make_worktree_under(repo.as_path().into(), "Task", &home).unwrap();
    let git_file = std::fs::read(made.root.join(".git")).unwrap();
    let held_at_path = std::sync::Arc::new(std::sync::Mutex::new(None));
    let seen = held_at_path.clone();
    let (pin, aside) = (made.root_pin, scratch.0.join("emptied-aside"));
    BEFORE_ROOT_RMDIR.with(|h| {
        *h.borrow_mut() = Some(Box::new(move |root: &Path| {
            *seen.lock().unwrap() = Some(crate::cwd_pin::CwdPin::of(root) == pin);
            std::fs::rename(root, &aside).unwrap();
            std::fs::create_dir(root).unwrap();
            std::fs::write(root.join(".git"), git_file).unwrap();
            std::fs::write(root.join("sentinel"), "theirs\n").unwrap();
        }))
    });
    remove_worktree(repo.as_path().into(), &made);
    assert_eq!(*held_at_path.lock().unwrap(), Some(true), "the made folder held its path");
    assert!(!branch_in(&repo, "task"), "its own branch removed");
    assert!(made.root.join("sentinel").exists(), "the folder that took its place stays");
}

/// A worktree whose `.git` file and registration name each other by relative paths (git's
/// `worktree.useRelativePaths`) is removed whole too.
#[cfg(unix)]
#[test]
fn a_worktree_registered_by_relative_paths_is_removed_whole() {
    let (_scratch, repo, home) = repo();
    let made = make_worktree_under(repo.as_path().into(), "Task", &home).unwrap();
    let admin = std::fs::canonicalize(repo.join(".git/worktrees/task")).unwrap();
    let root = std::fs::canonicalize(&made.root).unwrap();
    let relative = |from: &Path, to: &Path| {
        let up = from.components().count() - 1;
        let mut p = PathBuf::from("../".repeat(up));
        p.push(to.strip_prefix("/").unwrap());
        p
    };
    let to_admin = relative(&root, &admin);
    std::fs::write(made.root.join(".git"), format!("gitdir: {}\n", to_admin.display())).unwrap();
    let to_root = relative(&admin, &root.join(".git"));
    std::fs::write(admin.join("gitdir"), format!("{}\n", to_root.display())).unwrap();

    remove_worktree(repo.as_path().into(), &made);
    assert!(!made.root.exists(), "its folder removed");
    assert!(!admin.exists(), "its registration removed");
    assert!(!branch_in(&repo, "task"), "its branch removed");
}

/// A link put at the new worktree's path as git adds it never has the checkout written
/// through it: the repository it leads to keeps its files and its index.
#[cfg(unix)]
#[test]
fn a_link_at_the_worktrees_path_never_gets_the_checkout_written_through_it() {
    let (scratch, repo, home) = repo();
    let victim = scratch.0.join("victim");
    std::fs::create_dir_all(victim.join("sub")).unwrap();
    sh(&victim, &["init", "-q", "-b", "main"]);
    std::fs::write(victim.join("sub/a.txt"), "victim's own\n").unwrap();
    sh(&victim, &["add", "."]);
    sh(&victim, &["commit", "-q", "-m", "victim"]);
    let index = std::fs::read(victim.join(".git/index")).unwrap();
    let (aside, link_to) = (scratch.0.join("made-aside"), victim.clone());
    AFTER_ADD.with(|h| {
        *h.borrow_mut() = Some(Box::new(move |root: &Path| {
            std::fs::rename(root, &aside).unwrap();
            std::os::unix::fs::symlink(&link_to, root).unwrap();
        }))
    });
    let _ = make_worktree_under(repo.as_path().into(), "Task", &home);
    assert_eq!(std::fs::read_to_string(victim.join("sub/a.txt")).unwrap(), "victim's own\n");
    assert_eq!(std::fs::read(victim.join(".git/index")).unwrap(), index, "its index untouched");
}

/// The descriptor removal reads a folder through never reaches a child another thread
/// spawns meanwhile: it is close-on-exec from the moment it exists.
#[cfg(unix)]
#[test]
fn the_descriptor_a_removal_reads_through_is_close_on_exec_at_once() {
    let (scratch, _repo, _home) = repo();
    let dir = scratch.0.join("to-empty");
    std::fs::create_dir_all(dir.join("a")).unwrap();
    let flags = std::sync::Arc::new(std::sync::Mutex::new(None));
    let seen = flags.clone();
    AFTER_DUP.with(|h| {
        *h.borrow_mut() = Some(Box::new(move |fd| {
            *seen.lock().unwrap() = Some(unsafe { libc::fcntl(fd, libc::F_GETFD) });
        }))
    });
    empty_held(&std::fs::File::open(&dir).unwrap()).unwrap();
    let flags = flags.lock().unwrap().expect("a descriptor was duplicated");
    assert_ne!(flags & libc::FD_CLOEXEC, 0, "close-on-exec");
}

/// Off unix there is no folder identity: an untouched worktree is proven by git alone.
#[cfg(not(unix))]
#[test]
fn a_made_worktree_is_proven_by_git_alone_off_unix() {
    let (_scratch, repo, home) = repo();
    let made = make_worktree_under(repo.as_path().into(), "Task", &home).unwrap();
    assert_eq!(made.root_pin, None);
    let at = Dir::from(made.cwd.as_path());
    assert_eq!(verify_made(repo.as_path().into(), &made, at), Ok(()));
}

/// A revive's worktree add waits while this process changes the same repository (a model
/// race's add holds its lock), so two worktree changes never run at once in one repository.
#[test]
fn a_revive_add_waits_for_the_repository_lock() {
    let (_scratch, repo, home) = repo();
    let root = home.join("revived");
    let at = sh(&repo, &["rev-parse", "HEAD"]);
    let (tx, rx) = std::sync::mpsc::channel();
    with_repo_lock(repo.as_path().into(), || {
        let (common, target, at) = (repo.join(".git"), root.clone(), at.clone());
        std::thread::spawn(move || {
            let by = Instant::now() + std::time::Duration::from_secs(60);
            let place = target.to_string_lossy().into_owned();
            let args = ["--detach", place.as_str(), at.as_str()];
            let _ = tx.send(add_without_config(&common, &args, &target, &at, by));
        });
        // Waits for what must not happen: the add finishing while the lock is held.
        let early = rx.recv_timeout(std::time::Duration::from_secs(5));
        assert!(early.is_err(), "the revive changed the repository under its lock: {early:?}");
        assert!(!root.exists());
    });
    let added = rx.recv_timeout(std::time::Duration::from_secs(60)).expect("the revive ran");
    assert_eq!(added, Ok(()));
    assert!(root.join(".git").is_file());
}

#[test]
fn recovery_does_not_nest_a_worktree_in_a_reappeared_destination() {
    let (_scratch, repo, home) = repo();
    let root = home.join("reappeared");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("keep"), "user data").unwrap();
    let at = sh(&repo, &["rev-parse", "HEAD"]);
    let by = Instant::now() + std::time::Duration::from_secs(10);
    let result = add_without_config(
        &repo.join(".git"),
        &["--detach", root.to_str().unwrap(), &at],
        &root,
        &at,
        by,
    );
    assert!(result.is_err(), "destination appeared meanwhile: {result:?}");
    assert_eq!(std::fs::read_to_string(root.join("keep")).unwrap(), "user data");
    assert_eq!(std::fs::read_dir(root).unwrap().count(), 1, "no nested recovery tree");
}

#[test]
fn a_named_worktree_is_made_once_and_then_found() {
    let (_scratch, repo, home) = repo();
    let made = ensure_worktree_under(&repo, "Lane One", Some("next"), &home, None).unwrap();
    assert_eq!(made.reused, None);
    let w = &made.worktree;
    assert_eq!(w.root, home.join(".cmux/worktrees/proj/lane-one"));
    assert_eq!(w.branch, "cmux/lane-one");
    assert_eq!(w.base, "next");
    assert_eq!(std::fs::read_to_string(w.root.join("sub/a.txt")).unwrap(), "second\n");
    assert_eq!(sh(&repo, &["rev-parse", "cmux/lane-one"]), sh(&repo, &["rev-parse", "next"]));

    // Again, from a subfolder and with another base: the same worktree, untouched.
    std::fs::write(w.root.join("sub/a.txt"), "edited\n").unwrap();
    let again =
        ensure_worktree_under(&repo.join("sub"), "Lane One", Some("main"), &home, None).unwrap();
    assert_eq!(again.reused, Some("worktree"));
    assert_eq!(again.worktree.root, w.root);
    assert_eq!(again.worktree.cwd, w.root.join("sub"));
    assert_eq!(again.worktree.base, "next");
    assert_eq!(std::fs::read_to_string(w.root.join("sub/a.txt")).unwrap(), "edited\n");

    // Its folder gone, its branch kept: a new folder on that branch.
    sh(&repo, &["worktree", "remove", "--force", &w.root.to_string_lossy()]);
    let back = ensure_worktree_under(&repo, "Lane One", None, &home, None).unwrap();
    assert_eq!(back.reused, Some("branch"));
    assert_eq!(back.worktree.branch, "cmux/lane-one");
    assert_eq!(std::fs::read_to_string(w.root.join("sub/a.txt")).unwrap(), "second\n");
}

#[test]
fn a_named_worktree_refuses_what_it_cannot_reuse() {
    let (_scratch, repo, home) = repo();
    let squatter = home.join(".cmux/worktrees/proj/taken");
    std::fs::create_dir_all(&squatter).unwrap();
    let e = ensure_worktree_under(&repo, "taken", None, &home, None).err().unwrap();
    assert!(e.contains("is not a worktree of this repository"), "{e}");
    let e = ensure_worktree_under(&repo, "x", Some("no-such-ref"), &home, None).err().unwrap();
    assert!(e.contains("no commit"), "{e}");
    let e = ensure_worktree_under(&repo, "x", Some("--orphan"), &home, None).err().unwrap();
    assert!(e.contains("not an option"), "{e}");
    // Its branch checked out in another folder: said once, with that folder.
    let elsewhere = home.join("elsewhere");
    sh(&repo, &["worktree", "add", "-q", "-b", "cmux/y", &elsewhere.to_string_lossy()]);
    let e = ensure_worktree_under(&repo, "y", None, &home, None).err().unwrap();
    assert!(e.contains("checked out in another worktree") && e.contains("elsewhere"), "{e}");
    assert!(ensure_worktree_under(&repo, "//", None, &home, None).is_err());
}
