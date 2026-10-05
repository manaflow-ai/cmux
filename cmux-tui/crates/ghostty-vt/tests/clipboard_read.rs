//! Deferred OSC 52 clipboard reads (R92 bug 1, decision
//! CLIPBOARD-READ-BROKER): the session host answers a program's clipboard
//! read only after the viewer's user grants it, so the terminal defers the
//! read and the host completes it later. Reads stay ignored (no reply, as
//! before) until deferral is enabled, which the host does only for an owner
//! that negotiated `clipboard-read-v1`.

use std::sync::{Arc, Mutex};

use ghostty_vt::{Callbacks, ClipboardLocation, ClipboardReadRequest, Terminal, MAX_CLIPBOARD_READ_BYTES};

struct Harness {
    term: Terminal,
    written: Arc<Mutex<Vec<u8>>>,
    reads: Arc<Mutex<Vec<ClipboardReadRequest>>>,
}

impl Harness {
    fn new() -> Self {
        let written = Arc::new(Mutex::new(Vec::new()));
        let reads = Arc::new(Mutex::new(Vec::new()));
        let callbacks = Callbacks {
            on_pty_write: Some(Box::new({
                let written = written.clone();
                move |bytes: &[u8]| written.lock().unwrap().extend_from_slice(bytes)
            })),
            on_clipboard_read: Some(Box::new({
                let reads = reads.clone();
                move |request: ClipboardReadRequest| reads.lock().unwrap().push(request)
            })),
            ..Callbacks::default()
        };
        Self { term: Terminal::new(40, 5, 10_000, callbacks).unwrap(), written, reads }
    }

    fn take_written(&self) -> Vec<u8> {
        std::mem::take(&mut *self.written.lock().unwrap())
    }
}

#[test]
fn reads_are_ignored_until_deferral_is_enabled() {
    let mut h = Harness::new();
    h.term.vt_write(b"\x1b]52;c;?\x07");
    assert!(h.reads.lock().unwrap().is_empty());
    assert!(h.take_written().is_empty());
}

#[test]
fn a_deferred_read_is_answered_later_with_its_selector_and_terminator() {
    let mut h = Harness::new();
    h.term.set_clipboard_reads_deferred(true);
    h.term.vt_write(b"\x1b]52;p;?\x1b\\");
    let request = h.reads.lock().unwrap().pop().expect("the read reaches the host");
    assert_eq!(request.location, ClipboardLocation::Primary);
    assert_ne!(request.token, 0);
    assert!(h.take_written().is_empty(), "nothing is answered before the user decides");

    assert!(h.term.complete_clipboard_read(request.token, Some(b"hi")));
    assert_eq!(h.take_written(), b"\x1b]52;p;aGk=\x1b\\");
    // A token completes once.
    assert!(!h.term.complete_clipboard_read(request.token, Some(b"again")));
    assert!(h.take_written().is_empty());
}

#[test]
fn a_denied_or_oversized_read_answers_an_empty_clipboard() {
    let mut h = Harness::new();
    h.term.set_clipboard_reads_deferred(true);
    h.term.vt_write(b"\x1b]52;c;?\x07\x1b]52;c;?\x07");
    let tokens: Vec<u64> = h.reads.lock().unwrap().iter().map(|request| request.token).collect();
    assert_eq!(tokens.len(), 2);
    assert!(h.term.complete_clipboard_read(tokens[0], None));
    assert_eq!(h.take_written(), b"\x1b]52;c;\x07");
    let huge = vec![b'x'; MAX_CLIPBOARD_READ_BYTES + 1];
    assert!(h.term.complete_clipboard_read(tokens[1], Some(&huge)));
    assert_eq!(h.take_written(), b"\x1b]52;c;\x07", "over the cap the read is denied");
}

#[test]
fn disabling_deferral_stops_new_reads() {
    let mut h = Harness::new();
    h.term.set_clipboard_reads_deferred(true);
    h.term.set_clipboard_reads_deferred(false);
    h.term.vt_write(b"\x1b]52;c;?\x07");
    assert!(h.reads.lock().unwrap().is_empty());
}
