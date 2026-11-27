//! macOS terminal hosts run from the slim `cmux-tui-host` beside the daemon
//! (its verified copy), not from a copy of the multi-call `cmux-tui`: an idle
//! host no longer maps the monolith's dylib images. A daemon without that
//! sibling, or with a sibling of another build, still starts hosts from the
//! copy of its own executable (host_exe.rs).

use super::*;

/// The executable `pid` runs.
fn process_path(pid: u32) -> String {
    let mut path = [0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: proc_pidpath writes at most `path.len()` bytes.
    let written =
        unsafe { libc::proc_pidpath(pid as i32, path.as_mut_ptr().cast(), path.len() as u32) };
    String::from_utf8_lossy(&path[..usize::try_from(written).unwrap_or(0)]).into_owned()
}

/// Start `cat` in a new workspace, echo `marker` through it, and return its
/// surface and its host's pid.
fn echo_through_new_terminal(harness: &RecoveryHarness, marker: &str) -> (u64, u32) {
    let created = request(
        &harness.socket,
        serde_json::json!({"id": 1, "cmd": "run", "argv": ["/bin/cat"], "new_workspace": true}),
    );
    let surface = created["surface"].as_u64().unwrap();
    request(
        &harness.socket,
        serde_json::json!({"id": 2, "cmd": "send", "surface": surface, "text": format!("{marker}\n")}),
    );
    assert!(wait_for_screen(&harness.socket, surface, marker).contains(marker));
    (surface, wait_for_host_records(&harness.host_root(), 1)[0].1.host_pid)
}

/// The host runs `file_name` from its copy below the harness's host-exe root.
fn assert_runs_copy(harness: &RecoveryHarness, host_pid: u32, file_name: &str) {
    let path = process_path(host_pid);
    let copies = fs::canonicalize(harness.dir.join("host-exe")).unwrap();
    assert!(
        path.starts_with(&*copies.to_string_lossy()) && path.ends_with(&format!("/{file_name}")),
        "the host runs {path}, not its {file_name} copy below {}",
        copies.display()
    );
}

/// A daemon binary alone in its own folder, with `sibling` (a script) as
/// its `cmux-tui-host` when given.
fn daemon_without_built_sibling(harness: &RecoveryHarness, sibling: Option<&str>) -> PathBuf {
    let folder = harness.dir.join("bundle-bin");
    fs::create_dir_all(&folder).unwrap();
    let daemon = folder.join("cmux-tui");
    fs::copy(bin(), &daemon).unwrap();
    if let Some(script) = sibling {
        let host = folder.join("cmux-tui-host");
        fs::write(&host, script).unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&host, fs::Permissions::from_mode(0o755)).unwrap();
    }
    daemon
}

#[test]
fn a_terminal_host_runs_from_the_slim_host_copy() {
    let harness = RecoveryHarness::start("slim-host-runs");
    let marker = format!("slim-host-{}", std::process::id());
    let (_, host_pid) = echo_through_new_terminal(&harness, &marker);
    assert_runs_copy(&harness, host_pid, "cmux-tui-host");
    // Tooling that finds hosts by their command line still does.
    let output = Command::new("ps").args(["-o", "args=", "-p", &host_pid.to_string()]).output();
    let args = String::from_utf8_lossy(&output.unwrap().stdout).trim().to_owned();
    assert!(args.starts_with("cmux-tui __terminal-host --bootstrap-stdio"), "host args: {args}");
}

#[test]
fn a_restarted_daemon_adopts_a_slim_host() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("slim-host-adopt");
    let marker = format!("slim-before-{}", std::process::id());
    let created = request(
        &harness.socket,
        serde_json::json!({"id": 1, "cmd": "run", "argv": ["/bin/cat"], "new_workspace": true}),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    request(
        &harness.socket,
        serde_json::json!({"id": 2, "cmd": "send", "surface": surface, "text": format!("{marker}\n")}),
    );
    assert!(wait_for_screen(&harness.socket, surface, &marker).contains(&marker));
    let host_pid = wait_for_host_records(&harness.host_root(), 1)[0].1.host_pid;
    assert_runs_copy(&harness, host_pid, "cmux-tui-host");

    harness.sigkill();
    assert!(process_exists(host_pid as libc::pid_t), "the daemon's death ended its slim host");
    harness.restart();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    let adopted = loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id": 3, "cmd": "resolve-terminal", "terminal_id": terminal_id}),
        );
        if resolved["lifecycle"] == "running"
            && resolved["terminal_incarnation"].as_str() == Some(incarnation.as_str())
            && let Some(surface) = resolved["surface"].as_u64()
        {
            break surface;
        }
        assert!(
            Instant::now() < deadline,
            "the new daemon did not adopt the slim host: {resolved}"
        );
        std::thread::sleep(Duration::from_millis(50));
    };
    assert!(wait_for_screen(&harness.socket, adopted, &marker).contains(&marker));
    assert_eq!(wait_for_host_records(&harness.host_root(), 1)[0].1.host_pid, host_pid);
    let after = format!("slim-after-{}", std::process::id());
    request(
        &harness.socket,
        serde_json::json!({"id": 4, "cmd": "send", "surface": adopted, "text": format!("{after}\n")}),
    );
    assert!(wait_for_screen(&harness.socket, adopted, &after).contains(&after));
}

#[test]
fn without_a_slim_sibling_hosts_run_from_the_daemon_copy() {
    let mut harness = RecoveryHarness::start_unstarted("slim-host-missing");
    harness.binary = Some(daemon_without_built_sibling(&harness, None));
    harness.restart();
    let marker = format!("no-slim-{}", std::process::id());
    let (_, host_pid) = echo_through_new_terminal(&harness, &marker);
    assert_runs_copy(&harness, host_pid, "cmux-tui");
}

#[test]
fn a_slim_sibling_of_another_build_is_not_used() {
    let mut harness = RecoveryHarness::start_unstarted("slim-host-other-build");
    let other_build = "#!/bin/sh\necho 'cmux-tui-host 0000000000000000000000000000000000000000'\n";
    harness.binary = Some(daemon_without_built_sibling(&harness, Some(other_build)));
    harness.restart();
    let marker = format!("other-slim-{}", std::process::id());
    let (_, host_pid) = echo_through_new_terminal(&harness, &marker);
    assert_runs_copy(&harness, host_pid, "cmux-tui");
}
