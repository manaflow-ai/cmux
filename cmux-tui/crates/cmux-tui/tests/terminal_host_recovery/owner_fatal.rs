//! Crash-only daemons (plans/cmux-next/rust-panic-free.md, sections 5 and 6).
//!
//! A fatal path that no panic hook or supervisor sees (abort, stack
//! overflow, out of memory) ends the owner at once: it never leaves a live
//! process that answers nothing (manaflow-ai/cmux#22844). The restart path
//! (the app's reconnect runs `server ensure`, which starts this same
//! headless owner) brings back the same workspaces, tabs and terminal
//! output, because the terminals live in their own host processes. A crash
//! of one terminal host affects only that terminal.

use std::os::unix::process::ExitStatusExt;

use super::host_replacement::wait_for_daemon_custody;
use super::*;

fn make_fifo(path: &Path) {
    let c_path = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: `c_path` is a NUL-terminated string that outlives the call.
    assert_eq!(unsafe { libc::mkfifo(c_path.as_ptr(), 0o600) }, 0, "mkfifo {path:?}");
}

/// Start `/bin/cat` in a new workspace and show `marker` on its screen.
fn cat_with_marker(harness: &RecoveryHarness, name: &str, marker: &str) -> (String, u64) {
    let created = request(
        &harness.socket,
        serde_json::json!({
            "cmd": "run", "argv": ["/bin/cat"], "new_workspace": true, "name": name,
            "cols": 80, "rows": 24,
        }),
    );
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let surface = created["surface"].as_u64().unwrap();
    request(
        &harness.socket,
        serde_json::json!({"cmd": "send", "surface": surface, "text": format!("{marker}\n")}),
    );
    assert!(wait_for_screen(&harness.socket, surface, marker).contains(marker));
    (terminal_id, surface)
}

fn surface_of(harness: &RecoveryHarness, terminal_id: &str) -> u64 {
    let resolved = request(
        &harness.socket,
        serde_json::json!({"cmd": "resolve-terminal", "terminal_id": terminal_id}),
    );
    resolved["surface"].as_u64().unwrap_or_else(|| panic!("no surface: {resolved}"))
}

fn host_pid(harness: &RecoveryHarness, terminal_id: &str) -> Option<u32> {
    load_terminal_host_records(&harness.host_root())
        .unwrap_or_default()
        .into_iter()
        .find(|(_, record)| record.terminal_id == terminal_id)
        .map(|(_, record)| record.host_pid)
}

fn owner_fatal_path_ends_fast_and_the_restart_restores(kind: &str) {
    let mut harness = RecoveryHarness::start_unstarted(&format!("owner-fatal-{kind}"));
    let trigger = harness.dir.join("owner-fatal.trigger");
    make_fifo(&trigger);
    let mut command = harness.daemon_command();
    // Debug builds only: the owner takes this fatal path when the FIFO opens.
    command
        .env("CMUX_TUI_TEST_OWNER_PANIC", kind)
        .env("CMUX_TUI_TEST_OWNER_FATAL_TRIGGER", &trigger);
    harness.child = Some(command.spawn().unwrap());
    wait_for_socket(&harness.socket);
    let workspace = format!("fatal-{kind}");
    let marker = format!("before-{kind}-{}", std::process::id());
    let (terminal_id, _) = cat_with_marker(&harness, &workspace, &marker);

    // Read-write never blocks on a FIFO; the open releases the owner's seam.
    let release = fs::OpenOptions::new().read(true).write(true).open(&trigger).unwrap();
    let mut owner = harness.child.take().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let status = loop {
        if let Some(status) = owner.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = owner.kill();
            let _ = owner.wait();
            panic!("the owner did not end within 10 s of its {kind} path (a crash became a hang)");
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    drop(release);
    assert_eq!(status.signal(), Some(libc::SIGABRT), "{kind} ended the owner with {status:?}");
    let _ = fs::remove_file(&harness.socket);

    // The restart path: the same headless owner on the same state.
    harness.restart();
    wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "running");
    let tree = request(&harness.socket, serde_json::json!({"cmd": "list-workspaces"}));
    let restored = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["name"] == workspace.as_str())
        .unwrap_or_else(|| panic!("the workspace did not come back: {tree}"));
    let tab = first_tab(restored).unwrap_or_else(|| panic!("the tab did not come back: {tree}"));
    assert_eq!(tab["terminal_id"].as_str(), Some(terminal_id.as_str()), "{tab}");
    let surface = surface_of(&harness, &terminal_id);
    let screen = wait_for_screen(&harness.socket, surface, &marker);
    assert!(screen.contains(&marker), "the output did not come back: {screen:?}");
    let after = format!("after-{kind}-{}", std::process::id());
    request(
        &harness.socket,
        serde_json::json!({"cmd": "send", "surface": surface, "text": format!("{after}\n")}),
    );
    assert!(wait_for_screen(&harness.socket, surface, &after).contains(&after));
}

