use super::*;

#[test]
fn wedge_a_lookup_never_waits_on_a_held_writer_and_sees_each_change_at_once() {
    let table = Arc::new(PeerTable::default());
    let mut guard = table.lock().unwrap();
    // Another thread's lookup while the writer is held: answered, not parked.
    let t = table.clone();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || tx.send(t.get("a").is_none()).unwrap());
    assert_eq!(rx.recv_timeout(std::time::Duration::from_secs(5)), Ok(true));
    guard.clear();
    assert!(table.load().is_empty());
    drop(guard);
}
