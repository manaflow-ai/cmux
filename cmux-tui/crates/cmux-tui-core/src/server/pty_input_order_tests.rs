//! Per-terminal input order: a 1 MiB control `send` (its
//! text, its bytes and its submit Return), typed or pasted, and 1k keys
//! typed on a stream at the same time reach the PTY with no key inside the
//! send.

use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use base64::Engine;
use serde_json::json;

use crate::server::*;

const HALF: usize = 512 * 1024;
const KEYS: usize = 1_000;

/// Every byte the terminal's PTY writer received, in order.
#[derive(Clone, Default)]
struct Recorder(Arc<Mutex<Vec<u8>>>);

impl Write for Recorder {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Recorder {
    fn keys(&self) -> usize {
        self.0.lock().unwrap().iter().filter(|byte| **byte == b'k').count()
    }
}

/// One key of an INPUT frame on the surface's stream, written the way the
/// stream item writes it (`cmd_terminal_io::write_input`):
/// the creating-input flush, then the surface's input write.
fn stream_key(mux: &Arc<Mux>, surface: &Arc<crate::Surface>) {
    mux.wait_for_creating_input_flush(surface);
    surface.write_bytes_flow(b"k", 0).unwrap();
}

#[test]
fn pty_input_order_a_control_send_is_never_interleaved_with_stream_keys() {
    send_with_stream_keys(false);
}

#[test]
fn pty_input_order_a_control_paste_is_never_interleaved_with_stream_keys() {
    send_with_stream_keys(true);
}

/// Sends 1 MiB (`paste` or typed) with its submit Return while a stream
/// types keys, and checks that no key lands between the first byte of the
/// send and its Return.
fn send_with_stream_keys(paste: bool) {
    let mux = Mux::new_for_test("pty-input-order", crate::SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let recorder = Recorder::default();
    surface.replace_input_writer_for_test(Box::new(recorder.clone()));
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    let client = mux.local_test_client(0);

    let sent = Arc::new(AtomicBool::new(false));
    let typist = std::thread::spawn({
        let (mux, surface, sent) = (mux.clone(), surface.clone(), sent.clone());
        move || {
            let mut typed = 0;
            // Types until the send returned and at least 1k keys went in, so
            // keys arrive all through the send.
            while typed < KEYS || !sent.load(Ordering::Acquire) {
                stream_key(&mux, &surface);
                typed += 1;
            }
            typed
        }
    });
    while recorder.keys() == 0 {
        std::thread::yield_now();
    }

    let text = "a".repeat(HALF);
    let bytes = base64::engine::general_purpose::STANDARD.encode(vec![b'b'; HALF]);
    let command = serde_json::from_value::<Command>(json!({
        "cmd": "send",
        "surface": surface.id,
        "text": text,
        "bytes": bytes,
        "paste": paste,
        "submit": true,
    }))
    .unwrap();
    handle_command(&mux, client, command, &writer).unwrap();
    sent.store(true, Ordering::Release);
    let typed = typist.join().unwrap();

    let written = recorder.0.lock().unwrap().clone();
    assert_eq!(written.iter().filter(|byte| **byte == b'k').count(), typed);
    let start = written.iter().position(|byte| *byte == b'a').expect("the send's text");
    let end = written.iter().position(|byte| *byte == b'\r').expect("the send's Return");
    let paste = &written[start..end];
    let keys_inside = paste.iter().filter(|byte| **byte == b'k').count();
    assert_eq!(keys_inside, 0, "{keys_inside} of {typed} stream keys landed inside the send");
    assert_eq!(paste.len(), 2 * HALF);
    assert!(paste[..HALF].iter().all(|byte| *byte == b'a'));
    assert!(paste[HALF..].iter().all(|byte| *byte == b'b'));
    mux.close_surface(surface.id).unwrap();
}
