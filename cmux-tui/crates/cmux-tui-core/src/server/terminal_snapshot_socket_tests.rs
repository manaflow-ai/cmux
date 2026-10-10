//! terminal-snapshot-v1 over the raw v12 command path, with a captured
//! connection writer: the stream a client reads.

use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::tests::captured_writer;
use super::super::{BoundedOutbound, ClientTransport, Command, disconnect_client, handle_command};
use crate::{Mux, SurfaceOptions};

fn command(value: Value) -> Command {
    serde_json::from_value(value).expect("raw command")
}

/// The next stream event other than notifications, within `timeout`.
fn next_event(outbound: &BoundedOutbound, timeout: Duration) -> Option<Value> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(message) = outbound.try_pop() {
            let value: Value = serde_json::from_str(&message).expect("outbound JSON");
            if value["event"] != "notification" {
                return Some(value);
            }
            continue;
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

// ---- terminal-snapshot-history-v1 -------------------------------------

/// A surface running `cat` (it prints nothing on its own) whose primary
/// screen holds `lines` lines of scrollback.
fn quiet_surface_with_scrollback(
    session: &str,
    lines: usize,
) -> (std::sync::Arc<Mux>, std::sync::Arc<crate::Surface>) {
    let mux = Mux::new_for_test(
        session,
        SurfaceOptions { command: Some(vec!["cat".to_string()]), ..SurfaceOptions::default() },
    );
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let mut chunk = String::new();
    for line in 0..lines {
        chunk.push_str(&format!(
            "\x1b[32m{line:06}\x1b[0m compiling crate-{} v0.{}.{} (/home/dev/src/project/crates/c{}) in {}ms\r\n",
            line % 977,
            line % 13,
            line % 101,
            line % 31,
            line % 4099
        ));
        if chunk.len() > 1 << 16 {
            surface.inject_output_for_test(chunk.as_bytes());
            chunk.clear();
        }
    }
    surface.inject_output_for_test(chunk.as_bytes());
    (mux, surface)
}

// ---- terminal-snapshot-local-history-v1 -------------------------------

// ---- terminal-snapshot-images-v1 --------------------------------------

fn attach_images_viewer(
    mux: &std::sync::Arc<Mux>,
    surface: &crate::Surface,
    local_history: bool,
) -> (super::super::MessageWriter, std::sync::Arc<BoundedOutbound>, u64) {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    handle_command(
        mux,
        client,
        command(json!({
            "cmd": "attach-surface", "surface": surface.id,
            "snapshot": "ghostsnp", "snapshot_version": ghostty_vt::snapshot_version(),
            "snapshot_images": true, "snapshot_local_history": local_history,
        })),
        &writer,
    )
    .unwrap();
    (writer, outbound, client)
}

/// A 64x64 8-bit RGB PNG (one color), base64.
const PNG_64_RGB_BASE64: &str = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAT0lEQVR42u3PQQkAAAgEsItjJhMbywi+hcEKLFP9WgQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQELgs6CKEtxmKJKgAAAABJRU5ErkJggg==";

// ---- golden contract fixture --------------------------------------------

/// The checked-in host event lines that the Mac decoder test also reads.
const DOGFOOD_PNG_FIXTURE: &str = "spec/fixtures/terminal-snapshot-dogfood-png.jsonl";

/// One snapshot event as a fixture line. Volatile values become fixed
/// placeholders: `surface` (a per-process surface counter) and
/// `marker_epoch` (a process-wide counter) are `0`. Every other field is the
/// host's real value.
fn fixture_line(event: &Value) -> String {
    let mut event = event.clone();
    event["surface"] = json!(0);
    if event.get("marker_epoch").is_some() {
        event["marker_epoch"] = json!(0);
    }
    serde_json::to_string(&event).expect("fixture JSON")
}

/// Golden contract of the S3k dogfood flow: an 80x24 terminal with 40 short
/// lines of scrollback and one 64x64 RGB PNG (`f=100,a=T,c=8,r=4`, no id, no
/// `q`); a plain READY attach with `snapshot_images` and
/// `snapshot_local_history` gets READY, history chunks and images chunks;
/// then a resize to 60x20 gives one local READY. The lines must equal
/// `spec/fixtures/terminal-snapshot-dogfood-png.jsonl`;
/// `CMUX_UPDATE_SNAPSHOT_FIXTURE=1` rewrites the file.
#[test]
fn dogfood_png_snapshot_events_match_the_golden_fixture() {
    let (mux, surface) = quiet_surface_with_scrollback("snapshot-images-fixture", 0);
    for line in 0..40 {
        surface.inject_output_for_test(format!("line {line}\r\n").as_bytes());
    }
    surface.inject_output_for_test(
        format!("\x1b_Gf=100,a=T,c=8,r=4;{PNG_64_RGB_BASE64}\x1b\\\r\nafter\r\n").as_bytes(),
    );
    let (_writer, outbound, client) = attach_images_viewer(&mux, &surface, true);
    let mut lines = Vec::new();
    let ready = next_event(&outbound, Duration::from_secs(10)).expect("ready");
    assert_eq!(ready["phase"], "ready", "{ready}");
    lines.push(fixture_line(&ready));
    loop {
        let event = next_event(&outbound, Duration::from_secs(10)).expect("history or images");
        if event["event"] != "snapshot" {
            continue;
        }
        lines.push(fixture_line(&event));
        if event["phase"] == "images" && event["done"] == true {
            break;
        }
    }
    surface.resize(60, 20).unwrap();
    let local = loop {
        let event = next_event(&outbound, Duration::from_secs(10)).expect("local ready");
        if event["event"] == "snapshot" {
            break event;
        }
    };
    assert_eq!(local["history"], "local", "{local}");
    lines.push(fixture_line(&local));
    disconnect_client(&mux, client, false);
    mux.shutdown();

    let actual = lines.join("\n") + "\n";
    let path =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").join(DOGFOOD_PNG_FIXTURE);
    if std::env::var_os("CMUX_UPDATE_SNAPSHOT_FIXTURE").is_some() {
        std::fs::write(&path, &actual).expect("write the fixture");
        return;
    }
    let expected = std::fs::read_to_string(&path).unwrap_or_default();
    assert!(
        actual == expected,
        "{DOGFOOD_PNG_FIXTURE} differs from the host's events; rerun with \
         CMUX_UPDATE_SNAPSHOT_FIXTURE=1 and review the diff"
    );
}
