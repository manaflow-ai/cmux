use super::*;

fn stream(index: u128) -> TerminalStream {
    (
        Arc::new(TerminalPublicId::parse(format!("term_{index:032x}")).unwrap()),
        Arc::from("offer-generation"),
    )
}

fn resize(stream: &TerminalStream, cols: u16) -> JournalIngressEvent {
    JournalIngressEvent::TerminalResize {
        terminal_id: stream.0.clone(),
        generation: stream.1.clone(),
        occurred_at_ms: 1,
        cols,
        rows: 24,
        cell_width: 8,
        cell_height: 16,
    }
}

fn marker(stream: &TerminalStream, reason: &'static str) -> JournalIngressEvent {
    JournalIngressEvent::TerminalOutputGap {
        terminal_id: stream.0.clone(),
        generation: stream.1.clone(),
        occurred_at_ms: 1,
        reason,
    }
}

/// What the writer does when it drains `count` events: take them and
/// lower the lane depth. Returns (kind, terminal, reason or cols).
fn drain(
    sender: &JournalIngressSender,
    receivers: &super::super::JournalIngressReceivers,
    count: usize,
) -> Vec<(&'static str, Arc<TerminalPublicId>, String)> {
    let drained = (0..count)
        .map(|_| match &receivers.terminal.try_recv().unwrap().event {
            JournalIngressEvent::TerminalResize { terminal_id, cols, .. } => {
                ("resize", terminal_id.clone(), cols.to_string())
            }
            JournalIngressEvent::TerminalOutputGap { terminal_id, reason, .. } => {
                ("gap", terminal_id.clone(), reason.to_string())
            }
            _ => panic!("an unexpected event in the terminal lane"),
        })
        .collect::<Vec<_>>();
    sender.state.stats.drained(JournalLane::Terminal, count);
    drained
}

fn fill(sender: &JournalIngressSender, stream: &TerminalStream) {
    for _ in 0..JOURNAL_TERMINAL_QUEUE_CAPACITY {
        assert_eq!(sender.offer_terminal(resize(stream, 80)), TerminalOffer::Queued);
    }
}

#[test]
fn a_refused_geometry_change_leaves_one_marker_ahead_of_the_next_record() {
    let (sender, receivers) = JournalIngressSender::new(true);
    let receivers = receivers.unwrap();
    let (noisy, quiet) = (stream(1), stream(2));
    fill(&sender, &noisy);

    // Nothing drains the lane: each offer returns at once.
    assert_eq!(sender.offer_terminal(resize(&noisy, 81)), TerminalOffer::Owed);
    assert_eq!(sender.offer_terminal(resize(&noisy, 82)), TerminalOffer::Covered);
    assert_eq!(sender.offer_terminal(resize(&quiet, 90)), TerminalOffer::Owed);

    // Room, but more than half is still queued: the terminal waits.
    drain(&sender, &receivers, RESUME_DEPTH - 1);
    assert_eq!(sender.offer_terminal(resize(&noisy, 83)), TerminalOffer::Covered);

    drain(&sender, &receivers, 1);
    assert_eq!(sender.offer_terminal(resize(&noisy, 84)), TerminalOffer::QueuedAfterGap);
    assert_eq!(sender.offer_terminal(resize(&noisy, 85)), TerminalOffer::Queued);
    // Those three records took the lane above half again.
    assert_eq!(sender.offer_terminal(resize(&quiet, 91)), TerminalOffer::Covered);
    drain(&sender, &receivers, 3);
    assert_eq!(sender.offer_terminal(resize(&quiet, 92)), TerminalOffer::QueuedAfterGap);

    let queued = sender.state.stats.queued_depth(JournalLane::Terminal);
    let tail = drain(&sender, &receivers, queued);
    let tail = &tail[tail.len() - 5..];
    assert_eq!(
        tail.iter().map(|(kind, _, value)| (*kind, value.as_str())).collect::<Vec<_>>(),
        [
            ("gap", QUEUE_FULL_REASON),
            ("resize", "84"),
            ("resize", "85"),
            ("gap", QUEUE_FULL_REASON),
            ("resize", "92"),
        ]
    );
    assert_eq!((&tail[0].1, &tail[3].1), (&noisy.0, &quiet.0));
    assert!(receivers.terminal.try_recv().is_err());
    assert_eq!(sender.offer_owed_terminal_gaps(), 0);
}

#[test]
fn a_refused_marker_is_owed_with_its_own_reason() {
    let (sender, receivers) = JournalIngressSender::new(true);
    let receivers = receivers.unwrap();
    let (noisy, reconnected) = (stream(3), stream(4));
    fill(&sender, &noisy);

    assert_eq!(sender.offer_terminal(marker(&reconnected, "host_reconnect")), TerminalOffer::Owed);
    // A later record of that terminal is covered by the one owed marker.
    assert_eq!(sender.offer_terminal(resize(&reconnected, 100)), TerminalOffer::Covered);
    assert_eq!(sender.offer_owed_terminal_gaps(), 1, "the lane is still full");

    // A checkpoint does not wait for half: one free slot is enough.
    drain(&sender, &receivers, 1);
    assert_eq!(sender.offer_owed_terminal_gaps(), 0);
    let tail = drain(&sender, &receivers, JOURNAL_TERMINAL_QUEUE_CAPACITY);
    let (kind, terminal, reason) = tail.last().unwrap();
    assert_eq!((*kind, terminal, reason.as_str()), ("gap", &reconnected.0, "host_reconnect"));
    assert_eq!(sender.offer_terminal(resize(&reconnected, 101)), TerminalOffer::Queued);
}

#[test]
fn a_closed_journal_owes_nothing() {
    let (sender, _receivers) = JournalIngressSender::new(true);
    let terminal = stream(5);
    fill(&sender, &terminal);
    assert_eq!(sender.offer_terminal(resize(&terminal, 81)), TerminalOffer::Owed);
    sender.state.close_admission();
    assert_eq!(sender.offer_terminal(resize(&terminal, 82)), TerminalOffer::Queued);
    assert_eq!(sender.offer_owed_terminal_gaps(), 0);

    let (ephemeral, receivers) = JournalIngressSender::new(false);
    assert!(receivers.is_none());
    assert_eq!(ephemeral.offer_terminal(resize(&terminal, 83)), TerminalOffer::Queued);
}
