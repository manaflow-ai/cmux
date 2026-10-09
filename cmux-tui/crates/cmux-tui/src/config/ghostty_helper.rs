//! Ghostty config helper process: runs the resolver child, reads its bounded output, and reaps it and its process groups on a deadline.

use super::*;

pub(crate) fn is_ghostty_config_helper_invocation(args: &[String]) -> bool {
    args.first().map(String::as_str) == Some("__ghostty-config-defaults")
}

pub(crate) fn run_ghostty_config_helper() -> i32 {
    match parse_ghostty_application_defaults_from_paths_result(
        platform::ghostty_config_paths(),
        platform::ghostty_theme_dirs(),
    ) {
        GhosttyApplicationDefaultsParseOutcome::Parsed(defaults) => {
            print!("{}", serialize_ghostty_application_defaults(&defaults));
            0
        }
        GhosttyApplicationDefaultsParseOutcome::Partial(_) => 2,
        GhosttyApplicationDefaultsParseOutcome::Missing => 1,
        GhosttyApplicationDefaultsParseOutcome::TimedOut => 2,
    }
}

#[cfg(not(test))]
pub(super) fn ghostty_defaults_from_helper() -> GhosttyHelperDefaults {
    let Ok(exe) = platform::self_exe_for_spawn() else {
        return GhosttyHelperDefaults::Unavailable;
    };
    let mut command = Command::new(exe);
    command
        .arg("__ghostty-config-defaults")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(unix)]
    command.process_group(0);
    scrub_ghostty_helper_secret_environment(&mut command);
    ghostty_defaults_from_helper_command(command, GHOSTTY_CONFIG_HELPER_PARENT_DEADLINE)
}

#[cfg(any(not(test), all(test, unix)))]
pub(super) fn ghostty_defaults_from_helper_command(
    mut command: Command,
    parent_deadline: Duration,
) -> GhosttyHelperDefaults {
    let Ok(mut child) = command.spawn() else {
        return GhosttyHelperDefaults::Unavailable;
    };
    let Some(stdout) = child.stdout.take() else {
        terminate_ghostty_helper_child(child);
        return GhosttyHelperDefaults::Unavailable;
    };
    let Some(output_reader) = read_ghostty_helper_output_async(stdout) else {
        terminate_ghostty_helper_child(child);
        return GhosttyHelperDefaults::Unavailable;
    };
    let status = match child.wait_timeout(parent_deadline) {
        Ok(status) => status,
        Err(_) => {
            terminate_ghostty_helper_child(child);
            return GhosttyHelperDefaults::Unavailable;
        }
    };
    let status = match status {
        Some(status) => status,
        None => {
            terminate_ghostty_helper_child(child);
            return GhosttyHelperDefaults::TimedOut;
        }
    };
    if !status.success() {
        if status.code() == Some(2) {
            return GhosttyHelperDefaults::TimedOut;
        }
        return GhosttyHelperDefaults::Unavailable;
    }
    match output_reader.wait() {
        Some(output) => GhosttyHelperDefaults::Resolved(Box::new(GhosttyApplicationDefaults {
            colors: parse_resolved_ghostty_defaults(&output),
            scrollback_limit_bytes: parse_scrollback_limit_bytes(&output).flatten(),
        })),
        None => GhosttyHelperDefaults::Unavailable,
    }
}

pub(super) fn read_ghostty_helper_output_async(
    stdout: impl Read + Send + 'static,
) -> Option<GhosttyHelperOutputReader> {
    read_ghostty_limited_output_async(
        stdout,
        GHOSTTY_HELPER_OUTPUT_MAX_BYTES,
        "cmux-tui-ghostty-helper-output",
    )
}

pub(super) fn read_ghostty_limited_output_async(
    stdout: impl Read + Send + 'static,
    max_bytes: u64,
    thread_name: &'static str,
) -> Option<GhosttyHelperOutputReader> {
    let (sender, receiver) = mpsc::channel();
    std::thread::Builder::new()
        .name(thread_name.to_string())
        .spawn(move || {
            let _ = sender.send(read_ghostty_limited_string(stdout, max_bytes));
        })
        .ok()?;
    Some(GhosttyHelperOutputReader { receiver })
}

pub(super) struct GhosttyHelperOutputReader {
    receiver: mpsc::Receiver<Option<String>>,
}

impl GhosttyHelperOutputReader {
    pub(super) fn wait(self) -> Option<String> {
        self.receiver.recv().ok().flatten()
    }

    #[cfg(not(target_os = "macos"))]
    pub(super) fn recv_timeout(
        &self,
        timeout: Duration,
    ) -> Result<Option<String>, mpsc::RecvTimeoutError> {
        self.receiver.recv_timeout(timeout)
    }
}

pub(super) fn terminate_ghostty_helper_child(child: Child) {
    let _ = terminate_ghostty_helper_child_with_reaped_signal(child);
}

