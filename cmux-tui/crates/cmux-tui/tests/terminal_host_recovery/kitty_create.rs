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

/// A 64x64 8-bit RGB PNG (one color), base64.
const PNG_64_RGB_BASE64: &str = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAT0lEQVR42u3PQQkAAAgEsItjJhMbywi+hcEKLFP9WgQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQELgs6CKEtxmKJKgAAAABJRU5ErkJggg==";

/// S3k dogfood flow on a hosted terminal (the app's terminals): the PTY child
/// prints 400 short lines and one PNG transmission (`f=100,a=T,c=8,r=4`, no
/// id, no `q`). A snapshot viewer with `snapshot_images` then gets READY,
/// history and an images phase that recreates the image.
#[test]
fn a_hosted_png_reaches_a_snapshot_images_viewer() {
    let harness = RecoveryHarness::start("kitty-snapshot-images");
    let script = format!(
        "i=0; while [ $i -lt 400 ]; do echo \"line $i\"; i=$((i+1)); done; \
         printf '\\033_Gf=100,a=T,c=8,r=4;%s\\033\\\\' '{PNG_64_RGB_BASE64}'; \
         echo IMAGE-PRINTED; exec cat"
    );
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1, "cmd": "run", "argv": ["/bin/sh", "-c", script],
            "new_workspace": true, "name": "kitty-snapshot-images",
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let screen = wait_for_screen(&harness.socket, surface, "IMAGE-PRINTED");
    assert!(screen.contains("IMAGE-PRINTED"), "{screen}");

    let stream = transport::connect(&harness.socket).unwrap();
    stream.set_read_timeout(Some(test_timeout(Duration::from_secs(10)))).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    let identity =
        stream_request(&mut writer, &mut reader, serde_json::json!({"id": 2, "cmd": "identify"}));
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == "terminal-snapshot-images-v1"),
        "{identity}"
    );
    writeln!(
        writer,
        "{}",
        serde_json::json!({
            // The app's attach: its own size and local history as well.
            "id": 3, "cmd": "attach-surface", "surface": surface, "cols": 100, "rows": 30,
            "snapshot": "ghostsnp", "snapshot_version": ghostty_vt::snapshot_version(),
            "snapshot_images": true, "snapshot_local_history": true,
        })
    )
    .unwrap();
    let (mut ready, mut history_done, mut images) = (None::<serde_json::Value>, false, Vec::new());
    loop {
        let mut line = String::new();
        let read = reader.read_line(&mut line);
        assert!(
            read.as_ref().is_ok_and(|bytes| *bytes > 0),
            "stream ended or timed out: ready={} history_done={history_done} images={} ({read:?})",
            ready.is_some(),
            images.len()
        );
        let message: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_ne!(message["ok"], false, "attach failed: {message}");
        if message["event"] != "snapshot" {
            continue;
        }
        match message["phase"].as_str() {
            Some("ready") => {
                assert!(ready.is_none(), "a second READY: {message}");
                ready = Some(message);
            }
            Some("history") => history_done = message["done"] == true,
            Some("images") => {
                assert!(history_done, "images before the history ended");
                let data = message["data"].as_str().unwrap();
                images.extend(base64::engine::general_purpose::STANDARD.decode(data).unwrap());
                if message["done"] == true {
                    break;
                }
            }
            other => panic!("unexpected snapshot phase {other:?}: {message}"),
        }
    }
    let mut viewer =
        ghostty_vt::Terminal::new(80, 24, 1_000, ghostty_vt::Callbacks::default()).unwrap();
    viewer.apply_kitty_replay(&images).unwrap();
    let shown = viewer.kitty_graphics_snapshot().unwrap();
    assert_eq!(shown.images.len(), 1, "the images phase recreates the PNG image");
    assert_eq!((shown.images[0].width, shown.images[0].height), (64, 64));
    drop(writer);
    close_terminal_surface(&harness.socket, surface, 4);
    wait_for_no_host_records(&harness.host_root());
}
