//! cx-6so.49: a terminal survives its host process dying. Behavior at the
//! daemon's socket, under a real daemon:
//!
//! 1. SIGKILL of the host while the shell lives: an attached client keeps
//!    its stream (no `detached`), the terminal keeps its id and incarnation,
//!    and the journal records a `host_reconnect` output gap.
//! 2. Shell and host lost again soon after a respawn: the supervisor
//!    respawns again after its backoff (the old bound refused it and left
//!    "Terminal lost: its host process ended"), each new generation starts
//!    with a `host_respawn` gap, a client re-attaches to the new shell, and
//!    a terminal that uses every attempt ends as `restart_exhausted`.
//! 3. A respawn that a daemon stop cut off runs at the next daemon's start.

use std::io::BufRead as _;

use super::super::reconnect_checkpoints::gap_reasons;
use super::host_replacement::wait_for_daemon_custody;
use super::pty_custody::{kill_shell_then_host, send_line, signal_pid, wait_for_dead_host};
use super::*;

/// Debug builds: the supervisor's backoff schedule (its length is the
/// attempt bound per window).
const BACKOFF_ENV: &str = "CMUX_TUI_TEST_RESPAWN_BACKOFF_MS";

fn start_with_backoff(name: &str, schedule: &str) -> RecoveryHarness {
    let mut harness = RecoveryHarness::start_unstarted(name);
    let mut command = harness.daemon_command();
    command.env(BACKOFF_ENV, schedule);
    harness.child = Some(command.spawn().expect("spawn the daemon"));
    wait_for_socket(&harness.socket);
    harness
}

fn restart_with_backoff(harness: &mut RecoveryHarness, schedule: &str) {
    let mut command = harness.daemon_command();
    command.env(BACKOFF_ENV, schedule);
    harness.child = Some(command.spawn().expect("restart the daemon"));
    wait_for_socket(&harness.socket);
}

fn tab_named(harness: &RecoveryHarness, name: &str) -> serde_json::Value {
    let tree = request(&harness.socket, serde_json::json!({"cmd":"list-workspaces"}));
    tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|workspace| workspace["name"] == name)
        .and_then(first_tab)
        .cloned()
        .unwrap_or_else(|| panic!("workspace {name} has no tab: {tree}"))
}

fn resolve(harness: &RecoveryHarness, terminal_id: &str) -> serde_json::Value {
    request(
        &harness.socket,
        serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
    )
}

