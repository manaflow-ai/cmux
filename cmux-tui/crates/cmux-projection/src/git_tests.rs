use std::process::Command;

use super::*;

fn run(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8(out.stdout).unwrap()
}

/// A repo with a file, an executable, a link, a crate (so a `target` link) and a name that sorts
/// differently as a folder.
fn repo() -> (tempfile::TempDir, PathBuf, String) {
    let dir = tempfile::tempdir().unwrap();
    let work = dir.path().join("work");
    std::fs::create_dir_all(work.join("crate/src")).unwrap();
    std::fs::create_dir_all(work.join("a")).unwrap();
    std::fs::write(work.join("README.md"), "hello\n").unwrap();
    std::fs::write(work.join("a-b"), "dash\n").unwrap();
    std::fs::write(work.join("a/c"), "slash\n").unwrap();
    std::fs::write(work.join("crate/Cargo.lock"), "# lock\n").unwrap();
    std::fs::write(work.join("crate/src/main.rs"), "fn main() {}\n").unwrap();
    std::fs::write(work.join("run.sh"), "#!/bin/sh\n").unwrap();
    let mut perms = std::fs::metadata(work.join("run.sh")).unwrap().permissions();
    std::os::unix::fs::PermissionsExt::set_mode(&mut perms, 0o755);
    std::fs::set_permissions(work.join("run.sh"), perms).unwrap();
    std::os::unix::fs::symlink("README.md", work.join("link")).unwrap();
    run(&work, &["init", "-q"]);
    // As the lane mirrors have it, so a worktree keeps its own excludes.
    run(&work, &["config", "extensions.worktreeConfig", "true"]);
    run(&work, &["add", "-A"]);
    run(&work, &["commit", "-q", "-m", "one"]);
    let commit = run(&work, &["rev-parse", "HEAD"]).trim().to_owned();
    (dir, work.join(".git"), commit)
}

fn project(git_dir: &Path, commit: &str, book: &mut Book, now_ns: i64) -> Projection {
    let items = ls_tree(git_dir, commit).unwrap();
    let links = link_texts(git_dir, &items).unwrap();
    let layout = Layout {
        commit_ns: 1_000_000_000,
        now_ns,
        gitfile: Some("gitdir: /x\n".into()),
        real_root: Path::new("/real"),
        links: &links,
    };
    Projection::build(commit, &items, book, &layout).unwrap()
}

#[test]
fn ls_tree_lines_parse_into_items() {
    let bytes = b"100644 blob 0123456789012345678901234567890123456789      12\tsrc/a b.rs\0\
160000 commit 1111111111111111111111111111111111111111       -\tvendor/sub\0";
    let items = parse_ls_tree(bytes).unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(items[0].path, "src/a b.rs");
    assert_eq!(items[0].mode, 0o100_644);
    assert_eq!(items[0].size, 12);
    assert_eq!(items[1].mode, GITLINK);
    assert_eq!(items[1].size, 0);
}

#[test]
fn the_book_keeps_an_mtime_while_the_blob_stays_and_resets_it_when_it_changes() {
    let mut book = Book::default();
    assert_eq!(book.mtime("a", "x", 10), 10);
    assert_eq!(book.mtime("a", "x", 20), 10, "same blob, same mtime");
    assert_eq!(book.mtime("a", "y", 30), 30, "new content is newer than any build");
    assert_eq!(book.mtime("a", "x", 40), 40, "going back to an old blob is new content too");
    book.retain(&BTreeSet::new());
    assert_eq!(book.mtime("a", "y", 50), 50, "a path that left and came back is new");
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("book");
    book.save(&file).unwrap();
    assert_eq!(Book::load(&file), book);
}

#[test]
fn a_commit_projects_with_links_a_gitfile_and_build_output_on_the_real_disk() {
    let (_dir, git_dir, commit) = repo();
    let mut book = Book::default();
    let projection = project(&git_dir, &commit, &mut book, 5_000_000_000);
    let manifest = &projection.manifest;
    let link = manifest.entry(manifest.resolve("link").unwrap()).unwrap();
    assert_eq!(link.kind, Kind::Link);
    assert_eq!(link.link.as_deref(), Some("README.md"));
    let run_sh = manifest.entry(manifest.resolve("run.sh").unwrap()).unwrap();
    assert_eq!(run_sh.mode, 0o755);
    assert_eq!(run_sh.mtime_ns, 5_000_000_000);
    let target = manifest.entry(manifest.resolve("crate/target").unwrap()).unwrap();
    assert_eq!(target.link.as_deref(), Some("/real/crate/target"));
    assert_eq!(projection.real_dirs, ["crate/target"]);
    let gitfile = manifest.resolve(".git").unwrap();
    assert_eq!(projection.sources[gitfile as usize], Source::Bytes(b"gitdir: /x\n".to_vec()));
    let blobs = GitBlobs::new(&git_dir, projection.sources.clone());
    let readme = manifest.resolve("README.md").unwrap();
    assert_eq!(blobs.read(readme, 0, 100).unwrap(), b"hello\n");
    assert_eq!(blobs.read(readme, 2, 2).unwrap(), b"ll");
    assert!(!blobs.cache());
    let paths: Vec<&str> = projection.index.iter().map(|entry| entry.path.as_str()).collect();
    assert_eq!(
        paths,
        ["README.md", "a-b", "a/c", "crate/Cargo.lock", "crate/src/main.rs", "link", "run.sh"]
    );

    // The same commit again: every mtime is the one served before.
    let again = project(&git_dir, &commit, &mut book, 9_000_000_000);
    let second = again.manifest.entry(again.manifest.resolve("run.sh").unwrap()).unwrap();
    assert_eq!(second.mtime_ns, 5_000_000_000);
}

