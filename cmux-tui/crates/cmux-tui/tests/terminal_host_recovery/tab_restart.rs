//! cx-7e7b: the manual restart of a dead terminal tab (`restart-tab`,
//! `tab-restart-v1`, plans/cmux-next/ownership.md section 3.2). It reuses
//! the L2 respawn worker: the same terminal id gets a new shell and a new
//! incarnation, also after the respawn supervisor gave up
//! (`restart_exhausted`), and after a process end the tab kept (`on_exit` keep), also
//! from the CLI (`cmux tab <id> restart`). A tab whose terminal still runs
//! is a typed reject.

use super::*;
use crate::parallel_new_tabs::HostGate;

fn restart_tab(harness: &RecoveryHarness, tab: serde_json::Value) -> serde_json::Value {
    request_response(&harness.socket, serde_json::json!({"id":1,"cmd":"restart-tab","surface":tab}))
}

/// a. The supervisor used every attempt (two here) and the tab reads dead
/// with `restart_exhausted`; Restart brings the same terminal back with a
/// new shell, and the supervisor starts over: the next loss respawns again.
#[test]
fn a_manual_restart_brings_back_a_terminal_the_supervisor_gave_up_on() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start_unstarted("restart-after-exhausted");
    let mut command = harness.daemon_command();
    command.env("CMUX_TUI_TEST_RESPAWN_BACKOFF_MS", "0,0");
    harness.child = Some(command.spawn().expect("spawn the daemon"));
    wait_for_socket(&harness.socket);
    let (terminal_id, mut incarnation, _) = start_default_shell(&harness, "bound");
    for _ in 0..2 {
        kill_current_shell_and_host(&harness, &terminal_id);
        incarnation = wait_for_respawn(&harness, &terminal_id, &incarnation);
        let surface = tab_named(&harness, "bound")["surface"].as_u64().expect("surface");
        wait_for_screen(&harness.socket, surface, MARKER);
    }
    let live = tab_named(&harness, "bound");
    let surface = live["surface"].as_u64().expect("surface");
    let old_pid = echo_value(&harness, surface, "first", "$$");
    kill_current_shell_and_host(&harness, &terminal_id);
    wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "exited");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let dead = loop {
        let tab = tab_named(&harness, "bound");
        if tab["end"]["reason"] == "restart_exhausted" {
            break tab;
        }
        assert!(Instant::now() < deadline, "the supervisor never gave up: {tab}");
        std::thread::sleep(Duration::from_millis(25));
    };
    assert_eq!(dead["dead"], true, "{dead}");

    let restarted = restart_tab(&harness, dead["tab_resource_id"].clone());
    assert_eq!(restarted["ok"], true, "{restarted}");
    assert_eq!(restarted["data"]["terminal"], live["terminal_resource_id"], "{restarted}");
    let manual = wait_for_respawn(&harness, &terminal_id, &incarnation);

    let tab = tab_named(&harness, "bound");
    assert_eq!(tab["dead"], false, "{tab}");
    assert_eq!(tab["terminal_id"], terminal_id.as_str(), "the restart made a new terminal");
    assert_eq!(tab["tab_resource_id"], dead["tab_resource_id"], "the restart made a new tab");
    let surface = tab["surface"].as_u64().expect("the restarted tab has a surface");
    wait_for_screen(&harness.socket, surface, MARKER);
    assert_ne!(echo_value(&harness, surface, "second", "$$"), old_pid, "the same shell answered");
    let lines = wait_for_respawn_lines(&harness, &terminal_id, 3);
    assert_eq!(lines.len(), 3, "{lines:?}");
    assert_eq!(lines[2]["cause"], "user_restart");
    assert_eq!(lines[2]["new_incarnation"], manual.as_str());

    // The restart reset the supervisor: the next loss respawns at once.
    kill_current_shell_and_host(&harness, &terminal_id);
    wait_for_respawn(&harness, &terminal_id, &manual);
    assert_eq!(tab_named(&harness, "bound")["dead"], false);
}

