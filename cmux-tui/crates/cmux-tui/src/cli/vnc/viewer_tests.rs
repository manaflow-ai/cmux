use super::*;
use std::sync::{Condvar, mpsc};

fn disconnected_viewer() -> Viewer {
    let (tx, _) = crossbeam_channel::unbounded();
    let (capacity_tx, _) = crossbeam_channel::bounded(1);
    let config = super::super::parse(&["localhost".into()], &|_| None).unwrap().unwrap();
    Viewer::new(config, tx, capacity_tx, false, false)
}

fn key_event(key: char, modifiers: term::KeyModifiers) -> term::Event {
    term::Event::Key(term::KeyEvent::new(term::KeyCode::Char(key), modifiers))
}

#[test]
fn view_only_toggle_stays_behind_already_deferred_paste() {
    let mut viewer = disconnected_viewer();
    let paste = DeferredInput::Event(term::Event::Paste("λ".repeat(4 * 1024 * 1024 + 1)));
    viewer.deferred_input.push(&paste).unwrap();
    viewer.receive_terminal(key_event(']', term::KeyModifiers::CONTROL)).unwrap();
    viewer.receive_terminal(key_event('v', term::KeyModifiers::NONE)).unwrap();
    assert!(!viewer.config.view_only, "the toggle must not discard the earlier paste");
    let replay = viewer.deferred_input.pop().unwrap().unwrap();
    assert_eq!(replay, paste);
    viewer.replay_input(replay).unwrap();
    assert!(!viewer.config.view_only);
    let replay = viewer.deferred_input.pop().unwrap().unwrap();
    assert_eq!(replay, DeferredInput::ToggleViewOnly);
    viewer.replay_input(replay).unwrap();
    assert!(viewer.config.view_only);
}

#[test]
fn replaying_old_focus_loss_preserves_new_command_prefix() {
    let mut viewer = disconnected_viewer();
    viewer.deferred_input.push(&DeferredInput::Event(term::Event::FocusLost)).unwrap();
    viewer.receive_terminal(key_event(']', term::KeyModifiers::CONTROL)).unwrap();
    let replay = viewer.deferred_input.pop().unwrap().unwrap();
    viewer.replay_input(replay).unwrap();
    assert!(viewer.receive_terminal(key_event('q', term::KeyModifiers::NONE)).unwrap());
}

#[test]
fn doubled_command_prefix_queues_the_complete_escape_chord() {
    let mut viewer = disconnected_viewer();
    viewer.keyboard = Keyboard::new(true);
    viewer.deferred_input.push(&DeferredInput::Event(term::Event::FocusGained)).unwrap();
    for _ in 0..2 {
        viewer.receive_terminal(key_event(']', term::KeyModifiers::CONTROL)).unwrap();
    }
    assert_eq!(
        viewer.deferred_input.pop().unwrap(),
        Some(DeferredInput::Event(term::Event::FocusGained))
    );
    assert_eq!(viewer.deferred_input.pop().unwrap(), Some(DeferredInput::SendEscape));
}

struct StalledPaste {
    closed: Arc<(Mutex<bool>, Condvar)>,
    first_key: mpsc::SyncSender<()>,
}

impl Write for StalledPaste {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.first() == Some(&4) {
            self.first_key.send(()).unwrap();
            let (lock, ready) = &*self.closed;
            let (closed, timeout) = ready
                .wait_timeout_while(lock.lock().unwrap(), Duration::from_secs(10), |closed| {
                    !*closed
                })
                .unwrap();
            assert!(!timeout.timed_out(), "quit must cancel the blocked transport");
            assert!(*closed);
            return Err(io::ErrorKind::BrokenPipe.into());
        }
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[test]
fn quit_is_read_during_a_stalled_large_paste_and_cancels_it() {
    cancel_stalled_paste('q');
}

#[test]
fn reconnect_is_read_during_a_stalled_large_paste_and_cancels_it() {
    cancel_stalled_paste('r');
}

fn cancel_stalled_paste(command: char) {
    let closed = Arc::new((Mutex::new(false), Condvar::new()));
    let close = closed.clone();
    let (first_key, started) = mpsc::sync_channel(1);
    // A deterministic RFB 3.8 / no-auth server handshake; its writer stalls on
    // the first paste batch until the viewer closes the transport.
    let mut handshake = b"RFB 003.008\n".to_vec();
    handshake.extend([1, 1, 0, 0, 0, 0]);
    handshake.extend(1u16.to_be_bytes());
    handshake.extend(1u16.to_be_bytes());
    handshake.extend(cmux_vnc::pixel::PixelFormat::RGBX.encode());
    handshake.extend(0u32.to_be_bytes());
    let session = Session::start(
        cmux_vnc::Transport::from_parts(
            Box::new(io::Cursor::new(handshake)),
            Box::new(StalledPaste { closed: closed.clone(), first_key }),
            cmux_vnc::Closer::new(move || {
                *close.0.lock().unwrap() = true;
                close.1.notify_all();
            }),
        ),
        &SessionOptions::default(),
    )
    .unwrap();
    let (tx, rx) = crossbeam_channel::unbounded();
    let (capacity_tx, capacity_rx) = crossbeam_channel::bounded(1);
    let (terminal_tx, terminal_rx) = crossbeam_channel::bounded(1);
    let mut config = super::super::parse(&["localhost".into()], &|_| None).unwrap().unwrap();
    config.target =
        super::super::Target::Tcp(cmux_vnc::Endpoint { host: "127.0.0.1".into(), port: 0 });
    let mut viewer = Viewer::new(config, tx, capacity_tx, false, false);
    let input = session.input();
    viewer.watch_input_capacity(&input);
    viewer.state = State::Connected { input: input.clone() };
    let producer = thread::spawn(move || {
        terminal_tx.send(Msg::Term(term::Event::Paste("λ".repeat(4 * 1024 * 1024 + 1)))).unwrap();
        started.recv_timeout(Duration::from_secs(10)).unwrap();
        for (key, modifiers) in [
            ('x', term::KeyModifiers::NONE),
            (']', term::KeyModifiers::CONTROL),
            (command, term::KeyModifiers::NONE),
        ]
        .into_iter()
        .chain(
            (command == 'r')
                .then_some([(']', term::KeyModifiers::CONTROL), ('q', term::KeyModifiers::NONE)])
                .into_iter()
                .flatten(),
        ) {
            terminal_tx
                .send(Msg::Term(term::Event::Key(term::KeyEvent::new(
                    term::KeyCode::Char(key),
                    modifiers,
                ))))
                .unwrap();
        }
    });
    viewer.run(&rx, &terminal_rx, &capacity_rx).unwrap();
    producer.join().unwrap();
    assert!(*closed.0.lock().unwrap(), "quit must close without draining the paste");
    assert_eq!(viewer.current_generation(), u64::from(command == 'r'));
    assert!(viewer.deferred_input.is_empty(), "cancel also releases deferred input");
    input.close_after_pending(Duration::from_secs(1));
}
