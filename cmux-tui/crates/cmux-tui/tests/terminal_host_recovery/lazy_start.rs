//! Lazy start (infinite-items-flat). Leo, 2026-11-19: "Lazy start: a
//! restored or never-shown tab doesn't spawn its shell until it is first
//! shown. It keeps its title, cwd and scrollback from the snapshot."
//!
//! With `CMUX_TUI_LAZY_START=1`, a plain shell of a hidden workspace whose
//! host is gone after a reboot is parked (`relaunch.on_show`), not
//! respawned; an agent terminal, a command and the shell of the shown
//! workspace respawn as before. The parked shell starts on its first need,
//! once, with its previous screen, and the request that needed it goes on.

use std::io::Write as _;

use super::pty_custody::send_line;
use super::*;

const MARKER: &str = "session restored (previous process ended)";

fn lazy_harness(name: &str) -> RecoveryHarness {
    let mut harness = RecoveryHarness::start_unstarted(name);
    harness.extra_env.push(("CMUX_TUI_LAZY_START".into(), "1".into()));
    let trace = harness.dir.join("lazy-trace.log");
    harness.extra_env.push(("CMUX_TUI_LAZY_TRACE".into(), trace.display().to_string()));
    harness.restart();
    harness
}

fn workspaces(harness: &RecoveryHarness) -> Vec<serde_json::Value> {
    request(&harness.socket, serde_json::json!({"cmd":"list-workspaces"}))["workspaces"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn tab_named(harness: &RecoveryHarness, name: &str) -> serde_json::Value {
    workspaces(harness)
        .iter()
        .find(|workspace| workspace["name"] == name)
        .and_then(first_tab)
        .cloned()
        .unwrap_or_else(|| panic!("workspace {name} has no tab"))
}

/// A default shell in a new workspace `name`: (internal terminal id,
/// incarnation, surface).
fn new_shell(harness: &RecoveryHarness, name: &str) -> (String, String, u64) {
    let created = request(&harness.socket, serde_json::json!({"cmd":"new-workspace","name":name}));
    let surface = created["surface"].as_u64().expect("new-workspace returned no surface");
    let terminal_id = tab_named(harness, name)["terminal_id"].as_str().unwrap().to_string();
    // Its first need starts it, when lazy start left it unstarted.
    request(&harness.socket, serde_json::json!({"cmd":"read-screen","surface":surface}));
    let resolved = request(
        &harness.socket,
        serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
    );
    let incarnation = resolved["terminal_incarnation"].as_str().unwrap_or_default().to_string();
    (terminal_id, incarnation, surface)
}

/// Make the workspace `name` the shown one.
fn select(harness: &RecoveryHarness, name: &str) {
    let index = workspaces(harness)
        .iter()
        .position(|workspace| workspace["name"] == name)
        .expect("no such workspace");
    request(&harness.socket, serde_json::json!({"cmd":"select-workspace","index":index}));
}

/// Mark the shell of `surface` as running a claude session.
fn start_agent(harness: &RecoveryHarness, name: &str, surface: u64) {
    let public_id = tab_named(harness, name)["terminal_resource_id"].as_str().unwrap().to_string();
    let mut hook = Command::new(bin())
        .args(["__agent-hook", "claude", "SessionStart"])
        .env("CMUX_TUI_SOCKET", &harness.socket)
        .env("CMUX_TUI_TERMINAL_ID", &public_id)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn the agent hook");
    hook.stdin.take().unwrap().write_all(b"{\"session_id\":\"lazy-1\"}\n").unwrap();
    assert!(hook.wait().unwrap().success());
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let agents = request(&harness.socket, serde_json::json!({"cmd":"list-agents"}));
        if agents["agents"]
            .as_array()
            .into_iter()
            .flatten()
            .any(|agent| agent["surface"].as_u64() == Some(surface) && agent["agent"] == "claude")
        {
            return;
        }
        assert!(Instant::now() < deadline, "the hook never reached the terminal: {agents}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// A reboot: the daemon and every terminal host die, a new daemon starts.
fn reboot(harness: &mut RecoveryHarness, hosts: usize) {
    let records = wait_for_host_records(&harness.host_root(), hosts);
    harness.sigkill();
    for (_, record) in &records {
        // SAFETY: the record PID is a harness-owned terminal host.
        assert_eq!(unsafe { libc::kill(record.host_pid as libc::pid_t, libc::SIGKILL) }, 0);
    }
    // The starts counted after the reboot are its own: the first starts of
    // the set-up's never-started shells are not.
    if let Some(log) = harness.host_root().parent().map(|dir| dir.join("terminal-losses.jsonl")) {
        let _ = fs::remove_file(log);
    }
    harness.restart();
}

fn wait_for_respawn(harness: &RecoveryHarness, terminal_id: &str, old: &str) -> String {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        let incarnation = resolved["terminal_incarnation"].as_str().unwrap_or_default();
        if resolved["lifecycle"] == "running" && !incarnation.is_empty() && incarnation != old {
            return incarnation.to_string();
        }
        assert!(Instant::now() < deadline, "{terminal_id} was not respawned: {resolved}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// Wait until the tab of workspace `name` is parked: dead, starting on show.
fn wait_for_parked(harness: &RecoveryHarness, name: &str) -> serde_json::Value {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    loop {
        let tab = tab_named(harness, name);
        if tab["dead"] == true && tab["relaunch"]["on_show"] == true {
            return tab;
        }
        assert!(Instant::now() < deadline, "the tab of {name} was not parked: {tab}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn respawn_count(harness: &RecoveryHarness, terminal_id: &str) -> usize {
    let log = harness.host_root().parent().map(|dir| dir.join("terminal-losses.jsonl"));
    log.and_then(|log| fs::read_to_string(log).ok())
        .unwrap_or_default()
        .lines()
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .filter(|line| line["terminal_id"] == terminal_id && line["event"] == "terminal_respawned")
        .count()
}

fn host_of(harness: &RecoveryHarness, terminal_id: &str) -> bool {
    load_terminal_host_records(&harness.host_root())
        .unwrap_or_default()
        .iter()
        .any(|(_, record)| record.terminal_id == terminal_id)
}

/// The hidden plain shell, the hidden agent and the hidden command of a
/// rebooted session, and the shell of the shown workspace: parked tab id
/// and the others' ids.
struct Rebooted {
    lazy: (String, String, u64),
    agent: (String, String),
    command: (String, String),
    front: (String, String),
}

/// A journal checkpoint, so the screens survive the reboot (a capture refuses
/// while a shell still writes; a retry under the same key is the client's).
fn checkpoint(harness: &RecoveryHarness) {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let checkpoint = request_response(
            &harness.socket,
            serde_json::json!({
                "protocol":"cmux.protocol/2",
                "type":"request",
                "id":"lazy-checkpoint",
                "operation":"session.journal.checkpoint.create",
                "idempotency_key":"lazy-checkpoint",
                "params":{"machine":"current","session":"current"},
            }),
        );
        if checkpoint["ok"] == true {
            return;
        }
        assert!(Instant::now() < deadline, "{checkpoint}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn rebooted_session(harness: &mut RecoveryHarness) -> Rebooted {
    let lazy = new_shell(harness, "lazy");
    send_line(&harness.socket, lazy.2, "printf 'lazy-%s\\n' screen");
    wait_for_screen(&harness.socket, lazy.2, "lazy-screen\n");
    let (agent_id, agent_incarnation, agent_surface) = new_shell(harness, "agent");
    start_agent(harness, "agent", agent_surface);
    let command = run_cat_workspace(&harness.socket, 7, "command");
    let (front_id, front_incarnation, _) = new_shell(harness, "front");
    select(harness, "front");
    checkpoint(harness);
    reboot(harness, 4);
    Rebooted {
        lazy,
        agent: (agent_id, agent_incarnation),
        command,
        front: (front_id, front_incarnation),
    }
}

/// Restore: the hidden plain shell is parked with no host; the agent, the
/// command and the shown shell respawn as before. A read of its screen, its
/// first need, starts it once, below its previous screen, and returns that
/// screen.
#[test]
fn restore_parks_a_hidden_plain_shell_and_its_first_need_starts_it_once() {
    let _exclusive = exclusive_process_test();
    let mut harness = lazy_harness("lazy-restore");
    let session = rebooted_session(&mut harness);
    wait_for_respawn(&harness, &session.agent.0, &session.agent.1);
    wait_for_respawn(&harness, &session.command.0, &session.command.1);
    wait_for_respawn(&harness, &session.front.0, &session.front.1);
    let parked = wait_for_parked(&harness, "lazy");
    let (lazy_id, lazy_incarnation, _) = &session.lazy;
    assert!(!host_of(&harness, lazy_id), "the parked shell has a host");
    assert_eq!(respawn_count(&harness, lazy_id), 0);

    let surface = parked["surface"].as_u64().expect("the parked tab has a surface id");
    let started = Instant::now();
    let text = request(&harness.socket, serde_json::json!({"cmd":"read-screen","surface":surface}))
        ["text"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    let first_need = started.elapsed();
    assert!(text.contains("lazy-screen"), "the first read lost the previous screen: {text}");
    assert!(text.contains(MARKER), "{text}");
    wait_for_respawn(&harness, lazy_id, lazy_incarnation);
    let prompt = wait_for_prompt(&harness, surface);
    eprintln!(
        "LAZY-START first-need read-screen ms={} prompt ms={}",
        first_need.as_millis(),
        prompt.as_millis() + first_need.as_millis()
    );
    let tab = tab_named(&harness, "lazy");
    assert_eq!(tab["dead"], false, "{tab}");
    assert!(tab["relaunch"].is_null(), "a started tab is no longer parked: {tab}");
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(respawn_count(&harness, lazy_id), 1);
}

/// The time from now until the shell of `surface` draws a prompt below the
/// marker line.
fn wait_for_prompt(harness: &RecoveryHarness, surface: u64) -> Duration {
    let started = Instant::now();
    let deadline = started + test_timeout(Duration::from_secs(10));
    loop {
        let text = request(
            &harness.socket,
            serde_json::json!({"cmd":"read-screen","surface":surface}),
        )["text"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        let after = text.rsplit_once(MARKER).map_or("", |(_, after)| after);
        if after.lines().any(|line| {
            let line = line.trim_end();
            line.ends_with('$') || line.ends_with('#') || line.ends_with('%') || line.ends_with('>')
        }) {
            return started.elapsed();
        }
        assert!(Instant::now() < deadline, "no prompt below the marker: {text}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// Concurrent first needs (input from several clients at once) start the
/// parked shell exactly once, and every one of them is delivered.
#[test]
fn concurrent_first_needs_start_a_parked_shell_once() {
    let _exclusive = exclusive_process_test();
    let mut harness = lazy_harness("lazy-concurrent");
    let session = rebooted_session(&mut harness);
    let parked = wait_for_parked(&harness, "lazy");
    let surface = parked["surface"].as_u64().unwrap();
    let socket = harness.socket.as_path();
    std::thread::scope(|scope| {
        for index in 0..6 {
            scope.spawn(move || {
                let sent = request_response(
                    socket,
                    serde_json::json!({"cmd":"send","surface":surface,"text":format!("echo need-{index}\n")}),
                );
                assert_eq!(sent["ok"], true, "a first need was refused: {sent}");
            });
        }
    });
    let (lazy_id, lazy_incarnation, _) = &session.lazy;
    wait_for_respawn(&harness, lazy_id, lazy_incarnation);
    for index in 0..6 {
        let text = wait_for_screen(&harness.socket, surface, &format!("need-{index}\n"));
        assert!(text.contains(&format!("need-{index}\n")), "input {index} was lost: {text}");
    }
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(respawn_count(&harness, lazy_id), 1, "the parked shell started more than once");
}

/// Each first-need path starts a parked shell: attach, input, paste, the
/// process query, a wait, and `select-workspace` (a show).
#[test]
fn every_first_need_path_starts_a_parked_shell() {
    let _exclusive = exclusive_process_test();
    let needs: [(&str, fn(&RecoveryHarness, u64)); 6] = [
        ("send-key", |harness, surface| {
            request(
                &harness.socket,
                serde_json::json!({"cmd":"send-key","surface":surface,"keys":["enter"]}),
            );
        }),
        ("paste", |harness, surface| {
            request(
                &harness.socket,
                serde_json::json!({"cmd":"send","surface":surface,"text":"echo pasted","paste":true}),
            );
        }),
        ("process-info", |harness, surface| {
            let info = request(
                &harness.socket,
                serde_json::json!({"cmd":"process-info","surface":surface}),
            );
            assert!(!info.is_null(), "no process info");
        }),
        ("copy", |harness, surface| {
            request(
                &harness.socket,
                serde_json::json!({"cmd":"copy","surface":surface,"mode":"scrollback"}),
            );
        }),
        ("attach-surface", |harness, surface| {
            let attached = request_response(
                &harness.socket,
                serde_json::json!({"id":1,"cmd":"attach-surface","surface":surface,"cols":80,"rows":24}),
            );
            // The first line is the attach stream's first frame, or a refusal.
            assert_ne!(attached["ok"], false, "attach was refused: {attached}");
        }),
        ("select-workspace", |harness, _| select(harness, "lazy")),
    ];
    for (name, need) in needs {
        let mut harness = lazy_harness(&format!("lazy-need-{name}"));
        let session = rebooted_session(&mut harness);
        let surface = wait_for_parked(&harness, "lazy")["surface"].as_u64().unwrap();
        need(&harness, surface);
        let (lazy_id, lazy_incarnation, _) = &session.lazy;
        wait_for_respawn(&harness, lazy_id, lazy_incarnation);
        std::thread::sleep(Duration::from_millis(300));
        assert_eq!(respawn_count(&harness, lazy_id), 1, "{name} did not start it exactly once");
    }
}

/// Off (the default), the hidden plain shell respawns at once, as before.
#[test]
fn without_lazy_start_a_hidden_plain_shell_respawns_at_once() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("lazy-off");
    let session = rebooted_session(&mut harness);
    let (lazy_id, lazy_incarnation, _) = &session.lazy;
    wait_for_respawn(&harness, lazy_id, lazy_incarnation);
    assert!(tab_named(&harness, "lazy")["relaunch"].is_null());
}

// Never-started tabs: a plain shell created where no client shows it.

/// The first pane of workspace `name`.
fn pane_of(harness: &RecoveryHarness, name: &str) -> u64 {
    workspaces(harness)
        .iter()
        .find(|workspace| workspace["name"] == name)
        .and_then(|workspace| workspace["screens"][0]["panes"][0]["id"].as_u64())
        .unwrap_or_else(|| panic!("workspace {name} has no pane"))
}

/// The tab of `surface` in the tree.
fn tab_of(harness: &RecoveryHarness, surface: u64) -> serde_json::Value {
    workspaces(harness)
        .iter()
        .flat_map(|workspace| workspace["screens"].as_array().cloned().unwrap_or_default())
        .flat_map(|screen| screen["panes"].as_array().cloned().unwrap_or_default())
        .flat_map(|pane| pane["tabs"].as_array().cloned().unwrap_or_default())
        .find(|tab| tab["surface"].as_u64() == Some(surface))
        .unwrap_or_else(|| panic!("no tab shows surface {surface}"))
}

/// An attach stream on `surface`, held open while it lives: a client that
/// shows the surface's workspace.
fn attach_and_hold(harness: &RecoveryHarness, surface: u64) -> (Box<dyn Write + Send>, String) {
    let stream = transport::connect(&harness.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(
        writer,
        "{}",
        serde_json::json!({"id":1,"cmd":"attach-surface","surface":surface,"cols":80,"rows":24})
    )
    .unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    std::thread::spawn(move || {
        let mut sink = String::new();
        while reader.read_line(&mut sink).is_ok_and(|read| read > 0) {
            sink.clear();
        }
    });
    (writer, line)
}

/// A new workspace's and a new tab's plain shells start no host where no
/// client shows them; the tab reads parked with the request's place, and a
/// read of its screen starts its first shell once, with no restore marker.
#[test]
fn a_never_shown_plain_shell_starts_on_its_first_need() {
    let _exclusive = exclusive_process_test();
    let harness = lazy_harness("lazy-new");
    let created =
        request(&harness.socket, serde_json::json!({"cmd":"new-workspace","name":"fresh"}));
    let surface = created["surface"].as_u64().expect("new-workspace returned no surface");
    let tab = tab_named(&harness, "fresh");
    let terminal_id = tab["terminal_id"].as_str().unwrap().to_string();
    assert!(!host_of(&harness, &terminal_id), "a never-shown shell got a host");
    assert_eq!(tab["dead"], true, "{tab}");
    assert_eq!(
        tab["relaunch"]["on_show"],
        true,
        "{tab}\nlazy trace:\n{}",
        std::fs::read_to_string(harness.dir.join("lazy-trace.log")).unwrap_or_default()
    );

    let added = request(
        &harness.socket,
        serde_json::json!({"cmd":"new-tab","pane":pane_of(&harness, "fresh"),"cwd":"/tmp"}),
    );
    let tab_surface = added["surface"].as_u64().expect("new-tab returned no surface");
    let added_tab = tab_of(&harness, tab_surface);
    let added_id = added_tab["terminal_id"].as_str().unwrap().to_string();
    assert!(!host_of(&harness, &added_id), "a never-shown new tab got a host");
    assert_eq!(added_tab["relaunch"]["cwd"], "/tmp", "{added_tab}");

    let started = Instant::now();
    send_line(&harness.socket, surface, "printf 'first-%s\\n' shell");
    let text = wait_for_screen(&harness.socket, surface, "first-shell\n");
    eprintln!("LAZY-START never-shown first input to output ms={}", started.elapsed().as_millis());
    assert!(text.contains("first-shell"), "the first input was lost: {text}");
    assert!(!text.contains(MARKER), "a new tab shows a restore marker: {text}");
    assert!(host_of(&harness, &terminal_id));
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(respawn_count(&harness, &terminal_id), 1);
    assert!(!host_of(&harness, &added_id), "the other tab started with it");
}

/// A command, a shell with its own environment, and a new tab in a
/// workspace a client shows start at once, as before.
#[test]
fn commands_and_shown_workspaces_start_at_once() {
    let _exclusive = exclusive_process_test();
    let harness = lazy_harness("lazy-eager");
    let (command_id, _) = run_cat_workspace(&harness.socket, 3, "command");
    assert!(host_of(&harness, &command_id), "a command waited for its first need");
    let with_env = request(
        &harness.socket,
        serde_json::json!({"cmd":"create-terminal","env":{"LAZY_PROBE":"1"},"create_workspace":true,"workspace_name":"env","key":"6f1d2c3a-0b4e-4f5a-9c7d-8e2f1a3b4c5d","origin":"cmux-next","mutation_id":"lazy-env-create"}),
    );
    let env_id = with_env["terminal_id"].as_str().expect("create-terminal returned no id");
    assert!(host_of(&harness, env_id), "a shell with its own environment waited");

    let created =
        request(&harness.socket, serde_json::json!({"cmd":"new-workspace","name":"shown"}));
    let first = created["surface"].as_u64().unwrap();
    // A client shows the workspace: its first tab starts on the attach.
    let _client = attach_and_hold(&harness, first);
    let shown_id = tab_named(&harness, "shown")["terminal_id"].as_str().unwrap().to_string();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while !host_of(&harness, &shown_id) {
        assert!(Instant::now() < deadline, "the attach did not start the shown tab");
        std::thread::sleep(Duration::from_millis(25));
    }
    let added = request(
        &harness.socket,
        serde_json::json!({"cmd":"new-tab","pane":pane_of(&harness, "shown")}),
    );
    let added_id = tab_of(&harness, added["surface"].as_u64().unwrap())["terminal_id"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(host_of(&harness, &added_id), "a new tab of a shown workspace waited");
}

/// Concurrent first needs of a never-started tab start it once.
#[test]
fn concurrent_first_needs_start_a_never_shown_shell_once() {
    let _exclusive = exclusive_process_test();
    let harness = lazy_harness("lazy-new-concurrent");
    let created =
        request(&harness.socket, serde_json::json!({"cmd":"new-workspace","name":"fresh"}));
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = tab_named(&harness, "fresh")["terminal_id"].as_str().unwrap().to_string();
    let socket = harness.socket.as_path();
    std::thread::scope(|scope| {
        for index in 0..6 {
            scope.spawn(move || {
                let sent = request_response(
                    socket,
                    serde_json::json!({"cmd":"send","surface":surface,"text":format!("echo need-{index}\n")}),
                );
                assert_eq!(sent["ok"], true, "a first need was refused: {sent}");
            });
        }
    });
    for index in 0..6 {
        let text = wait_for_screen(&harness.socket, surface, &format!("need-{index}\n"));
        assert!(text.contains(&format!("need-{index}\n")), "input {index} was lost: {text}");
    }
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(respawn_count(&harness, &terminal_id), 1, "it started more than once");
}

/// Off (the default), a new workspace's shell starts at once.
#[test]
fn without_lazy_start_a_never_shown_shell_starts_at_once() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("lazy-new-off");
    request(&harness.socket, serde_json::json!({"cmd":"new-workspace","name":"fresh"}));
    let terminal_id = tab_named(&harness, "fresh")["terminal_id"].as_str().unwrap().to_string();
    assert!(host_of(&harness, &terminal_id));
}
