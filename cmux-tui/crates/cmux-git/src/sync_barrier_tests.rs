use super::*;

/// A creation lease another holder keeps (a stuck producer) holds a probe only until the
/// caller's deadline, for all ancestors together, and the error says it decided nothing.
/// Before, each ancestor's wait took a fixed 30 s past any deadline.
#[test]
fn a_held_creation_lease_ends_the_probe_at_the_callers_deadline() {
    let dir = tempfile::tempdir().unwrap();
    let repo = dir.path().canonicalize().unwrap().join("repo");
    // A description of its own, as another process has: flock excludes the probe's.
    let held = open(&creation_lock_path(&repo), true).unwrap();
    let _held = try_take(held, Kind::Exclusive).unwrap().expect("the lease is free");
    let started = Instant::now();
    let result = probe_within(&repo, started + Duration::from_millis(200));
    let took = started.elapsed();
    let Err(error) = result else { panic!("the held lease ends the probe") };
    assert!(lock_wait_elapsed(&error), "a wait that ran out, not a verdict: {error}");
    assert!(took < Duration::from_secs(2), "the probe took {took:?} past its 200 ms");
    let started = Instant::now();
    let error = wait_ready(&repo, Duration::from_millis(200)).unwrap_err();
    assert!(lock_wait_elapsed(&error));
    assert!(started.elapsed() < Duration::from_secs(2));
}

