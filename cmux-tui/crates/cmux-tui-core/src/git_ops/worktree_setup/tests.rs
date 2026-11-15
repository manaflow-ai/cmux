//! Tests of a worktree's setup: its output, its environment, its stops, its ports file and the
//! files that it writes in a git folder.

use super::*;

#[test]
fn tail_reads_from_an_offset_within_the_limit() {
    let mut bytes = [0_u8; 6];
    getrandom::fill(&mut bytes).unwrap();
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    let path = std::env::temp_dir().join(format!("cmux-setup-log-{hex}"));
    fs::write(&path, "0123456789").unwrap();
    assert_eq!(tail(&path, 4, 100), ("456789".to_string(), 4, 10));
    assert_eq!(tail(&path, 0, 3), ("789".to_string(), 7, 10));
    assert_eq!(tail(&path, 99, 100), (String::new(), 10, 10));
    fs::remove_file(path).unwrap();
}

#[test]
fn the_environment_has_both_names() {
    let place = Place {
        root: PathBuf::from("/w/fix-login"),
        main_root: Some(PathBuf::from("/repo")),
        git_dir: PathBuf::from("/repo/.git/worktrees/fix-login"),
    };
    let values = place.environment(Some(40_010));
    assert_eq!(values["CMUX_ROOT_PATH"], "/repo");
    assert_eq!(values["CONDUCTOR_ROOT_PATH"], "/repo");
    assert_eq!(values["CMUX_WORKSPACE_NAME"], "fix-login");
    assert_eq!(values["CONDUCTOR_PORT"], "40010");
}

/// A ports file above the size limit is not read, so the ports of the other worktrees are
/// not known: the setup does not start, its log says why, and the file stays.
#[cfg(unix)]
#[test]
fn own_tree_a_setup_does_not_start_with_a_ports_file_above_the_size_limit() {
    let mut bytes = [0_u8; 6];
    getrandom::fill(&mut bytes).unwrap();
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    let root = std::env::temp_dir().join(format!("cmux-setup-ports-{hex}"));
    fs::create_dir_all(&root).unwrap();
    let place = Place { root: root.clone(), main_root: None, git_dir: root.clone() };
    let ports_file = root.join("cmux-worktree-ports.json");
    let large = "x".repeat(1024 * 1024 + 1);
    let ports = json!({large: 1}).to_string();
    fs::write(&ports_file, &ports).unwrap();
    let recipe = Recipe { setup: Some("touch started".into()), ..Recipe::default() };

    let reply = start(place, recipe);

    assert_eq!(reply, json!({"state": "failed", "port": null}));
    assert_eq!(read_status(&root).map(|status| status.state), Some("failed".to_string()));
    let log = fs::read_to_string(root.join(LOG_FILE)).unwrap_or_default();
    assert!(log.contains("is larger than 1 MiB"), "{log}");
    // No `assert_eq`: its message has both texts, each above the limit.
    assert!(fs::read_to_string(&ports_file).unwrap() == ports, "the ports file changed");
    assert!(!root.join("started").exists(), "the setup ran");
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn a_setup_stops_itself_when_another_host_removes_the_worktree() {
    let mut bytes = [0_u8; 6];
    getrandom::fill(&mut bytes).unwrap();
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    let root = std::env::temp_dir().join(format!("cmux-setup-stop-{hex}"));
    fs::create_dir_all(&root).unwrap();
    let place = Place { root: root.clone(), main_root: None, git_dir: root.clone() };
    let log = File::create(root.join(LOG_FILE)).unwrap();
    let cancel = root.join(CANCEL_FILE);
    let other_host = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(300));
        fs::write(cancel, b"").unwrap();
    });
    let (handle, mut status) = (Run::default(), Status::default());
    let started = Instant::now();
    let outcome =
        shell(&place, "sleep 30", None, &log, SETUP_DEADLINE, Some((&handle, &mut status, None)));
    other_host.join().unwrap();
    assert!(matches!(outcome, Outcome::Exited(None)));
    assert!(started.elapsed() < Duration::from_secs(10), "{:?}", started.elapsed());
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn a_setup_stops_when_its_run_is_cancelled_without_a_signal() {
    let mut bytes = [0_u8; 6];
    getrandom::fill(&mut bytes).unwrap();
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    let root = std::env::temp_dir().join(format!("cmux-setup-cancel-{hex}"));
    fs::create_dir_all(&root).unwrap();
    let place = Place { root: root.clone(), main_root: None, git_dir: root.clone() };
    let log = File::create(root.join(LOG_FILE)).unwrap();
    let handle = Arc::new(Run::default());
    let canceller = {
        let handle = handle.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(300));
            handle.cancelled.store(true, Ordering::SeqCst);
        })
    };
    let mut status = Status::default();
    let started = Instant::now();
    let outcome =
        shell(&place, "sleep 30", None, &log, SETUP_DEADLINE, Some((&handle, &mut status, None)));
    canceller.join().unwrap();
    assert!(matches!(outcome, Outcome::Exited(None)));
    assert!(started.elapsed() < Duration::from_secs(10), "{:?}", started.elapsed());
    fs::remove_dir_all(root).unwrap();
}

