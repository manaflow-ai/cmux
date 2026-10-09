//! Tests for the Ghostty config helper process: output reading, deadlines and cleanup.

use super::*;

#[cfg(unix)]
#[test]
fn ghostty_config_helper_scrubs_provider_secret_environment() {
    let output = {
        let mut command = Command::new("/usr/bin/env");
        command
            .env("CMUX_MACHINE_PROVIDER_TOKEN", "edge-test-bearer")
            .env("CMUX_PROVIDER_WORKSPACE_AUTHORITY", "provider-workspace-authority-test")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        scrub_ghostty_helper_secret_environment(&mut command);
        command.output().unwrap()
    };
    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(!stdout.contains("CMUX_MACHINE_PROVIDER_TOKEN="), "{stdout}");
    assert!(!stdout.contains("CMUX_PROVIDER_WORKSPACE_AUTHORITY="), "{stdout}");
}

#[cfg(unix)]
fn wait_for_helper_ready_pid(
    stdout: std::process::ChildStdout,
    marker: &'static str,
) -> libc::pid_t {
    let (ready_sender, ready_receiver) = mpsc::sync_channel(1);
    std::thread::Builder::new()
        .name("cmux-tui-ghostty-test-ready-reader".to_string())
        .spawn(move || {
            use std::io::{BufRead, BufReader};

            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                let Some(pid) = line.strip_prefix(marker) else {
                    continue;
                };
                if let Ok(pid) = pid.trim().parse::<libc::pid_t>() {
                    let _ = ready_sender.send(pid);
                    return;
                }
            }
        })
        .unwrap();
    ready_receiver
        .recv_timeout(Duration::from_secs(2))
        .expect("helper did not publish its ready pid")
}

#[cfg(unix)]
fn wait_for_helper_reaped(reaped_receiver: mpsc::Receiver<()>) {
    reaped_receiver
        .recv_timeout(Duration::from_secs(2))
        .expect("helper reaper did not publish completion");
}

#[cfg(any(target_os = "linux", target_vendor = "apple"))]
struct TestProcessExit {
    descriptor: std::os::fd::OwnedFd,
}

#[cfg(any(target_os = "linux", target_vendor = "apple"))]
impl TestProcessExit {
    fn observe(pid: libc::pid_t) -> Option<Self> {
        use std::os::fd::FromRawFd;

        #[cfg(target_os = "linux")]
        // SAFETY: pidfd_open observes the supplied live test child and
        // returns a new descriptor without modifying process state.
        let descriptor = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
        #[cfg(target_vendor = "apple")]
        // SAFETY: kqueue returns a new descriptor without external state.
        let descriptor = unsafe { libc::kqueue() };
        #[cfg(target_os = "linux")]
        if descriptor < 0 {
            let error = io::Error::last_os_error();
            if matches!(error.raw_os_error(), Some(libc::ENOSYS) | Some(libc::EPERM)) {
                return None;
            }
            panic!("observe helper child {pid}: {error}");
        }
        #[cfg(target_vendor = "apple")]
        assert!(descriptor >= 0, "observe helper child {pid}: {}", io::Error::last_os_error());
        // SAFETY: pidfd_open and kqueue return a new owned descriptor.
        let descriptor = unsafe { std::os::fd::OwnedFd::from_raw_fd(descriptor as libc::c_int) };

        #[cfg(target_vendor = "apple")]
        {
            use std::os::fd::AsRawFd;

            let change = libc::kevent {
                ident: pid as libc::uintptr_t,
                filter: libc::EVFILT_PROC,
                flags: libc::EV_ADD | libc::EV_ENABLE | libc::EV_ONESHOT,
                fflags: libc::NOTE_EXIT,
                data: 0,
                udata: std::ptr::null_mut(),
            };
            let registered = unsafe {
                libc::kevent(
                    descriptor.as_raw_fd(),
                    &raw const change,
                    1,
                    std::ptr::null_mut(),
                    0,
                    std::ptr::null(),
                )
            };
            assert!(
                registered >= 0,
                "register helper child {pid} exit: {}",
                io::Error::last_os_error()
            );
        }

        Some(Self { descriptor })
    }

