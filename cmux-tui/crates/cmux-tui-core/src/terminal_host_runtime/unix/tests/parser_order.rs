//! A cell-metric or Kitty-limit commit changes the host terminal outside the
//! PTY byte stream and marks its own transition applied on the client thread.
//! It must not do that while an Output published before it still waits in the
//! FIFO parser queue. Otherwise the applied cursor passes bytes the terminal
//! has not parsed: a snapshot boundary runs ahead of the parsed bytes, and in a
//! debug build the parser panics with the terminal locked when it catches up
//! ("smart parser cursor moved backwards"). That panic poisoned the terminal,
//! so the host never read Terminate or never published its exit, and the host
//! and its shell outlived `terminal close` (cli.rs "left a durable
//! terminal-host process behind").
//!
//! The test thread is the parser. It holds the queued Output until the commit
//! either finished (its thread then queues a `Drain` marker) or sent its own
//! command into the parser queue. Then it checks the applied cursor before it
//! applies the queued Output.

use super::*;

/// The applied cursor when the parser reached the queued Output, and the
/// cursor after every command was applied.
struct ParserObservation {
    applied_before_queued_output: u64,
    applied_at_end: u64,
}

fn run_commit_against_queued_output(
    commit: impl FnOnce(&HostShared, &HostTap) -> anyhow::Result<bool> + Send + 'static,
) -> (u64, ParserObservation) {
    let (parser_commands, parser_receiver) = sync_channel(HOST_PARSER_QUEUE_CAPACITY);
    let host = test_host_shared_with_parser(parser_commands);
    let queued = host.smart.publish(Frame::new(MessageKind::Output, b"queued".to_vec()));
    host.parser_commands
        .send(ParserCommand::Output {
            bytes: b"queued".to_vec(),
            source_cursor: queued,
            accounted_bytes: 0,
        })
        .unwrap();

    let (target_socket, _target_peer) = UnixStream::pair().unwrap();
    let (target_tx, _target_rx) = mpsc_channel();
    let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);
    let committer = {
        let host = host.clone();
        thread::spawn(move || {
            let committed = commit(&host, &target);
            // Marks the end of the commit in the parser FIFO.
            host.parser_commands.send(ParserCommand::Drain).unwrap();
            committed
        })
    };

    let first = parser_receiver.recv().expect("the queued Output");
    let ParserCommand::Output { source_cursor, .. } = first else {
        panic!("the first queued command is not the Output");
    };
    assert_eq!(source_cursor, queued);
    // The commit queued a command (it waits for the parser), or it finished
    // and its thread queued the Drain marker. Both arrive without a timer.
    let second = parser_receiver.recv().expect("a command from the commit or its end marker");
    let applied_before_queued_output = host.smart.applied_cursor.load(Ordering::Acquire);
    // Apply the Output as the parser does, then answer the commit's command
    // (dropping its response sender also releases a waiting commit).
    host.smart.applied_cursor.fetch_max(queued, Ordering::AcqRel);
    let mut next = Some(second);
    loop {
        let command = match next.take() {
            Some(command) => command,
            None => parser_receiver.recv().expect("the commit's end marker"),
        };
        match command {
            ParserCommand::Drain => break,
            ParserCommand::Output { source_cursor, .. } => {
                host.smart.applied_cursor.fetch_max(source_cursor, Ordering::AcqRel);
            }
            _ => {}
        }
    }
    assert!(committer.join().unwrap().unwrap(), "the commit failed");
    let applied_at_end = host.smart.applied_cursor.load(Ordering::Acquire);
    (queued, ParserObservation { applied_before_queued_output, applied_at_end })
}

fn assert_commit_waits_for_queued_output(
    commit: impl FnOnce(&HostShared, &HostTap) -> anyhow::Result<bool> + Send + 'static,
) {
    let (queued, observed) = run_commit_against_queued_output(commit);
    assert!(
        observed.applied_before_queued_output < queued,
        "the commit marked its transition applied (applied cursor {}) while Output {queued} \
         was still queued for the parser",
        observed.applied_before_queued_output
    );
    assert!(
        observed.applied_at_end > queued,
        "the commit's own transition was not applied after the queued Output"
    );
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