/// A new folder with a folder `git-folder` in it, which has a link at `name`. The link leads to
/// `elsewhere/file` in the new folder, a file that is not there.
#[cfg(unix)]
fn folder_with_a_link_in_its_git_folder_at(name: &str) -> PathBuf {
    let mut bytes = [0_u8; 6];
    getrandom::fill(&mut bytes).unwrap();
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    let top = std::env::temp_dir().join(format!("cmux-setup-link-{hex}"));
    fs::create_dir_all(top.join("git-folder")).unwrap();
    fs::create_dir_all(top.join("elsewhere")).unwrap();
    fs::create_dir_all(top.join("root")).unwrap();
    std::os::unix::fs::symlink(top.join("elsewhere/file"), top.join("git-folder").join(name))
        .unwrap();
    top
}

/// Whether a write made the file that the link of [`folder_with_a_link_in_its_git_folder_at`]
/// leads to.
#[cfg(unix)]
fn made_elsewhere(top: &Path) -> bool {
    fs::symlink_metadata(top.join("elsewhere/file")).is_ok()
}

/// The place of a setup in a folder of [`folder_with_a_link_in_its_git_folder_at`].
#[cfg(unix)]
fn place_in(top: &Path) -> Place {
    Place { root: top.join("root"), main_root: None, git_dir: top.join("git-folder") }
}

/// The ports file is written to a `.partial` file that then takes its name. A link at the name
/// of the `.partial` file is not followed: the write stays in the git folder.
#[cfg(unix)]
#[test]
fn own_tree_the_ports_file_is_not_written_through_a_link() {
    let top = folder_with_a_link_in_its_git_folder_at("cmux-worktree-ports.json.partial");
    let (git_dir, root, other) = (top.join("git-folder"), top.join("root"), top.join("other"));
    let (own, next) = (root.to_str().unwrap(), other.to_str().unwrap());
    let ports = json!({own: 40_000, next: 40_010});
    fs::write(git_dir.join("cmux-worktree-ports.json"), ports.to_string()).unwrap();

    removed(&git_dir, &root);

    assert!(!made_elsewhere(&top), "the write followed the link");
    assert_eq!(ports::lookup(&git_dir, &root), None, "the ports of the work tree went back");
    assert_eq!(ports::lookup(&git_dir, &other), Some(40_010), "the other work tree has its ports");
    fs::remove_dir_all(top).unwrap();
}

/// The status file is written as the ports file is.
#[cfg(unix)]
#[test]
fn own_tree_a_setup_status_is_not_written_through_a_link() {
    let top = folder_with_a_link_in_its_git_folder_at("cmux-setup.json.partial");
    let git_dir = top.join("git-folder");
    let status = Status { state: "running".into(), ..Status::default() };

    let written = write_status(&git_dir.join(STATUS_FILE), &status);

    assert!(!made_elsewhere(&top), "the write followed the link");
    assert!(written.is_ok(), "{written:?}");
    assert_eq!(read_status(&git_dir).map(|status| status.state), Some("running".to_string()));
    fs::remove_dir_all(top).unwrap();
}

#[cfg(unix)]
#[test]
fn own_tree_the_run_lock_is_not_made_through_a_link() {
    let top = folder_with_a_link_in_its_git_folder_at(LOCK_FILE);

    let lock = hold(&top.join("git-folder"));

    assert!(!made_elsewhere(&top), "the open followed the link");
    assert!(lock.is_none(), "a link is the lock of no run");
    fs::remove_dir_all(top).unwrap();
}

