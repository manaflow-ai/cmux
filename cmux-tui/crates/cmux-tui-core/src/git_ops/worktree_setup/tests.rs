//! Tests of a worktree's setup: its output, its environment, its stops, its ports file and the
//! files that it writes in a git folder.

#[cfg(unix)]
use std::fs::OpenOptions;

use super::*;

#[cfg(unix)]
impl Place {
    /// The path of the work tree's own git folder, as the place got it.
    fn git_dir(&self) -> &Path {
        self.own.path()
    }
}

// Each test below names a git folder, or a file in it, by a path. These calls open the folder
// of that path for the one call, and give the call of the same name that a setup makes with
// the folder that it keeps.

#[cfg(unix)]
fn read_status(git_dir: &Path) -> Option<Status> {
    super::read_status(&OwnFolder::open(git_dir))
}

#[cfg(unix)]
fn hold(git_dir: &Path) -> Option<File> {
    super::hold(&OwnFolder::open(git_dir))
}

#[cfg(unix)]
fn held(git_dir: &Path) -> bool {
    super::held(&OwnFolder::open(git_dir))
}

#[cfg(unix)]
fn open_log(git_dir: &Path) -> Option<File> {
    super::open_log(&OwnFolder::open(git_dir))
}

/// `path`: the status file in a git folder.
#[cfg(unix)]
fn write_status(path: &Path, status: &Status) -> std::io::Result<()> {
    super::write_status(&OwnFolder::open(path.parent().unwrap()), status)
}

/// `path`: a log file in a folder.
fn tail(path: &Path, since: u64, limit: u64) -> (String, u64, u64) {
    let name = path.file_name().unwrap().to_str().unwrap();
    super::tail(&OwnFolder::open(path.parent().unwrap()), name, since, limit)
}

/// The calls of the ports with the path of a repository's git folder: each opens that folder
/// for the one call.
#[cfg(unix)]
mod ports {
    use std::path::Path;
    use std::time::Duration;

    use super::super::{OwnFolder, TooLarge, ports};

    pub(super) fn lookup(common_dir: &Path, root: &Path) -> Option<u16> {
        ports::lookup(&OwnFolder::open(common_dir), root)
    }

    pub(super) fn allocate_within(
        common_dir: &Path,
        root: &Path,
        wait: Duration,
    ) -> Result<Option<u16>, TooLarge> {
        ports::allocate_within(&OwnFolder::open(common_dir), root, wait)
    }

    pub(super) fn free(common_dir: &Path, root: &Path) {
        ports::free(&OwnFolder::open(common_dir), root);
    }
}

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
    let (git_dir, common_dir) =
        (Path::new("/repo/.git/worktrees/fix-login"), Path::new("/repo/.git"));
    let (root, main) = (PathBuf::from("/w/fix-login"), Some(PathBuf::from("/repo")));
    let place = Place::new(root, main, git_dir, common_dir);
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
    let place = Place::new(root.clone(), None, &root, &root);
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
    let place = Place::new(root.clone(), None, &root, &root);
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
    let place = Place::new(root.clone(), None, &root, &root);
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
    let git_dir = top.join("git-folder");
    Place::new(top.join("root"), None, &git_dir, &git_dir)
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

