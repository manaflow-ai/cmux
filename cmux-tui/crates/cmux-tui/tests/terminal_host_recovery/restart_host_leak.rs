//! P0 TERMINAL-HOST LEAK (restore fuzz row h, fgh-h-hog-2044 on cmux22,
//! 2026-10-31): 14 `kill -9`s of the daemon left 477 terminal hosts for
//! about 85 live terminals, and new terminals then failed with "PTY capacity
//! exhausted". Every host process holds one PTY of the Mac's 511.
//!
//! The cause was not orphaned hosts (every host stayed adoptable, as the
//! second test proves) but terminals the session itself kept: a closed
//! workspace's terminals live until the reap grace ends, and each daemon
//! start counted that grace again from zero, so under frequent restarts
//! none was ever reaped (`mux/terminal_reap.rs`). The rule: after any
//! number of daemon kills, every host is one a terminal of the session
//! still needs (or the current daemon's one spare, R81), closed terminals
//! end within the grace counted from their close, and a new terminal opens.

use super::*;

/// The `__terminal-host` processes whose `--owner` names one of `daemons`
/// (`<bundle>:<tag>@<daemon pid>`): every host these daemons started,
/// spare or serving, wherever its parent went.
fn hosts_of(daemons: &[u32]) -> std::collections::BTreeMap<u32, String> {
    let output = Command::new("ps").args(["-e", "-o", "pid=,args="]).output().expect("run ps");
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| {
            let line = line.trim();
            let (pid, args) = line.split_once(char::is_whitespace)?;
            if !args.contains("__terminal-host") {
                return None;
            }
            let owner = args.split_whitespace().skip_while(|arg| *arg != "--owner").nth(1)?;
            let daemon: u32 = owner.rsplit_once('@')?.1.parse().ok()?;
            let pid: u32 = pid.parse().ok()?;
            daemons.contains(&daemon).then(|| (pid, args.to_string()))
        })
        .collect()
}

fn daemon_pid(harness: &RecoveryHarness) -> u32 {
    harness.child.as_ref().unwrap().id()
}

/// Hosts with a discovery record, by pid, with their terminal ids.
fn recorded_hosts(harness: &RecoveryHarness) -> std::collections::BTreeMap<u32, String> {
    load_terminal_host_records(&harness.host_root())
        .unwrap()
        .into_iter()
        .map(|(_, record)| (record.host_pid, record.terminal_id))
        .collect()
}

/// Creates a `/bin/cat` terminal; `None` when the daemon did not answer ok
/// (killed mid-request).
fn try_run_cat(socket: &Path, id: u64, name: &str) -> Option<String> {
    let stream = transport::connect(socket).ok()?;
    let mut writer = stream.try_clone_box().ok()?;
    let mut reader = BufReader::new(stream);
    let request = serde_json::json!({
        "id": id,
        "cmd": "run",
        "argv": ["/bin/cat"],
        "new_workspace": id.is_multiple_of(3),
        "name": name,
    });
    writeln!(writer, "{request}").ok()?;
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    let reply: serde_json::Value = serde_json::from_str(&line).ok()?;
    (reply["ok"] == true).then(|| reply["data"]["terminal_id"].as_str().map(str::to_string))?
}