/// Wait until `terminal_id` runs an incarnation other than `old`.
fn wait_for_new_incarnation(harness: &RecoveryHarness, terminal_id: &str, old: &str) -> String {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    loop {
        let resolved = resolve(harness, terminal_id);
        let incarnation = resolved["terminal_incarnation"].as_str().unwrap_or_default();
        if resolved["lifecycle"] == "running" && !incarnation.is_empty() && incarnation != old {
            return incarnation.to_string();
        }
        assert!(Instant::now() < deadline, "{terminal_id} was not respawned: {resolved}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn current_host(harness: &RecoveryHarness, terminal_id: &str) -> (PathBuf, TerminalHostRecord) {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        if let Some(found) = load_terminal_host_records(&harness.host_root())
            .unwrap_or_default()
            .into_iter()
            .find(|(path, record)| {
                record.terminal_id == terminal_id
                    && terminal_host_record_liveness(path, record).ok()
                        == Some(TerminalHostLiveness::Live)
            })
        {
            return found;
        }
        assert!(Instant::now() < deadline, "{terminal_id} has no live host record");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// The ids the journal may use as the terminal's subject.
fn subject_ids(harness: &RecoveryHarness, name: &str, terminal_id: &str) -> Vec<String> {
    let tab = tab_named(harness, name);
    [Some(terminal_id), tab["terminal_resource_id"].as_str(), tab["content_resource_id"].as_str()]
        .into_iter()
        .flatten()
        .map(str::to_string)
        .collect()
}

fn gap_count(harness: &RecoveryHarness, ids: &[String], reason: &str) -> usize {
    gap_reasons(&harness.socket)
        .iter()
        .filter(|(subject, gap)| gap == reason && ids.contains(subject))
        .count()
}

/// Wait until the journal holds at least `count` `reason` gaps for `ids`
/// (the gap is enqueued like output, so it can trail the reconnect).
fn wait_for_gaps(harness: &RecoveryHarness, ids: &[String], reason: &str, count: usize) {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    loop {
        let found = gap_count(harness, ids, reason);
        if found >= count {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "{found} {reason} gaps for {ids:?}, want {count}: {:?}",
            gap_reasons(&harness.socket)
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// One `attach-surface` client: its events arrive on a channel.
struct AttachClient {
    events: mpsc::Receiver<serde_json::Value>,
    _writer: Box<dyn transport::Stream>,
}

impl AttachClient {
    fn attach(socket: &Path, surface: u64) -> Self {
        let stream = transport::connect(socket).expect("connect for attach");
        let mut writer = stream.try_clone_box().expect("clone attach stream");
        writeln!(
            writer,
            "{}",
            serde_json::json!({"id":1,"cmd":"attach-surface","surface":surface,"cols":80,"rows":24})
        )
        .expect("send attach-surface");
        let (sender, events) = mpsc::channel();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            while reader.read_line(&mut line).is_ok_and(|read| read > 0) {
                if let Ok(value) = serde_json::from_str::<serde_json::Value>(&line)
                    && sender.send(value).is_err()
                {
                    return;
                }
                line.clear();
            }
        });
        Self { events, _writer: writer }
    }

    /// Wait for `needle` in the client's stream (`vt-state`/`resized`
    /// replays and `output` chunks). Panics on `detached` or a timeout.
    fn wait_for_text(&self, needle: &str) {
        let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
        let mut seen = String::new();
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let event = self
                .events
                .recv_timeout(left)
                .unwrap_or_else(|_| panic!("the client never saw {needle:?}; it saw {seen:?}"));
            assert_ne!(event["event"], "detached", "the client was detached: {event}");
            for field in ["data", "replay"] {
                if let Some(encoded) = event[field].as_str()
                    && let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(encoded)
                {
                    seen.push_str(&String::from_utf8_lossy(&bytes));
                }
            }
            if seen.contains(needle) {
                return;
            }
        }
    }
}

#[test]
fn sigkill_of_a_host_keeps_an_attached_client_streaming_and_records_the_gap() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("supervisor-replace");
    let created = request(
        &harness.socket,
        serde_json::json!({"id":1,"cmd":"run","argv":["/bin/sh"],"new_workspace":true,"name":"kept"}),
    );
    let terminal_id = created["terminal_id"].as_str().expect("terminal id").to_string();
    let incarnation = created["terminal_incarnation"].as_str().expect("incarnation").to_string();
    let surface = created["surface"].as_u64().expect("surface");
    let (record_path, record) = current_host(&harness, &terminal_id);
    let ids = subject_ids(&harness, "kept", &terminal_id);

    let client = AttachClient::attach(&harness.socket, surface);
    send_line(&harness.socket, surface, "echo before-kill-$((6*7))");
    client.wait_for_text("before-kill-42");
    wait_for_daemon_custody(&harness, true);
    let gaps_before = gap_count(&harness, &ids, "host_reconnect");

    signal_pid(record.host_pid, libc::SIGKILL);
    wait_for_dead_host(&record_path, &record);
    let (_, replacement) = current_host(&harness, &terminal_id);
    assert_ne!(replacement.host_pid, record.host_pid, "the dead host still serves");

    // The same client, never re-attached, sees output the shell writes
    // through the replacement host.
    send_line(&harness.socket, surface, "echo after-kill-$((6*8))");
    client.wait_for_text("after-kill-48");
    let resolved = resolve(&harness, &terminal_id);
    assert_eq!(resolved["lifecycle"], "running", "{resolved}");
    assert_eq!(resolved["terminal_incarnation"], incarnation.as_str(), "{resolved}");
    assert_eq!(tab_named(&harness, "kept")["dead"], false);
    wait_for_gaps(&harness, &ids, "host_reconnect", gaps_before + 1);
}

#[test]
fn a_terminal_that_keeps_losing_its_host_respawns_with_backoff_then_stops_with_a_reason() {
    let _exclusive = exclusive_process_test();
    // Three attempts per window: at once, then after 300 ms twice.
    let harness = start_with_backoff("supervisor-backoff", "0,300,300");
    let created =
        request(&harness.socket, serde_json::json!({"id":1,"cmd":"new-workspace","name":"loop"}));
    let surface = created["surface"].as_u64().expect("new-workspace returned no surface");
    let terminal_id =
        tab_named(&harness, "loop")["terminal_id"].as_str().expect("terminal id").to_string();
    let mut incarnation =
        resolve(&harness, &terminal_id)["terminal_incarnation"].as_str().unwrap().to_string();
    let ids = subject_ids(&harness, "loop", &terminal_id);
    send_line(&harness.socket, surface, "echo first-shell-$((5*5))");
    wait_for_screen(&harness.socket, surface, "first-shell-25");

    // Three losses in quick succession: each one respawns (the second and
    // third after the backoff, where the old bound left the tab dead).
    for attempt in 1..=3 {
        let (path, record) = current_host(&harness, &terminal_id);
        kill_shell_then_host(&path, &record);
        incarnation = wait_for_new_incarnation(&harness, &terminal_id, &incarnation);
        let tab = tab_named(&harness, "loop");
        assert_eq!(tab["dead"], false, "attempt {attempt}: {tab}");
        wait_for_gaps(&harness, &ids, "host_respawn", attempt);
        // A client re-attaches to the new shell and sees the old screen and
        // the new shell's own output.
        let surface = tab["surface"].as_u64().expect("the respawned tab has a surface");
        let client = AttachClient::attach(&harness.socket, surface);
        client.wait_for_text("first-shell-25");
        let marker = format!("respawn-{attempt}-ok");
        send_line(&harness.socket, surface, &format!("echo {marker}"));
        client.wait_for_text(&marker);
    }

    // The fourth loss inside the window uses up the attempts: the terminal
    // ends with a reason the app can name, and nothing respawns it.
    let (path, record) = current_host(&harness, &terminal_id);
    kill_shell_then_host(&path, &record);
    let resolved = wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "exited");
    assert_eq!(resolved["terminal_incarnation"], incarnation.as_str(), "{resolved}");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let tab = loop {
        let tab = tab_named(&harness, "loop");
        if tab["end"]["reason"] == "restart_exhausted" {
            break tab;
        }
        assert!(Instant::now() < deadline, "the tab never named restart_exhausted: {tab}");
        std::thread::sleep(Duration::from_millis(25));
    };
    assert_eq!(tab["dead"], true, "{tab}");
    assert_eq!(tab["terminal_state"], "exited", "{tab}");
    assert_eq!(tab["end"]["kind"], "host_lost", "{tab}");
    // Past every backoff: still ended on the same incarnation.
    std::thread::sleep(Duration::from_secs(1));
    let resolved = resolve(&harness, &terminal_id);
    assert_eq!(resolved["lifecycle"], "exited", "{resolved}");
    assert_eq!(resolved["terminal_incarnation"], incarnation.as_str(), "{resolved}");
}

#[test]
fn a_respawn_cut_off_by_a_daemon_stop_runs_at_the_next_start() {
    let _exclusive = exclusive_process_test();
    // The second attempt waits a minute: the daemon stops inside that wait.
    let mut harness = start_with_backoff("supervisor-sweep", "0,60000");
    let created =
        request(&harness.socket, serde_json::json!({"id":1,"cmd":"new-workspace","name":"swept"}));
    let surface = created["surface"].as_u64().expect("new-workspace returned no surface");
    let terminal_id =
        tab_named(&harness, "swept")["terminal_id"].as_str().expect("terminal id").to_string();
    let first =
        resolve(&harness, &terminal_id)["terminal_incarnation"].as_str().unwrap().to_string();
    send_line(&harness.socket, surface, "echo swept-shell-$((4*4))");
    wait_for_screen(&harness.socket, surface, "swept-shell-16");

    let (path, record) = current_host(&harness, &terminal_id);
    kill_shell_then_host(&path, &record);
    let second = wait_for_new_incarnation(&harness, &terminal_id, &first);
    let (path, record) = current_host(&harness, &terminal_id);
    kill_shell_then_host(&path, &record);
    // The loss is committed; the terminal waits out its backoff and its tab
    // never reads dead meanwhile.
    wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "exited");
    let deadline = Instant::now() + Duration::from_millis(500);
    while Instant::now() < deadline {
        let tab = tab_named(&harness, "swept");
        assert_eq!(tab["dead"], false, "a tab in backoff read dead: {tab}");
        std::thread::sleep(Duration::from_millis(50));
    }

    harness.signal_daemon(libc::SIGTERM);
    let mut daemon = harness.child.take().expect("daemon");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while daemon.try_wait().expect("wait for the daemon").is_none() {
        assert!(Instant::now() < deadline, "daemon did not exit after SIGTERM");
        std::thread::sleep(Duration::from_millis(10));
    }
    let _ = fs::remove_file(&harness.socket);
    restart_with_backoff(&mut harness, "0,60000");

    let third = wait_for_new_incarnation(&harness, &terminal_id, &second);
    assert_ne!(third, first);
    let tab = tab_named(&harness, "swept");
    assert_eq!(tab["dead"], false, "{tab}");
    let surface = tab["surface"].as_u64().expect("the respawned tab has a surface");
    send_line(&harness.socket, surface, "echo after-restart-$((3*3))");
    wait_for_screen(&harness.socket, surface, "after-restart-9");
}
