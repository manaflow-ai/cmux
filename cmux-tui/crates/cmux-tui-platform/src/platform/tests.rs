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
    let mut child = std::process::Command::new("/bin/sleep")
        .arg("30")
        .current_dir(&target)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
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
    use std::os::unix::process::CommandExt as _;
    let mut command = std::process::Command::new("/bin/sleep");
    command
        .arg("30")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    // SAFETY: setsid is async-signal-safe and the closure does not
    // allocate between fork and exec.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = command.spawn().unwrap();
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

#[test]
fn codex_app_server_daemon_is_recognized_only_by_its_daemon_argv() {
    let argv = |args: &[&str]| args.iter().map(|arg| (*arg).to_owned()).collect::<Vec<_>>();
    assert!(is_codex_app_server_daemon(&argv(&[
        "/home/me/.codex/packages/app-server-daemon/releases/0.162.1/bin/codex",
        "app-server",
        "--listen",
        "unix://",
        "--analytics-default-enabled",
        "--managed-daemon",
    ])));
    // An older managed binary without the startup flag.
    assert!(is_codex_app_server_daemon(&argv(&[
        "/home/me/.codex/packages/app-server-daemon/releases/0.161.0/bin/codex",
        "app-server",
        "--listen",
        "unix://",
    ])));
    // The embedded TUI, an editor's own app-server, and a prompt that
    // merely mentions the words.
    assert!(!is_codex_app_server_daemon(&argv(&["codex", "--enable", "hooks", "-c", "x=1"])));
    assert!(!is_codex_app_server_daemon(&argv(&["/opt/codex", "app-server"])));
    assert!(!is_codex_app_server_daemon(&argv(&["app-server", "--managed-daemon"])));
    assert!(!is_codex_app_server_daemon(&argv(&["codex", "explain app-server"])));
}
