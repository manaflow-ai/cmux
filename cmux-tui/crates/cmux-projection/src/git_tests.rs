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
        real_root: Some(Path::new("/real")),
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

#[test]
fn an_unread_mount_ends_its_git_processes_and_drops_its_recent_blobs() {
    let (_dir, git_dir, commit) = repo();
    let projection = project(&git_dir, &commit, &mut Book::default(), 5_000_000_000);
    let readme = projection.manifest.resolve("README.md").unwrap();
    let blobs = GitBlobs::new(&git_dir, projection.sources);
    assert_eq!(blobs.read(readme, 0, 100).unwrap(), b"hello\n");
    assert_eq!(blobs.pooled(), 1, "a read leaves its git cat-file in the pool");

    // A sweep before the idle time keeps both.
    blobs.held.sweep(Instant::now(), IDLE, PACK_CHECK);
    assert_eq!(blobs.pooled(), 1);
    assert_eq!(blobs.held.recent.lock().unwrap().len(), 1);

    // After it, the process ends and the recent blobs go.
    blobs.held.sweep(Instant::now() + IDLE, IDLE, PACK_CHECK);
    assert_eq!(blobs.pooled(), 0, "an idle mount holds no git process");
    assert!(blobs.held.recent.lock().unwrap().is_empty(), "nor any blob bytes");

    // The next read starts a new one and reads the same bytes.
    assert_eq!(blobs.read(readme, 2, 2).unwrap(), b"ll");
    assert_eq!(blobs.pooled(), 1);
}

/// Whether the held child `pid` maps a deleted pack file (git maps a small pack whole and closes
/// its file).
#[cfg(target_os = "linux")]
fn maps_deleted_pack(pid: u32) -> bool {
    std::fs::read_to_string(format!("/proc/{pid}/maps"))
        .unwrap()
        .lines()
        .any(|line| line.trim_end().ends_with(" (deleted)") && line.contains("/objects/pack/"))
}

