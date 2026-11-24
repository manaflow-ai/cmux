use std::sync::Arc;

use super::{OutputStore, TerminalPublicId};

fn terminal() -> TerminalPublicId {
    TerminalPublicId::parse("term_00000000000000000000000000000e4d").unwrap()
}

#[test]
fn releasing_durably_covered_output_drops_memory_and_fences_late_chunks() {
    let store = OutputStore::new(None);
    let terminal = terminal();
    let generation: Arc<str> = Arc::from("generation");
    store.append(&terminal, &generation, b"final output", None);

    assert!(store.release_terminal_output(&terminal, generation.as_ref(), 12));
    let log = store.logs.lock().unwrap().get(&terminal).cloned().unwrap();
    let state = log.state.lock().unwrap();
    assert_eq!(state.tail.capacity(), 0);
    assert_eq!(state.pending.capacity(), 0);
    drop(state);
    let window = store.read_after(&terminal, 0, 1024).unwrap();
    assert!(window.bytes.is_empty());
    assert_eq!((window.start_offset, window.next_offset), (12, 12));
    assert_eq!(store.stream_end(&terminal).unwrap().1, 12);

    store.append(&terminal, &generation, b"late reader chunk", None);
    assert!(store.read_after(&terminal, 0, 1024).unwrap().bytes.is_empty());
    assert_eq!(store.stream_end(&terminal).unwrap().1, 12);
}

#[test]
fn an_exit_snapshot_that_lost_a_racing_chunk_does_not_release_output() {
    let store = OutputStore::new(None);
    let terminal = terminal();
    let generation: Arc<str> = Arc::from("generation");
    store.append(&terminal, &generation, b"still needed", None);

    assert!(!store.release_terminal_output(&terminal, generation.as_ref(), 11));
    assert_eq!(store.read_after(&terminal, 0, 1024).unwrap().bytes, b"still needed");
}

#[test]
fn a_new_generation_reopens_a_released_log() {
    let store = OutputStore::new(None);
    let terminal = terminal();
    let old_generation: Arc<str> = Arc::from("old");
    let new_generation: Arc<str> = Arc::from("new");
    store.append(&terminal, &old_generation, b"old output", None);
    assert!(store.release_terminal_output(&terminal, old_generation.as_ref(), 10));

    store.append(&terminal, &new_generation, b"new output", None);
    assert_eq!(store.read_after(&terminal, 0, 1024).unwrap().bytes, b"new output");
    assert_eq!(store.stream_end(&terminal).unwrap().0.as_ref(), "new");
}