#[cfg(target_os = "linux")]
#[test]
fn a_mounted_commit_is_a_clean_worktree_and_writes_land_in_the_upper_folder() {
    let fuse = Path::new("/dev/fuse").exists()
        && Command::new("fusermount3")
            .arg("--version")
            .output()
            .is_ok_and(|out| out.status.success());
    if !fuse {
        println!("skipping: no FUSE here (no /dev/fuse or no fusermount3)");
        return;
    }
    let (dir, git_dir, commit) = repo();
    let at = dir.path().join("mnt");
    std::fs::create_dir_all(&at).unwrap();
    let items = ls_tree(&git_dir, &commit).unwrap();
    let links = link_texts(&git_dir, &items).unwrap();
    let admin = git_dir.join("worktrees").join("projected");
    let real_root = dir.path().join("real");
    let layout = Layout {
        commit_ns: 1_000_000_000,
        now_ns: 5_000_000_000,
        gitfile: Some(Worktree::gitfile(&admin)),
        real_root: &real_root,
        links: &links,
    };
    let projection = Projection::build(&commit, &items, &mut Book::default(), &layout).unwrap();
    for real in &projection.real_dirs {
        std::fs::create_dir_all(real_root.join(real)).unwrap();
    }
    // SAFETY: getuid and getgid cannot fail.
    let owner = unsafe { (libc::getuid(), libc::getgid()) };
    let index = index_bytes(&projection.index, owner.0, owner.1).unwrap();
    Worktree::write(&git_dir, "projected", &at, &commit, &index, &projection.real_dirs).unwrap();
    let blobs = std::sync::Arc::new(GitBlobs::new(&git_dir, projection.sources));
    let state = dir.path().join("state");
    let overlay = std::sync::Arc::new(
        crate::overlay::Overlay::open(
            std::sync::Arc::new(projection.manifest),
            &state,
            blobs,
            owner,
        )
        .unwrap(),
    );
    let mounted = crate::mount::mount(overlay, &at).unwrap();
    assert_eq!(std::fs::read_to_string(at.join("crate/src/main.rs")).unwrap(), "fn main() {}\n");
    assert_eq!(run(&at, &["status", "--porcelain"]), "", "every file matches its index entry");
    assert_eq!(run(&at, &["rev-parse", "HEAD"]).trim(), commit);
    std::fs::write(at.join("crate/target/out"), "built").unwrap();
    assert!(real_root.join("crate/target/out").exists(), "build output is on the real disk");
    std::fs::write(at.join("README.md"), "changed\n").unwrap();
    assert_eq!(run(&at, &["status", "--porcelain"]), " M README.md\n");
    assert!(state.join("upper/README.md").exists());
    mounted.unmount();
}

#[test]
fn registering_the_same_checkout_again_leaves_head_untouched() {
    let (dir, git_dir, commit) = repo();
    let at = dir.path().join("mnt");
    let first = Worktree::write(&git_dir, "projected", &at, &commit, b"index", &[]).unwrap();
    let head = first.admin.join("HEAD");
    let old = std::time::SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_000);
    std::fs::File::options().write(true).open(&head).unwrap().set_modified(old).unwrap();
    Worktree::write(&git_dir, "projected", &at, &commit, b"index", &[]).unwrap();
    assert_eq!(
        std::fs::metadata(&head).unwrap().modified().unwrap(),
        old,
        "a build script watches HEAD"
    );
}

#[test]
fn registration_refuses_an_ordinary_worktree_without_touching_its_index() {
    let (dir, git_dir, commit) = repo();
    let work = git_dir.parent().unwrap();
    let ordinary = dir.path().join("projected");
    let ordinary_text = ordinary.to_str().unwrap();
    run(work, &["worktree", "add", "--detach", ordinary_text, &commit]);
    std::fs::write(ordinary.join("README.md"), "staged\n").unwrap();
    run(&ordinary, &["add", "README.md"]);
    let admin = git_dir.join("worktrees/projected");
    let before = std::fs::read(admin.join("index")).unwrap();
    let error =
        Worktree::write(&git_dir, "projected", &dir.path().join("mnt"), &commit, b"new", &[])
            .expect_err("ordinary worktrees must never be replaced");
    assert!(error.to_string().contains("not owned by this projection"));
    assert_eq!(std::fs::read(admin.join("index")).unwrap(), before);
    assert_eq!(run(&ordinary, &["status", "--porcelain"]), "M  README.md\n");
}

