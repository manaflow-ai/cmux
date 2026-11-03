//! HOT PATH AUDIT B rank 2 (hot-path-audit/terminal/AUDIT.md; ghostty-integration-DESIGN.md G5): a snapshot
//! viewer that asks for binary output (`binary_output: true`, capability `attach-binary-output-v1`) gets each
//! output chunk as one binary frame on its attach connection, never as a JSON line with base64 data.
//!
//! Frame: `0xFF 'C' 'O'`, kind u8 (1 = output), payload length u32 LE, generation u64 LE, stream offset u64 LE
//! (the offset after the payload, as the JSON `offset`), then the raw payload. 0xFF never starts a JSON line
//! (it is not UTF-8), so a reader tells frames from lines by the first byte.
//!
//! The count this test checks is deterministic: wire bytes per output byte, and JSON output lines. Base: every
//! chunk is a JSON line with base64, so the wire carries about 1.37 bytes per output byte and the reader must
//! JSON-decode every output line.

use std::io::{BufRead, BufReader, Read, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};
mod support;
use base64::Engine;
use cmux_tui_core::platform::transport;
use cmux_tui_core::{Mux, SurfaceOptions};

const FRAME_HEADER: usize = 24;
const FLOOD: usize = 256 * 1024;
const END: &[u8] = b"END-OF-FLOOD";

fn unique_session(prefix: &str) -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    format!("{prefix}-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed))
}

#[derive(Default)]
struct OutputCount {
    payload: Vec<u8>,
    wire_bytes: usize,
    binary_frames: usize,
    json_output_lines: usize,
}

/// Reads one item (a binary frame or a JSON line) and counts it when it is terminal output.
/// Returns false at EOF or on a read timeout.
fn read_item(reader: &mut BufReader<Box<dyn transport::Stream>>, count: &mut OutputCount) -> bool {
    let first = match reader.fill_buf() {
        Ok([]) => return false,
        Ok(buf) => buf[0],
        Err(_) => return false,
    };
    if first == 0xFF {
        let mut header = [0u8; FRAME_HEADER];
        reader.read_exact(&mut header).expect("frame header");
        assert_eq!(&header[..3], b"\xFFCO", "frame magic");
        let len = u32::from_le_bytes(header[4..8].try_into().unwrap()) as usize;
        let mut payload = vec![0u8; len];
        reader.read_exact(&mut payload).expect("frame payload");
        if header[3] == 1 {
            count.wire_bytes += FRAME_HEADER + len;
            count.binary_frames += 1;
            count.payload.extend_from_slice(&payload);
        }
        return true;
    }
    let mut line = String::new();
    match reader.read_line(&mut line) {
        Ok(0) | Err(_) => return false,
        Ok(_) => {}
    }
    let value: serde_json::Value = serde_json::from_str(&line).expect("JSON line");
    if value["event"] == "output" {
        count.wire_bytes += line.len();
        count.json_output_lines += 1;
        let data = base64::engine::general_purpose::STANDARD
            .decode(value["data"].as_str().expect("output data"))
            .expect("base64");
        count.payload.extend_from_slice(&data);
    }
    true
}

#[test]
fn a_binary_output_viewer_gets_raw_frames_with_one_wire_byte_per_output_byte() {
    // The flood starts after the attach (the sleep), so it reaches the viewer as live output, not in the READY.
    let script = format!(
        "sleep 1; head -c {FLOOD} /dev/zero | tr '\\000' x; printf '\\n{}\\n'; sleep 600",
        std::str::from_utf8(END).unwrap()
    );
    let options = SurfaceOptions {
        command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), script]),
        ..Default::default()
    };
    let mux = Mux::new(unique_session("attach-binary"), options);
    let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    let stream = transport::connect(&sock_path).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(
        writer,
        "{}",
        serde_json::json!({
            "id": 1, "cmd": "attach-surface", "surface": surface.id,
            "snapshot": "ghostsnp", "snapshot_version": ghostty_vt::snapshot_version(),
            "binary_output": true,
        })
    )
    .unwrap();

    let mut count = OutputCount::default();
    let deadline = Instant::now() + Duration::from_secs(60);
    while Instant::now() < deadline && !count.payload.windows(END.len()).any(|w| w == END) {
        if !read_item(&mut reader, &mut count) {
            break;
        }
    }
    let shown = count.payload.windows(END.len()).any(|w| w == END);
    mux.close_surface(surface.id).unwrap();
    cmux_tui_core::server::cleanup(&sock_path);

    assert!(
        shown,
        "the flood's end marker never reached the viewer ({} output bytes)",
        count.payload.len()
    );
    let output = count.payload.len();
    let per_byte = count.wire_bytes as f64 / output as f64;
    assert_eq!(
        count.json_output_lines, 0,
        "output came as {} JSON lines (base64): {:.3} wire bytes per output byte for {output} bytes",
        count.json_output_lines, per_byte
    );
    assert_eq!(
        count.wire_bytes,
        output + FRAME_HEADER * count.binary_frames,
        "a binary frame carries its header and the raw payload only"
    );
}
