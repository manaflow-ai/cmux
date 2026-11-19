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
    let index = index_bytes(&projection.index, ObjectFormat::Sha1, owner.0, owner.1).unwrap();
    Worktree::write(&git_dir, "projected", &at, &commit, &index, &projection.real_dirs).unwrap();
    let blobs = Arc::new(GitBlobs::new(&git_dir, projection.sources));
    let state = dir.path().join("state");
    let overlay = Arc::new(
        crate::overlay::Overlay::open(Arc::new(projection.manifest), &state, blobs, owner).unwrap(),
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
            .err()
            .expect("ordinary worktrees must never be replaced");
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
    let barrier = Arc::new(std::sync::Barrier::new(2));
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
fn bare_mirror_moves_core_bare_out_of_shared_config_without_breaking_ordinary_worktrees() {
    let (dir, source_git, commit) = repo();
    let source = source_git.parent().unwrap();
    let mirror = dir.path().join("mirror.git");
    let source_text = source.to_str().unwrap();
    let mirror_text = mirror.to_str().unwrap();
    run(dir.path(), &["clone", "--bare", source_text, mirror_text]);
    let ordinary = dir.path().join("ordinary");
    let ordinary_text = ordinary.to_str().unwrap();
    run(
        dir.path(),
        &["--git-dir", mirror_text, "worktree", "add", "--detach", ordinary_text, &commit],
    );

    let at = dir.path().join("mnt");
    Worktree::write(&mirror, "projected", &at, &commit, b"index", &[]).unwrap();
    Worktree::write(&mirror, "projected", &at, &commit, b"index", &[]).unwrap();
    assert_eq!(run(&ordinary, &["status", "--porcelain"]), "");

    let shared = mirror.join("config");
    let shared_text = shared.to_str().unwrap();
    let shared_bare = Command::new("git")
        .args(["config", "--file", shared_text, "--get", "core.bare"])
        .output()
        .unwrap();
    assert!(!shared_bare.status.success(), "core.bare must not leak to ordinary worktrees");
    let main = mirror.join("config.worktree");
    let main_text = main.to_str().unwrap();
    assert_eq!(run(dir.path(), &["config", "--file", main_text, "--get", "core.bare"]), "true\n");
}

#[test]
fn symbolic_head_remount_is_refused_without_reset_and_preserves_the_index() {
    let (dir, git_dir, commit) = repo();
    let at = dir.path().join("mnt");
    let first = Worktree::write(&git_dir, "projected", &at, &commit, b"initial", &[]).unwrap();
    std::fs::write(first.admin.join("HEAD"), b"ref: refs/heads/topic\n").unwrap();
    std::fs::write(first.admin.join("index"), b"staged-state\n").unwrap();

    let error = remount_needs_reset(&first.admin, &commit, false).unwrap_err();
    assert!(error.to_string().contains("symbolic HEAD"));
    assert_eq!(std::fs::read(first.admin.join("index")).unwrap(), b"staged-state\n");
    assert!(remount_needs_reset(&first.admin, &commit, true).unwrap());
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
    let bytes = index_bytes(&projection.index, ObjectFormat::Sha1, 1000, 1000).unwrap();
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

/// A repo made by `git init` with `init` flags, holding `files` (relative path bytes, content)
/// and `links` (relative path, link text bytes), committed.
fn repo_of(
    init: &[&str],
    files: &[(&[u8], &[u8])],
    links: &[(&str, &[u8])],
) -> (tempfile::TempDir, PathBuf, String) {
    use std::os::unix::ffi::OsStrExt as _;
    let dir = tempfile::tempdir().unwrap();
    let work = dir.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    for (path, bytes) in files {
        let path = work.join(OsStr::from_bytes(path));
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, bytes).unwrap();
    }
    for (path, text) in links {
        std::os::unix::fs::symlink(OsStr::from_bytes(text), work.join(path)).unwrap();
    }
    let mut args = vec!["init", "-q"];
    args.extend_from_slice(init);
    run(&work, &args);
    run(&work, &["add", "-A"]);
    run(&work, &["commit", "-q", "-m", "one"]);
    let commit = run(&work, &["rev-parse", "HEAD"]).trim().to_owned();
    (dir, work.join(".git"), commit)
}

/// `len` bytes of a 16-byte pattern, as `yes 0123456789abcde` prints it.
fn pattern(from: u64, len: usize) -> Vec<u8> {
    const LINE: &[u8; 16] = b"0123456789abcde\n";
    (from..from + len as u64).map(|at| LINE[(at % 16) as usize]).collect()
}

const MIB: u64 = 1024 * 1024;

#[test]
fn a_sha256_repository_projects_reads_and_indexes_like_a_sha1_one() {
    let (_dir, git_dir, commit) = repo_of(
        &["--object-format=sha256"],
        &[(b"README.md", b"hello\n"), (b"crate/Cargo.lock", b"# lock\n")],
        &[("link", b"README.md")],
    );
    assert_eq!(object_format(&git_dir).unwrap(), ObjectFormat::Sha256);
    assert_eq!(commit.len(), 64);
    let mut book = Book::default();
    let projection = project(&git_dir, &commit, &mut book, 5_000_000_000);
    let manifest = &projection.manifest;
    let link = manifest.entry(manifest.resolve("link").unwrap()).unwrap();
    assert_eq!(link.link.as_deref(), Some("README.md"));
    let blobs = GitBlobs::new(&git_dir, projection.sources.clone());
    let readme = manifest.resolve("README.md").unwrap();
    assert_eq!(blobs.read(readme, 0, 100).unwrap(), b"hello\n");

    let bytes = index_bytes(&projection.index, ObjectFormat::Sha256, 1000, 1000).unwrap();
    std::fs::write(git_dir.join("index"), bytes).unwrap();
    let work = git_dir.parent().unwrap();
    let staged = run(work, &["ls-files", "-s"]);
    let committed =
        run(work, &["ls-tree", "-r", "--format=%(objectmode) %(objectname) 0\t%(path)", &commit]);
    assert_eq!(staged, committed, "git reads a SHA-256 index of 32-byte ids and checksum");

    let (_sha1_dir, sha1_git_dir, _) = repo();
    assert_eq!(object_format(&sha1_git_dir).unwrap(), ObjectFormat::Sha1);
}

#[test]
fn index_ids_must_match_the_object_format() {
    let (_dir, git_dir, commit) = repo();
    let projection = project(&git_dir, &commit, &mut Book::default(), 5_000_000_000);
    let error = index_bytes(&projection.index, ObjectFormat::Sha256, 1000, 1000).unwrap_err();
    assert!(error.to_string().contains("not a Sha256 object id"), "{error}");
}

#[test]
fn a_commit_with_foo_and_foo_projects_both_as_on_linux() {
    let (_dir, git_dir, commit) = repo_of(
        &[],
        &[(b"Foo", b"upper\n"), (b"foo", b"lower\n"), (b"Dir/a", b"one\n"), (b"dir/a", b"two\n")],
        &[],
    );
    let projection = project(&git_dir, &commit, &mut Book::default(), 5_000_000_000);
    let manifest = &projection.manifest;
    let blobs = GitBlobs::new(&git_dir, projection.sources.clone());
    for (path, bytes) in [
        ("Foo", b"upper\n".as_slice()),
        ("foo", b"lower\n"),
        ("Dir/a", b"one\n"),
        ("dir/a", b"two\n"),
    ] {
        let entry = manifest.resolve(path).unwrap_or_else(|| panic!("{path} is missing"));
        assert_eq!(blobs.read(entry, 0, 100).unwrap(), bytes, "{path}");
    }
    let paths: Vec<&str> = projection.index.iter().map(|entry| entry.path.as_str()).collect();
    assert_eq!(paths, ["Dir/a", "Foo", "dir/a", "foo"]);
    let bytes = index_bytes(&projection.index, ObjectFormat::Sha1, 1000, 1000).unwrap();
    std::fs::write(git_dir.join("index"), bytes).unwrap();
    let work = git_dir.parent().unwrap();
    let committed =
        run(work, &["ls-tree", "-r", "--format=%(objectmode) %(objectname) 0\t%(path)", &commit]);
    assert_eq!(run(work, &["ls-files", "-s"]), committed);
}

#[test]
fn a_path_that_is_not_utf8_is_unsupported() {
    let (_dir, git_dir, commit) = repo_of(&[], &[(b"caf\xe9.txt", b"latin-1\n")], &[]);
    let error = ls_tree(&git_dir, &commit).unwrap_err();
    assert!(error.downcast_ref::<Unsupported>().is_some(), "{error:#}");
    assert!(error.to_string().contains("not UTF-8"), "{error:#}");
    assert!(error.to_string().contains("ordinary checkout"), "{error:#}");
}

#[test]
fn a_link_text_that_is_not_utf8_is_unsupported() {
    let (_dir, git_dir, commit) = repo_of(&[], &[(b"a", b"a\n")], &[("link", b"caf\xe9")]);
    let items = ls_tree(&git_dir, &commit).unwrap();
    let error = link_texts(&git_dir, &items).unwrap_err();
    assert!(error.downcast_ref::<Unsupported>().is_some(), "{error:#}");
    assert!(error.to_string().contains("\"link\""), "{error:#}");
}

#[cfg(target_os = "linux")]
#[test]
fn a_mounted_sha256_commit_with_foo_and_foo_is_a_clean_worktree() {
    let fuse = Path::new("/dev/fuse").exists()
        && Command::new("fusermount3")
            .arg("--version")
            .output()
            .is_ok_and(|out| out.status.success());
    if !fuse {
        println!("skipping: no FUSE here (no /dev/fuse or no fusermount3)");
        return;
    }
    let (dir, git_dir, commit) = repo_of(
        &["--object-format=sha256"],
        &[(b"Foo", b"upper\n"), (b"foo", b"lower\n"), (b"src/main.rs", b"fn main() {}\n")],
        &[("link", b"Foo")],
    );
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
    // SAFETY: getuid and getgid cannot fail.
    let owner = unsafe { (libc::getuid(), libc::getgid()) };
    let format = object_format(&git_dir).unwrap();
    let index = index_bytes(&projection.index, format, owner.0, owner.1).unwrap();
    Worktree::write(&git_dir, "projected", &at, &commit, &index, &projection.real_dirs).unwrap();
    let blobs = Arc::new(GitBlobs::new(&git_dir, projection.sources));
    let overlay = Arc::new(
        crate::overlay::Overlay::open(
            Arc::new(projection.manifest),
            &dir.path().join("state"),
            blobs,
            owner,
        )
        .unwrap(),
    );
    let mounted = crate::mount::mount(overlay, &at).unwrap();
    assert_eq!(std::fs::read_to_string(at.join("Foo")).unwrap(), "upper\n");
    assert_eq!(std::fs::read_to_string(at.join("foo")).unwrap(), "lower\n");
    assert_eq!(run(&at, &["status", "--porcelain"]), "", "every file matches its index entry");
    assert_eq!(run(&at, &["rev-parse", "HEAD"]).trim(), commit);
    std::fs::write(at.join("foo"), "changed\n").unwrap();
    assert_eq!(run(&at, &["status", "--porcelain"]), " M foo\n");
    assert_eq!(std::fs::read_to_string(at.join("Foo")).unwrap(), "upper\n");
    mounted.unmount();
}

#[test]
fn a_big_blob_streams_in_ranges_and_every_process_stays_in_step() {
    let size = 20 * MIB + 3;
    let big = pattern(0, size as usize);
    let (_dir, git_dir, commit) =
        repo_of(&[], &[(b"big.bin", &big), (b"small.txt", b"small\n")], &[]);
    let projection = project(&git_dir, &commit, &mut Book::default(), 5_000_000_000);
    let manifest = &projection.manifest;
    let big_entry = manifest.resolve("big.bin").unwrap();
    let small_entry = manifest.resolve("small.txt").unwrap();
    let blobs = GitBlobs::new(&git_dir, projection.sources.clone());
    let streams = |blobs: &GitBlobs| blobs.streams.lock().unwrap().len();
    let slice = |from: u64, len: u64| big[from as usize..(from + len).min(size) as usize].to_vec();

    // A range from the middle leaves a stream part way through the blob.
    assert_eq!(
        blobs.read(big_entry, 4 * MIB + 1, 4 * MIB as u32).unwrap(),
        slice(4 * MIB + 1, 4 * MIB)
    );
    assert_eq!(streams(&blobs), 1);
    // The same range again is kept: no stream moves.
    assert_eq!(
        blobs.read(big_entry, 4 * MIB + 1, 4 * MIB as u32).unwrap(),
        slice(4 * MIB + 1, 4 * MIB)
    );
    assert_eq!(streams(&blobs), 1);
    // Another blob meanwhile takes a process of its own.
    assert_eq!(blobs.read(small_entry, 0, 100).unwrap(), b"small\n");
    // A range before the stream opens a second one; the first stays for the range after it.
    assert_eq!(blobs.read(big_entry, 3, 100).unwrap(), slice(3, 100));
    assert_eq!(streams(&blobs), 2);
    assert_eq!(
        blobs.read(big_entry, 8 * MIB + 1, 4 * MIB as u32).unwrap(),
        slice(8 * MIB + 1, 4 * MIB)
    );
    // More streams than kept: the least recently used is drained into the pool or ended.
    for offset in [19 * MIB, 15 * MIB, 11 * MIB, 7 * MIB, 5 * MIB, MIB] {
        assert_eq!(blobs.read(big_entry, offset, 4096).unwrap(), slice(offset, 4096), "{offset}");
        assert!(streams(&blobs) <= STREAMS);
    }
    // The last range ends the record and puts the process back in the pool, in step.
    assert_eq!(blobs.read(big_entry, size - 10, 100).unwrap(), slice(size - 10, 10));
    assert_eq!(blobs.read(big_entry, size + 5, 100).unwrap(), b"");
    assert!(blobs.pool.lock().unwrap().iter().all(CatFile::in_step));
    // A whole read of the big blob is refused; nothing that big is ever held.
    let mut answers = blobs.batch(&[big_entry, small_entry]).into_iter();
    assert_eq!(answers.next(), Some(Err(FetchError::Failed)));
    assert_eq!(answers.next(), Some(Ok(b"small\n".to_vec())));
    assert!(blobs.retained() <= RECENT_BYTES);
    assert!(blobs.recent.lock().unwrap().iter().all(|held| held.bytes.len() as u64 <= WHOLE_BYTES));

    // Resynchronization on one process: a partial read, then the next request.
    let work = git_dir.parent().unwrap();
    let big_oid = run(work, &["rev-parse", "HEAD:big.bin"]).trim().to_owned();
    let small_oid = run(work, &["rev-parse", "HEAD:small.txt"]).trim().to_owned();
    let mut cat = CatFile::spawn(&git_dir).unwrap();
    assert_eq!(cat.start(&big_oid).unwrap(), size);
    assert_eq!(cat.take(10).unwrap(), slice(0, 10));
    cat.skip(size - 100 - 10).unwrap();
    cat.drain().unwrap();
    assert!(cat.in_step());
    assert_eq!(cat.blob(&small_oid, 100).unwrap(), b"small\n");
    assert_eq!(cat.blob(&commit, 1 << 20), Err(FetchError::Failed), "a commit is not a blob");
    assert!(cat.in_step(), "a short non-blob record is drained");
    assert_eq!(cat.blob(&small_oid, 3), Err(FetchError::Failed), "bigger than asked for");
    assert!(cat.in_step(), "a short refused blob is drained");
    assert_eq!(cat.blob(&small_oid, 100).unwrap(), b"small\n");
    // A long rest is not drained: the process is out of step and takes no request.
    assert_eq!(cat.start(&big_oid).unwrap(), size);
    assert_eq!(cat.drain(), Err(FetchError::Failed));
    assert!(!cat.in_step());
    assert_eq!(cat.start(&small_oid), Err(FetchError::Failed));
}

#[test]
fn kept_bytes_stay_within_the_budget() {
    let blobs = GitBlobs::new(Path::new("/nonexistent"), Vec::new());
    let piece = WHOLE_BYTES as usize;
    for entry in 0..20 {
        let bytes = Arc::new(vec![0u8; piece]);
        blobs.hold(Held { entry, start: 0, size: piece as u64, bytes });
        assert!(blobs.retained() <= RECENT_BYTES, "{entry}");
    }
    assert_eq!(blobs.retained(), RECENT_BYTES / piece * piece);
    // A piece over the limit is never kept, even into an empty cache.
    let blobs = GitBlobs::new(Path::new("/nonexistent"), Vec::new());
    let bytes = Arc::new(vec![0u8; piece + 1]);
    blobs.hold(Held { entry: 0, start: 0, size: piece as u64 + 1, bytes });
    assert_eq!(blobs.retained(), 0);
}

#[test]
fn a_seed_refuses_a_blob_bigger_than_a_peer_takes_and_serves_the_next() {
    let big = pattern(0, crate::peers::MAX_HTTP_BODY_BYTES + 1);
    let (_dir, git_dir, _commit) =
        repo_of(&[], &[(b"big.bin", &big), (b"small.txt", b"small\n")], &[]);
    let work = git_dir.parent().unwrap();
    let big_oid = run(work, &["rev-parse", "HEAD:big.bin"]).trim().to_owned();
    let small_oid = run(work, &["rev-parse", "HEAD:small.txt"]).trim().to_owned();
    let mut reader = ObjectReader::spawn_local(&git_dir).unwrap();
    assert_eq!(reader.blob(&big_oid), None);
    assert_eq!(reader.blob(&small_oid), Some(b"small\n".to_vec()));
}

/// Set in the child process [`a_multi_gib_blob_reads_in_ranges_under_a_memory_ceiling`] starts.
#[cfg(target_os = "linux")]
const BIG_BLOB_CHILD: &str = "CMUX_PROJECTION_BIG_BLOB_CHILD";

/// A blob past 4 GiB, read in ranges through a stand-in `git cat-file --batch` that makes its
/// bytes on the fly (`yes | head`), so the test takes seconds and no disk. It runs in a process
/// of its own so its peak memory is its own: reading the blob whole would take 5 GiB.
#[cfg(target_os = "linux")]
#[test]
fn a_multi_gib_blob_reads_in_ranges_under_a_memory_ceiling() {
    if std::env::var_os(BIG_BLOB_CHILD).is_none() {
        let out = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "git::tests::a_multi_gib_blob_reads_in_ranges_under_a_memory_ceiling",
            ])
            .args(["--nocapture", "--test-threads=1"])
            .env(BIG_BLOB_CHILD, "1")
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(
            out.status.success() && stdout.contains("1 passed"),
            "{stdout}\n{}",
            String::from_utf8_lossy(&out.stderr)
        );
        return;
    }
    let size: u64 = 5 * 1024 * MIB + 5;
    let dir = tempfile::tempdir().unwrap();
    let program = dir.path().join("git");
    std::fs::write(
        &program,
        format!(
            "#!/bin/sh\n\
             # Answers `git cat-file --batch` for one made-up blob, `big`.\n\
             while read -r oid; do\n\
               if [ \"$oid\" = big ]; then\n\
                 printf 'big blob {size}\\n'\n\
                 yes 0123456789abcde | head -c {size}\n\
                 printf '\\n'\n\
               else\n\
                 printf '%s missing\\n' \"$oid\"\n\
               fi\n\
             done\n"
        ),
    )
    .unwrap();
    let mut perms = std::fs::metadata(&program).unwrap().permissions();
    std::os::unix::fs::PermissionsExt::set_mode(&mut perms, 0o755);
    std::fs::set_permissions(&program, perms).unwrap();
    let mut blobs = GitBlobs::new(dir.path(), vec![Source::Blob("big".into())]);
    blobs.program = program.into_os_string();

    let four = 4 * MIB as u32;
    assert_eq!(blobs.read(0, 0, four).unwrap(), pattern(0, four as usize));
    let past_u32 = (4 << 30) + 3;
    assert_eq!(blobs.read(0, past_u32, 65_536).unwrap(), pattern(past_u32, 65_536));
    assert_eq!(blobs.read(0, size - 7, 4096).unwrap(), pattern(size - 7, 7));
    assert_eq!(blobs.read(0, size + 10, 10).unwrap(), b"");
    // Back before every stream: the pooled process, in step after the blob's end, starts anew.
    assert_eq!(blobs.read(0, 2 * MIB, 16).unwrap(), pattern(2 * MIB, 16));
    assert!(blobs.retained() <= RECENT_BYTES);

    let status = std::fs::read_to_string("/proc/self/status").unwrap();
    let peak_kib: u64 = status
        .lines()
        .find_map(|line| line.strip_prefix("VmHWM:"))
        .and_then(|rest| rest.trim().trim_end_matches("kB").trim().parse().ok())
        .unwrap();
    assert!(peak_kib < 256 * 1024, "peak memory {peak_kib} KiB reading a {size}-byte blob");
}
