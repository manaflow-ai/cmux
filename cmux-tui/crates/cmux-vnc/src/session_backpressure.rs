use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};

struct PausedWriter {
    bytes: Arc<Mutex<Vec<u8>>>,
    started: Option<mpsc::SyncSender<()>>,
    resume: Receiver<()>,
}

impl Write for PausedWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if let Some(started) = self.started.take() {
            started.send(()).unwrap();
            self.resume.recv_timeout(Duration::from_secs(10)).unwrap();
        }
        self.bytes.lock().unwrap().extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[test]
fn saturated_paste_backpressures_source_and_keeps_refresh_and_input_ordered() {
    let written = Arc::new(Mutex::new(Vec::new()));
    let (started_tx, started_rx) = mpsc::sync_channel(1);
    let (resume_tx, resume_rx) = mpsc::sync_channel(1);
    let closed = Arc::new(AtomicUsize::new(0));
    let on_close = closed.clone();
    let unblock = resume_tx.clone();
    let input = Input::spawn(
        Box::new(PausedWriter {
            bytes: written.clone(),
            started: Some(started_tx),
            resume: resume_rx,
        }),
        Closer::new(move || {
            on_close.fetch_add(1, Ordering::SeqCst);
            let _ = unblock.try_send(());
        }),
    )
    .unwrap();
    let text = "é".repeat(9_000);
    input.paste(text.clone()).unwrap();
    started_rx.recv_timeout(Duration::from_secs(10)).unwrap();
    assert!(!input.has_capacity(4), "one in-flight paste pauses further source reads");
    for index in 0..WRITE_QUEUE {
        input.key(index as u32, true).unwrap();
    }
    assert!(!input.has_capacity(1));
    assert!(
        matches!(input.key(999_999, true), Err(VncError::Io(error)) if error.kind() == io::ErrorKind::WouldBlock)
    );
    assert_eq!(closed.load(Ordering::SeqCst), 0, "full admission must not cancel accepted input");

    // Thousands of automatic refresh requests occupy one side slot. A full
    // refresh stays full even when subsequent incremental requests arrive.
    input.refresh(800, 600).unwrap();
    for _ in 0..WRITE_QUEUE * 2 {
        input.request_frame(true, 640, 480).unwrap();
    }
    assert!(!input.has_capacity(1));
    let (room_tx, room_rx) = mpsc::sync_channel(1);
    input.set_capacity_notifier(move || {
        let _ = room_tx.try_send(());
    });
    let (blocked_tx, blocked_rx) = mpsc::sync_channel(1);
    let (done_tx, done_rx) = mpsc::sync_channel(1);
    let producer = input.clone();
    let source = thread::spawn(move || {
        assert!(!producer.has_capacity(1));
        blocked_tx.send(()).unwrap();
        // Same source-admission contract as the viewer: retain the current
        // event and read no later input until the writer reports room.
        for index in 0..WRITE_QUEUE * 2 {
            while !producer.has_capacity(1) {
                room_rx.recv_timeout(Duration::from_secs(10)).unwrap();
            }
            producer.key((index + WRITE_QUEUE) as u32, false).unwrap();
        }
        done_tx.send(()).unwrap();
    });
    blocked_rx.recv_timeout(Duration::from_secs(10)).unwrap();
    assert!(matches!(done_rx.try_recv(), Err(mpsc::TryRecvError::Empty)));
    resume_tx.send(()).unwrap();
    done_rx.recv_timeout(Duration::from_secs(10)).unwrap();
    source.join().unwrap();
    input.close_after_pending(Duration::from_secs(10));
    assert_eq!(closed.load(Ordering::SeqCst), 1);

    let mut expected = Vec::new();
    for (index, c) in text.chars().enumerate() {
        if index == 1_024 {
            // A refresh may pass between complete key pairs, never inside
            // the clipboard body or between the paste and its trailing keys.
            expected.extend(message::update_request(false, &Rect::new(0, 0, 640, 480)));
        }
        let keysym = crate::keysym::char_keysym(c);
        expected.extend(message::key_event(keysym, true));
        expected.extend(message::key_event(keysym, false));
    }
    expected.extend(message::client_cut_text(&to_latin1(&text)));
    for index in 0..WRITE_QUEUE {
        expected.extend(message::key_event(index as u32, true));
    }
    for index in 0..WRITE_QUEUE * 2 {
        expected.extend(message::key_event((index + WRITE_QUEUE) as u32, false));
    }
    assert_eq!(*written.lock().unwrap(), expected);
}

#[test]
fn refresh_retains_its_place_before_later_input() {
    // Hold the writer before its first dequeue, reproducing the schedule where
    // the reader requests another frame and the UI queues a key immediately.
    let queue = InputQueue::default();
    let first = message::key_event(1, true);
    let later = message::key_event(2, true);
    {
        let mut state = queue.state.lock().unwrap();
        state.pending.push_back(PendingInput::Bytes(first.clone()));
        state.refresh = Some((false, 640, 480));
        state.refresh_ahead = state.pending.len();
        state.pending.push_back(PendingInput::Bytes(later.clone()));
    }
    for expected in [first, message::update_request(false, &Rect::new(0, 0, 640, 480)), later] {
        let Some(PendingInput::Bytes(actual)) = queue.next() else {
            panic!("expected queued bytes");
        };
        assert_eq!(actual, expected);
    }
}

#[test]
fn coalesced_refresh_neither_overtakes_earlier_keys_nor_follows_later_keys() {
    let written = Arc::new(Mutex::new(Vec::new()));
    let (started_tx, started_rx) = mpsc::sync_channel(1);
    let (resume_tx, resume_rx) = mpsc::sync_channel(1);
    let input = Input::spawn(
        Box::new(PausedWriter {
            bytes: written.clone(),
            started: Some(started_tx),
            resume: resume_rx,
        }),
        Closer::new(|| {}),
    )
    .unwrap();
    input.key(1, true).unwrap();
    started_rx.recv_timeout(Duration::from_secs(10)).unwrap();
    input.key(2, true).unwrap();
    input.refresh(800, 600).unwrap();
    input.key(3, true).unwrap();
    for _ in 0..WRITE_QUEUE * 2 {
        input.request_frame(true, 640, 480).unwrap();
    }
    resume_tx.send(()).unwrap();
    input.close_after_pending(Duration::from_secs(10));
    let expected = [
        message::key_event(1, true),
        message::key_event(2, true),
        message::update_request(false, &Rect::new(0, 0, 640, 480)),
        message::key_event(3, true),
    ]
    .concat();
    assert_eq!(*written.lock().unwrap(), expected);
}
