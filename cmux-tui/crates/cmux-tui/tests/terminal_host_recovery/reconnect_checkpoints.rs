//! A wave of terminal-host reconnects must not capture one full-session
//! journal checkpoint per reconnect (nx-scale step 1). Each capture is O(N)
//! terminals under the registry lock, so a wave of N reconnects cost O(N^2)
//! and stalled the daemon near 1,024 terminals. A reconnect records a
//! `terminal.output.gap` (reason `host_reconnect`) in its terminal lane; the
//! journal retention worker coalesces the wave into one checkpoint.

use super::*;

const WAVE: usize = 6;
/// Bytes each terminal writes while the daemon is stopped: more than the
/// host's 8 MiB queued-output budget for the daemon's admin tap, so the host
/// closes that tap and the daemon must reconnect.
const FLOOD_BYTES: usize = 12_000_000;

fn start_wave_harness() -> RecoveryHarness {
    let mut harness = RecoveryHarness::start_unstarted("reconnect-wave");
    let mut command = harness.daemon_command();
    // Debug builds: one coalesced checkpoint per 4 s at most.
    command.env("CMUX_TUI_TEST_JOURNAL_CHECKPOINT_INTERVAL_MS", "4000");
    harness.child = Some(command.spawn().unwrap());
    wait_for_socket(&harness.socket);
    harness
}

fn checkpoint_count(socket: &Path, id: &str) -> usize {
    let listed = resource_request(
        socket,
        id,
        "session.journal.checkpoint.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    listed["checkpoints"].as_array().map_or(0, Vec::len)
}

/// Every `terminal.output.gap` record from the beginning of the journal as
/// (terminal subject, reason), read from a subscription until no record
/// arrives for two seconds.
pub(super) fn gap_reasons(socket: &Path) -> Vec<(String, String)> {
    let stream = transport::connect(socket).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(
        writer,
        "{}",
        serde_json::json!({
            "protocol":"cmux.protocol/2",
            "type":"request",
            "id":"reconnect-gaps",
            "operation":"session.journal.subscribe",
            "params":{
                "machine":"current",
                "session":"current",
                "stream_id":"stream_22222222222242228222222222222222",
                "start":"beginning",
                "filter":{"kinds":["terminal.output.gap"],"max_sensitivity":"sensitive"},
            },
        })
    )
    .unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let opened: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(opened["ok"], true, "journal subscription failed: {opened}");
    let mut gaps = Vec::new();
    loop {
        line.clear();
        if reader.read_line(&mut line).is_err() || line.is_empty() {
            break;
        }
        let envelope: serde_json::Value = serde_json::from_str(&line).unwrap();
        let record = &envelope["item"];
        let terminal = record["subjects"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|subject| subject["kind"] == "terminal")
            .and_then(|subject| subject["id"].as_str())
            .unwrap_or_default()
            .to_string();
        let reason = record["payload"]["reason"].as_str().unwrap_or_default().to_string();
        gaps.push((terminal, reason));
    }
    gaps
}

#[test]
fn reconnect_wave_records_gaps_and_coalesces_into_one_checkpoint() {
    let _exclusive = exclusive_process_test();
    let harness = start_wave_harness();
    let trigger = harness.dir.join("flood");
    let mut created = Vec::new();
    for index in 0..WAVE {
        let done = harness.dir.join(format!("flooded-{index}"));
        let script = format!(
            "while [ ! -e '{}' ]; do sleep 0.05; done; head -c {FLOOD_BYTES} /dev/zero; \
             : > '{}'; exec cat",
            trigger.display(),
            done.display()
        );
        let run = request(
            &harness.socket,
            serde_json::json!({
                "id":1,"cmd":"run","argv":["/bin/sh","-c",script],"new_workspace":true,
                "cols":80,"rows":24,
            }),
        );
        created.push((
            run["surface"].as_u64().unwrap(),
            run["terminal_id"].as_str().unwrap().to_string(),
            done,
        ));
    }
    wait_for_host_records(&harness.host_root(), WAVE);
    // A launch can resync its host once (defaults changed while it was being
    // installed), which takes the same reconnect path. Let those settle, so
    // the count below is the wave's own.
    std::thread::sleep(Duration::from_secs(6));
    let before_revision = request(
        &harness.socket,
        serde_json::json!({"id":2,"cmd":"list-terminals"}),
    )["terminal_revision"]
        .as_u64()
        .unwrap();
    let before = checkpoint_count(&harness.socket, "checkpoints-before");

    // Freeze only the daemon. Every host keeps reading its PTY, overflows the
    // daemon tap's queued-output budget, and closes that tap.
    harness.signal_daemon(libc::SIGSTOP);
    fs::write(&trigger, b"").unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(60));
    while created.iter().any(|(_, _, done)| !done.exists()) {
        if Instant::now() >= deadline {
            harness.signal_daemon(libc::SIGCONT);
            panic!("the terminals did not finish their output flood");
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    harness.signal_daemon(libc::SIGCONT);

    // Each terminal reconnects to its live host: adopting, then ready.
    let deadline = Instant::now() + test_timeout(Duration::from_secs(30));
    loop {
        let events = request(
            &harness.socket,
            serde_json::json!({"id":3,"cmd":"terminal-events","after_revision":before_revision}),
        );
        let ready = events["events"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|event| event["kind"] == "terminal-ready")
            .count();
        if ready >= WAVE {
            break;
        }
        assert!(Instant::now() < deadline, "the reconnect wave did not complete: {events}");
        std::thread::sleep(Duration::from_millis(50));
    }

    // One coalesced checkpoint covers the wave, not one per reconnect.
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    while checkpoint_count(&harness.socket, "checkpoints-wait") == before {
        assert!(Instant::now() < deadline, "no checkpoint covered the reconnect wave");
        std::thread::sleep(Duration::from_millis(100));
    }
    std::thread::sleep(Duration::from_millis(1500));
    // A loaded host can spread the wave so that one straggler gets the next
    // interval's checkpoint; one capture per reconnect is the bug.
    let checkpoints = checkpoint_count(&harness.socket, "checkpoints-after") - before;
    assert!(
        checkpoints <= 2,
        "a wave of {WAVE} host reconnects must coalesce, got {checkpoints} checkpoints"
    );

    // Every reconnect left durable evidence of its no-tap interval. A launch
    // resync may add earlier gaps; the wave reconnected all terminals.
    let gaps = gap_reasons(&harness.socket);
    let reconnected = gaps
        .iter()
        .filter(|(_, reason)| reason == "host_reconnect")
        .map(|(terminal, _)| terminal.as_str())
        .collect::<std::collections::HashSet<_>>();
    assert_eq!(
        reconnected.len(),
        WAVE,
        "every reconnected terminal needs a host_reconnect gap record: {gaps:?}"
    );

    // A coalesced checkpoint follows every gap, so the tail becomes
    // reducible within one interval.
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let preview = resource_request(
            &harness.socket,
            "reconnect-preview",
            "session.journal.restore.preview",
            serde_json::json!({"machine":"current","session":"current","checkpoint":"latest"}),
            None,
        );
        if preview["fully_reducible"] == true {
            break;
        }
        assert!(Instant::now() < deadline, "no checkpoint covered every gap: {preview}");
        std::thread::sleep(Duration::from_millis(200));
    }

    for (index, (surface, _, _)) in created.iter().enumerate() {
        close_terminal_surface(&harness.socket, *surface, 10 + index as u64);
    }
    wait_for_no_host_records(&harness.host_root());
}
