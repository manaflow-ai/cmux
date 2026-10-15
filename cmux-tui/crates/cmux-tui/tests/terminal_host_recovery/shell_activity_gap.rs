//! cx-6so.61: the shell facts of `terminal-activity-v1` stay right when the
//! daemon's link to a live terminal host breaks, and when a dead host is
//! replaced on the same shell.
//!
//! - A reconnect restores the host's OSC 133 state. A command that ended
//!   while the daemon had no link (only `133;D`, no new prompt) must still
//!   reach subscribers as a change, or they keep showing it running.
//! - A replacement host starts with the owner's state, so the command still
//!   reads running after the rehost and after a later daemon restart.

use super::host_replacement::{wait_for_daemon_custody, wait_for_replacement};
use super::pty_custody::{signal_pid, wait_for_dead_host};
use super::*;
use crate::shell_activity_restart::{close, terminal_extra, wait_for_extra};

/// More than the host's 8 MiB queued-output budget for the daemon's tap, so
/// the host closes the tap of a stopped daemon and the daemon must reconnect.
const FLOOD_BYTES: usize = 12_000_000;

/// A `session.events` subscription; its lines arrive on the receiver. The
/// returned writer keeps the stream's connection open.
fn session_events(socket: &Path) -> (impl Sized + use<>, mpsc::Receiver<String>) {
    let stream = transport::connect(socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stream).lines() {
            let Ok(line) = line else { break };
            if sender.send(line).is_err() {
                break;
            }
        }
    });
    writeln!(
        writer,
        "{}",
        serde_json::json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": "shell-activity-gap-events",
            "operation": "session.events",
            "params": {
                "machine": "current",
                "session": "current",
                "stream_id": "stream_33333333333343338333333333333333",
            },
        })
    )
    .unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let remaining =
            deadline.checked_duration_since(Instant::now()).expect("no session.events reply");
        let line = receiver.recv_timeout(remaining).expect("no session.events reply");
        let message: serde_json::Value = serde_json::from_str(&line).unwrap();
        if message["id"] == "shell-activity-gap-events" {
            assert_eq!(message["ok"], true, "session.events failed: {message}");
            return (writer, receiver);
        }
    }
}

/// The values of the running terminal's upserts in the delta items that
/// arrive within `within`, until one satisfies `done`.
fn wait_for_terminal_upsert(
    events: &mpsc::Receiver<String>,
    within: Duration,
    done: impl Fn(&serde_json::Value) -> bool,
) -> Result<serde_json::Value, Vec<serde_json::Value>> {
    let deadline = Instant::now() + within;
    let mut seen = Vec::new();
    while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
        let Ok(line) = events.recv_timeout(remaining) else { break };
        let message: serde_json::Value = serde_json::from_str(&line).unwrap();
        let item = &message["item"];
        if message["type"] != "stream_item" || item["kind"] != "delta" {
            continue;
        }
        for change in item["changes"].as_array().into_iter().flatten() {
            // A record published while the link is down is `adopting` and
            // carries no shell facts at all: only a running one tells.
            if change["kind"] != "upsert"
                || change["resource"] != "terminal"
                || change["value"]["running"] != true
            {
                continue;
            }
            if done(&change["value"]) {
                return Ok(change["value"].clone());
            }
            seen.push(change["value"].clone());
        }
    }
    Err(seen)
}