/// b. A process end under `on_exit` keep leaves the tab dead with its
/// final screen; Restart starts a shell under the same terminal id.
#[test]
fn a_manual_restart_brings_back_a_kept_process_exit() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("restart-kept-exit");
    let workspace = &create_empty_workspace(&harness.socket, "restart-kept", "Restart kept");
    let run = resource_request(
        &harness.socket,
        "restart-kept-run",
        "workspace.run",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "workspace":workspace,
            "argv":["/bin/sh","-c","printf 'kept-exit-marker\\n'; exit 9"],
            "on_exit":"keep",
        }),
        Some("restart-kept-run"),
    );
    let public_terminal = run["value"]["terminal_id"].as_str().expect("terminal").to_string();
    let tab = run["value"]["tab_id"].as_str().expect("tab").to_string();
    let terminal_id = tab_named(&harness, "Restart kept")["terminal_id"]
        .as_str()
        .expect("the run tab names its terminal")
        .to_string();
    let exited = wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "exited");
    let incarnation = exited["terminal_incarnation"].as_str().unwrap_or_default().to_string();
    let dead = tab_named(&harness, "Restart kept");
    assert_eq!(dead["dead"], true, "{dead}");

    // Through the CLI: `cmux tab <tab_…> restart` sends the same command.
    let restarted = Command::new(bin())
        .args(["--json", "--session", &harness.session, "tab", &tab, "restart", "--socket"])
        .arg(&harness.socket)
        .output()
        .expect("run the CLI");
    let stdout = String::from_utf8_lossy(&restarted.stdout);
    assert!(
        restarted.status.success(),
        "tab restart failed: {stdout} {}",
        String::from_utf8_lossy(&restarted.stderr)
    );
    assert!(stdout.contains(&public_terminal), "the CLI did not name the terminal: {stdout}");
    wait_for_respawn(&harness, &terminal_id, &incarnation);
    let tab = tab_named(&harness, "Restart kept");
    assert_eq!(tab["dead"], false, "{tab}");
    assert_eq!(tab["terminal_resource_id"], public_terminal.as_str(), "{tab}");
    let surface = tab["surface"].as_u64().expect("the restarted tab has a surface");
    let text = wait_for_screen(&harness.socket, surface, "kept-exit-marker");
    assert!(text.contains("kept-exit-marker"), "the final screen is gone: {text}");
    echo_value(&harness, surface, "alive", "$$");
}

/// c. A tab whose terminal runs is a typed reject and keeps its shell.
#[test]
fn a_restart_of_a_running_tab_is_a_typed_reject() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("restart-live");
    let (terminal_id, incarnation, surface) = start_default_shell(&harness, "live");
    let refused = restart_tab(&harness, serde_json::json!(surface));
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["error_code"], "tab-not-dead", "{refused}");
    let resolved = request(
        &harness.socket,
        serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
    );
    assert_eq!(resolved["terminal_incarnation"], incarnation.as_str(), "{resolved}");
    assert!(respawn_lines(&harness, &terminal_id).is_empty());
}

