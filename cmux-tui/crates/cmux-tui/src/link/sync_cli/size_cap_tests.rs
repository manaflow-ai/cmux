//! A copy past its limits is never refused: it judges the folder fast, then sends a first pass
//! (smallest files first, no repository history) and leaves the rest on this Mac; one under them is
//! unchanged; `--allow-large` sends it whole.

use std::path::Path;
use std::time::Instant;

use super::super::local::{LocalSet, Rules, collect};
use super::{Cap, TEST_FIRST, TEST_LIMITS};

fn write(top: &Path, relative: &str, bytes: usize) {
    let path = top.join(relative);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, vec![b'x'; bytes]).unwrap();
}

fn with_limits<T>(bytes: u64, files: u64, run: impl FnOnce() -> T) -> T {
    TEST_LIMITS.with(|limits| limits.set(Some((bytes, files))));
    let out = run();
    TEST_LIMITS.with(|limits| limits.set(None));
    out
}

fn with_first<T>(bytes: u64, files: u64, run: impl FnOnce() -> T) -> T {
    TEST_FIRST.with(|limits| limits.set(Some((bytes, files))));
    let out = run();
    TEST_FIRST.with(|limits| limits.set(None));
    out
}

fn capped(top: &Path) -> LocalSet {
    collect(top, Rules::Copy, Some(Cap::new())).expect("a copy past its limits is never refused")
}

fn left_on_mac(set: &LocalSet) -> u64 {
    set.skips.json().1["left_on_mac"].as_u64().unwrap_or(0)
}

fn git(top: &Path, args: &[&str]) {
    let status = cmux_process::Command::new("git")
        .arg("-C")
        .arg(top)
        .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
        .args(args)
        .status()
        .unwrap();
    assert!(status.success(), "git {args:?}");
}

/// The real limits: a sparse 21 GiB file (no disk spent) is judged in well under a second, and the
/// copy sends the folder's small files without it rather than refusing.
#[test]
fn a_folder_past_twenty_gib_sends_a_first_pass_fast_at_the_real_limit() {
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    let file = std::fs::File::create(top.join("disk.img")).unwrap();
    file.set_len(21 * 1024 * 1024 * 1024).unwrap();
    for index in 0..50 {
        write(&top, &format!("src/f{index}.txt"), 10);
    }
    let started = Instant::now();
    let set = capped(&top);
    assert!(started.elapsed().as_secs() < 5, "took {:?}", started.elapsed());
    assert!(!set.files.contains_key("disk.img"), "the 21 GiB file stays on this Mac");
    // Every small file goes, wherever the big one was in the listing.
    assert_eq!(set.files.len(), 50, "{:?}", set.files.keys());
    assert!(set.files.keys().all(|path| path.starts_with("src/")), "{:?}", set.files.keys());
    assert_eq!(left_on_mac(&set), 1);
}

/// Past the file limit (a lowered one): the listing stops there and the first pass is the smallest
/// files, by path among equals, up to its own limit.
#[test]
fn a_folder_past_the_file_limit_sends_its_smallest_files_first() {
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    // 260 files of 1 byte and 40 of 50: the 100 the listing reaches, in whatever order the disk
    // lists them, hold at least 60 of 1 byte, so the 40 sent are all of 1 byte.
    for index in 0..300 {
        write(&top, &format!("d{}/f{index:03}.txt", index % 7), if index < 40 { 50 } else { 1 });
    }
    let set = with_limits(u64::MAX, 100, || with_first(u64::MAX, 40, || capped(&top)));
    assert_eq!(set.files.len(), 40);
    assert!(!set.git);
    // 100 listed, 40 sent, 60 left, plus the one past the limit.
    assert_eq!(left_on_mac(&set), 61);
    let sizes: Vec<u64> =
        set.files.keys().map(|path| std::fs::metadata(top.join(path)).unwrap().len()).collect();
    assert!(sizes.iter().all(|size| *size == 1), "the smallest go first: {sizes:?}");
}

/// The first pass's byte budget holds: a file bigger than what is left of it stays here.
#[test]
fn the_first_pass_keeps_to_its_bytes() {
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    write(&top, "a.txt", 10);
    write(&top, "b.txt", 20);
    write(&top, "c.bin", 5_000);
    write(&top, "d.bin", 6_000);
    let set = with_limits(1_000, u64::MAX, || with_first(100, u64::MAX, || capped(&top)));
    let sent: Vec<&str> = set.files.keys().map(String::as_str).collect();
    assert_eq!(sent, ["a.txt", "b.txt"]);
}

