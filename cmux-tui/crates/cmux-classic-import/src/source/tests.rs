use super::*;
use std::fs::File;
use std::time::Duration;

fn write(root: &Path, path: &str, modified: Option<u64>) -> PathBuf {
    let file = root.join(path);
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(&file, "{}").unwrap();
    if let Some(seconds) = modified {
        File::options()
            .write(true)
            .open(&file)
            .unwrap()
            .set_modified(UNIX_EPOCH + Duration::from_secs(seconds))
            .unwrap();
    }
    file
}

/// The newest save wins whichever build reads it: a cmux NEXT nightly
/// beside the classic stable someone still uses brings stable's session.
#[test]
fn the_newest_channel_is_read_and_a_tie_goes_to_the_own_channel() {
    let root = tempfile::tempdir().unwrap();
    write(root.path(), "support/cmux/session-com.cmuxterm.app.json", Some(1));
    write(root.path(), "support/cmux/session-com.cmuxterm.app.nightly.json", Some(2));
    write(root.path(), "support/cmux/session-com.cmuxterm.app.debug.json", Some(9));
    let support = root.path().join("support");
    for own in ["com.cmuxterm.app", "com.cmuxterm.app.nightly.cmux-next", "com.cmuxterm.app.rc"] {
        assert_eq!(Finder::new(&support, Some(own)).channel(), Some("com.cmuxterm.app.nightly"));
    }
    assert_eq!(
        Finder::new(&support, Some("com.cmuxterm.app")).channels_by_recency(),
        ["com.cmuxterm.app.nightly", "com.cmuxterm.app"]
    );
    // Equal times: the own channel, then stable before the others.
    write(root.path(), "support/cmux/session-com.cmuxterm.app.json", Some(5));
    write(root.path(), "support/cmux/session-com.cmuxterm.app.nightly.json", Some(5));
    write(root.path(), "support/cmux/session-com.cmuxterm.app.rc.json", Some(5));
    assert_eq!(
        Finder::new(&support, Some("com.cmuxterm.app.rc.cmux-next")).channels_by_recency(),
        ["com.cmuxterm.app.rc", "com.cmuxterm.app", "com.cmuxterm.app.nightly"]
    );
    assert_eq!(
        Finder::new(&support, None).channels_by_recency(),
        ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.rc"]
    );
}

/// Every channel's files, the newest channel's first.
#[test]
fn all_candidates_go_channel_by_channel_newest_first() {
    let root = tempfile::tempdir().unwrap();
    let stable = write(root.path(), "support/cmux/session-com.cmuxterm.app.json", Some(1));
    let nightly = write(root.path(), "support/cmux/session-com.cmuxterm.app.nightly.json", Some(3));
    let copy =
        write(root.path(), "support/cmux/session-com.cmuxterm.app.nightly-previous.json", Some(2));
    let finder = Finder::new(&root.path().join("support"), Some("com.cmuxterm.app"));
    let all: Vec<PathBuf> = finder.all_candidates().into_iter().map(|(file, _)| file).collect();
    assert_eq!(all, [nightly, copy, stable]);
}

#[test]
fn the_socket_lock_paths_follow_the_channel() {
    let home = Path::new("/Users/me");
    let tmp = Path::new("/tmp");
    assert_eq!(
        RunningProbe::lock_paths("com.cmuxterm.app", home, tmp),
        [home.join(".local/state/cmux/cmux.sock.lock"), PathBuf::from("/tmp/cmux.sock.lock")]
    );
    assert_eq!(
        RunningProbe::lock_paths("com.cmuxterm.app.nightly", home, tmp)[0],
        home.join(".local/state/cmux/cmux-nightly.sock.lock")
    );
    assert_eq!(
        RunningProbe::lock_paths("com.cmuxterm.app.rc", home, tmp)[1],
        PathBuf::from("/tmp/cmux-rc.sock.lock")
    );
    assert_eq!(
        RunningProbe::lock_paths("com.cmuxterm.app.staging", home, tmp)[1],
        PathBuf::from("/tmp/cmux-staging.sock.lock")
    );
}

/// A lock another open file description holds is held; a free one, a
/// missing file and a link are not.
#[cfg(unix)]
#[test]
fn a_held_socket_lock_says_classic_is_open() {
    let root = tempfile::tempdir().unwrap();
    let lock = write(root.path(), "cmux.sock.lock", None);
    assert!(!RunningProbe::is_lock_held(&lock));
    assert!(!RunningProbe::is_lock_held(&root.path().join("missing.lock")));
    let holder = cmux_file_lock::FileLock::try_take(
        File::open(&lock).unwrap(),
        cmux_file_lock::Kind::Exclusive,
    )
    .unwrap();
    assert!(RunningProbe::is_lock_held(&lock));
    let link = root.path().join("link.lock");
    std::os::unix::fs::symlink(&lock, &link).unwrap();
    assert!(!RunningProbe::is_lock_held(&link));
    // FileLock unlocks before it closes, so a process another test starts keeps no lock.
    drop(holder);
    assert!(!RunningProbe::is_lock_held(&lock));
}

#[test]
fn a_channel_with_only_its_previous_copy_is_still_found() {
    let root = tempfile::tempdir().unwrap();
    write(root.path(), "support/cmux/session-com.cmuxterm.app.nightly-previous.json", Some(5));
    let finder = Finder::new(&root.path().join("support"), None);
    assert_eq!(finder.channel(), Some("com.cmuxterm.app.nightly"));
}

