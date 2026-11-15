use super::*;

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
