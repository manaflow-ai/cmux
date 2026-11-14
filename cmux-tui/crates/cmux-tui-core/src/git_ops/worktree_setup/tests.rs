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

/// The ports file is written under a second name that then takes its name. A link at the
/// second name is not followed: the write stays in the git folder.
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
