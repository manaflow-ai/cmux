//! Close-path timing: a close never waits for a host's termination receipt
//! or a Kitty budget update, and ending 100 hosts costs only their exit fsyncs.

use super::*;

/// A close replies once its commit is durable. It never waits for the host's
/// termination receipt: that receipt travels behind the terminal's output on
/// the host stream, and waiting for it inline held the reply (and the
/// terminal's runtime lock) for the full two-second control timeout whenever
/// the stream was slow, which made 100 sequential closes take over 15 s.
#[test]
fn close_terminal_replies_without_waiting_for_the_host_termination_receipt() {
    let mut harness = RecoveryHarness::start_unstarted("close-ack-late");
    let mut command = harness.daemon_command();
    command.env("CMUX_TUI_TEST_TERMINATE_ACK_DELAY_MS", "3000");
    harness.child = Some(command.spawn().unwrap());
    wait_for_socket(&harness.socket);
    let (terminal_id, incarnation) = run_cat_workspace(&harness.socket, 1, "close-ack-late");
    wait_for_host_records(&harness.host_root(), 1);

    let started = Instant::now();
    let closed = request(
        &harness.socket,
        serde_json::json!({
            "id": 2,
            "cmd": "close-terminal",
            "terminal_id": &terminal_id,
            "terminal_incarnation": &incarnation,
        }),
    );
    let replied_in = started.elapsed();
    assert_eq!(closed["terminal_id"].as_str(), Some(terminal_id.as_str()), "{closed}");
    // The control timeout the old inline wait spent is two seconds; the
    // reply itself needs one durable commit.
    assert!(
        replied_in < Duration::from_secs(2),
        "close-terminal waited {replied_in:?} for the host's termination receipt"
    );
    assert!(!tree_terminal_ids(&harness.socket).contains(&terminal_id));
    wait_for_no_host_records(&harness.host_root());
}

/// Ending many terminals never waits for each host's termination receipt:
/// the host-close pool asks every host to end and then waits for the durable
/// exit receipts. With eight pool workers and receipts that arrive late, a
/// receipt wait per host serialized the batch (the close_tabs 100-terminal
/// test took 4.2 s on macOS, run 36769176794).
#[test]
fn batch_close_ends_hosts_without_waiting_for_termination_receipts() {
    const COUNT: usize = 48;
    let mut harness = RecoveryHarness::start_unstarted("batch-close-ack-late");
    let mut command = harness.daemon_command();
    command.env("CMUX_TUI_TEST_TERMINATE_ACK_DELAY_MS", "3000");
    harness.child = Some(command.spawn().unwrap());
    wait_for_socket(&harness.socket);
    let mut surfaces = Vec::with_capacity(COUNT);
    for index in 0..COUNT {
        let created = request(
            &harness.socket,
            serde_json::json!({
                "id": index + 1,
                "cmd": "run",
                "argv": ["/bin/cat"],
                "new_workspace": true,
                "name": format!("batch-ack-{index}"),
            }),
        );
        surfaces.push(created["surface"].as_u64().unwrap());
    }
    wait_for_host_records(&harness.host_root(), COUNT);

    let started = Instant::now();
    request(
        &harness.socket,
        serde_json::json!({
            "id": 1_000,
            "cmd": "close-tabs",
            "surfaces": surfaces,
            "end_terminals": true,
        }),
    );
    wait_for_no_host_records_within(&harness.host_root(), test_timeout(Duration::from_secs(10)));
    let hosts_in = started.elapsed();
    // 48 hosts on eight workers: waiting for each late receipt (up to the 2 s
    // control timeout) takes at least 12 s. Ending 48 hosts in parallel costs
    // their exit-receipt fsyncs, a few seconds on a CI Linux VM (16 hosts took
    // 3.1 s in run 36779722840).
    assert!(
        hosts_in < Duration::from_secs(8),
        "ending {COUNT} hosts waited for their termination receipts: {hosts_in:?}"
    );
}