    fn wait(self, timeout: Duration) {
        use std::os::fd::AsRawFd;

        #[cfg(target_os = "linux")]
        let ready = {
            let mut descriptor =
                libc::pollfd { fd: self.descriptor.as_raw_fd(), events: libc::POLLIN, revents: 0 };
            let timeout_ms = i32::try_from(timeout.as_millis()).unwrap_or(i32::MAX);
            unsafe { libc::poll(&raw mut descriptor, 1, timeout_ms) }
        };
        #[cfg(target_vendor = "apple")]
        let ready = {
            // SAFETY: kevent fully initializes the event before it is read.
            let mut event = unsafe { std::mem::zeroed::<libc::kevent>() };
            let timeout = libc::timespec {
                tv_sec: timeout.as_secs().try_into().unwrap_or(libc::time_t::MAX),
                tv_nsec: timeout.subsec_nanos().into(),
            };
            unsafe {
                libc::kevent(
                    self.descriptor.as_raw_fd(),
                    std::ptr::null(),
                    0,
                    &raw mut event,
                    1,
                    &raw const timeout,
                )
            }
        };
        assert!(ready > 0, "helper child did not exit before the final deadline");
    }
}

#[cfg(unix)]
#[test]
fn ghostty_config_helper_cleanup_reaps_killed_child() {
    let child = Command::new("/bin/sleep").arg("5").spawn().unwrap();
    let pid = child.id() as libc::pid_t;

    let reaped_receiver = terminate_ghostty_helper_child_with_reaped_signal(child);
    wait_for_helper_reaped(reaped_receiver);

    assert!(!unix_process_exists(pid), "helper child {pid} was not reaped");
}

#[cfg(unix)]
#[test]
fn ghostty_process_scan_cleanup_reaps_killed_child() {
    let mut command = Command::new("/bin/sleep");
    command.arg("5").process_group(0);
    let child = command.spawn().unwrap();
    let pid = child.id() as libc::pid_t;

    let reaped_receiver = terminate_ghostty_process_scan_child_with_reaped_signal(child);
    wait_for_helper_reaped(reaped_receiver);

    assert!(!unix_process_exists(pid), "process scan child {pid} was not reaped");
}

#[cfg(unix)]
#[test]
fn ghostty_config_helper_parent_deadline_allows_startup_margin() {
    let mut command = Command::new("/bin/sh");
    command
        .args(["-c", "sleep 0.32; printf 'foreground=#010203\nbackground=#040506\n'"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0);

    let defaults =
        ghostty_defaults_from_helper_command(command, GHOSTTY_CONFIG_HELPER_PARENT_DEADLINE);

    let GhosttyHelperDefaults::Resolved(defaults) = defaults else {
        panic!("helper should resolve within parent startup margin");
    };
    assert_eq!(defaults.colors.fg, Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }));
    assert_eq!(defaults.colors.bg, Some(Rgb { r: 0x04, g: 0x05, b: 0x06 }));
}

#[cfg(all(unix, not(target_os = "macos")))]
#[test]
fn ghostty_desktop_probe_cleanup_kills_stdout_inheriting_child() {
    let (started_sender, started_receiver) = mpsc::sync_channel(1);
    let (reaped_sender, reaped_receiver) = mpsc::sync_channel(1);

    let started_at = Instant::now();
    let output = desktop_theme_command_output_with_lifecycle_signals(
        "/bin/sh",
        &["-c", "sleep 5 & printf \"'prefer-dark'\\n\"; exit 0"],
        Some(Instant::now() + Duration::from_secs(1)),
        Some(&started_sender),
        Some(&reaped_sender),
    );
    let child_group = started_receiver
        .recv_timeout(Duration::from_secs(2))
        .expect("desktop probe did not publish its process group")
        as libc::pid_t;
    wait_for_helper_reaped(reaped_receiver);

    assert_eq!(output, None);
    assert!(
        started_at.elapsed() < Duration::from_secs(1),
        "desktop probe output drain was not bounded"
    );

    assert!(
        !unix_process_group_is_live(child_group),
        "stdout-inheriting desktop probe group {child_group} was not killed"
    );
}