pub(super) fn terminate_ghostty_helper_child_with_reaped_signal(
    mut child: Child,
) -> mpsc::Receiver<()> {
    #[cfg(unix)]
    let descendant_groups = ghostty_helper_descendant_process_groups(child.id() as libc::pid_t);
    #[cfg(unix)]
    unsafe {
        for group in descendant_groups {
            // SAFETY: group IDs are read from the process table for descendants
            // of the helper being terminated.
            libc::killpg(group, libc::SIGKILL);
        }
        // SAFETY: killpg only sends SIGKILL to the helper-owned process group.
        libc::killpg(child.id() as libc::pid_t, libc::SIGKILL);
    }
    let _ = child.kill();
    reap_ghostty_child_after_short_wait(child, "cmux-tui-ghostty-helper-reaper")
}

#[cfg(unix)]
pub(super) fn ghostty_helper_descendant_process_groups(root_pid: libc::pid_t) -> Vec<libc::pid_t> {
    let Some(text) = ghostty_helper_process_table_snapshot() else {
        return Vec::new();
    };
    ghostty_helper_descendant_process_groups_from_table(root_pid, &text)
}

#[cfg(unix)]
pub(super) fn ghostty_helper_process_table_snapshot() -> Option<String> {
    let mut command = Command::new("/bin/ps");
    command
        .args(["-axo", "pid=,ppid=,pgid="])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0);
    let Ok(mut child) = command.spawn() else {
        return None;
    };
    let Some(stdout) = child.stdout.take() else {
        terminate_ghostty_process_scan_child(child);
        return None;
    };
    let Some(output_reader) = read_ghostty_limited_output_async(
        stdout,
        GHOSTTY_PROCESS_SCAN_OUTPUT_MAX_BYTES,
        "cmux-tui-ghostty-process-scan-output",
    ) else {
        terminate_ghostty_process_scan_child(child);
        return None;
    };
    let status = match child.wait_timeout(GHOSTTY_PROCESS_SCAN_DEADLINE) {
        Ok(Some(status)) => status,
        Ok(None) | Err(_) => {
            terminate_ghostty_process_scan_child(child);
            return None;
        }
    };
    if !status.success() {
        return None;
    }
    output_reader.wait()
}

#[cfg(unix)]
pub(super) fn terminate_ghostty_process_scan_child(child: Child) {
    let _ = terminate_ghostty_process_scan_child_with_reaped_signal(child);
}

#[cfg(unix)]
pub(super) fn terminate_ghostty_process_scan_child_with_reaped_signal(
    mut child: Child,
) -> mpsc::Receiver<()> {
    unsafe {
        // SAFETY: this only targets the bounded process-scan child group.
        libc::killpg(child.id() as libc::pid_t, libc::SIGKILL);
    }
    let _ = child.kill();
    reap_ghostty_child_after_short_wait(child, "cmux-tui-ghostty-process-scan-reaper")
}

pub(super) fn reap_ghostty_child_after_short_wait(
    mut child: Child,
    reaper_name: &'static str,
) -> mpsc::Receiver<()> {
    let (reaped_sender, reaped_receiver) = mpsc::sync_channel(1);
    if matches!(child.wait_timeout(Duration::from_millis(10)), Ok(Some(_))) {
        let _ = reaped_sender.send(());
        return reaped_receiver;
    }
    let _ = std::thread::Builder::new().name(reaper_name.to_string()).spawn(move || {
        let _ = child.wait();
        let _ = reaped_sender.send(());
    });
    reaped_receiver
}

#[cfg(unix)]
pub(super) fn ghostty_helper_descendant_process_groups_from_table(
    root_pid: libc::pid_t,
    text: &str,
) -> Vec<libc::pid_t> {
    let mut children = HashMap::<libc::pid_t, Vec<(libc::pid_t, libc::pid_t)>>::new();
    for line in text.lines() {
        let mut parts = line.split_whitespace();
        let Some(pid) = parts.next().and_then(|value| value.parse::<libc::pid_t>().ok()) else {
            continue;
        };
        let Some(ppid) = parts.next().and_then(|value| value.parse::<libc::pid_t>().ok()) else {
            continue;
        };
        let Some(pgid) = parts.next().and_then(|value| value.parse::<libc::pid_t>().ok()) else {
            continue;
        };
        children.entry(ppid).or_default().push((pid, pgid));
    }

    let mut groups = HashSet::<libc::pid_t>::new();
    let mut stack = vec![root_pid];
    while let Some(parent) = stack.pop() {
        let Some(descendants) = children.get(&parent) else {
            continue;
        };
        for &(pid, pgid) in descendants {
            stack.push(pid);
            if pgid > 0 && pgid != root_pid {
                groups.insert(pgid);
            }
        }
    }
    groups.into_iter().collect()
}

#[cfg(any(not(test), all(test, unix)))]
pub(super) fn scrub_ghostty_helper_secret_environment(command: &mut Command) {
    for name in ["CMUX_MACHINE_PROVIDER_TOKEN", "CMUX_PROVIDER_WORKSPACE_AUTHORITY"] {
        command.env_remove(name);
    }
}