/// A close commits and updates the tree before its host exits, and many
/// closes end their hosts in parallel instead of one after another.
#[test]
fn closing_one_hundred_terminals_updates_the_tree_at_once_and_ends_every_host() {
    const COUNT: usize = 100;
    let harness = RecoveryHarness::start("close-one-hundred");
    let terminals: Vec<(String, String)> = (0..COUNT)
        .map(|index| run_cat_workspace(&harness.socket, index + 1, &format!("close-{index}")))
        .collect();
    wait_for_host_records(&harness.host_root(), COUNT);

    let stream = transport::connect(&harness.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    let started = Instant::now();
    for (index, (terminal_id, incarnation)) in terminals.iter().enumerate() {
        stream_request(
            &mut writer,
            &mut reader,
            serde_json::json!({
                "id": 1_000 + index,
                "cmd": "close-terminal",
                "terminal_id": terminal_id,
                "terminal_incarnation": incarnation,
            }),
        );
    }
    let closed_in = started.elapsed();
    let remaining = tree_terminal_ids(&harness.socket);
    let tree_in = started.elapsed();
    assert!(
        terminals.iter().all(|(terminal_id, _)| !remaining.contains(terminal_id)),
        "closed terminals remained in the tree"
    );
    let host_deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while !load_terminal_host_records(&harness.host_root()).unwrap().is_empty()
        || !load_terminal_host_exit_records(&harness.host_root()).unwrap().is_empty()
    {
        assert!(Instant::now() < host_deadline, "closed terminal hosts did not exit");
        std::thread::sleep(Duration::from_millis(10));
    }
    let hosts_in = started.elapsed();
    eprintln!(
        "closed {COUNT} terminals: replies {closed_in:?}, tree {tree_in:?}, hosts {hosts_in:?}"
    );
    // Each reply waits only for its durable commit (one fsync plus a full
    // resource projection, 10-35 ms on hosted Linux), never for the host's
    // termination receipt or exit. 100 replies take about 1.7 s there; a
    // reply that waited for a receipt stalled up to 2 s each (8.5-10 s in
    // runs 36711759589 and 36736552304).
    assert!(closed_in < test_timeout(Duration::from_secs(5)), "closes took {closed_in:?}");
    // Hosts were signaled as each close committed and end in parallel, so
    // all of them end within the cost of ending 100 hosts at once: about 400
    // fsyncs (see close_tabs_ends_one_hundred_terminals_in_one_commit), about
    // 1 s on a Mac and several seconds on a CI Linux VM. Ending them one
    // after another costs a multiple of that. The old bound (3 s after the
    // last reply) held only while the replies themselves were slow enough to
    // hide the teardown.
    let host_bound = if cfg!(target_os = "macos") { 3 } else { 10 };
    assert!(
        hosts_in < closed_in + test_timeout(Duration::from_secs(host_bound)),
        "host exits trailed the last close by {:?}",
        hosts_in.saturating_sub(closed_in)
    );
}

/// `close-tabs` with `end_terminals` removes 100 terminal tabs and ends their
/// terminals in one durable commit: the tree reflects it within a second and
/// every host ends within three.
#[test]
fn close_tabs_ends_one_hundred_terminals_in_one_commit() {
    const COUNT: usize = 100;
    let harness = RecoveryHarness::start("close-tabs-hundred");
    let identify = request(&harness.socket, serde_json::json!({"id": 1, "cmd": "identify"}));
    assert!(
        identify["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|capability| capability == "batch-close-v1")
    );
    let mut surfaces = Vec::with_capacity(COUNT);
    let mut terminals = Vec::with_capacity(COUNT);
    for index in 0..COUNT {
        let created = request(
            &harness.socket,
            serde_json::json!({
                "id": index + 2,
                "cmd": "run",
                "argv": ["/bin/cat"],
                "new_workspace": true,
                "name": format!("batch-{index}"),
            }),
        );
        surfaces.push(created["surface"].as_u64().unwrap());
        terminals.push(created["terminal_id"].as_str().unwrap().to_string());
    }
    wait_for_host_records(&harness.host_root(), COUNT);

    let started = Instant::now();
    let reply = request(
        &harness.socket,
        serde_json::json!({
            "id": 1_000,
            "cmd": "close-tabs",
            "surfaces": surfaces,
            "end_terminals": true,
            "transaction": "close-hundred",
        }),
    );
    let replied_in = started.elapsed();
    let remaining = tree_terminal_ids(&harness.socket);
    let tree_in = started.elapsed();
    wait_for_no_host_records_within(&harness.host_root(), test_timeout(Duration::from_secs(10)));
    let hosts_in = started.elapsed();
    eprintln!(
        "close-tabs {COUNT} terminals: reply {replied_in:?}, tree {tree_in:?}, hosts {hosts_in:?}"
    );
    assert_eq!(reply["transaction"], "close-hundred");
    assert_eq!(reply["closed"].as_array().unwrap().len(), COUNT);
    let ended = reply["terminals"].as_array().unwrap();
    assert_eq!(ended.len(), COUNT);
    for terminal_id in &terminals {
        assert!(!remaining.contains(terminal_id), "closed terminal remained in the tree");
        assert!(ended.iter().any(|ended| ended["terminal_id"] == terminal_id.as_str()));
    }
    assert!(tree_in < test_timeout(Duration::from_secs(1)), "tree took {tree_in:?}");
    // Each host fsyncs its exit receipt and the owner fsyncs the record
    // directory when it acknowledges it: about 400 fsyncs for 100 hosts.
    // That takes about 1 s on a Mac and several seconds on a CI Linux VM.
    let host_bound = if cfg!(target_os = "macos") { 3 } else { 10 };
    assert!(hosts_in < test_timeout(Duration::from_secs(host_bound)), "hosts took {hosts_in:?}");
}
