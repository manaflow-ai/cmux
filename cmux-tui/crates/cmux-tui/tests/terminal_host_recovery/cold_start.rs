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
    let phase_clock = Instant::now();
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
    eprintln!("PHASE created t={:?}", phase_clock.elapsed());
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
    eprintln!("PHASE killed t={:?}", phase_clock.elapsed());
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
    eprintln!("PHASE restarted t={:?}", phase_clock.elapsed());
    request(&harness.socket, serde_json::json!({"id": 1, "cmd": "identify"}));
    let answered = started.elapsed();
    eprintln!("PHASE answered t={:?}", phase_clock.elapsed());
    // The bound: ending the hosts first costs at least COUNT * LOSS_DELAY_MS
    // (4 s) by construction, plus the start pass; answering first costs only
    // the start pass, which answers_before_adoption bounds at 3 s for a
    // loaded runner (the live-host bench answers 60 hosts in 250 ms). 3.5 s
    // leaves a debug build's start pass of 200 rows its room.
    assert!(
        answered < Duration::from_millis(3_500),
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
    eprintln!("PHASE tab-pending t={:?}", phase_clock.elapsed());

    let attach_started = Instant::now();
    let stream = transport::connect(&harness.socket).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(20))).ok();
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
    eprintln!("PHASE attached t={:?} response={response}", phase_clock.elapsed());
    // Diagnostic: which request hangs, and is the daemon still alive.
    for (index, probe) in [
        serde_json::json!({"id": 901, "cmd": "identify"}),
        serde_json::json!({"id": 902, "cmd": "list-terminals"}),
        serde_json::json!({"id": 903, "cmd": "list-workspaces"}),
    ]
    .into_iter()
    .enumerate()
    {
        let alive = harness.child.as_mut().map(|child| child.try_wait().ok().flatten().is_none());
        let stream = transport::connect(&harness.socket);
        eprintln!("PHASE probe {index} connect={} alive={alive:?}", stream.is_ok());
        let Ok(stream) = stream else { continue };
        stream.set_read_timeout(Some(Duration::from_secs(10))).ok();
        let mut writer = stream.try_clone_box().unwrap();
        let mut reader = BufReader::new(stream);
        let started = Instant::now();
        writeln!(writer, "{probe}").unwrap();
        let mut line = String::new();
        let read = reader.read_line(&mut line);
        eprintln!(
            "PHASE probe {index} {} after {:?}: {:?} {}",
            probe["cmd"],
            started.elapsed(),
            read.as_ref().map_err(|error| error.kind()),
            &line.chars().take(160).collect::<String>()
        );
    }
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
    let records = load_terminal_host_records(&harness.host_root()).unwrap_or_default();
    eprintln!("PHASE body-done t={:?} live-host-records={}", phase_clock.elapsed(), records.len());
    drop(harness);
    eprintln!("PHASE dropped t={:?}", phase_clock.elapsed());
}

/// Starts a daemon with `count` terminals, then kills it and every host, as
/// a reboot does. Returns the harness (stopped), the host records, and the
/// last-queued terminal's host id and tab content id.
fn cold_session(
    name: &str,
    count: usize,
) -> (RecoveryHarness, Vec<(PathBuf, TerminalHostRecord)>, String, String) {
    let mut harness = RecoveryHarness::start(name);
    for index in 0..count {
        request(
            &harness.socket,
            serde_json::json!({"cmd": "run", "argv": ["/bin/cat"],
                               "new_workspace": index % 4 == 0, "name": format!("cold-{index}")}),
        );
    }
    let records = wait_for_host_records(&harness.host_root(), count);
    let last = records.iter().map(|(_, record)| record.terminal_id.clone()).max().unwrap();
    let before = request(&harness.socket, serde_json::json!({"cmd": "list-workspaces"}));
    let content = tabs(&before)
        .into_iter()
        .find(|tab| tab["terminal_id"] == last.as_str())
        .and_then(|tab| tab["content_resource_id"].as_str().map(str::to_string))
        .unwrap_or_else(|| panic!("no tab shows terminal {last}: {before}"));
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
    (harness, records, last, content)
}

