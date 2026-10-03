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

/// Upper bound for ending 100 terminal hosts at once, in seconds. Each host
/// fsyncs its exit receipt and its record directory, and the owner fsyncs
/// the record directory when it acknowledges the receipt: about 400 fsyncs.
/// On macOS `sync_all` is F_FULLFSYNC, which flushes the whole device cache
/// and does not run in parallel, so the cost is the device's, not the
/// worker pool's. Measured: 0.3 s for 100 hosts on an Apple-silicon Mac
/// (local runs of the hosted binary), 3.4-3.8 s on hosted macOS runners
/// (runs 36944275265, 36785429387, 36961653859), up to 8.9 s on hosted Linux
/// (run 36951369512). A teardown that waits for each host in turn (the 2 s
/// receipt wait this test caught) costs tens of seconds.
const HUNDRED_HOST_TEARDOWN_BOUND_SECS: u64 = 10;

/// A close commits and updates the tree before its host exits, and many
/// closes end their hosts in parallel instead of one after another.
#[test]
fn closing_one_hundred_terminals_updates_the_tree_at_once_and_ends_every_host() {
    let _exclusive = exclusive_process_test();
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
    let mut slowest = (0, Duration::ZERO);
    for (index, (terminal_id, incarnation)) in terminals.iter().enumerate() {
        let one = Instant::now();
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
        if one.elapsed() > slowest.1 {
            slowest = (index, one.elapsed());
        }
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
        "closed {COUNT} terminals: replies {closed_in:?} (slowest #{} {:?}), tree {tree_in:?}, \
         hosts {hosts_in:?}",
        slowest.0, slowest.1
    );
    // Each reply waits only for its durable commit (one fsync plus a full
    // resource projection), never for a host's termination receipt, exit or
    // Kitty acknowledgement; each of those waited up to the 2 s control
    // timeout (runs 36711759589, 36736552304, 36953259790). The commit fsync
    // is F_FULLFSYNC on macOS, so the total follows the device: 1.7 s on
    // hosted Linux, 2.1-7.2 s on hosted macOS (runs 36785429387, 36961653859,
    // 36991955184). A single reply therefore carries the stall signal.
    assert!(
        slowest.1 < test_timeout(Duration::from_secs(1)),
        "close #{} took {:?}",
        slowest.0,
        slowest.1
    );
    assert!(
        closed_in < test_timeout(Duration::from_secs(HUNDRED_HOST_TEARDOWN_BOUND_SECS)),
        "closes took {closed_in:?}"
    );
    // Hosts were signaled as each close committed and end in parallel, so
    // all of them end within the cost of ending 100 hosts at once.
    assert!(
        hosts_in < closed_in + test_timeout(Duration::from_secs(HUNDRED_HOST_TEARDOWN_BOUND_SECS)),
        "host exits trailed the last close by {:?}",
        hosts_in.saturating_sub(closed_in)
    );
}

/// `close-tabs` with `end_terminals` removes 100 terminal tabs and ends their
/// terminals in one durable commit: the tree reflects it within a second and
/// every host ends within three.
#[test]
fn close_tabs_ends_one_hundred_terminals_in_one_commit() {
    let _exclusive = exclusive_process_test();
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
    assert!(
        hosts_in < test_timeout(Duration::from_secs(HUNDRED_HOST_TEARDOWN_BOUND_SECS)),
        "hosts took {hosts_in:?}"
    );
}

/// Every Kitty image budget bucket change (a power of two of the terminal
/// count) sends new limits to every live terminal host. A hosted terminal
/// answers with ResyncRequired and then the acknowledgement. The daemon's
/// reader reconnected on ResyncRequired and dropped the acknowledgement, so
/// each update waited the full 2 s control timeout while it held that
/// terminal's runtime lock, and a close of that terminal waited behind it.
/// Closing 17 terminals crosses the 32 -> 8 bucket change; no close may wait
/// for a Kitty update.
#[test]
fn kitty_budget_rebalance_never_holds_a_terminal_for_the_control_timeout() {
    const COUNT: usize = 17;
    let harness = RecoveryHarness::start("kitty-rebalance");
    let terminals: Vec<(String, String)> = (0..COUNT)
        .map(|index| run_cat_workspace(&harness.socket, index + 1, &format!("kitty-{index}")))
        .collect();
    wait_for_host_records(&harness.host_root(), COUNT);
    let stream = transport::connect(&harness.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    let mut slowest = (0, Duration::ZERO);
    for (index, (terminal_id, incarnation)) in terminals.iter().enumerate() {
        let started = Instant::now();
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
        if started.elapsed() > slowest.1 {
            slowest = (index, started.elapsed());
        }
    }
    assert!(
        slowest.1 < Duration::from_millis(1_000),
        "close {} waited {:?} behind a Kitty budget update",
        slowest.0,
        slowest.1
    );
    wait_for_no_host_records(&harness.host_root());
}
