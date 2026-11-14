//! A copy past its limits is refused fast, before anything is sent, with `copy.too_large`; one
//! under them is unchanged; a grant (`--allow-large`, "Copy anyway") lets its folder send what was
//! counted, plus a margin, for a day.

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

/// `--allow-large` grants one folder, at its counted size: another folder is still counted.
#[test]
fn allow_large_lets_one_folder_through() {
    let state = tempfile::tempdir().unwrap();
    grants_in(state.path());
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    for index in 0..20 {
        write(&top, &format!("f{index}.txt"), 1);
    }
    let other = tempfile::tempdir().unwrap();
    let other = std::fs::canonicalize(other.path()).unwrap();
    for index in 0..20 {
        write(&other, &format!("f{index}.txt"), 1);
    }
    with_limits(u64::MAX, 5, || {
        assert!(super::check_plain(&top).is_err());
        let grant = super::allow(&top).unwrap();
        assert_eq!((grant.folder.as_path(), grant.bytes, grant.files), (top.as_path(), 20, 20));
        assert_eq!(super::check_plain(&top), Ok(()));
        assert!(super::check_plain(&other).is_err(), "a grant is for its own folder only");
    });
}

/// The copy itself (not only the plain-folder check) runs with the grant's limits: a granted
/// folder lists whole, and past the margin the copy stops with `copy.too_large`.
#[test]
fn the_copy_runs_with_the_grants_limits() {
    let state = tempfile::tempdir().unwrap();
    grants_in(state.path());
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    for index in 0..30 {
        write(&top, &format!("f{index}.txt"), 1);
    }
    with_limits(10, 5, || {
        refused(&top);
        super::measure(&top, None).unwrap();
        super::record(&top, 30, 30).unwrap();
        let set = collect(&top, Rules::Copy, Some(Cap::of(&top))).unwrap();
        assert_eq!(set.files.len(), 30);
        let past = std::fs::File::create(top.join("past.img")).unwrap();
        past.set_len(2 * 1024 * 1024 * 1024).unwrap();
        let large = refused(&top);
        assert_eq!(large.max_bytes, 30 + 1024 * 1024 * 1024, "{large:?}");
    });
}

/// "Copy anyway" counts to the end, never stopping at a limit, and reports as it goes.
#[test]
fn measure_counts_the_whole_folder_and_reports_progress() {
    let state = tempfile::tempdir().unwrap();
    grants_in(state.path());
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    for index in 0..4_100 {
        write(&top, &format!("d{}/f{index}.txt", index % 11), 2);
    }
    write(&top, "node_modules/p/index.js", 1000);
    let reports = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let heard = reports.clone();
    let progress = super::Progress(std::sync::Arc::new(move |bytes, files| {
        heard.lock().unwrap().push((bytes, files));
    }));
    let measured = with_limits(1, 1, || super::measure(&top, Some(progress))).unwrap();
    assert_eq!((measured.bytes, measured.files), (8_200, 4_100), "to the end, by the copy's rules");
    assert_eq!(*reports.lock().unwrap(), vec![(4_000, 2_000), (8_000, 4_000)]);
}

/// A grant is written whole (a new file renamed over the old), readable by this user only, and
/// leaves nothing beside it; a second grant replaces the first.
#[test]
fn a_grant_is_written_whole_and_private() {
    use std::os::unix::fs::PermissionsExt as _;
    let state = tempfile::tempdir().unwrap();
    grants_in(state.path());
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    for index in 0..7 {
        write(&top, &format!("f{index}.txt"), 1);
    }
    super::measure(&top, None).unwrap();
    super::record(&top, 5, 5).unwrap();
    let grant = super::record(&top, 7, 7).unwrap();
    let path = super::grant_path(&top).unwrap();
    let names: Vec<_> = std::fs::read_dir(path.parent().unwrap())
        .unwrap()
        .map(|entry| entry.unwrap().file_name())
        .collect();
    assert_eq!(names, vec![path.file_name().unwrap().to_owned()], "no temporary file left");
    assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    assert_eq!(super::granted(&top), Some(grant));
}

/// A grant lasts a day: one recorded 25 hours ago, or dated in the future, counts as none.
#[test]
fn a_grant_from_yesterday_or_the_future_is_no_grant() {
    let state = tempfile::tempdir().unwrap();
    grants_in(state.path());
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    let mut grant = super::allow(&top).unwrap();
    for granted_at in [grant.granted_at - 25 * 60 * 60, grant.granted_at + 60 * 60] {
        grant.granted_at = granted_at;
        let path = super::grant_path(&top).unwrap();
        std::fs::write(path, serde_json::to_vec(&grant).unwrap()).unwrap();
        assert_eq!(super::granted(&top), None, "granted at {granted_at}");
    }
}