/// The surface of the tab that shows `content`, which must be pending.
fn pending_surface(socket: &Path, content: &str) -> u64 {
    let tree = request(socket, serde_json::json!({"cmd": "list-workspaces"}));
    let tab = tabs(&tree)
        .into_iter()
        .find(|tab| tab["content_resource_id"] == content)
        .unwrap_or_else(|| panic!("the cold start lost the tab of {content}: {tree}"));
    assert_eq!(tab["terminal_state"], "adopting", "the tab is not pending: {tab}");
    tab["surface"].as_u64().unwrap()
}

/// Attaches to `surface` on a new connection: its answer and how long it took.
fn attach(socket: &Path, surface: u64) -> (serde_json::Value, Duration) {
    let started = Instant::now();
    let stream = transport::connect(socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(
        writer,
        "{}",
        serde_json::json!({"id": 7, "cmd": "attach-surface", "surface": surface})
    )
    .unwrap();
    loop {
        let mut line = String::new();
        reader.read_line(&mut line).expect("the attach connection closed before its answer");
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        if value["id"] == 7 {
            return (value, started.elapsed());
        }
    }
}

/// Waits until every terminal of `records` runs with a surface.
fn wait_all_running(socket: &Path, records: &[(PathBuf, TerminalHostRecord)]) {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(60));
    let mut pending: std::collections::HashSet<String> =
        records.iter().map(|(_, record)| record.terminal_id.clone()).collect();
    while !pending.is_empty() {
        pending.retain(|terminal_id| {
            let resolved = request(
                socket,
                serde_json::json!({"cmd": "resolve-terminal", "terminal_id": terminal_id}),
            );
            resolved["lifecycle"] != "running" || resolved["surface"].as_u64().is_none()
        });
        assert!(Instant::now() < deadline, "{} terminals never respawned", pending.len());
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// The app attaches after the owner said ready, while hundreds of ends are
/// queued. The attached terminal's end goes first, and its respawn must not
/// wait behind them: a respawn of a restored terminal runs in the
/// background, at a priority the System lane holds back while the ends run.
/// Before, the respawn the attach waited for was posted there and starved
/// until the queued ends drained (here 200 x 200 ms / 8 = 5 s), past the
/// attach's 4 s bound.
#[test]
fn an_attach_after_ready_respawns_its_terminal_before_the_queued_ends() {
    const COUNT: usize = 200;
    const LOSS_DELAY_MS: u64 = 200;
    let (mut harness, _records, last, content) = cold_session("cold-start-after-ready", COUNT);
    harness
        .extra_env
        .push(("CMUX_TUI_TEST_HOST_LOSS_LOG_DELAY_MS".to_string(), LOSS_DELAY_MS.to_string()));
    harness.restart();
    request(&harness.socket, serde_json::json!({"id": 1, "cmd": "identify"}));
    // Well after the owner said ready: the ends run, most still queued.
    std::thread::sleep(Duration::from_millis(1_000));
    let surface = pending_surface(&harness.socket, &content);
    let (response, attached) = attach(&harness.socket, surface);
    assert_eq!(
        response["ok"], true,
        "the attach after ready failed after {attached:?}: its respawn waited behind the \
         queued ends: {response}"
    );
    // Its end (one 200 ms commit) and its launch: well under the 5 s queue.
    assert!(
        attached < Duration::from_millis(2_500),
        "the attach after ready answered after {attached:?}: its respawn waited for the queue"
    );
    let resolved = request(
        &harness.socket,
        serde_json::json!({"cmd": "resolve-terminal", "terminal_id": last}),
    );
    assert_eq!(resolved["lifecycle"], "running", "{resolved}");
}

/// A reboot that also lost the host records (a cleared temporary folder):
/// every row has no record. The start marks them adopting in one commit and
/// ends them after its first answer; a restart while they are still adopting
/// with no record ends them the same way, and every one respawns.
#[test]
fn terminals_with_no_host_record_end_after_the_answer_and_respawn_across_a_restart() {
    const COUNT: usize = 40;
    let (mut harness, records, _last, content) = cold_session("cold-start-no-records", COUNT);
    // A cleared folder takes every file of a host: its record, endpoint,
    // liveness proof and lock. A record deleted alone leaves the endpoint,
    // which the respawned host could not take.
    for (path, record) in &records {
        let _ = fs::remove_file(path);
        let _ = fs::remove_file(&record.endpoint);
        for entry in fs::read_dir(harness.host_root()).unwrap().flatten() {
            if entry.file_name().to_string_lossy().contains(record.terminal_id.as_str()) {
                let _ = fs::remove_file(entry.path());
            }
        }
    }
    // The ends wait long enough for a restart to find every row adopting.
    harness.extra_env.push(("CMUX_TUI_TEST_ADOPTION_DELAY_MS".to_string(), "30000".to_string()));
    harness.restart();
    let listed = request(&harness.socket, serde_json::json!({"cmd": "list-terminals"}));
    let adopting = listed["terminals"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|terminal| terminal["lifecycle"] == "adopting")
        .count();
    assert_eq!(adopting, COUNT, "rows with no record are not adopting: {listed}");
    pending_surface(&harness.socket, &content);
    harness.sigkill();

    harness.extra_env.clear();
    harness.restart();
    wait_all_running(&harness.socket, &records);
}

/// The app attaches while the ends run (after the owner said ready), and
/// each end holds its System lane slot (a debug hook stands in for a slow
/// commit). The lane runs 5 such tries at once, so the queue of 200 ends
/// takes 8 s. The ends start in no set order, so the test attaches to 5
/// terminals that still adopt, at once: each one's end must go first, and
/// then its respawn, so all 5 are live well before the queue reaches them
/// (by chance, all 5 in its first 2.5 s is far below 1 %). Before, every end
/// waited in the lane's own queue, where `Permits::promote` could not reach
/// it, and a respawn queued at a background priority was not raised.
#[test]
fn an_attach_while_the_ends_run_ends_and_respawns_its_terminal_first() {
    const COUNT: usize = 200;
    const ATTACHES: usize = 5;
    let (mut harness, _records, _last, _content) = cold_session("cold-start-end-hold", COUNT);
    harness.extra_env.push(("CMUX_TUI_TEST_END_HOLD_MS".to_string(), "200".to_string()));
    harness.restart();
    // The ends run: the owner said ready and some already committed.
    let deadline = Instant::now() + test_timeout(Duration::from_secs(30));
    loop {
        let listed = request(&harness.socket, serde_json::json!({"cmd": "list-terminals"}));
        let done = listed["terminals"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|terminal| terminal["lifecycle"] != "adopting")
            .count();
        if done >= 10 {
            break;
        }
        assert!(Instant::now() < deadline, "the ends never started: {listed}");
        std::thread::sleep(Duration::from_millis(50));
    }
    let tree = request(&harness.socket, serde_json::json!({"cmd": "list-workspaces"}));
    let targets = tabs(&tree)
        .into_iter()
        .filter(|tab| tab["terminal_state"] == "adopting")
        .filter_map(|tab| {
            Some((tab["surface"].as_u64()?, tab["content_resource_id"].as_str()?.to_owned()))
        })
        .take(ATTACHES)
        .collect::<Vec<_>>();
    assert_eq!(targets.len(), ATTACHES, "too few tabs still pending: {tree}");
    let socket = harness.socket.clone();
    let attaches = targets
        .iter()
        .map(|(surface, _)| {
            let (socket, surface) = (socket.clone(), *surface);
            std::thread::spawn(move || attach(&socket, surface))
        })
        .collect::<Vec<_>>();
    for ((surface, terminal_id), attach) in targets.iter().zip(attaches) {
        let (response, attached) = attach.join().unwrap();
        assert_eq!(
            response["ok"], true,
            "the attach to {surface} while the ends ran failed after {attached:?}: its end or \
             its respawn waited behind the queue: {response}"
        );
        assert!(
            attached < Duration::from_millis(2_500),
            "the attach to {surface} while the ends ran answered after {attached:?}: it waited \
             for the queue"
        );
        let resolved = request(
            &harness.socket,
            serde_json::json!({"cmd": "resolve-terminal", "terminal_id": terminal_id}),
        );
        assert_eq!(resolved["lifecycle"], "running", "{resolved}");
    }
}
