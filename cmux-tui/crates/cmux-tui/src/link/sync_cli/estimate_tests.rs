//! A start's copy estimate, before any machine: time counts as well as size, a listing that runs
//! long is bounded and still starts, `--allow-large` still sends it whole, and the copy after a
//! start sends what the start said.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use super::super::local::{self, Rules};
use super::super::size_cap;
use super::*;

fn write(top: &Path, relative: &str, bytes: usize) {
    let path = top.join(relative);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, vec![b'x'; bytes]).unwrap();
}

fn folder() -> (tempfile::TempDir, PathBuf) {
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    (root, top)
}

/// Runs `run` with the link's rate at `rate` bytes a second and the state kept in `state`.
fn with<T>(rate: Option<u64>, state: Option<&Path>, run: impl FnOnce() -> T) -> T {
    TEST_RATE.with(|cell| cell.set(rate));
    TEST_STATE.with(|cell| *cell.borrow_mut() = state.map(Path::to_path_buf));
    let out = run();
    TEST_RATE.with(|cell| cell.set(None));
    TEST_STATE.with(|cell| *cell.borrow_mut() = None);
    out
}

/// A first pass of at most `bytes` in `files`, as `size_cap`'s tests set it.
fn with_first<T>(bytes: u64, files: u64, run: impl FnOnce() -> T) -> T {
    size_cap::TEST_FIRST.with(|cell| cell.set(Some((bytes, files))));
    let out = run();
    size_cap::TEST_FIRST.with(|cell| cell.set(None));
    out
}

/// Ten files of 10 kB: 100 kB, far under the size limits.
fn small_project(top: &Path) {
    for index in 0..10 {
        write(top, &format!("src/f{index}.txt"), 10_000);
    }
}

#[test]
fn a_slow_link_starts_from_a_first_pass_under_the_size_limits() {
    let (_root, top) = folder();
    small_project(&top);
    // 1 kB/s: 100 kB is 100 s, past the minute.
    let estimate = with(Some(1000), None, || with_first(30_000, 100, || of_folder(&top))).unwrap();
    assert_eq!(estimate.mode, Mode::FirstPass, "{estimate:?}");
    assert_eq!(estimate.why, Some(Why::Time));
    assert_eq!((estimate.folder_files, estimate.folder_bytes), (10, 100_000));
    assert_eq!((estimate.files, estimate.bytes), (3, 30_000));
    assert_eq!((estimate.left_files, estimate.left_bytes), (7, 70_000));
    assert_eq!(estimate.seconds, Some(30));
    assert!(estimate.complete && estimate.measured);
}

#[test]
fn a_fast_link_under_the_size_limits_still_goes_whole() {
    let (_root, top) = folder();
    small_project(&top);
    let estimate = with(Some(1024 * 1024 * 1024), None, || of_folder(&top)).unwrap();
    assert_eq!(estimate.mode, Mode::Whole, "{estimate:?}");
    assert_eq!(estimate.why, None);
    assert_eq!((estimate.files, estimate.bytes, estimate.left_files), (10, 100_000, 0));
    assert_eq!(estimate.seconds, Some(1));
}

#[test]
fn allow_large_still_sends_it_whole_on_a_slow_link() {
    let (_root, top) = folder();
    small_project(&top);
    let (mut set, stopped) = local::listed(&top, Rules::Copy, Some(size_cap::Cap::new())).unwrap();
    let estimate = with(Some(1000), None, || decide(&mut set, stopped, true));
    assert_eq!((estimate.mode, estimate.why), (Mode::Whole, None));
    assert_eq!(set.files.len(), 10);
}

/// A listing that runs past its bound (a cold parent of many folders) stops there, and the start
/// goes on from a first pass of what it listed.
#[test]
fn a_listing_past_its_time_bound_still_starts_from_a_first_pass() {
    let (_root, top) = folder();
    for index in 0..2100 {
        write(&top, &format!("d{}/f{index:05}.txt", index % 7), 3);
    }
    let started = Instant::now();
    let (mut set, stopped) =
        local::listed(&top, Rules::Copy, Some(size_cap::Cap::until(started))).unwrap();
    assert!(stopped, "a bound already past stops the listing");
    let estimate = with(Some(1024 * 1024 * 1024), None, || decide(&mut set, stopped, false));
    assert_eq!((estimate.mode, estimate.why), (Mode::FirstPass, Some(Why::ListingBound)));
    assert!(!estimate.complete);
    assert_eq!(estimate.folder_files, 1024, "the clock is read every 1,024 files");
    assert!(estimate.left_files >= 1, "{estimate:?}");
}

#[test]
fn past_the_size_limits_is_a_first_pass_by_size_or_files() {
    let (_root, top) = folder();
    small_project(&top);
    let by_size = size_cap::with_test_limits(50_000, 100, || {
        with(Some(1024 * 1024 * 1024), None, || of_folder(&top))
    })
    .unwrap();
    assert_eq!((by_size.mode, by_size.why), (Mode::FirstPass, Some(Why::Size)));
    let by_files = size_cap::with_test_limits(1 << 40, 4, || {
        with(Some(1024 * 1024 * 1024), None, || of_folder(&top))
    })
    .unwrap();
    assert_eq!((by_files.mode, by_files.why), (Mode::FirstPass, Some(Why::Files)));
    assert!(!by_files.complete);
}

