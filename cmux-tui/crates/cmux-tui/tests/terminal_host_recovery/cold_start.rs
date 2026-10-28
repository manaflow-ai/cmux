//! A cold start (after a reboot, or with every process of cmux killed): each
//! restored terminal's host is dead. The owner answers its first client
//! before it commits those ends, as it answers before it adopts live hosts
//! (answers_before_adoption.rs): it ends and respawns them as work items, a
//! few at a time and in the background, and an attach to one (the app
//! attaches the terminals it shows) has that terminal end and respawn first.
//! Chrome's session restore loads the shown tab first and the background
//! tabs after it. Before, the owner committed each end, one registry commit
//! each, before its first answer (600 terminals: 10.5 s on a capture Mac,
//! cp/restore-investigate bench), and its 600 respawns started together.

use super::*;

/// The tabs of `tree` (`list-workspaces`), each as JSON.
fn tabs(tree: &serde_json::Value) -> Vec<serde_json::Value> {
    tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .cloned()
        .collect()
}

#[test]
fn a_cold_start_answers_before_it_ends_its_dead_hosts_and_respawns_an_attached_one_first() {
    const COUNT: usize = 200;
    // Each committed host loss waits this long after its commit (debug hook):
    // ending COUNT hosts before the first answer costs COUNT times this (4 s).
    const LOSS_DELAY_MS: u64 = 20;
    let mut harness = RecoveryHarness::start("cold-start");
    for index in 0..COUNT {
        request(
            &harness.socket,
            serde_json::json!({
                "id": 100 + index,
                "cmd": "run",
                "argv": ["/bin/cat"],
                "new_workspace": index % 4 == 0,
                "name": format!("cold-{index}"),
            }),
        );
    }
    let records = wait_for_host_records(&harness.host_root(), COUNT);
    // Records are taken in path order: the last one is the last in the queue.
    let last = records.iter().map(|(_, record)| record.terminal_id.clone()).max().unwrap();
    let before = request(&harness.socket, serde_json::json!({"cmd": "list-workspaces"}));
    let content = tabs(&before)
        .into_iter()
        .find(|tab| tab["terminal_id"] == last.as_str())
        .and_then(|tab| tab["content_resource_id"].as_str().map(str::to_string))
        .unwrap_or_else(|| panic!("no tab shows terminal {last}: {before}"));
    // The daemon goes first, so no owner sees the hosts die.
    harness.sigkill();
    for (_, record) in &records {
        // SAFETY: the record PID is a harness-owned terminal host.
        unsafe { libc::kill(record.host_pid as libc::pid_t, libc::SIGKILL) };
    }
    for (_, record) in &records {
        let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
        // SAFETY: probes the harness-owned host PID without signalling it.
        while unsafe { libc::kill(record.host_pid as libc::pid_t, 0) } == 0 {
            assert!(Instant::now() < deadline, "host {} outlived SIGKILL", record.host_pid);
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    harness
        .extra_env
        .push(("CMUX_TUI_TEST_HOST_LOSS_LOG_DELAY_MS".to_string(), LOSS_DELAY_MS.to_string()));
    let started = Instant::now();
    harness.restart();
    request(&harness.socket, serde_json::json!({"id": 1, "cmd": "identify"}));
    let answered = started.elapsed();
    // The bound: ending the hosts first costs at least COUNT * LOSS_DELAY_MS
    // (4 s) by construction; answering first costs only the start pass, which
    // answers_before_adoption bounds at 3 s for a loaded runner (the live-host
    // bench answers 60 hosts in 250 ms).
    assert!(
        answered < Duration::from_millis(2_500),
        "the cold start answered after {answered:?}: it ended its {COUNT} dead hosts first"
    );

    let tree = request(&harness.socket, serde_json::json!({"cmd": "list-workspaces"}));
    let tab = tabs(&tree)
        .into_iter()
        .find(|tab| tab["content_resource_id"] == content.as_str())
        .unwrap_or_else(|| panic!("the cold start lost the tab of {last}: {tree}"));
    // R41: a tab whose terminal respawns never reads as dead meanwhile.
    assert_eq!(tab["terminal_state"], "adopting", "the last-queued tab is not pending: {tab}");
    let surface = tab["surface"].as_u64().unwrap();

    let attach_started = Instant::now();
    let stream = transport::connect(&harness.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(
        writer,
        "{}",
        serde_json::json!({"id": 7, "cmd": "attach-surface", "surface": surface})
    )
    .unwrap();
    let response = loop {
        let mut line = String::new();
        reader.read_line(&mut line).expect("the attach connection closed before its answer");
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        if value["id"] == 7 {
            break value;
        }
    };
    let attached = attach_started.elapsed();
    let pending = tabs(&request(&harness.socket, serde_json::json!({"cmd": "list-workspaces"})))
        .into_iter()
        .filter(|tab| tab["terminal_state"] == "adopting")
        .count();
    assert_eq!(
        response["ok"], true,
        "an attach to the respawning terminal failed instead of waiting for it: {response}"
    );
    // The background ends and respawns of COUNT terminals take longer than
    // the attached one: many are still pending when it answers.
    assert!(
        pending >= COUNT / 4,
        "the attach answered after {attached:?}, when only {pending} tabs were still pending: \
         it waited for the queue instead of going first"
    );
    let resolved = request(
        &harness.socket,
        serde_json::json!({"cmd": "resolve-terminal", "terminal_id": last}),
    );
    assert_eq!(resolved["lifecycle"], "running", "{resolved}");
    assert_eq!(resolved["surface"].as_u64(), Some(surface), "{resolved}");
}