#[test]
fn a_channel_with_only_an_archive_is_still_found() {
    let root = tempfile::tempdir().unwrap();
    let archive = write(
        root.path(),
        "support/cmux/session-history/session-com.cmuxterm.app.nightly-9000-w1-p1.json",
        None,
    );
    let finder = Finder::new(&root.path().join("support"), None);
    assert_eq!(finder.channel(), Some("com.cmuxterm.app.nightly"));
    let files: Vec<PathBuf> = finder.candidates(None).into_iter().map(|(file, _)| file).collect();
    assert_eq!(files, [archive]);
}

/// The session file, its `-previous` copy, then the newest archive of the same channel only.
#[test]
fn candidates_are_the_file_its_copy_then_the_newest_archive() {
    let root = tempfile::tempdir().unwrap();
    let primary = write(root.path(), "support/cmux/session-com.cmuxterm.app.json", None);
    let previous = write(root.path(), "support/cmux/session-com.cmuxterm.app-previous.json", None);
    write(
        root.path(),
        "support/cmux/session-history/session-com.cmuxterm.app-1000-w1-p1.json",
        None,
    );
    let newest = write(
        root.path(),
        "support/cmux/session-history/session-com.cmuxterm.app-2000-w1-p1.json",
        None,
    );
    write(
        root.path(),
        "support/cmux/session-history/session-com.cmuxterm.app.nightly-9000-w1-p1.json",
        None,
    );
    let finder = Finder::new(&root.path().join("support"), Some("com.cmuxterm.app"));
    let files: Vec<PathBuf> =
        finder.candidates(Some("com.cmuxterm.app")).into_iter().map(|(file, _)| file).collect();
    assert_eq!(files, [primary.clone(), previous, newest.clone()]);
    assert!(finder.is_session_file(&primary) && finder.is_session_file(&newest));
    assert!(!finder.is_session_file(&root.path().join("support/cmux/other.json")));
    assert!(!finder.is_session_file(&root.path().join("elsewhere/session-com.cmuxterm.app.json")));
}

/// Only the exact files a run reads count: not a link to another file,
/// not an older archive, not a look-alike name, not a path through `..`.
#[cfg(unix)]
#[test]
fn a_session_file_is_a_regular_file_a_run_reads_and_nothing_else() {
    let root = tempfile::tempdir().unwrap();
    let secret = write(root.path(), "elsewhere/secret.json", None);
    let primary = root.path().join("support/cmux/session-com.cmuxterm.app.json");
    std::fs::create_dir_all(primary.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&secret, &primary).unwrap();
    let older = write(
        root.path(),
        "support/cmux/session-history/session-com.cmuxterm.app-1000-w1-p1.json",
        None,
    );
    write(
        root.path(),
        "support/cmux/session-history/session-com.cmuxterm.app-2000-w1-p1.json",
        None,
    );
    let look_alike = write(root.path(), "support/cmux/session-evil.json", None);
    let finder = Finder::new(&root.path().join("support"), Some("com.cmuxterm.app"));
    assert!(!finder.is_session_file(&primary));
    assert!(finder.candidates(None).iter().all(|(file, _)| file != &primary));
    assert!(!finder.is_session_file(&older));
    assert!(!finder.is_session_file(&look_alike));
    let through = root.path().join(
        "support/cmux/session-history/../session-history/session-com.cmuxterm.app-2000-w1-p1.json",
    );
    assert!(!finder.is_session_file(&through));
}

#[test]
fn the_same_save_is_its_created_at_else_its_size_and_date() {
    let source = |path: &str, size, created| Source {
        path: path.into(),
        bundle_id: "com.cmuxterm.app".into(),
        size,
        modified_at: 5.0,
        created_at: created,
    };
    assert!(source("/a", 1, Some(1.0)).is_same_save(&source("/a-previous", 99, Some(1.0))));
    assert!(!source("/a", 1, Some(1.0)).is_same_save(&source("/a", 1, Some(2.0))));
    assert!(source("/a", 1, None).is_same_save(&source("/b", 1, None)));
    assert!(!source("/a", 1, None).is_same_save(&source("/a", 2, None)));
}

#[test]
fn classic_runs_while_its_sentinel_is_there_and_it_saved_lately() {
    let root = tempfile::tempdir().unwrap();
    let probe = RunningProbe { state_root: root.path().to_path_buf() };
    let source = Source {
        path: "/s".into(),
        bundle_id: "com.cmuxterm.app".into(),
        size: 1,
        modified_at: 1000.0,
        created_at: None,
    };
    assert!(!probe.is_running(&source, 1010.0));
    write(root.path(), "lifecycle/com.cmuxterm.app/running.sentinel", None);
    assert!(probe.is_running(&source, 1010.0));
    // An old save with a sentinel is a classic that crashed.
    assert!(!probe.is_running(&source, 1100.0));
    let home = Path::new("/Users/me");
    assert_eq!(RunningProbe::default_state_root(home, None), home.join(".local/state/cmux"));
    assert_eq!(RunningProbe::default_state_root(home, Some(" ~/st ")), home.join("st/cmux"));
    assert_eq!(RunningProbe::default_state_root(home, Some("/x")), PathBuf::from("/x/cmux"));
}
