//! The terminal host answers screen reads and reports title, directory and
//! bell itself (perf100 cut 1, step one of the host owning terminal state:
//! plans in /tmp/perf100/tui/terminal-state-design.md). The daemon used to
//! answer `read-screen` from its own mirror, which applies host output in
//! order behind any backlog, and to derive title, directory and bell from
//! that mirror per output chunk.
//!
//! A debug seam slows every output frame the daemon's mirror applies
//! (CMUX_TUI_TEST_HOSTED_OUTPUT_APPLY_DELAY_MS). With the mirror lagging,
//! `read-screen` still shows what the program just printed, because the
//! host's parser answers; and a title, a directory (OSC 7) and a bell set
//! by the program still reach the tree and the event stream exactly once.

use super::*;

const MIRROR_DELAY_MS: u64 = 4_000;

#[test]
fn read_screen_comes_from_the_host_and_metadata_still_arrives_once() {
    let mut harness = RecoveryHarness::start_unstarted("host-reads");
    harness.extra_env.push((
        "CMUX_TUI_TEST_HOSTED_OUTPUT_APPLY_DELAY_MS".into(),
        MIRROR_DELAY_MS.to_string(),
    ));
    harness.restart();
    let created = request(
        &harness.socket,
        serde_json::json!({"id": 1, "cmd": "run", "argv": ["/bin/cat"], "new_workspace": true}),
    );
    let surface = created["surface"].as_u64().unwrap();
    let (events, _subscription) = subscribe_events(&harness.socket);

    // The program prints a title, a directory, a bell and a marker in one
    // write (cat echoes the line back as output).
    let marker = format!("host-reads-{}", std::process::id());
    let line = format!(
        "\u{1b}]0;HostTitle\u{7}\u{1b}]7;file://localhost/tmp/host-reads\u{7}\u{7}{marker}\n"
    );
    request(
        &harness.socket,
        serde_json::json!({"id": 2, "cmd": "send", "surface": surface, "text": line}),
    );
    let started = Instant::now();
    // Well before the mirror applies it, the screen shows the marker.
    let deadline = started + Duration::from_millis(MIRROR_DELAY_MS / 2);
    let shown = loop {
        let text = request(
            &harness.socket,
            serde_json::json!({"id": 3, "cmd": "read-screen", "surface": surface}),
        )["text"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        if text.contains(&marker) {
            break started.elapsed();
        }
        assert!(
            Instant::now() < deadline,
            "read-screen did not show the marker before the mirror applied it: {text:?}"
        );
        std::thread::sleep(Duration::from_millis(25));
    };
    eprintln!("host-reads: marker on screen after {shown:?} (mirror delay {MIRROR_DELAY_MS} ms)");

    // Title, directory and bell arrive once each (from the host's frames).
    let deadline = Instant::now() + test_timeout(Duration::from_secs(20));
    let (mut titles, mut bells, mut directory) = (0, 0, false);
    while Instant::now() < deadline && !(titles >= 1 && bells >= 1 && directory) {
        let Ok(event) = events.recv_timeout(Duration::from_millis(200)) else { continue };
        if event["surface"].as_u64() != Some(surface) {
            continue;
        }
        match event["event"].as_str() {
            Some("title-changed") if event["title"] == "HostTitle" => titles += 1,
            Some("bell") => bells += 1,
            _ => {}
        }
        let tree = request(&harness.socket, serde_json::json!({"id": 4, "cmd": "list-workspaces"}));
        directory |= tree.to_string().contains("/tmp/host-reads");
    }
    // Let a duplicate (mirror and host both reporting) show up.
    let settle = Instant::now() + Duration::from_millis(MIRROR_DELAY_MS + 1_000);
    while Instant::now() < settle {
        let Ok(event) = events.recv_timeout(Duration::from_millis(200)) else { continue };
        if event["surface"].as_u64() != Some(surface) {
            continue;
        }
        match event["event"].as_str() {
            Some("title-changed") if event["title"] == "HostTitle" => titles += 1,
            Some("bell") => bells += 1,
            _ => {}
        }
    }
    assert_eq!(titles, 1, "the title changed once");
    assert_eq!(bells, 1, "the bell rang once");
    assert!(directory, "the directory reached the tree");
}

/// The event stream, one parsed line per message (the subscription stays
/// open while the second value lives).
fn subscribe_events(
    socket: &Path,
) -> (mpsc::Receiver<serde_json::Value>, Box<dyn transport::Stream>) {
    let stream = transport::connect(socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    writeln!(writer, "{}", serde_json::json!({"id": 99, "cmd": "subscribe"})).unwrap();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        while reader.read_line(&mut line).map(|n| n > 0).unwrap_or(false) {
            if let Ok(value) = serde_json::from_str::<serde_json::Value>(&line)
                && tx.send(value).is_err()
            {
                return;
            }
            line.clear();
        }
    });
    (rx, writer)
}
