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

/// `man` on macOS is a shell script: its job leader is `sh` running
/// `/usr/bin/man`, with less under it. The job's program is `man` (a pager
/// the phone scrolls with cursor keys), while Claude Code (`node` running its
/// script, its native binary, or a wrapper's `sh -c`) and a bare shell keep
/// their own names, which the phone's allowlist does not hold.
#[test]
fn job_program_names_a_shell_script_and_keeps_everything_else() {
    let argv = |args: &[&str]| args.iter().map(|arg| arg.to_string()).collect::<Vec<_>>();
    // sh(man) -> less: the job is man.
    assert_eq!(
        job_program("/bin/sh", &argv(&["/bin/sh", "/usr/bin/man", "ls"])).as_deref(),
        Some("man")
    );
    // macOS /bin/sh hands off to bash with the same argv.
    assert_eq!(
        job_program("/bin/bash", &argv(&["sh", "/usr/bin/man", "git"])).as_deref(),
        Some("man")
    );
    // A binary pager or editor leads its own job.
    assert_eq!(
        job_program("/usr/bin/less", &argv(&["less", "notes.txt"])).as_deref(),
        Some("less")
    );
    assert_eq!(job_program("/usr/bin/git", &argv(&["git", "log"])).as_deref(), Some("git"));
    // node(claude): node, never the script it runs, and never a pager.
    let claude = job_program("/usr/local/bin/node", &argv(&["node", "/usr/local/bin/claude"]));
    assert_eq!(claude.as_deref(), Some("node"));
    assert_eq!(
        job_program("/Users/me/.local/share/claude/versions/2.1.322", &argv(&["claude"]))
            .as_deref(),
        Some("2.1.322")
    );
    // A wrapper script for an agent names the agent.
    assert_eq!(
        job_program("/bin/sh", &argv(&["/bin/sh", "/opt/bin/claude"])).as_deref(),
        Some("claude")
    );
    // A shell with no script: the shell (sh -c, options, interactive, login).
    assert_eq!(job_program("/bin/sh", &argv(&["sh", "-c", "less x | cat"])).as_deref(), Some("sh"));
    assert_eq!(job_program("/bin/bash", &argv(&["bash", "-l"])).as_deref(), Some("bash"));
    assert_eq!(job_program("/bin/zsh", &argv(&["-zsh"])).as_deref(), Some("zsh"));
    assert_eq!(job_program("/bin/zsh", &[]).as_deref(), Some("zsh"));
    // node and ssh are not shells: their first argument is not the program.
    assert_eq!(job_program("/usr/bin/ssh", &argv(&["ssh", "less"])).as_deref(), Some("ssh"));
    assert_eq!(job_program("", &[]), None);
}