#[cfg(unix)]
#[test]
fn own_tree_a_setup_log_is_not_written_through_a_link() {
    let top = folder_with_a_link_in_its_git_folder_at(LOG_FILE);
    let mut status = Status::default();

    run(&place_in(&top), &Recipe::default(), &mut status, &Run::default(), None);

    assert!(!made_elsewhere(&top), "the open followed the link");
    assert_eq!(status.state, "failed", "a setup with no log does not go on");
    fs::remove_dir_all(top).unwrap();
}

#[cfg(unix)]
#[test]
fn own_tree_a_teardown_log_is_not_written_through_a_link() {
    let top = folder_with_a_link_in_its_git_folder_at(LOG_FILE);

    let reply = teardown(&place_in(&top), Some("touch ran"));

    assert!(!made_elsewhere(&top), "the open followed the link");
    assert_eq!(reply, None, "a teardown with no log does not run");
    assert!(!top.join("root/ran").exists(), "the teardown ran");
    fs::remove_dir_all(top).unwrap();
}

/// A removal tells the setup of another session host to stop by a marker file.
#[cfg(unix)]
#[test]
fn own_tree_the_stop_marker_is_not_written_through_a_link() {
    let top = folder_with_a_link_in_its_git_folder_at(CANCEL_FILE);
    // The status of a setup that this session host did not start.
    let status = r#"{"state":"running","started_ms":1}"#;
    fs::write(top.join("git-folder").join(STATUS_FILE), status).unwrap();

    stop(&place_in(&top));

    assert!(!made_elsewhere(&top), "the write followed the link");
    fs::remove_dir_all(top).unwrap();
}

/// The text of the file that [`folder_with_a_second_name_in_its_git_folder_at`] makes.
#[cfg(unix)]
const KEPT: &str = "a file that is not a file of the setup\n";

/// A new folder with the folders `git-folder`, `elsewhere` and `root` in it.
#[cfg(unix)]
fn folder_with_a_git_folder() -> PathBuf {
    let mut bytes = [0_u8; 6];
    getrandom::fill(&mut bytes).unwrap();
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    let top = std::env::temp_dir().join(format!("cmux-setup-name-{hex}"));
    fs::create_dir_all(top.join("git-folder")).unwrap();
    fs::create_dir_all(top.join("elsewhere")).unwrap();
    fs::create_dir_all(top.join("root")).unwrap();
    top
}

/// A folder of [`folder_with_a_git_folder`]. Its file `elsewhere/file`, with the text [`KEPT`],
/// has a second name: `name` in `git-folder`.
#[cfg(unix)]
fn folder_with_a_second_name_in_its_git_folder_at(name: &str) -> PathBuf {
    let top = folder_with_a_git_folder();
    fs::write(top.join("elsewhere/file"), KEPT).unwrap();
    fs::hard_link(top.join("elsewhere/file"), top.join("git-folder").join(name)).unwrap();
    top
}

/// The text of the file elsewhere of [`folder_with_a_second_name_in_its_git_folder_at`].
#[cfg(unix)]
fn text_elsewhere(top: &Path) -> String {
    fs::read_to_string(top.join("elsewhere/file")).unwrap()
}

/// Only the marker's name is used, so a file that is at the name is not opened: a file that has
/// the marker's name as a second name keeps its text and its 2 names. This test and
/// [`own_tree_the_stop_marker_is_made_when_there_is_none`] are one proof together: that test,
/// with the same status, shows that the stop comes to the marker.
#[cfg(unix)]
#[test]
fn own_tree_the_stop_marker_changes_no_file_with_a_second_name() {
    use std::os::unix::fs::MetadataExt as _;
    let top = folder_with_a_second_name_in_its_git_folder_at(CANCEL_FILE);
    // The status of a setup that this session host did not start.
    let status = r#"{"state":"running","started_ms":1}"#;
    fs::write(top.join("git-folder").join(STATUS_FILE), status).unwrap();

    stop(&place_in(&top));

    let names = fs::metadata(top.join("elsewhere/file")).map_or(0, |file| file.nlink());
    assert_eq!((text_elsewhere(&top).as_str(), names), (KEPT, 2));
    fs::remove_dir_all(top).unwrap();
}