/// What a copy leaves out is not counted: heavy folders and secrets are not sent, so a folder whose
/// bulk is `node_modules` goes whole.
#[test]
fn what_the_copy_leaves_out_is_not_counted() {
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    write(&top, "package.json", 2);
    write(&top, "index.js", 10);
    for index in 0..200 {
        write(&top, &format!("node_modules/p{index}/index.js"), 1000);
    }
    write(&top, ".env", 100_000);
    let set = with_limits(1000, 10, || capped(&top));
    assert_eq!(set.files.len(), 2);
    assert_eq!(left_on_mac(&set), 0);
}

/// A folder under the limits lists exactly what an uncapped copy lists.
#[test]
fn a_folder_under_the_limits_is_unchanged() {
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    for index in 0..500 {
        write(&top, &format!("d{}/f{index}.txt", index % 13), 1 + index % 300);
    }
    let capped = capped(&top);
    let plain = collect(&top, Rules::Copy, None).unwrap();
    assert_eq!(capped.files.keys().collect::<Vec<_>>(), plain.files.keys().collect::<Vec<_>>());
    assert_eq!(left_on_mac(&capped), 0);
}

/// In git a history past the limits never goes in part: the first pass is the working files as a
/// plain copy, without `.git/`.
#[test]
fn a_git_folder_past_the_limits_sends_its_files_without_history() {
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    git(&top, &["init", "-q"]);
    write(&top, "a.txt", 10);
    git(&top, &["add", "a.txt"]);
    git(&top, &["commit", "-qm", "a"]);
    // A pack the size of a big history, sparse.
    let pack = top.join(".git/objects/pack/pack-big.pack");
    std::fs::create_dir_all(pack.parent().unwrap()).unwrap();
    std::fs::File::create(&pack).unwrap().set_len(8 * 1024 * 1024 * 1024).unwrap();
    let set = with_limits(1024 * 1024 * 1024, u64::MAX, || capped(&top));
    assert!(set.files.contains_key("a.txt"), "{:?}", set.files.keys());
    assert!(set.files.keys().all(|path| !path.starts_with(".git/")), "{:?}", set.files.keys());
    assert!(!set.git, "a first pass is a plain copy");
}

/// In git the listing streams through the cap: `git ls-files` is stopped at the first file past the
/// limit, so a working copy of millions of files is never listed whole.
#[test]
fn a_git_folder_listing_stops_at_the_first_file_past_the_limit() {
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    git(&top, &["init", "-q"]);
    for index in 0..300 {
        write(&top, &format!("tracked/d{}/f{index}.txt", index % 7), 1);
    }
    git(&top, &["add", "tracked"]);
    git(&top, &["commit", "-qm", "tracked"]);
    for index in 0..300 {
        write(&top, &format!("untracked/f{index}.txt"), 1);
    }

    // The listing itself: the first error from a visit ends it, with that error, and nothing
    // more is visited.
    let mut visited = 0;
    let mut skipped = 0;
    let stopped = super::super::local::working_files(&top, &mut skipped, &mut |_, _| {
        visited += 1;
        if visited > 100 {
            anyhow::bail!("stop at {visited}");
        }
        Ok(())
    });
    assert_eq!(stopped.unwrap_err().to_string(), "stop at 101");
    assert_eq!(visited, 101, "nothing is listed past the first file over the limit");

    // Every file, tracked and untracked, is visited once when nothing stops it.
    let mut all = Vec::new();
    super::super::local::working_files(&top, &mut skipped, &mut |path, untracked| {
        all.push((path, untracked));
        Ok(())
    })
    .unwrap();
    assert_eq!(all.len(), 600);
    assert_eq!(all.iter().filter(|(_, untracked)| *untracked).count(), 300);

    // A copy past the file limit sends the 150 listed before it, never .git/.
    let set = with_limits(u64::MAX, 150, || capped(&top));
    assert_eq!(set.files.len(), 150);
    assert!(set.files.keys().all(|path| !path.starts_with(".git/")));
}