/// d. cx-6xk9: Restart of a kept process end whose old host is still alive
/// (its record, endpoint and live marker in place). The old host waits at
/// an exit gate (a FIFO the test holds closed) after its process ended, so
/// it stays alive across the restart for as long as the test wants. The
/// restart must wait for that host to exit: while the gate is closed the
/// terminal stays launching and its tab never reads a failed restart
/// ("terminal host identity already exists"); once the gate opens, the same
/// terminal runs under a new incarnation and a new host.
#[test]
fn a_manual_restart_waits_for_the_old_host_of_a_kept_process_exit() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start_unstarted("restart-held-host");
    let gate_path = harness.dir.join("host-exit-gate");
    let mut command = harness.daemon_command();
    command.env("CMUX_TUI_TEST_HOST_EXIT_GATE", &gate_path);
    harness.child = Some(command.spawn().expect("spawn the daemon"));
    wait_for_socket(&harness.socket);
    // Every host that ends from here on waits at the gate.
    let gate = HostGate::create(gate_path);
    let workspace = &create_empty_workspace(&harness.socket, "restart-held", "Restart held");
    let run = resource_request(
        &harness.socket,
        "restart-held-run",
        "workspace.run",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "workspace":workspace,
            "argv":["/bin/sh","-c","printf 'held-exit-marker\\n'; exit 9"],
            "on_exit":"keep",
        }),
        Some("restart-held-run"),
    );
    let public_terminal = run["value"]["terminal_id"].as_str().expect("terminal").to_string();
    let terminal_id = tab_named(&harness, "Restart held")["terminal_id"]
        .as_str()
        .expect("the run tab names its terminal")
        .to_string();
    let exited = wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "exited");
    let incarnation = exited["terminal_incarnation"].as_str().unwrap_or_default().to_string();
    let dead = tab_named(&harness, "Restart held");
    assert_eq!(dead["dead"], true, "{dead}");
    // The process ended, and its host is still alive at the gate.
    let (record_path, old_record) = load_terminal_host_records(&harness.host_root())
        .unwrap_or_default()
        .into_iter()
        .find(|(_, record)| record.terminal_id == terminal_id)
        .expect("the ended terminal's host left its record before the gate");
    assert_eq!(
        terminal_host_record_liveness(&record_path, &old_record).unwrap(),
        TerminalHostLiveness::Live,
        "the gated host does not hold its live marker"
    );

    let restarted = restart_tab(&harness, dead["tab_resource_id"].clone());
    assert_eq!(restarted["ok"], true, "{restarted}");
    // While the old host lives, the restart waits: the terminal stays
    // launching, the old host keeps its record and live marker.
    let resolve = || {
        request(
            &harness.socket,
            serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
        )
    };
    // Before the worker begins the terminal still reads exited; a failed
    // launch would read exited again with a `restart_failed` end.
    let mut began = false;
    let held_until = Instant::now() + Duration::from_millis(1500);
    while Instant::now() < held_until || !began {
        let resolved = resolve();
        let tab = tab_named(&harness, "Restart held");
        assert_ne!(
            tab["end"]["reason"], "restart_failed",
            "the restart did not wait for the live old host: {resolved} {tab}"
        );
        match resolved["lifecycle"].as_str() {
            Some("launching") => began = true,
            Some("exited") if !began => {}
            _ => panic!("the restart did not wait for the live old host: {resolved} {tab}"),
        }
        assert_eq!(
            terminal_host_record_liveness(&record_path, &old_record).unwrap(),
            TerminalHostLiveness::Live,
            "the old host left the gate early"
        );
        assert!(
            Instant::now() < held_until + test_timeout(Duration::from_secs(10)),
            "the restart never began: {resolved} {tab}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    // Open the gate: the old host exits, and the restart goes on.
    let open = gate.open();
    let new_incarnation = wait_for_respawn(&harness, &terminal_id, &incarnation);
    drop(open);
    drop(gate);
    let tab = tab_named(&harness, "Restart held");
    assert_eq!(tab["dead"], false, "{tab}");
    assert_eq!(tab["terminal_resource_id"], public_terminal.as_str(), "{tab}");
    let (_, new_record) = load_terminal_host_records(&harness.host_root())
        .unwrap_or_default()
        .into_iter()
        .find(|(_, record)| record.terminal_id == terminal_id)
        .expect("the restarted terminal has no host record");
    assert_eq!(new_record.incarnation, new_incarnation);
    assert_ne!(new_record.host_pid, old_record.host_pid, "the old host serves the restart");
    let lines = wait_for_respawn_lines(&harness, &terminal_id, 1);
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert_eq!(lines[0]["cause"], "user_restart");
    let surface = tab["surface"].as_u64().expect("the restarted tab has a surface");
    let text = wait_for_screen(&harness.socket, surface, "held-exit-marker");
    assert!(text.contains("held-exit-marker"), "the final screen is gone: {text}");
    echo_value(&harness, surface, "alive", "$$");
}

/// e. A tab kept by `shutdown-daemon` `end_terminals` + `keep_layout`
/// (`tab-restart-kept-layout-v1`). Restart starts the new shell in the
/// directory the keep recorded, in the same tab, and ends the keep: the
/// tab is an ordinary terminal tab again, so its shell's `exit` closes it
/// (a kept tab would stay, dead, for the next frontend to restart again).
#[test]
fn a_manual_restart_of_a_kept_layout_tab_starts_in_its_directory_and_ends_the_keep() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("restart-kept-layout");
    let (terminal_id, _, surface) = start_default_shell(&harness, "kept-layout");
    let kept_dir = harness.dir.join("keptdir");
    fs::create_dir_all(&kept_dir).unwrap();
    // The physical path: the session host records the shell's real directory.
    let kept_dir = kept_dir.canonicalize().unwrap().to_string_lossy().into_owned();
    send_line(&harness.socket, surface, &format!("cd '{kept_dir}'"));
    // The base name: a full path can wrap on the screen.
    let base = r#"$(basename "$PWD")"#;
    assert_eq!(echo_value(&harness, surface, "before", base), "keptdir");

    let identify = request(&harness.socket, serde_json::json!({"id": 2, "cmd": "identify"}));
    let capabilities = identify["capabilities"].as_array().unwrap();
    assert!(
        capabilities.iter().any(|capability| capability == "tab-restart-kept-layout-v1"),
        "{identify}"
    );
    let accepted = request(
        &harness.socket,
        serde_json::json!({
            "id": 3,
            "cmd": "shutdown-daemon",
            "pid": identify["pid"],
            "generation": identify["generation"],
            "end_terminals": true,
            "keep_layout": true,
        }),
    );
    assert_eq!(accepted["accepted"], true, "{accepted}");
    let mut daemon = harness.child.take().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while daemon.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "daemon did not exit after shutdown");
        std::thread::sleep(Duration::from_millis(10));
    }
    wait_for_no_host_records(&harness.host_root());

    harness.restart();
    let dead = tab_named(&harness, "kept-layout");
    assert_eq!(dead["dead"], true, "{dead}");
    assert_eq!(dead["relaunch"]["cwd"], kept_dir.as_str(), "the keep recorded another directory");
    let resolved = request(
        &harness.socket,
        serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
    );
    let incarnation = resolved["terminal_incarnation"].as_str().unwrap_or_default().to_string();
    let restarted = restart_tab(&harness, dead["tab_resource_id"].clone());
    assert_eq!(restarted["ok"], true, "{restarted}");
    wait_for_respawn(&harness, &terminal_id, &incarnation);

    let tab = tab_named(&harness, "kept-layout");
    assert_eq!(tab["dead"], false, "{tab}");
    assert_eq!(tab["tab_resource_id"], dead["tab_resource_id"], "the restart made a new tab");
    assert!(tab["relaunch"].is_null(), "{tab}");
    let surface = tab["surface"].as_u64().expect("the restarted tab has a surface");
    wait_for_screen(&harness.socket, surface, MARKER);
    assert_eq!(echo_value(&harness, surface, "after", base), "keptdir", "not the kept directory");

    // The keep ended: the shell's exit closes the tab.
    send_line(&harness.socket, surface, "exit");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let tree = request(&harness.socket, serde_json::json!({"cmd":"list-workspaces"}));
        let present = tree["workspaces"]
            .as_array()
            .into_iter()
            .flatten()
            .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
            .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
            .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
            .any(|tab| tab["tab_resource_id"] == dead["tab_resource_id"]);
        if !present {
            break;
        }
        assert!(Instant::now() < deadline, "exit left the restarted kept tab: {tree}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// e2. A kept tab no frontend started (its workspace is hidden: frontends
/// start a kept tab only when a window shows it, #17587) starts when a
/// request needs its shell: text sent to it through the control socket
/// (`send {surface}`, the path of the CLI's `send`) starts it in place, in
/// the same tab, and reaches its new shell; the socket never finds a dead
/// tab the app draws as live. The send never waits for the start: the
/// restarted daemon's respawn worker is held at a gate (a FIFO the test keeps
/// closed) after it put the new shell in the tab and before that shell's
/// launch stream starts, and the send's reply arrives while it is held, with
/// the text queued. Once the gate opens, the queued text reaches the new
/// shell, and by then the tab is an ordinary terminal tab again.
#[test]
fn text_sent_to_an_unstarted_kept_tab_starts_it_and_reaches_its_new_shell() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("send-to-kept-layout");
    start_default_shell(&harness, "kept-hidden");
    let identify = request(&harness.socket, serde_json::json!({"id": 2, "cmd": "identify"}));
    let accepted = request(
        &harness.socket,
        serde_json::json!({
            "id": 3,
            "cmd": "shutdown-daemon",
            "pid": identify["pid"],
            "generation": identify["generation"],
            "end_terminals": true,
            "keep_layout": true,
        }),
    );
    assert_eq!(accepted["accepted"], true, "{accepted}");
    let mut daemon = harness.child.take().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while daemon.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "daemon did not exit after shutdown");
        std::thread::sleep(Duration::from_millis(10));
    }
    wait_for_no_host_records(&harness.host_root());

    let gate_path = harness.dir.join("respawn-start-gate");
    let mut command = harness.daemon_command();
    command.env("CMUX_TUI_TEST_RESPAWN_START_GATE", &gate_path);
    harness.child = Some(command.spawn().expect("spawn the daemon"));
    wait_for_socket(&harness.socket);
    // Every respawn worker from here on waits at the gate.
    let gate = HostGate::create(gate_path);
    let dead = tab_named(&harness, "kept-hidden");
    assert_eq!(dead["dead"], true, "{dead}");
    assert!(dead["relaunch"]["cwd"].is_string(), "{dead}");
    let surface = dead["surface"].as_u64().expect("the kept tab has a surface id");
    // No `restart-tab`: the send alone starts the tab.
    let (replied, reply) = std::sync::mpsc::channel();
    let socket = harness.socket.clone();
    std::thread::spawn(move || {
        let _ = replied.send(request_response(
            &socket,
            serde_json::json!({"id": 4, "cmd": "send", "surface": surface, "text": "echo kept-$((40+2))\n"}),
        ));
    });
    let sent = reply
        .recv_timeout(test_timeout(Duration::from_secs(10)))
        .expect("the send waited for the kept tab's start: no reply while its worker is held");
    assert_eq!(sent["ok"], true, "the send to the unstarted kept tab failed: {sent}");
    assert_eq!(sent["data"]["queued"], true, "the text was not queued for the start: {sent}");

    let _open = gate.open();
    let text = wait_for_screen(&harness.socket, surface, "kept-42");
    assert!(text.contains("kept-42"), "the text never reached the new shell: {text}");
    // The worker writes the queued text only after its start ended.
    let live = tab_named(&harness, "kept-hidden");
    assert_eq!(live["dead"], false, "the send left the kept tab dead: {live}");
    assert_eq!(live["tab_resource_id"], dead["tab_resource_id"], "the start made a new tab");
    assert!(live["relaunch"].is_null(), "the started tab is still kept: {live}");
}