/// A setup looks for the stop marker by its name and follows no link: a link at the marker's
/// name stops the setup, also a link that leads to no file. The setup's command does not start.
#[cfg(unix)]
#[test]
fn own_tree_a_stop_marker_that_is_a_link_stops_the_setup() {
    let top = folder_with_a_link_in_its_git_folder_at(CANCEL_FILE);
    let place = place_in(&top);
    let log = File::create(top.join("git-folder").join(LOG_FILE)).unwrap();
    let (handle, mut status) = (Run::default(), Status::default());

    let outcome =
        shell(&place, "touch ran", None, &log, SETUP_DEADLINE, Some((&handle, &mut status, None)));

    let ran = top.join("root/ran").exists();
    fs::remove_dir_all(top).unwrap();
    assert!(matches!(outcome, Outcome::Exited(None)) && !ran, "the setup's command started");
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

    let port = with_the_port_lock_held(&top, move || ports::lookup(place.git_dir(), &place.root));

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
        ports::allocate_within(place.git_dir(), &place.root, Duration::ZERO).ok().flatten()
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

    let reply = read(&place.root, place.git_dir(), place.git_dir(), 0);

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
    let (made, text) = (lock.is_some(), text_elsewhere(&top));
    drop(lock);
    fs::remove_dir_all(top).unwrap();
    assert_eq!(
        (made, free_at_the_name, text.as_str(), names, free_elsewhere),
        (true, false, KEPT, 1, true)
    );
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

    let port = ports::allocate_within(place.git_dir(), &place.root, Duration::ZERO).ok().flatten();

    let names = fs::metadata(&elsewhere).map_or(0, |file| file.nlink());
    let (text, made) = (text_elsewhere(&top), lock_file.is_file());
    fs::remove_dir_all(top).unwrap();
    assert_eq!((port, text.as_str(), names, made), (Some(40_010), KEPT, 1, true));
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

/// The read of a worktree's port opens no port lock: no lock file is there after it.
#[cfg(unix)]
#[test]
fn own_tree_a_port_read_makes_no_port_lock_file() {
    let top = folder_with_a_port_of_its_root();
    let place = place_in(&top);

    let port = ports::lookup(place.git_dir(), &place.root);

    let made = top.join("git-folder/cmux-worktree-ports.lock").exists();
    fs::remove_dir_all(top).unwrap();
    assert_eq!((port, made), (Some(40_010), false));
}

/// An allocation makes no port lock through a link: with a link in the lock's place it gives
/// the worktree's port, and no file is made where the link leads.
#[cfg(unix)]
#[test]
fn own_tree_a_port_allocation_makes_no_file_through_a_link_in_the_place_of_the_port_lock() {
    let top = folder_with_a_link_in_its_git_folder_at("cmux-worktree-ports.lock");
    let place = place_in(&top);
    let root = place.root.to_string_lossy().into_owned();
    let ports = json!({root: 40_010});
    fs::write(place.git_dir().join("cmux-worktree-ports.json"), ports.to_string()).unwrap();

    let port = ports::allocate_within(place.git_dir(), &place.root, Duration::ZERO).ok().flatten();

    let made = made_elsewhere(&top);
    fs::remove_dir_all(top).unwrap();
    assert_eq!((port, made), (Some(40_010), false));
}

/// A folder of [`folder_with_a_port_of_its_root`] with a named pipe in the place of the port
/// lock, and the path of the pipe. No end of the pipe is open.
#[cfg(unix)]
fn folder_with_a_named_pipe_in_the_place_of_the_port_lock() -> (PathBuf, PathBuf) {
    let top = folder_with_a_port_of_its_root();
    let lock_file = top.join("git-folder/cmux-worktree-ports.lock");
    named_pipe(&lock_file);
    (top, lock_file)
}

/// Makes a named pipe at `path`. No end of the pipe is open.
#[cfg(unix)]
fn named_pipe(path: &Path) {
    use std::os::unix::ffi::OsStrExt as _;
    let name = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
    // SAFETY: mkfifo(2) with a path that `name` keeps to the end of the call.
    let made = unsafe { libc::mkfifo(name.as_ptr(), 0o600) };
    assert_eq!(made, 0, "the test did not make the named pipe");
}

/// Whether the thing at `path` is a named pipe.
#[cfg(unix)]
fn is_a_named_pipe(path: &Path) -> bool {
    use std::os::unix::fs::FileTypeExt as _;
    fs::symlink_metadata(path).is_ok_and(|named| named.file_type().is_fifo())
}

/// An allocation gives the worktree's port with a named pipe in the place of the port lock,
/// and the pipe stays in its place. The two ends of the pipe are open here, so no open of it
/// waits.
#[cfg(unix)]
#[test]
fn own_tree_a_port_allocation_gives_the_port_with_a_named_pipe_in_the_place_of_the_port_lock() {
    let (top, lock_file) = folder_with_a_named_pipe_in_the_place_of_the_port_lock();
    let ends = OpenOptions::new().read(true).write(true).open(&lock_file).unwrap();
    let place = place_in(&top);

    let port = ports::allocate_within(place.git_dir(), &place.root, Duration::ZERO).ok().flatten();

    drop(ends);
    let stays = is_a_named_pipe(&lock_file);
    fs::remove_dir_all(top).unwrap();
    assert_eq!((port, stays), (Some(40_010), true));
}

/// An allocation does not wait for the other end of a named pipe in the place of the port
/// lock: with no end of the pipe open it gives the worktree's port, and the pipe stays in its
/// place. The allocation runs on a thread of its own. `None`: it did not end in 10 s. The 10 s
/// are not a time that the call is measured against: they only make a failed test from a call
/// that waits with no end. The test opens the pipe for a read before the join, so an open that
/// waits for that end goes on then.
#[cfg(unix)]
#[test]
fn own_tree_a_port_allocation_waits_for_no_end_of_a_named_pipe_in_the_place_of_the_port_lock() {
    use std::os::unix::fs::OpenOptionsExt as _;
    let (top, lock_file) = folder_with_a_named_pipe_in_the_place_of_the_port_lock();
    let place = place_in(&top);

    let (sender, receiver) = std::sync::mpsc::channel();
    let thread = std::thread::spawn(move || {
        let _ = sender.send(ports::allocate_within(place.git_dir(), &place.root, Duration::ZERO));
    });
    let port = receiver.recv_timeout(Duration::from_secs(10)).ok();

    let end = OpenOptions::new().read(true).custom_flags(libc::O_NONBLOCK).open(&lock_file);
    let joined = thread.join().is_ok();
    drop(end);
    let stays = is_a_named_pipe(&lock_file);
    fs::remove_dir_all(top).unwrap();
    assert_eq!((port.and_then(Result::ok).flatten(), stays, joined), (Some(40_010), true, true));
}

/// The free of a worktree's block takes the worktree out of the list when the port lock is free.
#[cfg(unix)]
#[test]
fn own_tree_a_port_free_takes_the_worktree_out_of_the_list() {
    let top = folder_with_a_port_of_its_root();
    let place = place_in(&top);

    ports::free(place.git_dir(), &place.root);

    let port = ports::lookup(place.git_dir(), &place.root);
    let list = fs::read_to_string(top.join("git-folder/cmux-worktree-ports.json"));
    fs::remove_dir_all(top).unwrap();
    assert_eq!((port, list.unwrap_or_default().as_str()), (None, "{}"));
}

/// The free of a worktree's block writes no list while another session host holds the port
/// lock: the list keeps its bytes. The block goes back at a later allocation, when its folder
/// is gone.
#[cfg(unix)]
#[test]
fn own_tree_a_port_free_writes_no_list_while_the_port_lock_is_held() {
    let top = folder_with_a_port_of_its_root();
    let place = place_in(&top);
    let list = top.join("git-folder/cmux-worktree-ports.json");
    let before = fs::read_to_string(&list).unwrap();

    let ended = with_the_port_lock_held(&top, move || ports::free(place.git_dir(), &place.root));

    let after = fs::read_to_string(&list).unwrap_or_default();
    fs::remove_dir_all(top).unwrap();
    assert_eq!((ended.is_some(), after), (true, before));
}

/// The free of a worktree's block writes no list with a link in the place of the port lock:
/// the list keeps its bytes, and no file is made where the link leads.
#[cfg(unix)]
#[test]
fn own_tree_a_port_free_writes_no_list_with_a_link_in_the_place_of_the_port_lock() {
    let top = folder_with_a_link_in_its_git_folder_at("cmux-worktree-ports.lock");
    let place = place_in(&top);
    let root = place.root.to_string_lossy().into_owned();
    let ports = json!({root: 40_010});
    let list = place.git_dir().join("cmux-worktree-ports.json");
    fs::write(&list, ports.to_string()).unwrap();
    let before = fs::read_to_string(&list).unwrap();

    ports::free(place.git_dir(), &place.root);

    let after = fs::read_to_string(&list).unwrap_or_default();
    let made = made_elsewhere(&top);
    fs::remove_dir_all(top).unwrap();
    assert_eq!((after, made), (before, false));
}

/// A log that has a second name is made new with no open of its file: the look at the name
/// comes first. The file here takes no open for a write, so an open of it for the log fails.
/// (The user root can open it: the test then passes with and without the look.)
#[cfg(unix)]
#[test]
fn own_tree_a_log_with_a_second_name_is_made_new_with_no_open_of_its_file() {
    use std::os::unix::fs::PermissionsExt as _;
    let top = folder_with_a_second_name_in_its_git_folder_at(LOG_FILE);
    fs::set_permissions(top.join("elsewhere/file"), fs::Permissions::from_mode(0o444)).unwrap();

    let log = open_log(&top.join("git-folder"));

    let (made, text) = (log.is_some(), text_elsewhere(&top));
    drop(log);
    fs::remove_dir_all(top).unwrap();
    assert_eq!((made, text.as_str()), (true, KEPT));
}

/// The read of an open log does not move the place of the open file: a process that writes
/// the log shares that place.
#[cfg(unix)]
#[test]
fn the_read_of_an_open_log_does_not_move_the_place_of_the_open_file() {
    use std::io::{Seek as _, SeekFrom};
    let top = folder_with_a_git_folder();
    let path = top.join("git-folder").join(LOG_FILE);
    fs::write(&path, "0123456789").unwrap();
    let mut log = File::open(&path).unwrap();
    log.seek(SeekFrom::Start(2)).unwrap();

    let text = tail_of(&log, 4, 100);

    let place = log.stream_position().unwrap();
    fs::remove_dir_all(top).unwrap();
    assert_eq!((text, place), (("456789".to_string(), 4, 10), 2));
}

/// A new folder with the folders `repository/worktrees/name` (the git folder of a repository
/// with the git folder of one work tree in it), `elsewhere` and `root` in it.
#[cfg(unix)]
fn folder_with_a_work_tree_of_a_repository() -> PathBuf {
    let mut bytes = [0_u8; 6];
    getrandom::fill(&mut bytes).unwrap();
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    let top = std::env::temp_dir().join(format!("cmux-setup-kept-{hex}"));
    fs::create_dir_all(top.join("repository/worktrees/name")).unwrap();
    fs::create_dir_all(top.join("elsewhere")).unwrap();
    fs::create_dir_all(top.join("root")).unwrap();
    top
}

/// The names of the entries of `folder`, in their order.
#[cfg(unix)]
fn names_in(folder: &Path) -> Vec<String> {
    let name = |entry: fs::DirEntry| entry.file_name().to_string_lossy().into_owned();
    let mut names: Vec<String> = fs::read_dir(folder)
        .map(|entries| entries.flatten().map(name).collect())
        .unwrap_or_default();
    names.sort();
    names
}

/// A setup keeps the git folder that it has at its start. The setup's command waits for a line
/// of a named pipe. While it waits, the name of the git folder goes to a different folder.
/// Then the command gets its line and ends: the last status of the setup is in the git folder
/// of its start, and the different folder gets no file.
///
/// The open of the pipe for a write runs on a thread of its own: it ends when the command has
/// the pipe open for its read. `None`: it did not end in 10 s. The 10 s are not a time that
/// the setup is measured against: they only make a failed test from a command that does not
/// come to the pipe. The run is stopped then, and the test opens the pipe for a read before
/// the join, so the open for a write goes on.
#[cfg(unix)]
#[test]
fn own_tree_a_setup_keeps_the_folder_that_it_opened() {
    use std::os::unix::fs::OpenOptionsExt as _;
    let top = folder_with_a_work_tree_of_a_repository();
    let git_dir = top.join("repository/worktrees/name");
    let gate = top.join("root/gate");
    named_pipe(&gate);
    let place = Place::new(top.join("root"), None, &git_dir, &top.join("repository"));
    let command = r#"read line < "$CMUX_WORKSPACE_PATH/gate""#;
    let recipe = Recipe { setup: Some(command.into()), ..Recipe::default() };
    let handle = Arc::new(Run::default());
    let setup = {
        let handle = handle.clone();
        std::thread::spawn(move || {
            let mut status = Status::default();
            run(&place, &recipe, &mut status, &handle, None);
            status.state
        })
    };
    let (sender, receiver) = std::sync::mpsc::channel();
    let opener = {
        let gate = gate.clone();
        std::thread::spawn(move || {
            let _ = sender.send(OpenOptions::new().write(true).open(gate));
        })
    };
    let end = receiver.recv_timeout(Duration::from_secs(10)).ok().and_then(Result::ok);
    let waits = end.is_some();
    let release = if let Some(mut end) = end {
        fs::rename(&git_dir, top.join("repository/worktrees/kept")).unwrap();
        std::os::unix::fs::symlink(top.join("elsewhere"), &git_dir).unwrap();
        let _ = std::io::Write::write_all(&mut end, b"go\n");
        None
    } else {
        handle.cancelled.store(true, Ordering::SeqCst);
        Some(OpenOptions::new().read(true).custom_flags(libc::O_NONBLOCK).open(&gate))
    };
    let joined = opener.join().is_ok();
    drop(release);

    let state = setup.join().unwrap_or_default();

    let kept = read_status(&top.join("repository/worktrees/kept")).map(|status| status.state);
    let elsewhere = names_in(&top.join("elsewhere"));
    fs::remove_dir_all(top).unwrap();
    assert!(waits && joined, "the setup's command did not come to the pipe");
    assert_eq!(
        (state.as_str(), kept.as_deref(), elsewhere),
        ("succeeded", Some("succeeded"), Vec::new())
    );
}

/// A setup keeps the ports file of the repository whose git folder it has at its start. The
/// name of that git folder goes to a different folder before the setup starts: the work tree
/// has its block of ports from the repository's ports file, and the different folder gets no
/// file.
#[cfg(unix)]
#[test]
fn own_tree_a_setup_keeps_the_ports_file_of_the_folder_that_it_opened() {
    let top = folder_with_a_work_tree_of_a_repository();
    let root = top.join("root");
    let own = root.to_str().unwrap();
    let ports = json!({own: 40_010}).to_string();
    fs::write(top.join("repository/cmux-worktree-ports.json"), ports).unwrap();
    let (git_dir, common_dir) = (top.join("repository/worktrees/name"), top.join("repository"));
    let place = Place::new(root, None, &git_dir, &common_dir);
    fs::rename(top.join("repository"), top.join("kept")).unwrap();
    std::os::unix::fs::symlink(top.join("elsewhere"), top.join("repository")).unwrap();

    // A recipe with no file list and no command: the start gives the work tree its ports only.
    let reply = start(place, Recipe::default());

    let elsewhere = names_in(&top.join("elsewhere"));
    fs::remove_dir_all(top).unwrap();
    assert_eq!((reply, elsewhere), (json!({"state": "none", "port": 40_010}), Vec::new()));
}