/// Leo's `~/Projects`: no repository itself, repositories inside it, and more than a copy sends
/// whole. The first pass holds each repository's files and none of their histories.
#[test]
fn a_parent_of_repositories_past_the_limits_sends_their_files_without_their_histories() {
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    for name in ["cmux", "web", "work/api"] {
        let repo = top.join(name);
        std::fs::create_dir_all(&repo).unwrap();
        git(&repo, &["init", "-q"]);
        write(&repo, "src/main.rs", 64);
        git(&repo, &["add", "."]);
        git(&repo, &["commit", "-qm", "init"]);
    }
    write(&top, "notes.md", 32);
    std::fs::create_dir_all(top.join("Downloads")).unwrap();
    std::fs::File::create(top.join("Downloads/disk.img"))
        .unwrap()
        .set_len(21 * 1024 * 1024 * 1024)
        .unwrap();
    let started = Instant::now();
    let set = capped(&top);
    assert!(started.elapsed().as_secs() < 5, "took {:?}", started.elapsed());
    for path in ["notes.md", "cmux/src/main.rs", "web/src/main.rs", "work/api/src/main.rs"] {
        assert!(set.files.contains_key(path), "{path}: {:?}", set.files.keys());
    }
    assert!(!set.files.contains_key("Downloads/disk.img"));
    assert!(set.files.keys().all(|path| !path.contains(".git/")), "{:?}", set.files.keys());
    assert!(left_on_mac(&set) >= 1);
}

/// A parent of repositories whose nested histories hold most of its files (cmuxterm-hq#11697): the
/// histories never stop the listing short, so a folder named after them is in the first pass.
#[test]
fn nested_histories_do_not_stop_the_listing_before_later_folders() {
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    for index in 0..150 {
        write(&top, &format!("aaa/.git/objects/{:02x}/o{index:03}", index % 16), 1);
    }
    write(&top, "aaa/src/main.rs", 1);
    for index in 0..50 {
        write(&top, &format!("zzz/f{index:02}.txt"), 1);
    }
    let set = with_limits(u64::MAX, 100, || capped(&top));
    assert!(set.files.contains_key("aaa/src/main.rs"), "{:?}", set.files.keys());
    for index in 0..50 {
        let path = format!("zzz/f{index:02}.txt");
        assert!(set.files.contains_key(&path), "{path}: {:?}", set.files.keys());
    }
    assert!(set.files.keys().all(|path| !path.contains(".git/")), "{:?}", set.files.keys());
    assert!(!set.git);
    assert_eq!(left_on_mac(&set), 150, "the histories stay on this Mac");
    // Still bounded: histories past four times the limit end the listing.
    for index in 150..600 {
        write(&top, &format!("aaa/.git/objects/{:02x}/o{index:03}", index % 16), 1);
    }
    let set = with_limits(u64::MAX, 100, || capped(&top));
    assert!(set.files.len() <= 100, "{}", set.files.len());
}

/// `--allow-large` records the folder for a day; a copy of it then counts nothing and goes whole.
#[test]
fn allow_large_lets_one_folder_through() {
    let state = tempfile::tempdir().unwrap();
    super::TEST_STATE.with(|dir| *dir.borrow_mut() = Some(state.path().to_path_buf()));
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    for index in 0..20 {
        write(&top, &format!("f{index}.txt"), 1);
    }
    let other = tempfile::tempdir().unwrap();
    let other = std::fs::canonicalize(other.path()).unwrap();
    write(&other, "f.txt", 1);
    assert!(!super::allowed(&top));
    super::allow(&top).unwrap();
    assert!(super::allowed(&top) && !super::allowed(&other));
}

#[test]
fn the_allow_large_flag_is_taken_only_as_a_flag() {
    let words = |list: &[&str]| list.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
    let take = |list: &[&str]| super::take_allow_large(&words(list), &["--socket"]);
    assert_eq!(take(&["a", "--allow-large"]), (words(&["a"]), true));
    // A flag's value and anything after `--` are never the flag.
    assert_eq!(
        take(&["--socket", "--allow-large", "a"]),
        (words(&["--socket", "--allow-large", "a"]), false)
    );
    assert_eq!(take(&["--", "--allow-large"]), (words(&["--", "--allow-large"]), false));
}