/// f. `run --on-exit shell`: the command's end drops the tab into a shell.
/// The same tab and terminal id get a new shell (a new incarnation) below
/// the command's final screen, from the CLI as from the resource request,
/// and that shell's own exit closes the tab as any shell's does.
#[test]
fn on_exit_shell_drops_the_tab_into_a_shell_after_the_command() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("on-exit-shell");
    let workspace = &create_empty_workspace(&harness.socket, "on-exit-shell", "On exit shell");
    let run = Command::new(bin())
        .args(["--json", "--session", &harness.session, "workspace", workspace, "run"])
        .args(["--on-exit", "shell", "--socket"])
        .arg(&harness.socket)
        // The command lives a moment, so the test sees its own incarnation
        // before the respawn into the shell replaces it (a create now answers
        // after its terminal's output is released, new-terminal-100x).
        .args(["--", "/bin/sh", "-c", "printf 'shell-exit-marker\\n'; sleep 0.5; exit 9"])
        .output()
        .expect("run the CLI");
    let stdout = String::from_utf8_lossy(&run.stdout);
    assert!(
        run.status.success(),
        "run --on-exit shell failed: {stdout} {}",
        String::from_utf8_lossy(&run.stderr)
    );
    let first = tab_named(&harness, "On exit shell");
    let terminal_id =
        first["terminal_id"].as_str().expect("the run tab names its terminal").to_string();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let incarnation = loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        let incarnation = resolved["terminal_incarnation"].as_str().unwrap_or_default();
        if !incarnation.is_empty() {
            break incarnation.to_string();
        }
        assert!(Instant::now() < deadline, "the command never started: {resolved}");
        std::thread::sleep(Duration::from_millis(25));
    };
    wait_for_respawn(&harness, &terminal_id, &incarnation);

    let tab = tab_named(&harness, "On exit shell");
    assert_eq!(tab["dead"], false, "the tab did not drop into a shell: {tab}");
    assert_eq!(tab["terminal_id"], terminal_id.as_str(), "the shell is another terminal");
    assert_eq!(tab["tab_resource_id"], first["tab_resource_id"], "the shell is another tab");
    let surface = tab["surface"].as_u64().expect("the shell's tab has a surface");
    let text = wait_for_screen(&harness.socket, surface, "shell-exit-marker");
    assert!(text.contains("shell-exit-marker"), "the command's screen is gone: {text}");
    echo_value(&harness, surface, "dropped", "$$");

    // The dropped-in shell is an ordinary shell: its exit closes the tab.
    send_line(&harness.socket, surface, "exit");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let tree = request(&harness.socket, serde_json::json!({"cmd":"list-workspaces"}));
        let present = tree["workspaces"]
            .as_array()
            .into_iter()
            .flatten()
            .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
            .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
            .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
            .any(|tab| tab["tab_resource_id"] == first["tab_resource_id"]);
        if !present {
            break;
        }
        assert!(Instant::now() < deadline, "the shell's exit left the tab: {tree}");
        std::thread::sleep(Duration::from_millis(25));
    }
}