#[test]
fn owner_abort_ends_the_owner_and_the_restart_restores_its_terminals() {
    owner_fatal_path_ends_fast_and_the_restart_restores("abort");
}

#[test]
fn owner_stack_overflow_ends_the_owner_and_the_restart_restores_its_terminals() {
    owner_fatal_path_ends_fast_and_the_restart_restores("stack_overflow");
}

#[test]
fn owner_out_of_memory_ends_the_owner_and_the_restart_restores_its_terminals() {
    owner_fatal_path_ends_fast_and_the_restart_restores("oom");
}

#[test]
fn a_terminal_host_panic_affects_only_its_own_terminal() {
    let mut harness = RecoveryHarness::start_unstarted("host-panic-one");
    let once = harness.dir.join("host-abort-once");
    let trigger = harness.dir.join("host-abort-once.trigger");
    make_fifo(&trigger);
    let mut command = harness.daemon_command();
    // Debug builds only: the first host panics and aborts when the FIFO opens.
    command.env("CMUX_TUI_TEST_HOST_ABORT_ONCE", &once);
    harness.child = Some(command.spawn().unwrap());
    wait_for_socket(&harness.socket);
    let owner_pid = harness.child.as_ref().unwrap().id();
    let pid = std::process::id();
    let crashing = format!("crashing-{pid}");
    let (crashing_id, _) = cat_with_marker(&harness, "crashing", &crashing);
    // Only a host whose PTY master the owner holds can be replaced.
    wait_for_daemon_custody(&harness, true);
    let neighbor = format!("neighbor-{pid}");
    let (neighbor_id, neighbor_surface) = cat_with_marker(&harness, "neighbor", &neighbor);
    let crashed_host = host_pid(&harness, &crashing_id).expect("the crashing host's record");
    let neighbor_host = host_pid(&harness, &neighbor_id).expect("the neighbor host's record");

    let release = fs::OpenOptions::new().read(true).write(true).open(&trigger).unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(20));
    while host_pid(&harness, &crashing_id).is_none_or(|host| host == crashed_host) {
        assert!(Instant::now() < deadline, "the crashed host was not replaced");
        std::thread::sleep(Duration::from_millis(25));
    }
    drop(release);
    assert!(once.exists(), "the crash seam did not run");
    wait_for_terminal_lifecycle(&harness.socket, &crashing_id, "running");

    // The owner and the other terminal never noticed.
    assert!(harness.child.as_mut().unwrap().try_wait().unwrap().is_none(), "the owner ended");
    assert_eq!(harness.child.as_ref().unwrap().id(), owner_pid);
    assert_eq!(
        host_pid(&harness, &neighbor_id),
        Some(neighbor_host),
        "the neighbor's host changed"
    );
    let still = format!("neighbor-after-{pid}");
    request(
        &harness.socket,
        serde_json::json!({"cmd": "send", "surface": neighbor_surface, "text": format!("{still}\n")}),
    );
    let screen = wait_for_screen(&harness.socket, neighbor_surface, &still);
    assert!(screen.contains(&neighbor) && screen.contains(&still), "{screen:?}");

    // The crashed terminal keeps its tab, its screen and its process.
    let surface = surface_of(&harness, &crashing_id);
    let screen = wait_for_screen(&harness.socket, surface, &crashing);
    assert!(screen.contains(&crashing), "the crashed terminal lost its output: {screen:?}");
    let after = format!("crashing-after-{pid}");
    request(
        &harness.socket,
        serde_json::json!({"cmd": "send", "surface": surface, "text": format!("{after}\n")}),
    );
    assert!(wait_for_screen(&harness.socket, surface, &after).contains(&after));
}
