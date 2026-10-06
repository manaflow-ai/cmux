//! FLAKE-TERMINAL-HOST-RECOVERY-SIDECARS: a cell-metric or Kitty-limit
//! commit changes the terminal outside the PTY byte stream. It must not mark
//! its transition applied while an Output published before it is still
//! queued for the FIFO parser: the parser would then move the applied cursor
//! backwards (a debug-build panic that left the host unable to publish its
//! exit, so it lived forever; in a release build a snapshot boundary ahead of
//! the parsed bytes).

use super::*;

/// A host whose parser queue holds one published, unapplied Output, and
/// the receiver for a parser the test starts later.
fn host_with_queued_output() -> (Arc<HostShared>, Receiver<ParserCommand>, u64) {
    let term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    let (parser_commands, receiver) = sync_channel(HOST_PARSER_QUEUE_CAPACITY);
    let host = test_host_shared_with(
        term,
        parser_commands,
        ClipboardReads::new(Arc::new(SystemClock)),
    );
    let queued = host.smart.publish(Frame::new(MessageKind::Output, b"queued".to_vec()));
    host.parser_commands
        .send(ParserCommand::Output {
            bytes: b"queued".to_vec(),
            source_cursor: queued,
            accounted_bytes: 0,
        })
        .unwrap();
    (host, receiver, queued)
}

fn start_parser(host: &Arc<HostShared>, receiver: Receiver<ParserCommand>) -> thread::JoinHandle<()> {
    let initial_colors = host.term.lock().unwrap().color_overrides();
    let parser_host = host.clone();
    let signals = ParserSignals {
        pending_responses: Arc::new(Mutex::new(Vec::new())),
        title_changed: Arc::new(AtomicBool::new(false)),
        bell: Arc::new(AtomicBool::new(false)),
    };
    thread::spawn(move || run_host_parser(parser_host, receiver, initial_colors, signals))
}

/// Runs `commit` while the parser has not applied the queued Output, then
/// starts the parser. The commit must wait for the parser before it marks
/// its own transition applied.
fn assert_commit_waits_for_queued_output(
    commit: impl FnOnce(&HostShared, &HostTap) -> anyhow::Result<bool> + Send + 'static,
) {
    let (host, receiver, queued) = host_with_queued_output();
    let (target_socket, _target_peer) = UnixStream::pair().unwrap();
    let (target_tx, _target_rx) = mpsc_channel();
    let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);
    let committer = {
        let host = host.clone();
        thread::spawn(move || commit(&host, &target))
    };
    // A commit that does not wait for the parser finishes at once.
    let deadline = Instant::now() + Duration::from_millis(500);
    while !committer.is_finished() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(5));
    }
    assert!(
        !committer.is_finished(),
        "the commit marked its transition applied (applied cursor {}) while Output {queued} \
         was still queued for the parser",
        host.smart.applied_cursor.load(Ordering::Acquire)
    );
    let parser = start_parser(&host, receiver);
    assert!(committer.join().unwrap().unwrap());
    assert!(host.smart.applied_cursor.load(Ordering::Acquire) > queued);
    host.parser_commands.send(ParserCommand::Drain).unwrap();
    parser.join().expect("the parser applied every command in order");
}

#[test]
fn a_cell_metric_commit_waits_for_queued_output() {
    assert_commit_waits_for_queued_output(|host, target| {
        host.set_cell_pixel_size(9, 18, 42, target)
    });
}

#[test]
fn a_kitty_limit_commit_waits_for_queued_output() {
    assert_commit_waits_for_queued_output(|host, target| {
        host.set_kitty_graphics_limits(KittyGraphicsLimits::disabled(), 43, target)
    });
}