/// The margin is the larger of 10% and 1 GiB (bytes), and of 10% and 10,000 (files).
#[test]
fn a_grants_margin_is_ten_percent_or_the_floor() {
    let grant = |bytes, files| super::Grant { folder: "/f".into(), bytes, files, granted_at: 0 };
    const GIB: u64 = 1024 * 1024 * 1024;
    assert_eq!(grant(5 * GIB, 1_000).max_bytes(), 6 * GIB);
    assert_eq!(grant(100 * GIB, 1_000).max_bytes(), 110 * GIB);
    assert_eq!(grant(0, 1_000).max_files(), 11_000);
    assert_eq!(grant(0, 1_000_000).max_files(), 1_100_000);
    assert_eq!(grant(u64::MAX, u64::MAX).max_bytes(), u64::MAX, "saturates");
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

/// Grants of this thread's tests are kept under `state`.
fn grants_in(state: &Path) {
    super::TEST_STATE.with(|dir| *dir.borrow_mut() = Some(state.to_path_buf()));
}

/// `--allow-large` grants the folder at the size it had then, plus a margin (1 GiB or 10%, and
/// 10,000 files or 10%): a folder that grows within it still goes, one that grows past it is
/// refused again, with what was found.
#[test]
fn a_granted_folder_that_grows_past_its_margin_is_refused_again() {
    let state = tempfile::tempdir().unwrap();
    grants_in(state.path());
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    for index in 0..20 {
        write(&top, &format!("f{index}.txt"), 1);
    }
    with_limits(10, 5, || {
        assert!(super::check_plain(&top).is_err(), "past the limits before any grant");
        super::allow(&top).unwrap();
        assert_eq!(super::check_plain(&top), Ok(()), "the folder as granted goes");
        // Sparse files: no disk spent.
        std::fs::File::create(top.join("within.img")).unwrap().set_len(512 * 1024 * 1024).unwrap();
        assert_eq!(super::check_plain(&top), Ok(()), "half a GiB more is within the margin");
        std::fs::File::create(top.join("past.img"))
            .unwrap()
            .set_len(2 * 1024 * 1024 * 1024)
            .unwrap();
        let large = super::check_plain(&top).expect_err("2.5 GiB more is past the margin");
        assert!(large.bytes > 2 * 1024 * 1024 * 1024, "{large:?}");
    });
}

/// A grant that does not say the size it was given for (an older `--allow-large`, a bare path)
/// is no grant: the folder is counted and refused as before.
#[test]
fn a_grant_without_its_size_is_no_grant() {
    let state = tempfile::tempdir().unwrap();
    grants_in(state.path());
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    for index in 0..20 {
        write(&top, &format!("f{index}.txt"), 1);
    }
    let path = super::grant_path(&top).unwrap();
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, top.as_os_str().as_encoded_bytes()).unwrap();
    with_limits(u64::MAX, 5, || {
        assert!(super::check_plain(&top).is_err(), "an old grant lets nothing through");
    });
}

/// "Copy anyway" grants only what a count found: `record` takes its numbers from a fresh
/// `measure` of the same folder, never from free input. With no count, or numbers above what the
/// count found, it refuses and grants nothing.
#[test]
fn a_grant_is_never_more_than_a_count_found() {
    let state = tempfile::tempdir().unwrap();
    grants_in(state.path());
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    for index in 0..20 {
        write(&top, &format!("f{index}.txt"), 1);
    }
    with_limits(10, 5, || {
        assert!(super::record(&top, 20, 20).is_err(), "no count yet");
        assert_eq!(super::granted(&top), None);
        let measured = super::measure(&top, None).unwrap();
        assert_eq!((measured.bytes, measured.files), (20, 20));
        assert!(super::record(&top, 21, 20).is_err(), "more bytes than the count found");
        assert!(super::record(&top, 20, 21).is_err(), "more files than the count found");
        assert!(super::record(&top, u64::MAX, u64::MAX).is_err());
        assert_eq!(super::granted(&top), None, "a refused record grants nothing");
        let grant = super::record(&top, 20, 20).unwrap();
        assert_eq!((grant.bytes, grant.files), (20, 20));
        assert_eq!(super::check_plain(&top), Ok(()));
    });
    // A count of another folder is no count of this one.
    let other = tempfile::tempdir().unwrap();
    let other = std::fs::canonicalize(other.path()).unwrap();
    assert!(super::record(&other, 1, 1).is_err());
}

/// A grant is written through no symbolic link: a link planted at the temporary file's name is
/// refused, and what it points at is left as it was.
#[test]
fn a_grant_is_never_written_through_a_link() {
    let state = tempfile::tempdir().unwrap();
    grants_in(state.path());
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    write(&top, "f.txt", 1);
    super::measure(&top, None).unwrap();
    let path = super::grant_path(&top).unwrap();
    let dir = path.parent().unwrap();
    std::fs::create_dir_all(dir).unwrap();
    let outside = tempfile::tempdir().unwrap();
    let target = outside.path().join("target");
    std::fs::write(&target, b"keep").unwrap();
    let name = path.file_name().unwrap().to_string_lossy();
    let temporary = dir.join(format!(".{name}.{}.tmp", std::process::id()));
    std::os::unix::fs::symlink(&target, &temporary).unwrap();
    assert!(super::record(&top, 1, 1).is_err(), "a link at the temporary name is refused");
    assert_eq!(std::fs::read(&target).unwrap(), b"keep", "nothing written through the link");
    assert_eq!(super::granted(&top), None);
}

/// The folder that keeps grants is this user's only (0700), also when it was there already, open
/// to others; a link in its place is refused.
#[test]
fn the_grant_folder_is_private_and_no_link() {
    use std::os::unix::fs::PermissionsExt as _;
    let state = tempfile::tempdir().unwrap();
    grants_in(state.path());
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    write(&top, "f.txt", 1);
    super::measure(&top, None).unwrap();
    let path = super::grant_path(&top).unwrap();
    let dir = path.parent().unwrap().to_path_buf();
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
    super::record(&top, 1, 1).unwrap();
    assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);

    std::fs::remove_dir_all(&dir).unwrap();
    let elsewhere = tempfile::tempdir().unwrap();
    std::os::unix::fs::symlink(elsewhere.path(), &dir).unwrap();
    assert!(super::record(&top, 1, 1).is_err(), "a link in place of the grant folder");
    assert_eq!(std::fs::read_dir(elsewhere.path()).unwrap().count(), 0, "nothing written there");
}
