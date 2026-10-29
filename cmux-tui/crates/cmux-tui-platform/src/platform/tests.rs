use super::*;

#[cfg(windows)]
use std::ffi::OsString;
#[cfg(windows)]
use std::sync::Mutex;

#[cfg(windows)]
static RUNTIME_ENV_LOCK: Mutex<()> = Mutex::new(());

#[cfg(unix)]
#[test]
fn private_socket_peer_uid_must_match_the_expected_user() {
    let (client, server) = std::os::unix::net::UnixStream::pair().unwrap();
    let owner = effective_uid();

    assert_eq!(unix_peer_uid(&client).unwrap(), owner);
    assert_eq!(unix_peer_uid(&server).unwrap(), owner);
    require_unix_peer_uid(&client, owner).unwrap();
    let error = require_unix_peer_uid(&client, owner.wrapping_add(1))
        .expect_err("a peer running as another user must be refused");
    assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn foreground_cwd_lookup_reads_a_live_child_directory_and_fails_closed() {
    let target = std::env::temp_dir()
        .canonicalize()
        .unwrap()
        .join(format!("cmux-foreground-cwd-{}", std::process::id()));
    std::fs::create_dir_all(&target).unwrap();
    let mut child = cmux_process::Command::new("/bin/sleep")
        .arg("30")
        .current_dir(&target)
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .spawn()
        .unwrap();
    let observed = process_cwd(child.id());
    child.kill().unwrap();
    child.wait().unwrap();
    assert_eq!(
        observed.map(PathBuf::from),
        Some(target.clone()),
        "the live child working directory was not observed"
    );
    assert_eq!(process_cwd(u32::MAX), None, "an impossible PID did not fail closed");
    std::fs::remove_dir(&target).unwrap();
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn foreground_cwd_requires_a_controlling_terminal() {
    // The child starts its own session, so it deterministically has no
    // controlling terminal and the foreground lookup must fail closed
    // instead of inventing a directory.
    let mut child = cmux_process::Command::new("/bin/sleep")
        .arg("30")
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .new_session()
        .spawn()
        .unwrap();
    let observed = foreground_process_group(child.id());
    child.kill().unwrap();
    child.wait().unwrap();
    assert_eq!(observed, None);
    assert_eq!(foreground_cwd(u32::MAX), None);
}

#[cfg(windows)]
#[test]
fn normalize_long_windows_parent_paths_preserve_component_semantics() {
    let path = PathBuf::from(format!(r"C:\{}\..\state", "segment".repeat(42)));
    let normalized = normalize_filesystem_path(path.clone());
    let text = normalized.to_string_lossy();
    assert_eq!(normalized, path, "{text}");
}

#[cfg(windows)]
#[test]
fn normalize_long_windows_relative_failures_preserve_original_spelling() {
    let parent = vec!["segment"; 36].join(r"\");
    for path in
        [PathBuf::from(format!(r"{parent}\..\state")), PathBuf::from(format!(r"{parent}\state."))]
    {
        let normalized = normalize_filesystem_path(path.clone());
        assert_eq!(normalized, path, "{}", normalized.display());
    }
}

#[cfg(windows)]
#[test]
fn normalize_long_windows_root_relative_paths_preserve_current_drive_semantics() {
    let path = PathBuf::from(format!(r"\{}\state", "segment".repeat(42)));
    let normalized = normalize_filesystem_path(path.clone());
    assert_eq!(normalized, path, "{}", normalized.display());
}

#[cfg(windows)]
#[test]
fn normalize_long_windows_trailing_dot_or_space_paths_preserve_component_semantics() {
    let parent = vec!["segment"; 36].join(r"\");
    for child in ["state.", "state "] {
        let path = PathBuf::from(format!(r"C:\{parent}\{child}"));
        let normalized = normalize_filesystem_path(path.clone());
        assert_eq!(normalized, path, "{}", normalized.display());
    }
}

#[cfg(windows)]
#[test]
fn normalize_long_windows_reserved_device_paths_preserve_component_semantics() {
    let parent = vec!["segment"; 36].join(r"\");
    for child in ["CON", "nul.txt", "Com9.log", "LPT¹"] {
        let path = PathBuf::from(format!(r"C:\{parent}\{child}"));
        let normalized = normalize_filesystem_path(path.clone());
        assert_eq!(normalized, path, "{}", normalized.display());
    }
}

/// Review 3 of cp/daemon-foreground-state (blocker): a threaded shell forks
/// from any thread, and the no-child test reads the main thread's children
/// only, so a shell with more than one thread is unknown (never idle). The
/// state field says whether it sleeps in a read (follow-up, review 4 item 1).
#[test]
fn shell_idle_a_shell_with_more_than_one_thread_has_no_exec_name() {
    // pid (comm) state ppid pgrp session tty_nr tpgid flags minflt cminflt
    // majflt cmajflt utime stime cutime cstime priority nice num_threads ...
    let one = "4242 (bash) S 1 4242 4242 34816 4242 4194560 0 0 0 0 0 0 0 0 20 0 1 0 100 0";
    assert_eq!(single_thread_name(one), Some(("bash".to_string(), true)));
    let running = "4242 (bash) R 1 4242 4242 34816 4242 4194560 0 0 0 0 0 0 0 0 20 0 1 0 100 0";
    assert_eq!(single_thread_name(running), Some(("bash".to_string(), false)), "on a CPU");
    let four = "4242 (nu) S 1 4242 4242 34816 4242 4194560 0 0 0 0 0 0 0 0 20 0 4 0 100 0";
    assert_eq!(single_thread_name(four), None, "a threaded shell");
    let odd = "4242 (a) b (c) S 1 4242 4242 34816 4242 4194560 0 0 0 0 0 0 0 0 20 0 1 0 100 0";
    assert_eq!(
        single_thread_name(odd),
        Some(("a) b (c".to_string(), true)),
        "the name ends at the last )"
    );
    assert_eq!(single_thread_name("4242 (bash) S 1"), None, "a short line is unknown");
}
