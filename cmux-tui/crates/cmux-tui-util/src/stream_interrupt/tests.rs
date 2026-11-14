use super::*;

#[test]
fn a_fired_source_wakes_a_blocked_receiver() {
    let (sender, receiver) = signal();
    let interrupt = StreamInterrupt::new();
    let source = InterruptSet::default();
    source.register(&interrupt);
    receiver.wake_on(&interrupt);
    let waiter = std::thread::spawn(move || receiver.recv_until_interrupted(&interrupt));
    std::thread::sleep(Duration::from_millis(20));
    source.fire();
    assert_eq!(waiter.join().unwrap(), Err(RecvTimeoutError::Timeout));
    drop(sender);
}

#[test]
fn registering_after_the_close_fires_at_once() {
    let source = InterruptSet::default();
    source.fire();
    let interrupt = StreamInterrupt::new();
    source.register(&interrupt);
    assert!(interrupt.is_fired());
}

#[test]
fn signals_coalesce_and_report_a_dropped_sender() {
    let (sender, receiver) = signal();
    assert!(sender.try_send(()).is_ok());
    assert!(matches!(sender.try_send(()), Err(TrySendError::Full(()))));
    assert!(receiver.try_recv().is_ok());
    assert!(matches!(receiver.try_recv(), Err(TryRecvError::Empty)));
    drop(sender);
    assert!(matches!(receiver.try_recv(), Err(TryRecvError::Disconnected)));
    assert_eq!(
        receiver.recv_until_interrupted(&StreamInterrupt::default()),
        Err(RecvTimeoutError::Disconnected)
    );
}