/// The window review F1 (cmux#38084, 8843ee22f76) found: the reader saw the marker locked,
/// then the producer failed and dropped both locks. The head lock is free now, but the
/// producer never marked its head, so the folder is not past its head.
#[test]
fn a_producer_that_failed_between_the_reads_is_never_past_its_head() {
    let dir = std::env::temp_dir().join(format!("cmux-sync-unit-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let repo = dir.canonicalize().unwrap().join("repo");
    let sync = Sync::begin(&repo).unwrap();
    let marker = open(&marker(&repo).unwrap(), false).unwrap();
    let marker =
        try_take(marker, Kind::Shared).unwrap().expect_err("the reader sees the marker locked");
    drop(sync);
    assert!(matches!(syncing_state(&repo, marker).unwrap(), Syncing::Ended(_)));
    assert!(matches!(probe(&repo).unwrap(), Probe::Incomplete));
    let _ = std::fs::remove_dir_all(&dir);
}

/// Review F1 (cmux#38084, 9efddcbb52a): a producer from before head locks holds only the
/// marker. The head sidecar an earlier sync left is free, and that must not read as this
/// producer's head.
#[test]
fn an_older_producer_beside_a_left_head_sidecar_is_short_of_its_head() {
    let dir = std::env::temp_dir().join(format!("cmux-sync-legacy-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let repo = dir.canonicalize().unwrap().join("repo");
    let mut sync = Sync::begin(&repo).unwrap();
    sync.head_ready();
    sync.complete().unwrap();
    assert!(head_marker(&repo).unwrap().exists() && owner_marker(&repo).unwrap().exists());
    let legacy = open(&marker(&repo).unwrap(), true).unwrap();
    let legacy = try_take(legacy, Kind::Exclusive).unwrap().expect("the marker is free");
    assert!(matches!(probe(&repo).unwrap(), Probe::Syncing));
    drop(legacy);
    assert!(matches!(probe(&repo).unwrap(), Probe::Ready(_)));
    let _ = std::fs::remove_dir_all(&dir);
}

/// A sync that ended frees its locks at once, also while a child forked meanwhile (any
/// thread of a process that runs git, as the seed job's does) still has copies of its
/// descriptors: a lock belongs to the open file description, which a close alone leaves
/// held until the child execs or exits. Before, the next reader saw the ended sync as still
/// running and the next sync was refused "repository is in use" (LOCK-AUDIT, c-conc's
/// symptom: a lock refused after a wait proved it free).
#[test]
fn an_ended_sync_frees_its_locks_while_a_forked_child_still_has_its_descriptors() {
    let dir = std::env::temp_dir().join(format!("cmux-sync-forked-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let repo = dir.canonicalize().unwrap().join("repo");
    let mut sync = Sync::begin(&repo).unwrap();
    sync.head_ready();
    // SAFETY: the child calls only pause, which is async-signal-safe, until SIGKILL ends it.
    let child = unsafe { libc::fork() };
    assert!(child >= 0, "fork failed");
    if child == 0 {
        loop {
            // SAFETY: as above.
            unsafe { libc::pause() };
        }
    }
    sync.complete().unwrap();
    let ready = matches!(probe(&repo), Ok(Probe::Ready(_)));
    let again = Sync::begin(&repo).map(drop);
    let mut status = 0;
    // SAFETY: `child` is this test's own child and `status` outlives the call.
    unsafe {
        libc::kill(child, libc::SIGKILL);
        libc::waitpid(child, &mut status, 0);
    }
    let _ = std::fs::remove_dir_all(&dir);
    assert!(ready, "an ended sync read as running while a forked child kept its descriptors");
    again.expect("an ended sync's locks are free while a forked child keeps its descriptors");
}

/// What a ledger line holds: `**` everything, `a/**` a folder whole, `a/` (and `/` for the
/// root) a folder's own files only, and a plain line that one file.
#[test]
fn a_ledger_line_holds_its_file_its_folders_own_files_or_its_folder_whole() {
    let ledger = "/\na/\nb/**\nc/d.rs\n";
    for (path, is_dir, held) in [
        ("README.md", false, true),
        ("a/x.rs", false, true),
        ("a/sub/x.rs", false, false),
        ("a/sub", true, false),
        ("a", true, false),
        ("b", true, true),
        ("b/deep/x.rs", false, true),
        ("bb/x.rs", false, false),
        ("c/d.rs", false, true),
        ("c/e.rs", false, false),
        ("c/d.rs", true, false),
        ("", true, false),
    ] {
        assert_eq!(ledger_holds(ledger, path, is_dir), held, "{path} dir={is_dir}");
    }
    assert!(ledger_holds("**\n", "anything/at/all", true));
    assert!(!ledger_holds("", "a.rs", false));
}

/// A read-only tool runs on a filling checkout once the ledger holds its path, asks the
/// producer for one it does not hold, and a path not there yet (a folder still to come)
/// waits for a whole folder's line, not its parent's own files.
#[test]
fn a_reader_runs_on_what_the_ledger_holds_and_asks_for_the_rest() {
    let dir = std::env::temp_dir().join(format!("cmux-sync-ledger-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let repo = dir.canonicalize().unwrap().join("repo");
    let mut sync = Sync::begin(&repo).unwrap();
    std::fs::create_dir_all(repo.join("a")).unwrap();
    std::fs::write(repo.join("a/x.rs"), "x").unwrap();
    sync.head_ready();
    sync.filled(&["a/"]).unwrap();
    let short = Duration::from_millis(50);
    wait_filled(&repo.join("a/x.rs"), short).expect("a filled file reads at once");
    let waited = wait_filled(&repo.join("a/sub"), short).unwrap_err();
    assert_eq!(waited.kind(), io::ErrorKind::TimedOut, "a folder still to come waits");
    assert_eq!(sync.wants(), vec![String::from("a/sub")], "the reader asked for it");
    assert!(sync.wants().is_empty(), "wants are emptied once read");
    sync.filled(&["a/sub/**"]).unwrap();
    wait_filled(&repo.join("a/sub"), short).expect("a whole folder's line holds it");
    let waited = wait_ready(&repo, short).unwrap_err();
    assert_eq!(waited.kind(), io::ErrorKind::TimedOut, "every other tool still waits");
    sync.complete().unwrap();
    wait_filled(&repo.join("elsewhere"), short).expect("a whole checkout holds everything");
    let mut again = Sync::begin(&repo).unwrap();
    again.head_ready();
    let waited = wait_filled(&repo.join("a/x.rs"), short).unwrap_err();
    assert_eq!(waited.kind(), io::ErrorKind::TimedOut, "a new sync starts an empty ledger");
    drop(again);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Leo, 2026-11-25 (#17): "what if the user deletes the folders that were on their source of
/// truth machines? ... say genshin. it can go partial and resume whenever." A copy whose source
/// went away past its head ends ready with a note of why, so tools run on what landed; one
/// short of its head may not; the sync that completes it later takes the note away.
#[test]
fn a_partial_sync_reads_ready_with_its_note_until_a_whole_sync_completes_it() {
    let dir = std::env::temp_dir().join(format!("cmux-sync-partial-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let repo = dir.canonicalize().unwrap().join("repo");
    // Short of its head: refused, and dropping it leaves the folder failed as before.
    let early = Sync::begin(&repo).unwrap();
    assert!(early.complete_partial("source_missing").is_err());
    assert!(matches!(probe(&repo).unwrap(), Probe::Incomplete));
    assert_eq!(partial(&repo), None);

    let mut sync = Sync::begin(&repo).unwrap();
    sync.head_ready();
    sync.complete_partial("source_missing").unwrap();
    assert!(matches!(probe(&repo).unwrap(), Probe::Ready(_)));
    wait_ready(&repo, Duration::from_secs(1)).unwrap();
    assert_eq!(partial(&repo).as_deref(), Some("source_missing"));

    // The resume: a whole sync of the same folder.
    let mut again = Sync::begin(&repo).unwrap();
    again.head_ready();
    again.complete().unwrap();
    assert!(matches!(probe(&repo).unwrap(), Probe::Ready(_)));
    assert_eq!(partial(&repo), None);
    let _ = std::fs::remove_dir_all(&dir);
}
