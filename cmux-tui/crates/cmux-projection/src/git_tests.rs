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

/// A blobless bare clone of `repo()`'s commit, as a machine with no copy of the repo makes one:
/// trees only, blobs from its origin on demand. Origin answers `object-info` when `object_info`.
fn blobless(object_info: bool) -> (tempfile::TempDir, PathBuf, String) {
    let (dir, git_dir, commit) = repo();
    let origin = dir.path().join("origin.git");
    run(
        dir.path(),
        &["clone", "-q", "--bare", git_dir.to_str().unwrap(), origin.to_str().unwrap()],
    );
    run(&origin, &["config", "uploadpack.allowFilter", "true"]);
    run(&origin, &["config", "uploadpack.allowAnySHA1InWant", "true"]);
    if object_info {
        run(&origin, &["config", "transfer.advertiseObjectInfo", "true"]);
    }
    let mirror = dir.path().join("mirror.git");
    let url = format!("file://{}", origin.display());
    run(
        dir.path(),
        &["clone", "-q", "--bare", "--filter=blob:none", &url, mirror.to_str().unwrap()],
    );
    (dir, mirror, commit)
}

fn missing_count(git_dir: &Path, commit: &str) -> usize {
    missing(git_dir, commit).unwrap().len()
}

#[test]
fn a_lazy_tree_is_sized_without_fetching_a_file_blob() {
    let (dir, mirror, commit) = blobless(true);
    let files = 6; // README.md, a-b, a/c, crate/Cargo.lock, crate/src/main.rs, run.sh
    assert_eq!(missing_count(&mirror, &commit), files + 1, "the clone holds no blob");
    let tree = lazy_tree(&mirror, &commit, None).unwrap();
    assert_eq!(tree.links_fetched, 1, "only the link's text is fetched");
    assert_eq!(tree.missing.len(), files);
    assert_eq!(missing_count(&mirror, &commit), files, "no file blob was fetched to size it");
    let full = ls_tree(&dir.path().join("work/.git"), &commit).unwrap();
    assert_eq!(tree.items, full, "same paths, modes, ids and sizes as ls-tree -l on a full store");
}

#[test]
fn a_lazy_tree_takes_sizes_from_a_listing_when_origin_cannot_say() {
    let (dir, mirror, commit) = blobless(false);
    assert!(lazy_tree(&mirror, &commit, None).is_err(), "no object-info, no listing: an error");
    let work = dir.path().join("work");
    let listing = Command::new("git")
        .args(["ls-tree", "-r", "-l", "-z", "--full-tree", &commit])
        .current_dir(&work)
        .output()
        .unwrap()
        .stdout;
    let tree = lazy_tree(&mirror, &commit, Some(&listing)).unwrap();
    assert_eq!(tree.items, ls_tree(&work.join(".git"), &commit).unwrap());
    assert_eq!(missing_count(&mirror, &commit), 6);
}

#[test]
fn a_lazy_read_fetches_its_folder_in_one_request_and_nothing_else() {
    let (_dir, mirror, commit) = blobless(true);
    let tree = lazy_tree(&mirror, &commit, None).unwrap();
    let mut book = Book::default();
    let links = link_texts(&mirror, &tree.items).unwrap();
    let layout = Layout {
        commit_ns: 1_000_000_000,
        now_ns: 5_000_000_000,
        gitfile: None,
        real_root: Path::new("/real"),
        links: &links,
    };
    let projection = Projection::build(&commit, &tree.items, &mut book, &layout).unwrap();
    let main = projection.manifest.resolve("crate/src/main.rs").unwrap();
    let readme = projection.manifest.resolve("README.md").unwrap();
    let blobs = GitBlobs::new(&mirror, projection.sources).lazy(&projection.manifest, tree.missing);
    assert_eq!(blobs.read(main, 0, 64).unwrap(), b"fn main() {}\n");
    assert_eq!(blobs.fetches(), 1);
    assert_eq!(missing_count(&mirror, &commit), 5, "only crate/src's one file came");
    assert_eq!(blobs.read(readme, 0, 64).unwrap(), b"hello\n");
    assert_eq!(blobs.fetches(), 2);
    // The top folder's other files (a-b, run.sh) came with README.md; a/c and Cargo.lock did not.
    assert_eq!(missing_count(&mirror, &commit), 2);
    assert_eq!(blobs.read(main, 0, 64).unwrap(), b"fn main() {}\n");
    assert_eq!(blobs.fetches(), 2, "a second read is local");
}