#[test]
fn a_second_mount_name_cannot_take_over_an_owned_admin_directory() {
    let (dir, git_dir, commit) = repo();
    let first_at = dir.path().join("first");
    let second_at = dir.path().join("second");
    let first = Worktree::write(&git_dir, "projected", &first_at, &commit, b"first", &[]).unwrap();
    let before_gitdir = std::fs::read(first.admin.join("gitdir")).unwrap();
    let before_index = std::fs::read(first.admin.join("index")).unwrap();
    assert!(Worktree::write(&git_dir, "projected", &second_at, &commit, b"second", &[]).is_err());
    assert_eq!(std::fs::read(first.admin.join("gitdir")).unwrap(), before_gitdir);
    assert_eq!(std::fs::read(first.admin.join("index")).unwrap(), before_index);
}

#[test]
fn concurrent_different_mounts_can_claim_a_name_only_once() {
    let (dir, git_dir, commit) = repo();
    let first_at = dir.path().join("first");
    let second_at = dir.path().join("second");
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
    let (first, second) = std::thread::scope(|scope| {
        let first_barrier = barrier.clone();
        let first_git = git_dir.clone();
        let first_commit = commit.clone();
        let first_at = first_at.clone();
        let first = scope.spawn(move || {
            first_barrier.wait();
            Worktree::write(&first_git, "racing", &first_at, &first_commit, b"first", &[]).is_ok()
        });
        let second_barrier = barrier.clone();
        let second_git = git_dir.clone();
        let second_commit = commit.clone();
        let second_at = second_at.clone();
        let second = scope.spawn(move || {
            second_barrier.wait();
            Worktree::write(&second_git, "racing", &second_at, &second_commit, b"second", &[])
                .is_ok()
        });
        (first.join().unwrap(), second.join().unwrap())
    });
    assert_ne!(first, second, "exactly one racing claimant must own the admin directory");
    let admin = git_dir.join("worktrees/racing");
    let gitdir = std::fs::read_to_string(admin.join("gitdir")).unwrap();
    assert!(
        gitdir == format!("{}/.git\n", first_at.display())
            || gitdir == format!("{}/.git\n", second_at.display())
    );
}

#[test]
fn bare_mirrors_enable_worktree_config_for_projection_excludes() {
    let dir = tempfile::tempdir().unwrap();
    let git_dir = dir.path().join("mirror.git");
    let git_dir_text = git_dir.to_str().unwrap();
    run(dir.path(), &["init", "--bare", "-q", git_dir_text]);
    let at = dir.path().join("mnt");
    Worktree::write(&git_dir, "projected", &at, "deadbeef", b"index", &["target".into()]).unwrap();

    assert_eq!(
        run(
            dir.path(),
            &["--git-dir", git_dir_text, "config", "--bool", "extensions.worktreeConfig"]
        ),
        "true\n"
    );
    let config = git_dir.join("worktrees/projected/config.worktree");
    let config_text = config.to_str().unwrap();
    let exclude = git_dir.join("worktrees/projected/projection-exclude");
    assert_eq!(
        run(dir.path(), &["config", "--file", config_text, "--get", "core.excludesFile"]),
        format!("{}\n", exclude.display())
    );
    assert_eq!(
        run(dir.path(), &["config", "--file", config_text, "--get", "core.bare"]),
        "false\n"
    );
}

#[test]
fn object_reader_drains_non_blob_records_before_the_next_blob() {
    let (_dir, git_dir, commit) = repo();
    let work = git_dir.parent().unwrap();
    let readme = run(work, &["rev-parse", "HEAD:README.md"]).trim().to_owned();
    let mut reader = ObjectReader::spawn_local(&git_dir).unwrap();
    assert_eq!(reader.blob(&commit), None, "a commit is not a blob");
    assert_eq!(reader.blob(&readme), Some(b"hello\n".to_vec()));
}

#[test]
fn worktree_names_cannot_escape_the_mirror_admin_directory() {
    let (_dir, git_dir, commit) = repo();
    let at = git_dir.parent().unwrap().join("mnt");
    for name in ["", ".", "..", "nested/projected", "/tmp/projected"] {
        assert!(Worktree::write(&git_dir, name, &at, &commit, b"index", &[]).is_err(), "{name:?}");
    }
}

#[test]
fn git_reads_the_written_index_as_the_commit() {
    let (_dir, git_dir, commit) = repo();
    let mut book = Book::default();
    let projection = project(&git_dir, &commit, &mut book, 5_000_000_000);
    let bytes = index_bytes(&projection.index, 1000, 1000).unwrap();
    let index = git_dir.join("index");
    std::fs::write(&index, bytes).unwrap();
    let work = git_dir.parent().unwrap();
    let staged = run(work, &["ls-files", "-s"]);
    let committed =
        run(work, &["ls-tree", "-r", "--format=%(objectmode) %(objectname) 0\t%(path)", &commit]);
    assert_eq!(staged, committed);
    let debug = run(work, &["ls-files", "--debug", "run.sh"]);
    assert!(debug.contains("mtime: 5:0"), "{debug}");
    assert!(debug.contains("size: 10"), "{debug}");
}