#[cfg(any(target_os = "linux", target_vendor = "apple"))]
#[test]
fn ghostty_config_helper_cleanup_reaps_process_group_children() {
    const READY_MARKER: &str = "CMUX_HELPER_READY:";
    let script = format!("sleep 5 & echo {READY_MARKER}$!; wait");
    let mut command = Command::new("/bin/sh");
    command.arg("-c").arg(script).stdout(Stdio::piped()).process_group(0);
    let mut child = command.spawn().unwrap();
    let parent_pid = child.id() as libc::pid_t;
    let child_pid = wait_for_helper_ready_pid(child.stdout.take().unwrap(), READY_MARKER);
    let child_exit = TestProcessExit::observe(child_pid);

    let reaped_receiver = terminate_ghostty_helper_child_with_reaped_signal(child);
    wait_for_helper_reaped(reaped_receiver);
    if let Some(child_exit) = child_exit {
        child_exit.wait(Duration::from_secs(2));
        assert!(!unix_process_is_live(child_pid), "helper child {child_pid} was not killed");
    } else {
        crate::client_log::stderr_log!(
            "config",
            "skipped helper child {child_pid} exit postcondition: pidfd_open is unsupported"
        );
    }

    assert!(!unix_process_exists(parent_pid), "helper parent {parent_pid} was not reaped");
}

#[cfg(any(target_os = "linux", target_vendor = "apple"))]
#[test]
fn ghostty_config_helper_cleanup_kills_descendant_process_groups() {
    const CHILD_MARKER: &str = "CMUX_TEST_GHOSTTY_HELPER_DESCENDANT_GROUP";
    const READY_MARKER: &str = "CMUX_DESCENDANT_READY:";
    if std::env::var_os(CHILD_MARKER).is_some() {
        let mut command = Command::new("/bin/sleep");
        command.arg("5").process_group(0);
        let mut child = command.spawn().unwrap();
        println!("{READY_MARKER}{}", child.id());
        io::stdout().flush().unwrap();
        let _ = child.wait();
        return;
    }

    let mut command = Command::new(std::env::current_exe().unwrap());
    command
        .args([
            "--exact",
            "config::tests::ghostty_config_helper_cleanup_kills_descendant_process_groups",
            "--nocapture",
        ])
        .env(CHILD_MARKER, "1")
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0);
    let mut child = command.spawn().unwrap();
    let parent_pid = child.id() as libc::pid_t;
    let child_pid = wait_for_helper_ready_pid(child.stdout.take().unwrap(), READY_MARKER);
    let child_exit = TestProcessExit::observe(child_pid);

    let reaped_receiver = terminate_ghostty_helper_child_with_reaped_signal(child);
    wait_for_helper_reaped(reaped_receiver);
    if let Some(child_exit) = child_exit {
        child_exit.wait(Duration::from_secs(2));
        assert!(
            !unix_process_is_live(child_pid),
            "descendant process-group child {child_pid} was not killed"
        );
    } else {
        crate::client_log::stderr_log!(
            "config",
            "skipped descendant process-group child {child_pid} exit postcondition: \
             pidfd_open is unsupported"
        );
    }

    assert!(!unix_process_exists(parent_pid), "helper parent {parent_pid} was not reaped");
}

#[cfg(unix)]
fn unix_process_is_live(pid: libc::pid_t) -> bool {
    if !unix_process_exists(pid) {
        return false;
    }
    let Ok(output) = Command::new("/bin/ps").args(["-o", "stat=", "-p", &pid.to_string()]).output()
    else {
        return true;
    };
    if !output.status.success() {
        return unix_process_exists(pid);
    }
    let stat = String::from_utf8_lossy(&output.stdout);
    !stat.trim_start().starts_with('Z')
}

#[cfg(unix)]
fn unix_process_exists(pid: libc::pid_t) -> bool {
    if unsafe { libc::kill(pid, 0) } == 0 {
        return true;
    }
    io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
}