/// Waits until every recorded terminal is running and attached again.
fn wait_until_adopted(harness: &RecoveryHarness) {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(30));
    loop {
        let pending: Vec<String> = recorded_hosts(harness)
            .into_values()
            .filter(|terminal_id| {
                let resolved = request_response(
                    &harness.socket,
                    serde_json::json!({"id": 7, "cmd": "resolve-terminal", "terminal_id": terminal_id}),
                );
                resolved["data"]["lifecycle"] == "adopting"
                    || resolved["data"]["lifecycle"] == "launching"
            })
            .collect();
        if pending.is_empty() {
            return;
        }
        assert!(Instant::now() < deadline, "terminals never adopted again: {pending:?}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Every host the daemons started is recorded, or is the current daemon's
/// one spare. Waits for the restarted daemon to settle, then reports what
/// is left over.
fn assert_no_unrecorded_hosts(harness: &RecoveryHarness, daemons: &[u32], step: &str) {
    let current = daemon_pid(harness);
    let deadline = Instant::now() + test_timeout(Duration::from_secs(20));
    loop {
        let recorded = recorded_hosts(harness);
        let hosts = hosts_of(daemons);
        let unrecorded: Vec<(&u32, &String)> =
            hosts.iter().filter(|(pid, _)| !recorded.contains_key(pid)).collect();
        let foreign_spares =
            unrecorded.iter().filter(|(_, args)| !args.contains(&format!("@{current}"))).count();
        if foreign_spares == 0 && unrecorded.len() <= 1 {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "{step}: {} terminal hosts run for {} recorded terminals; {} have no record \
             ({foreign_spares} started by an earlier daemon), so no daemon can adopt or end \
             them: {unrecorded:?}",
            hosts.len(),
            recorded.len(),
            unrecorded.len(),
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// Ends every host these daemons started that the harness's own teardown
/// (records only) would miss.
fn end_hosts_of(daemons: &[u32]) {
    for pid in hosts_of(daemons).into_keys() {
        // SAFETY: a host process these test daemons started (its --owner
        // names one of them).
        unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
    }
}

struct EndHosts(Vec<u32>);

impl Drop for EndHosts {
    fn drop(&mut self) {
        end_hosts_of(&self.0);
    }
}

/// The leak row h found: a plain workspace close keeps its terminals until
/// the reap grace ends, and each daemon start used to count that grace
/// again from zero. With restarts faster than the grace (a crash loop, or
/// the fuzz's kill every ~14 s against a 30 s grace) no closed terminal was
/// ever reaped, and their PTYs ran out. The grace runs across restarts:
/// closed terminals end, the placed one keeps running, and a new terminal
/// opens.
#[test]
fn daemon_restarts_faster_than_the_reap_grace_still_reap_closed_terminals() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start_with_args(
        "restart-reap-grace",
        &["--terminal-reap-grace-seconds", "4"],
    );
    let mut daemons = EndHosts(vec![daemon_pid(&harness)]);
    let (placed, _) = run_cat_workspace(&harness.socket, 1, "placed");
    let closed: Vec<String> = (0..3)
        .map(|index| run_cat_workspace(&harness.socket, 10 + index, &format!("closed-{index}")).0)
        .collect();
    wait_for_host_records(&harness.host_root(), 4);
    let tree = request(&harness.socket, serde_json::json!({"id": 20, "cmd": "list-workspaces"}));
    for workspace in tree["workspaces"].as_array().unwrap() {
        if workspace["name"].as_str().is_some_and(|name| name.starts_with("closed-")) {
            request(
                &harness.socket,
                serde_json::json!({"id": 21, "cmd": "close-workspace", "key": workspace["key"]}),
            );
        }
    }
    // Every daemon lives 2 s, half the grace, for 16 s: four graces.
    for _ in 0..8 {
        std::thread::sleep(Duration::from_secs(2));
        harness.sigkill();
        harness.restart();
        daemons.0.push(daemon_pid(&harness));
    }
    // Checked within a quarter of the grace after the last start: a grace
    // counted from that start is not over yet.
    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        let recorded: std::collections::BTreeSet<String> =
            recorded_hosts(&harness).into_values().collect();
        let left: Vec<&String> = closed.iter().filter(|id| recorded.contains(*id)).collect();
        if left.is_empty() {
            assert!(recorded.contains(&placed), "the placed terminal was reaped: {recorded:?}");
            break;
        }
        assert!(
            Instant::now() < deadline,
            "{} of 3 terminals closed 16 s ago (reap grace 4 s, 8 daemon restarts) still \
             hold a host and a PTY: {left:?}",
            left.len()
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    wait_until_adopted(&harness);
    assert_no_unrecorded_hosts(&harness, &daemons.0, "after the restarts");
    try_run_cat(&harness.socket, 900, "after-restarts").expect("a new terminal opens");
}

/// The fuzz's case: each `kill -9` lands while terminals are being created
/// (and the restarted daemon is still adopting). Afterwards every host is
/// one the session serves, and a new terminal opens.
#[test]
fn daemon_kills_during_creates_leave_only_the_hosts_the_session_serves() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("restart-host-leak-inflight");
    let mut daemons = EndHosts(vec![daemon_pid(&harness)]);
    let mut next_id = 1000;
    for kill in 0..8 {
        let socket = harness.socket.clone();
        let first = next_id;
        next_id += 100;
        let creator = std::thread::spawn(move || {
            for id in first..first + 100 {
                if try_run_cat(&socket, id, &format!("inflight-{id}")).is_none() {
                    return;
                }
            }
        });
        // Kill while creates are in flight; after kill 3, also before the
        // previous restart finished adopting.
        std::thread::sleep(Duration::from_millis(if kill < 3 { 300 } else { 120 }));
        harness.sigkill();
        let _ = creator.join();
        harness.restart();
        daemons.0.push(daemon_pid(&harness));
    }
    wait_until_adopted(&harness);
    assert_no_unrecorded_hosts(&harness, &daemons.0, "after 8 kills during creates");
    try_run_cat(&harness.socket, 9_000, "after-kills").expect("a new terminal opens");
}