#[test]
fn a_repack_retires_the_git_processes_holding_the_old_packs() {
    let (dir, git_dir, commit) = repo();
    let work = dir.path().join("work");
    run(&work, &["repack", "-adq"]);
    let projection = project(&git_dir, &commit, &mut Book::default(), 5_000_000_000);
    let readme = projection.manifest.resolve("README.md").unwrap();
    let blobs = GitBlobs::new(&git_dir, projection.sources);
    assert_eq!(blobs.read(readme, 0, 100).unwrap(), b"hello\n");
    assert_eq!(blobs.pooled(), 1);
    let pid = blobs.held.pool.lock().unwrap().free[0].cat.pid();

    // Before the next check is due, a busy process stays (nothing has changed yet).
    blobs.held.sweep(Instant::now(), IDLE, PACK_CHECK);
    assert_eq!(blobs.pooled(), 1);

    // A new commit and a repack: the pack the process opened is deleted.
    std::fs::write(work.join("README.md"), "hello again\n").unwrap();
    run(&work, &["commit", "-qam", "two"]);
    run(&work, &["repack", "-adq"]);
    run(&work, &["prune-packed"]);
    #[cfg(target_os = "linux")]
    assert!(maps_deleted_pack(pid), "git cat-file keeps the deleted pack mapped");

    // The pooled process is from before the change: the next read uses it once, then it ends.
    let generation = blobs.held.generation();
    blobs.held.packs.lock().unwrap().check(Instant::now() + PACK_CHECK, PACK_CHECK);
    assert_eq!(blobs.held.generation(), generation + 1, "the pack folder moved");
    blobs.held.recent.lock().unwrap().clear();
    assert_eq!(blobs.read(readme, 0, 100).unwrap(), b"hello\n", "the old blob is in the new pack");
    assert_eq!(blobs.pooled(), 0, "a process from before the repack ends after its read");

    // A new one serves the next read and stays, and a sweep with no change keeps it.
    blobs.held.recent.lock().unwrap().clear();
    assert_eq!(blobs.read(readme, 0, 100).unwrap(), b"hello\n");
    assert_eq!(blobs.pooled(), 1);
    blobs.held.sweep(Instant::now() + 2 * PACK_CHECK, IDLE * 100, PACK_CHECK);
    assert_eq!(blobs.pooled(), 1, "unchanged packs keep a busy process");

    // A pooled one, never idle, is retired by the sweep once the packs change again.
    run(&work, &["commit", "-q", "--allow-empty", "-m", "three"]);
    run(&work, &["repack", "-adq"]);
    blobs.held.sweep(Instant::now() + 3 * PACK_CHECK, IDLE * 100, PACK_CHECK);
    assert_eq!(blobs.pooled(), 0, "a repack retires the pooled process");
    #[cfg(target_os = "linux")]
    assert!(!Path::new(&format!("/proc/{pid}")).exists(), "and it is reaped, not a zombie");
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
        real_root: Some(&real_root),
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
    let old = std::time::SystemTime::UNIX_EPOCH + Duration::from_secs(1_000);
    std::fs::File::options().write(true).open(&head).unwrap().set_modified(old).unwrap();
    Worktree::write(&git_dir, "projected", &at, &commit, b"index", &[]).unwrap();
    assert_eq!(
        std::fs::metadata(&head).unwrap().modified().unwrap(),
        old,
        "a build script watches HEAD"
    );
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

#[test]
fn a_kept_listing_answers_without_git_and_matches_it() {
    let (dir, git_dir, commit) = repo();
    let cache = dir.path().join("keep/trees").join(&commit);
    let listed = ls_tree_cached(&git_dir, &commit, &cache).unwrap();
    assert_eq!(listed, ls_tree(&git_dir, &commit).unwrap());
    assert!(cache.exists(), "the listing is kept");
    // A wrong git dir: only the kept listing can answer.
    let kept = ls_tree_cached(&dir.path().join("nowhere"), &commit, &cache).unwrap();
    assert_eq!(kept, listed);
}

#[test]
fn a_new_commits_listing_takes_its_sizes_from_a_kept_one_and_matches_git() {
    let (dir, git_dir, commit) = repo();
    let trees = dir.path().join("keep/trees");
    ls_tree_cached(&git_dir, &commit, &trees.join(&commit)).unwrap();
    let work = dir.path().join("work");
    std::fs::write(work.join("README.md"), "hello, a longer line\n").unwrap();
    std::fs::write(work.join("new.txt"), "new\n").unwrap();
    std::fs::remove_file(work.join("a-b")).unwrap();
    run(&work, &["add", "-A"]);
    run(&work, &["commit", "-q", "-m", "two"]);
    let two = run(&work, &["rev-parse", "HEAD"]).trim().to_owned();
    let listed = ls_tree_cached(&git_dir, &two, &trees.join(&two)).unwrap();
    assert_eq!(listed, ls_tree(&git_dir, &two).unwrap());
}

#[test]
fn a_sparse_index_holds_the_left_out_paths_as_skip_worktree() {
    let (dir, git_dir, commit) = repo();
    let projection = project(&git_dir, &commit, &mut Book::default(), 2_000_000_000);
    let kept: Vec<IndexEntry> =
        projection.index.iter().filter(|e| !e.path.starts_with("crate/")).cloned().collect();
    let skipped: Vec<TreeItem> = ls_tree(&git_dir, &commit)
        .unwrap()
        .into_iter()
        .filter(|item| item.path.starts_with("crate/"))
        .collect();
    let index = dir.path().join("sparse-index");
    std::fs::write(&index, index_bytes_sparse(&kept, &skipped, ObjectFormat::Sha1, 0, 0).unwrap())
        .unwrap();
    let git = |args: &[&str]| {
        let out = Command::new("git")
            .arg("--git-dir")
            .arg(&git_dir)
            .args(args)
            .env("GIT_INDEX_FILE", &index)
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8(out.stdout).unwrap()
    };
    let listed = git(&["ls-files", "-v"]);
    assert!(listed.contains("S crate/src/main.rs"), "{listed}");
    assert!(listed.contains("H README.md"), "{listed}");
    assert_eq!(git(&["diff-index", "--cached", "--name-only", &commit]), "", "nothing staged");
}

#[test]
fn sixteen_parallel_reads_run_at_most_the_cap_of_git_processes() {
    let (_dir, git_dir, commit) = repo();
    let projection = project(&git_dir, &commit, &mut Book::default(), 5_000_000_000);
    let readme = projection.manifest.resolve("README.md").unwrap();
    let main_rs = projection.manifest.resolve("crate/src/main.rs").unwrap();
    let blobs = Arc::new(GitBlobs::new(&git_dir, projection.sources));
    assert_eq!(blobs.pooled(), 0, "a mount nobody read starts no git process");

    let start = Arc::new(std::sync::Barrier::new(16));
    let readers: Vec<_> = (0..16)
        .map(|i| {
            let (blobs, start) = (blobs.clone(), start.clone());
            std::thread::spawn(move || {
                start.wait();
                for round in 0..50 {
                    // Drop the recent blobs now and then so reads reach git.
                    if (i + round) % 7 == 0 {
                        blobs.held.recent.lock().unwrap().clear();
                    }
                    let at = if (i + round) % 2 == 0 { readme } else { main_rs };
                    assert!(!blobs.read(at, 0, 100).unwrap().is_empty());
                }
            })
        })
        .collect();
    for reader in readers {
        reader.join().unwrap();
    }
    assert!(blobs.peak() >= 1);
    assert!(blobs.peak() <= MAX_CATS, "peak {} past the cap {MAX_CATS}", blobs.peak());
    assert!(blobs.pooled() <= MAX_CATS);

    blobs.held.sweep(Instant::now() + IDLE, IDLE, PACK_CHECK);
    assert_eq!(blobs.pooled(), 0);
    assert_eq!(blobs.held.pool.lock().unwrap().live, 0, "an idle mount holds no git process");
}

#[test]
fn object_reader_drains_non_blob_records_before_the_next_blob() {
    let (_dir, git_dir, commit) = repo();
    let readme = run(git_dir.parent().unwrap(), &["rev-parse", "HEAD:README.md"]).trim().to_owned();
    let mut reader = ObjectReader::spawn_local(&git_dir).unwrap();
    assert_eq!(reader.blob(&commit), None);
    assert_eq!(reader.blob(&readme), Some(b"hello\n".to_vec()));
}

#[test]
#[cfg(target_os = "linux")]
fn a_commit_with_case_only_distinct_paths_stays_distinct() {
    use std::os::unix::ffi::OsStrExt as _;
    let dir = tempfile::tempdir().unwrap();
    let work = dir.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    for (name, bytes) in [(b"Foo".as_slice(), b"upper\n".as_slice()), (b"foo", b"lower\n")] {
        std::fs::write(work.join(std::ffi::OsStr::from_bytes(name)), bytes).unwrap();
    }
    run(&work, &["init", "-q"]);
    run(&work, &["add", "-A"]);
    run(&work, &["commit", "-q", "-m", "one"]);
    let git_dir = work.join(".git");
    let commit = run(&work, &["rev-parse", "HEAD"]).trim().to_owned();
    let projection = project(&git_dir, &commit, &mut Book::default(), 5_000_000_000);
    assert!(projection.manifest.resolve("Foo").is_some());
    assert!(projection.manifest.resolve("foo").is_some());
    let index = index_bytes(&projection.index, ObjectFormat::Sha1, 1000, 1000).unwrap();
    std::fs::write(git_dir.join("index"), index).unwrap();
    assert_eq!(run(&work, &["ls-files", "--stage"]).lines().count(), 2);
}

#[test]
#[cfg(target_os = "linux")]
fn a_non_utf8_git_path_is_unsupported() {
    use std::os::unix::ffi::OsStrExt as _;
    let dir = tempfile::tempdir().unwrap();
    let work = dir.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    std::fs::write(work.join(std::ffi::OsStr::from_bytes(b"caf\xe9.txt")), b"latin\n").unwrap();
    run(&work, &["init", "-q"]);
    run(&work, &["add", "-A"]);
    run(&work, &["commit", "-q", "-m", "one"]);
    let commit = run(&work, &["rev-parse", "HEAD"]).trim().to_owned();
    let error = ls_tree(&work.join(".git"), &commit).unwrap_err();
    assert!(error.downcast_ref::<Unsupported>().is_some(), "{error:#}");
}
