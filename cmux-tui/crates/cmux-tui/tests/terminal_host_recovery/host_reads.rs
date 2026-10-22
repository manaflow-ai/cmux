//! The terminal host answers screen reads (perf100 cut 1, the first step of
//! the host owning terminal state). The daemon used to answer `read-screen`
//! from its own mirror, which applies host output in order behind any
//! backlog, so a read showed the screen as it was before that backlog.
//!
//! A debug seam slows every output frame the daemon's mirror applies
//! (CMUX_TUI_TEST_HOSTED_OUTPUT_APPLY_DELAY_MS). With the mirror lagging,
//! `read-screen` still shows what the program just printed, because the
//! host's parser answers.

use super::*;

const MIRROR_DELAY_MS: u64 = 4_000;

#[test]
fn read_screen_comes_from_the_host_ahead_of_a_lagging_mirror() {
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

    let marker = format!("host-reads-{}", std::process::id());
    let line = format!("{marker}\n");
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
}
