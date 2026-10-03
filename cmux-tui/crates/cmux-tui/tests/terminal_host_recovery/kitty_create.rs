//! Creating a terminal never waits for the Kitty image budget. Each power of
//! two of the terminal count changes every terminal's share, and a new
//! terminal is reserved only after the existing ones shrink. Before the Kitty
//! acknowledgement fix (d2d3e80eac9) each shrink waited the 2 s control
//! timeout, so the 3rd, 5th, 9th, 17th and 33rd terminal took about 2.1 s to
//! create and then started with Kitty graphics disabled (GPUI lane defect
//! E2; reproduced with pin f39636c811a, 2.11-2.16 s each).

use super::*;

/// `kitty_graphics_state.image_bytes` from the first `vt-state` event of a
/// byte attach to `surface`.
fn kitty_image_bytes(socket: &Path, surface: u64) -> u64 {
    let stream = transport::connect(socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(
        writer,
        "{}",
        serde_json::json!({"id": 1, "cmd": "attach-surface", "surface": surface, "cols": 80, "rows": 24})
    )
    .unwrap();
    loop {
        let mut line = String::new();
        assert!(reader.read_line(&mut line).unwrap() > 0, "attach ended before vt-state");
        let message: serde_json::Value = serde_json::from_str(&line).unwrap();
        if message["event"] == "vt-state" {
            return message["kitty_graphics_state"]["image_bytes"].as_u64().unwrap();
        }
        assert_ne!(message["ok"], false, "attach failed: {message}");
    }
}

#[test]
fn terminals_created_across_kitty_budget_buckets_start_fast_with_kitty_enabled() {
    const COUNT: usize = 9;
    let harness = RecoveryHarness::start("kitty-create");
    let mut created = Vec::new();
    let mut slowest = (0, Duration::ZERO);
    for index in 0..COUNT {
        let started = Instant::now();
        let reply = request(
            &harness.socket,
            serde_json::json!({
                "id": index + 1,
                "cmd": "run",
                "argv": ["/bin/cat"],
                "new_workspace": true,
                "name": format!("kitty-create-{index}"),
            }),
        );
        if started.elapsed() > slowest.1 {
            slowest = (index + 1, started.elapsed());
        }
        created.push(reply["surface"].as_u64().unwrap());
    }
    assert!(
        slowest.1 < test_timeout(Duration::from_secs(1)),
        "creating terminal #{} took {:?} (a Kitty budget wait)",
        slowest.0,
        slowest.1
    );
    // The bucket-change terminals end with working Kitty limits.
    for nth in [3, 5, 9] {
        let bytes = kitty_image_bytes(&harness.socket, created[nth - 1]);
        assert!(bytes > 0, "terminal #{nth} started with Kitty graphics disabled");
    }
    for (index, surface) in created.into_iter().enumerate() {
        close_terminal_surface(&harness.socket, surface, 100 + index as u64);
    }
    wait_for_no_host_records(&harness.host_root());
}