#[test]
fn the_rate_is_the_median_of_the_last_copies_and_the_default_before_any() {
    let state = tempfile::tempdir().unwrap();
    with(None, Some(state.path()), || {
        assert_eq!(rate(), (DEFAULT_RATE, false));
        // Too small to say anything about the link: not kept.
        record_rate(1024, Duration::from_millis(1));
        assert_eq!(rate(), (DEFAULT_RATE, false));
        let mib = 1024 * 1024;
        record_rate(10 * mib, Duration::from_secs(1));
        record_rate(40 * mib, Duration::from_secs(2));
        record_rate(90 * mib, Duration::from_secs(3));
        assert_eq!(rate(), (20 * mib, true));
        for _ in 0..SAMPLES {
            record_rate(10 * mib, Duration::from_secs(10));
        }
        assert_eq!(rate(), (mib, true), "only the last {SAMPLES} copies count");
    });
}

#[test]
fn a_slow_link_sizes_the_first_pass_to_the_budget() {
    with(Some(1024 * 1024), None, || {
        // 1 MiB/s for a minute is 60 MiB, under the 256 MiB first pass.
        assert_eq!(size_cap::first_limits().0, 60 * 1024 * 1024);
    });
    with(Some(1), None, || assert_eq!(within_budget(size_cap::FIRST_BYTES), 8 * 1024 * 1024));
    with(Some(1 << 30), None, || assert_eq!(size_cap::first_limits().0, size_cap::FIRST_BYTES));
}

/// Two surfaces of one start (the CLI's, then the app's preflight) list once; the copy after it
/// sends what the start said, even on a link that got faster in between.
#[test]
fn the_copy_sends_what_its_start_decided() {
    let (_root, top) = folder();
    small_project(&top);
    let state = tempfile::tempdir().unwrap();
    let first =
        with(Some(1000), Some(state.path()), || with_first(30_000, 100, || of_folder(&top)))
            .unwrap();
    assert_eq!(first.mode, Mode::FirstPass);
    let again = with(Some(1 << 30), Some(state.path()), || of_folder(&top)).unwrap();
    assert_eq!(again, first, "read back, not listed again");
    let mut set = local::collect(&top, Rules::Copy, Some(size_cap::Cap::new())).unwrap();
    let copied = with(Some(1 << 30), Some(state.path()), || {
        with_first(30_000, 100, || for_copy(&top, &mut set))
    })
    .unwrap();
    assert_eq!(copied.mode, Mode::FirstPass);
    assert_eq!(set.files.len(), 3, "the first pass the start said");
}

#[test]
fn a_copy_with_no_start_before_it_decides_by_time_itself() {
    let (_root, top) = folder();
    small_project(&top);
    let mut fast = local::collect(&top, Rules::Copy, Some(size_cap::Cap::new())).unwrap();
    let whole = with(Some(1 << 30), None, || for_copy(&top, &mut fast)).unwrap();
    assert_eq!((whole.mode, fast.files.len()), (Mode::Whole, 10));
    let mut slow = local::collect(&top, Rules::Copy, Some(size_cap::Cap::new())).unwrap();
    let first =
        with(Some(1000), None, || with_first(30_000, 100, || for_copy(&top, &mut slow))).unwrap();
    assert_eq!((first.mode, first.why, slow.files.len()), (Mode::FirstPass, Some(Why::Time), 3));
    // `--allow-large` (no cap): nothing to decide.
    let mut allowed = local::collect(&top, Rules::Copy, None).unwrap();
    assert!(with(Some(1000), None, || for_copy(&top, &mut allowed)).is_none());
}

fn git(dir: &Path, args: &[&str]) {
    let status = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
        .args(args)
        .status()
        .unwrap();
    assert!(status.success(), "git {args:?}");
}

/// A repository with a GitHub remote whose commit is on the remote is seeded: no copy, no time
/// for one; the copy it falls back to is still decided.
#[test]
fn a_github_repository_is_a_seed_and_a_plain_folder_is_not() {
    let (_root, top) = folder();
    git(&top, &["init", "-q", "-b", "main"]);
    write(&top, "src/main.rs", 100);
    git(&top, &["add", "."]);
    git(&top, &["commit", "-qm", "init"]);
    git(&top, &["remote", "add", "origin", "https://github.com/example/app.git"]);
    git(&top, &["update-ref", "refs/remotes/origin/main", "HEAD"]);
    let seed = with(Some(1 << 30), None, || of_folder(&top)).unwrap();
    assert_eq!((seed.mode, seed.copy_mode, seed.seconds), (Mode::Seed, Some(Mode::Whole), None));
    assert_eq!(seed.copy(), Mode::Whole);
    let slow = with(Some(1), None, || of_folder(&top)).unwrap();
    assert_eq!((slow.mode, slow.copy()), (Mode::Seed, Mode::FirstPass));

    let (_plain_root, plain) = folder();
    small_project(&plain);
    assert_eq!(with(Some(1 << 30), None, || of_folder(&plain)).unwrap().mode, Mode::Whole);
}

#[test]
fn the_words_say_what_goes_and_what_stays() {
    let (_root, top) = folder();
    small_project(&top);
    let whole = with(Some(1 << 30), None, || of_folder(&top)).unwrap();
    assert_eq!(whole.words(), "Copying 100 kB (10 files), about 1 s");
    let first = with(Some(1000), None, || with_first(30_000, 100, || of_folder(&top))).unwrap();
    assert_eq!(
        first.words(),
        "Starting now with 30 kB (3 files); 70 kB stays on this Mac until the chat asks for it"
    );
}