#[cfg(all(unix, not(target_os = "macos")))]
fn unix_process_group_is_live(group: libc::pid_t) -> bool {
    let Ok(output) = Command::new("/bin/ps").args(["-axo", "pgid=,stat="]).output() else {
        return unsafe { libc::killpg(group, 0) } == 0;
    };
    if !output.status.success() {
        return unsafe { libc::killpg(group, 0) } == 0;
    }
    String::from_utf8_lossy(&output.stdout).lines().any(|line| {
        let mut parts = line.split_whitespace();
        parts.next().and_then(|value| value.parse::<libc::pid_t>().ok()) == Some(group)
            && parts.next().is_some_and(|status| !status.starts_with('Z'))
    })
}

#[test]
fn ghostty_config_helper_output_reader_drains_large_palette() {
    let mut output = String::new();
    for index in 0..256 {
        output.push_str(&format!("palette.{index}=#010203\n"));
    }
    assert!(output.len() > 4 * 1024);

    let reader = read_ghostty_helper_output_async(io::Cursor::new(output.clone())).unwrap();

    assert_eq!(reader.wait(), Some(output));
}

#[test]
fn ghostty_config_helper_output_reader_enforces_byte_limit() {
    let output = "x".repeat(GHOSTTY_HELPER_OUTPUT_MAX_BYTES as usize + 1);

    let reader = read_ghostty_helper_output_async(io::Cursor::new(output)).unwrap();

    assert_eq!(reader.wait(), None);
}

#[test]
fn ghostty_defaults_falls_back_to_files_when_helper_is_unavailable() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-helper-fallback-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let config = dir.join("config");
    std::fs::write(&config, "foreground = #010203\nbackground = #040506\n").unwrap();

    let defaults =
        ghostty_defaults_from_sources(vec![config], Vec::new(), GhosttyHelperDefaults::Unavailable);

    let _ = std::fs::remove_dir_all(dir);

    assert_eq!(defaults.fg, Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }));
    assert_eq!(defaults.bg, Some(Rgb { r: 0x04, g: 0x05, b: 0x06 }));
    assert_eq!(defaults.cursor_style, Some(CursorShape::Block));
}

#[test]
fn ghostty_defaults_use_helper_result_before_file_fallback() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-helper-result-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let config = dir.join("config");
    std::fs::write(&config, "foreground = #010203\nbackground = #040506\n").unwrap();
    // The helper child serializes application defaults that are already
    // resolved, so the parent passes them through without resolving again.
    let helper = resolve_ghostty_application_defaults(DefaultColors {
        fg: Some(Rgb { r: 0xa0, g: 0xa1, b: 0xa2 }),
        bg: Some(Rgb { r: 0xb0, g: 0xb1, b: 0xb2 }),
        ..Default::default()
    });

    let defaults = ghostty_defaults_from_sources(
        vec![config],
        Vec::new(),
        GhosttyHelperDefaults::Resolved(Box::new(GhosttyApplicationDefaults {
            colors: helper,
            scrollback_limit_bytes: None,
        })),
    );

    let _ = std::fs::remove_dir_all(dir);

    assert_eq!(defaults.fg, Some(Rgb { r: 0xa0, g: 0xa1, b: 0xa2 }));
    assert_eq!(defaults.bg, Some(Rgb { r: 0xb0, g: 0xb1, b: 0xb2 }));
    assert_eq!(defaults.cursor_style, Some(CursorShape::Block));
}

#[test]
fn ghostty_defaults_do_not_retry_files_after_helper_timeout() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-helper-timeout-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let config = dir.join("config");
    std::fs::write(&config, "foreground = #010203\nbackground = #040506\n").unwrap();

    let defaults =
        ghostty_defaults_from_sources(vec![config], Vec::new(), GhosttyHelperDefaults::TimedOut);

    let _ = std::fs::remove_dir_all(dir);

    assert_eq!(defaults.fg, None);
    assert_eq!(defaults.bg, None);
    assert_eq!(defaults.cursor_style, Some(CursorShape::Block));
}
