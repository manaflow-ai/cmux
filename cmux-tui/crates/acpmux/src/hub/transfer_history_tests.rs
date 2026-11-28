use super::*;

#[test]
fn a_chats_second_pack_waits_for_its_first_and_another_chats_does_not() {
    let first = PackTurn::take("turn-chat-a");
    let _other = PackTurn::take("turn-chat-b");
    let (sent, got) = std::sync::mpsc::channel();
    let second = std::thread::spawn(move || {
        let _turn = PackTurn::take("turn-chat-a");
        sent.send(()).unwrap();
    });
    assert!(
        got.recv_timeout(std::time::Duration::from_millis(200)).is_err(),
        "the second pack ran beside the first"
    );
    drop(first);
    got.recv_timeout(std::time::Duration::from_secs(10)).expect("the second pack never ran");
    second.join().unwrap();
    assert!(!PACKING.0.lock().unwrap().contains("turn-chat-a"));
}

#[test]
fn a_prepack_that_ended_without_a_pack_does_not_hold_its_export() {
    let slot = Arc::new(Prepack::default());
    PREPACKS.lock().unwrap().insert("ended-chat".into(), (7, slot.clone()));
    // What a thread that never started leaves: the slot ended as failed.
    drop(PrepackDone { slot: &slot, packed: None });
    assert!(Hub::prepack_waited("ended-chat", 7).is_none());
    assert!(!PREPACKS.lock().unwrap().contains_key("ended-chat"));
}