#[test]
fn shell_activity_survives_a_reconnect_that_missed_the_command_end() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("shell-activity-gap");
    let trigger = harness.dir.join("finish");
    let finished = harness.dir.join("finished");
    // A command runs; on the trigger it floods past the tap budget, then
    // ends with `133;D` and no new prompt (`133;A`).
    let script = format!(
        "printf '\\033]133;A\\007\\033]133;C\\007started\\r\\n'; \
         while [ ! -e '{}' ]; do sleep 0.05; done; head -c {FLOOD_BYTES} /dev/zero; \
         printf '\\033]133;D;0\\007'; : > '{}'; exec sleep 600",
        trigger.display(),
        finished.display()
    );
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/sh", "-c", script],
            "new_workspace": true,
            "name": "shell-activity-gap",
            "cols": 80,
            "rows": 8,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    assert!(wait_for_screen(&harness.socket, surface, "started").contains("started"));
    wait_for_extra(&harness, "a running command", |extra| extra["activity"]["state"] == "running");
    wait_for_host_records(&harness.host_root(), 1);
    let (_events_stream, events) = session_events(&harness.socket);
    let before_revision = request(
        &harness.socket,
        serde_json::json!({"id": 2, "cmd": "list-terminals"}),
    )["terminal_revision"]
        .as_u64()
        .unwrap();

    // Freeze only the daemon: the host keeps reading the PTY, sees the
    // command end, and closes the daemon's overfull tap.
    harness.signal_daemon(libc::SIGSTOP);
    fs::write(&trigger, b"").unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(60));
    while !finished.exists() {
        if Instant::now() >= deadline {
            harness.signal_daemon(libc::SIGCONT);
            panic!("the command did not finish its output flood");
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    // The host parses the PTY's last bytes (the `133;D`) before the daemon
    // can ask for a snapshot.
    std::thread::sleep(Duration::from_millis(500));
    while events.try_recv().is_ok() {}
    harness.signal_daemon(libc::SIGCONT);

    let ended = wait_for_terminal_upsert(&events, test_timeout(Duration::from_secs(20)), |value| {
        value["extra"].get("activity").is_none()
    });

    // The daemon reconnected to its live host (not a plain read of the
    // stream it had).
    let deadline = Instant::now() + test_timeout(Duration::from_secs(30));
    loop {
        let terminal_events = request(
            &harness.socket,
            serde_json::json!({"id": 3, "cmd": "terminal-events", "after_revision": before_revision}),
        );
        if terminal_events["events"]
            .as_array()
            .unwrap()
            .iter()
            .any(|event| event["kind"] == "terminal-ready")
        {
            break;
        }
        assert!(Instant::now() < deadline, "the daemon never reconnected: {terminal_events}");
        std::thread::sleep(Duration::from_millis(50));
    }
    let extra = terminal_extra(&harness);
    assert!(extra.get("activity").is_none(), "the ended command still runs: {extra}");
    match ended {
        Ok(value) => assert!(value["extra"].get("busy").is_none(), "{value}"),
        Err(seen) => panic!(
            "subscribers never learned that the command ended during the link gap; \
             running upserts after the reconnect: {seen:?}"
        ),
    }
    close(&harness, terminal_id, incarnation);
}

#[test]
fn shell_activity_survives_a_host_replacement_then_a_daemon_restart() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("shell-activity-rehost");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": [
                "/bin/sh",
                "-c",
                "printf '\\033]133;A\\007\\033]133;C\\007started\\r\\n'; sleep 600",
            ],
            "new_workspace": true,
            "name": "shell-activity-rehost",
            "cols": 80,
            "rows": 8,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    assert!(wait_for_screen(&harness.socket, surface, "started").contains("started"));
    let before = wait_for_extra(&harness, "a running command", |extra| {
        extra["activity"]["state"] == "running"
    });
    let since = before["activity"]["since_ms"].clone();
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    wait_for_daemon_custody(&harness, true);

    // The host dies under the running daemon, which replaces it on the
    // same shell; the command prints nothing more.
    signal_pid(record.host_pid, libc::SIGKILL);
    wait_for_dead_host(&record_path, &record);
    let replacement = wait_for_replacement(&harness, &record);
    assert_eq!(replacement.incarnation, incarnation);
    // Typed text the terminal echoes back reaches the daemon only through
    // the replacement host: the reconnect to it is done.
    request(
        &harness.socket,
        serde_json::json!({"id": 2, "cmd": "send", "surface": surface, "text": "rehosted"}),
    );
    assert!(wait_for_screen(&harness.socket, surface, "rehosted").contains("rehosted"));
    let rehosted = terminal_extra(&harness);
    assert_eq!(
        rehosted["activity"]["state"], "running",
        "the rehost ended the command: {rehosted}"
    );
    assert_eq!(rehosted["activity"]["since_ms"], since, "{rehosted}");

    // The next daemon adopts the replacement host, which kept the state.
    harness.sigkill();
    harness.restart();
    let resolved = wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "running");
    assert_eq!(resolved["terminal_incarnation"], incarnation.as_str(), "{resolved}");
    let after = wait_for_extra(&harness, "a running command after the restart", |extra| {
        extra["activity"]["state"] == "running"
    });
    assert_eq!(after["activity"]["since_ms"], since, "{after}");
    close(&harness, terminal_id, incarnation);
}