/// The stop makes the marker when there is none: the setup of the other session host looks for
/// the marker's name.
#[cfg(unix)]
#[test]
fn own_tree_the_stop_marker_is_made_when_there_is_none() {
    let top = folder_with_a_git_folder();
    // The status of a setup that this session host did not start.
    let status = r#"{"state":"running","started_ms":1}"#;
    fs::write(top.join("git-folder").join(STATUS_FILE), status).unwrap();
    let marker = top.join("git-folder").join(CANCEL_FILE);
    let before = marker.exists();

    stop(&place_in(&top));

    assert_eq!((before, marker.exists()), (false, true));
    fs::remove_dir_all(top).unwrap();
}

/// A log that has a second name is made new: the setup's lines go into the new log, and the
/// file at the other name keeps its text.
#[cfg(unix)]
#[test]
fn own_tree_a_setup_log_with_a_second_name_is_made_new() {
    let top = folder_with_a_second_name_in_its_git_folder_at(LOG_FILE);
    // A recipe with a file list and no command: the run writes its lines and starts no shell.
    let recipe = Recipe { include: vec!["notes.txt".into()], ..Recipe::default() };
    let mut status = Status::default();

    run(&place_in(&top), &recipe, &mut status, &Run::default(), None);

    let log = fs::read_to_string(top.join("git-folder").join(LOG_FILE)).unwrap_or_default();
    assert_eq!(
        (text_elsewhere(&top).as_str(), log.contains(KEPT), log.contains("Copied 0 files")),
        (KEPT, false, true),
        "the log: {log}"
    );
    assert_eq!(status.state, "succeeded");
    fs::remove_dir_all(top).unwrap();
}

/// A teardown's log is opened as a setup's log is.
#[cfg(unix)]
#[test]
fn own_tree_a_teardown_log_with_a_second_name_is_made_new() {
    let top = folder_with_a_second_name_in_its_git_folder_at(LOG_FILE);

    let reply = teardown(&place_in(&top), Some("touch ran")).unwrap_or_default();

    let log = fs::read_to_string(top.join("git-folder").join(LOG_FILE)).unwrap_or_default();
    assert_eq!(
        (text_elsewhere(&top).as_str(), log.contains(KEPT), log.contains("$ touch ran")),
        (KEPT, false, true),
        "the log: {log}"
    );
    // The reply has the lines of the new log from its start.
    let output = reply["output"].as_str().unwrap_or_default();
    assert!(output.starts_with("$ touch ran\n"), "{reply}");
    assert_eq!(reply["state"], "succeeded", "{reply}");
    assert!(top.join("root/ran").exists(), "the teardown did not run");
    fs::remove_dir_all(top).unwrap();
}

/// A log with one name is the setup's own log: a teardown writes at its end, and the reply has
/// the teardown's lines only.
#[cfg(unix)]
#[test]
fn own_tree_a_log_with_one_name_keeps_its_lines() {
    let top = folder_with_a_git_folder();
    let log_path = top.join("git-folder").join(LOG_FILE);
    fs::write(&log_path, "a line of the setup\n").unwrap();

    let reply = teardown(&place_in(&top), Some("touch ran")).unwrap_or_default();

    let log = fs::read_to_string(&log_path).unwrap_or_default();
    assert!(log.starts_with("a line of the setup\n$ touch ran\n"), "the log: {log}");
    let output = reply["output"].as_str().unwrap_or_default();
    assert!(output.starts_with("$ touch ran\n"), "{reply}");
    assert_eq!(reply["state"], "succeeded", "{reply}");
    fs::remove_dir_all(top).unwrap();
}

/// A folder of [`folder_with_a_git_folder`] whose ports file says that the worktree `root` has
/// the block of ports that starts at 40010.
#[cfg(unix)]
fn folder_with_a_port_of_its_root() -> PathBuf {
    let top = folder_with_a_git_folder();
    let root = top.join("root").to_string_lossy().into_owned();
    let ports = json!({root: 40_010});
    fs::write(top.join("git-folder/cmux-worktree-ports.json"), ports.to_string()).unwrap();
    top
}

