//! Tests of a worktree's setup: its output, its environment, its stops and its ports file.

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
