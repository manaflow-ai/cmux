//! A copy past its limits is refused fast, before anything is sent, with `copy.too_large`; one
//! under them is unchanged; `--allow-large` sends it whole.

use std::path::Path;
use std::time::Instant;

use super::super::local::{Rules, collect};
use super::{CODE, Cap, TEST_LIMITS, TooLarge, count, size};

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

fn refused(top: &Path) -> TooLarge {
    let cap = Some(Cap::of(top));
    match collect(top, Rules::Copy, cap) {
        Err(error) => error.downcast::<TooLarge>().expect("refused as too large"),
        Ok(set) => panic!("copied {} files past the limit", set.files.len()),
    }
}

/// The real limits: a sparse 21 GiB file (no disk spent) is refused in well under a second, and
/// the count stops at it rather than walking the rest of the folder.
#[test]
fn a_folder_past_twenty_gib_is_refused_fast_at_the_real_limit() {
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    let file = std::fs::File::create(top.join("disk.img")).unwrap();
    file.set_len(21 * 1024 * 1024 * 1024).unwrap();
    for index in 0..50 {
        write(&top, &format!("src/f{index}.txt"), 10);
    }
    let started = Instant::now();
    let large = refused(&top);
    assert!(started.elapsed().as_secs() < 5, "took {:?}", started.elapsed());
    assert!(large.bytes > super::MAX_BYTES && large.max_files == super::MAX_FILES);
    let text = large.to_string();
    assert!(text.contains("is too big to copy to a Cloud machine"), "{text}");
    assert!(text.contains("at least 21 GB"), "{text}");
    assert!(text.contains("Pick the project folder"), "{text}");
    assert!(!text.contains("--allow-large"), "the app's toast shows it: no flag there: {text}");
    // The copy's own error line takes the stable code.
    let error = anyhow::Error::new(large);
    assert_eq!(super::super::push_failure(&error).0, CODE);
}

/// Past the file limit (a lowered one): refused, the count stopped at the limit.
#[test]
fn a_folder_past_the_file_limit_is_refused_and_stops_counting() {
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    for index in 0..300 {
        write(&top, &format!("d{}/f{index}.txt", index % 7), 1);
    }
    let large = with_limits(u64::MAX, 100, || refused(&top));
    assert_eq!(large.files, 101, "counting stops at the first file past the limit");
    assert!(large.to_string().contains("at least 101 files"), "{large}");
}

/// What a copy leaves out is not counted: heavy folders and secrets are not sent, so a folder whose
/// bulk is `node_modules` passes.
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
    let set = with_limits(1000, 10, || collect(&top, Rules::Copy, Some(Cap::of(&top))))
        .expect("the copy's own files are under the limit");
    assert_eq!(set.files.len(), 2);
}

/// A folder under the limits lists exactly what an uncapped copy lists.
#[test]
fn a_folder_under_the_limits_is_unchanged() {
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    for index in 0..500 {
        write(&top, &format!("d{}/f{index}.txt", index % 13), 1 + index % 300);
    }
    let capped = collect(&top, Rules::Copy, Some(Cap::of(&top))).unwrap();
    let plain = collect(&top, Rules::Copy, None).unwrap();
    assert_eq!(capped.files.keys().collect::<Vec<_>>(), plain.files.keys().collect::<Vec<_>>());
    assert_eq!(super::check_plain(&top), Ok(()));
}

/// In git the repository's history goes with a streamed copy (a seed's fallback), so it counts, and
/// when it is the bulk the refusal names it and points at a seed.
#[test]
fn a_git_folder_counts_its_history_and_names_it() {
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    let git = |args: &[&str]| {
        let status = cmux_process::Command::new("git")
            .arg("-C")
            .arg(&top)
            .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
            .args(args)
            .status()
            .unwrap();
        assert!(status.success(), "git {args:?}");
    };
    git(&["init", "-q"]);
    write(&top, "a.txt", 10);
    git(&["add", "a.txt"]);
    git(&["commit", "-qm", "a"]);
    // A pack the size of a big history, sparse.
    let pack = top.join(".git/objects/pack/pack-big.pack");
    std::fs::create_dir_all(pack.parent().unwrap()).unwrap();
    std::fs::File::create(&pack).unwrap().set_len(8 * 1024 * 1024 * 1024).unwrap();
    let large = with_limits(1024 * 1024 * 1024, u64::MAX, || refused(&top));
    assert!(large.git_bytes * 2 > large.bytes, "{large:?}");
    let text = large.to_string();
    assert!(text.contains("of it the repository's history (.git)"), "{text}");
    assert!(text.contains("Push it to GitHub"), "{text}");
    // A plain-folder check leaves a git folder to the copy (a seed may take it whole).
    assert_eq!(with_limits(1, 1, || super::check_plain(&top)), Ok(()));
}

/// In git the listing streams through the cap: `git ls-files` is stopped at the first file past the
/// limit, so a working copy of millions of files is never listed whole before it is refused.
#[test]
fn a_git_folder_listing_stops_at_the_first_file_past_the_limit() {
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    let git = |args: &[&str]| {
        let status = cmux_process::Command::new("git")
            .arg("-C")
            .arg(&top)
            .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
            .args(args)
            .status()
            .unwrap();
        assert!(status.success(), "git {args:?}");
    };
    git(&["init", "-q"]);
    for index in 0..300 {
        write(&top, &format!("tracked/d{}/f{index}.txt", index % 7), 1);
    }
    git(&["add", "tracked"]);
    git(&["commit", "-qm", "tracked"]);
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

    // A copy past the file limit is refused there, counted from the listing, before .git/.
    let large = with_limits(u64::MAX, 150, || refused(&top));
    assert_eq!(large.files, 151, "counting stops at the first file past the limit");
    assert_eq!(large.git_bytes, 0, "refused while listing the working files, before .git/");
}

/// `--allow-large` records the folder for a day; a copy of it then counts nothing.
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
    write(&other, "g.txt", 1);
    with_limits(u64::MAX, 5, || {
        assert!(super::check_plain(&top).is_err());
        super::allow(&top).unwrap();
        assert!(super::allowed(&top) && !super::allowed(&other));
        assert_eq!(super::check_plain(&top), Ok(()));
        assert_eq!(super::check_plain(&other), Ok(()));
    });
}

#[test]
fn sizes_and_counts_read_plainly() {
    assert_eq!(size(632 * 1024 * 1024 * 1024), "632 GB");
    assert_eq!(size(20 * 1024 * 1024 * 1024 + 1), "20 GB");
    assert_eq!(size(5 * 1024 * 1024 * 1024 + 300 * 1024 * 1024), "5.3 GB");
    assert_eq!(size(128 * 1024 * 1024), "128 MB");
    assert_eq!(count(500_001), "500,001");
    assert_eq!(count(999), "999");
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