/// What `call` gives on a thread of its own while a second open of the port lock of
/// [`folder_with_a_port_of_its_root`] holds the lock, as another session host holds it during
/// an allocation. `None`: the call did not end in 10 s. The 10 s are not a time that a call
/// is measured against: they only make a failed test from a call that waits with no end. The
/// lock is let go before the join, so a call that waits for it ends then.
#[cfg(unix)]
fn with_the_port_lock_held<T: Send + 'static>(
    top: &Path,
    call: impl FnOnce() -> T + Send + 'static,
) -> Option<T> {
    use std::os::fd::AsRawFd as _;
    let mut options = OpenOptions::new();
    options.create(true).truncate(false).write(true);
    let held = options.open(top.join("git-folder/cmux-worktree-ports.lock")).unwrap();
    // SAFETY: flock(2) on a descriptor that `held` keeps open; LOCK_NB makes it return at once.
    let taken = unsafe { libc::flock(held.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    assert_eq!(taken, 0, "the test did not get the port lock");
    let (sender, receiver) = std::sync::mpsc::channel();
    let thread = std::thread::spawn(move || {
        let _ = sender.send(call());
    });
    let result = receiver.recv_timeout(Duration::from_secs(10)).ok();
    // SAFETY: as above. The unlock is its own call: a close alone keeps the lock while a child
    // that another test forked has a copy of the descriptor.
    unsafe {
        libc::flock(held.as_raw_fd(), libc::LOCK_UN);
    }
    thread.join().unwrap();
    result
}

/// The read of a worktree's port takes no port lock: it gives the port while another session
/// host holds the lock.
#[cfg(unix)]
#[test]
fn own_tree_a_port_read_takes_no_port_lock() {
    let top = folder_with_a_port_of_its_root();
    let place = place_in(&top);

    let port = with_the_port_lock_held(&top, move || ports::lookup(&place.git_dir, &place.root));

    fs::remove_dir_all(top).unwrap();
    assert_eq!(port, Some(Some(40_010)), "the read waited for the port lock");
}

/// An allocation waits a bounded time for the port lock: it ends while another session host
/// holds the lock, and the worktree has its port. The time is zero here, which is one try of
/// the lock and no wait.
#[cfg(unix)]
#[test]
fn own_tree_a_port_allocation_waits_a_bounded_time_for_the_port_lock() {
    let top = folder_with_a_port_of_its_root();
    let place = place_in(&top);

    let port = with_the_port_lock_held(&top, move || {
        ports::allocate_within(&place.git_dir, &place.root, Duration::ZERO).ok().flatten()
    });

    fs::remove_dir_all(top).unwrap();
    assert_eq!(port, Some(Some(40_010)), "the allocation waited for the port lock with no end");
}

/// The read of a setup gives no text of a log that has a second name: the text is the text of
/// the file at the other name. The read gives the setup's state.
#[cfg(unix)]
#[test]
fn own_tree_a_setup_read_gives_no_text_of_a_log_with_a_second_name() {
    let top = folder_with_a_second_name_in_its_git_folder_at(LOG_FILE);
    let status = r#"{"state":"succeeded","started_ms":1}"#;
    fs::write(top.join("git-folder").join(STATUS_FILE), status).unwrap();
    let place = place_in(&top);

    let reply = read(&place.root, &place.git_dir, 0);

    fs::remove_dir_all(top).unwrap();
    assert_eq!((&reply["output"], &reply["state"]), (&json!(""), &json!("succeeded")), "{reply}");
}

/// A run lock that has a second name is made new: the run's lock is on the new file, and the
/// file at the other name keeps its text, has one name and has no lock.
#[cfg(unix)]
#[test]
fn own_tree_the_run_lock_with_a_second_name_is_made_new() {
    use std::os::unix::fs::MetadataExt as _;
    let top = folder_with_a_second_name_in_its_git_folder_at(LOCK_FILE);
    let elsewhere = top.join("elsewhere/file");

    let lock = hold(&top.join("git-folder"));

    let names = fs::metadata(&elsewhere).map_or(0, |file| file.nlink());
    let free_elsewhere = crate::fork_tests::free(&elsewhere);
    let free_at_the_name = crate::fork_tests::free(&top.join("git-folder").join(LOCK_FILE));
    assert_eq!(
        (lock.is_some(), free_at_the_name, text_elsewhere(&top).as_str(), names, free_elsewhere),
        (true, false, KEPT, 1, true)
    );
    drop(lock);
    fs::remove_dir_all(top).unwrap();
}

/// The port lock is opened as the run lock is: a lock file that has a second name is made new,
/// and the file at the other name keeps its text and has one name.
#[cfg(unix)]
#[test]
fn own_tree_the_port_lock_with_a_second_name_is_made_new() {
    use std::os::unix::fs::MetadataExt as _;
    let top = folder_with_a_port_of_its_root();
    let (elsewhere, lock_file) =
        (top.join("elsewhere/file"), top.join("git-folder/cmux-worktree-ports.lock"));
    fs::write(&elsewhere, KEPT).unwrap();
    fs::hard_link(&elsewhere, &lock_file).unwrap();
    let place = place_in(&top);

    let port = ports::allocate_within(&place.git_dir, &place.root, Duration::ZERO).ok().flatten();

    let names = fs::metadata(&elsewhere).map_or(0, |file| file.nlink());
    assert_eq!((port, text_elsewhere(&top).as_str(), names), (Some(40_010), KEPT, 1));
    assert!(lock_file.is_file(), "the ports have no lock file");
    fs::remove_dir_all(top).unwrap();
}

/// A lock file that has a second name is the lock of no run: a lock that a program has on the
/// file at the other name is not read as a setup that runs.
#[cfg(unix)]
#[test]
fn own_tree_a_lock_file_with_a_second_name_is_no_run_lock() {
    use std::os::fd::AsRawFd as _;
    let top = folder_with_a_second_name_in_its_git_folder_at(LOCK_FILE);
    let other = File::open(top.join("elsewhere/file")).unwrap();
    // SAFETY: flock(2) on a descriptor that `other` keeps open; LOCK_NB makes it return at once.
    let taken = unsafe { libc::flock(other.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    assert_eq!(taken, 0, "the test did not get the lock of the file");

    let run_lock = held(&top.join("git-folder"));

    // SAFETY: as above. The unlock is its own call, as in `with_the_port_lock_held`.
    unsafe {
        libc::flock(other.as_raw_fd(), libc::LOCK_UN);
    }
    fs::remove_dir_all(top).unwrap();
    assert!(!run_lock, "a lock on a file with a second name was read as the lock of a run");
}

/// The log of a setup that does not start is opened as the log of a setup that runs: a log
/// that has a second name is made new, and the file at the other name keeps its text.
#[cfg(unix)]
#[test]
fn own_tree_the_log_of_a_setup_that_does_not_start_is_made_new_with_a_second_name() {
    let top = folder_with_a_second_name_in_its_git_folder_at(LOG_FILE);
    // A ports file above the size limit: the setup does not start, and its log says why.
    let large = "x".repeat(1024 * 1024 + 1);
    let ports = json!({large: 1}).to_string();
    fs::write(top.join("git-folder/cmux-worktree-ports.json"), ports).unwrap();
    let recipe = Recipe { setup: Some("touch started".into()), ..Recipe::default() };

    let reply = start(place_in(&top), recipe);

    let log = fs::read_to_string(top.join("git-folder").join(LOG_FILE)).unwrap_or_default();
    let (text, started) = (text_elsewhere(&top), top.join("root/started").exists());
    fs::remove_dir_all(top).unwrap();
    assert_eq!((&reply["state"], started), (&json!("failed"), false), "{reply}");
    assert_eq!(
        (text.as_str(), log.contains(KEPT), log.contains("is larger than 1 MiB")),
        (KEPT, false, true)
    );
}

/// A write of a JSON file that fails at its open gives the error of that open.
#[cfg(unix)]
#[test]
fn own_tree_a_json_write_gives_the_error_of_its_open() {
    let top = folder_with_a_git_folder();
    // A folder that is not there: the open of the `.partial` file gives `NotFound`.
    let path = top.join("no-such-folder").join(STATUS_FILE);

    let written = write_status(&path, &Status::default());

    fs::remove_dir_all(top).unwrap();
    assert_eq!(written.map_err(|error| error.kind()), Err(std::io::ErrorKind::NotFound));
}
