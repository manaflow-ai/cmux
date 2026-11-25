use std::sync::Arc;

use super::{OutputStore, TerminalPublicId};

fn terminal() -> TerminalPublicId {
    TerminalPublicId::parse("term_00000000000000000000000000000e4d").unwrap()
}

#[test]
fn memory_mode_release_keeps_output_and_late_chunks_readable() {
    let store = OutputStore::new(None);
    let terminal = terminal();
    let generation: Arc<str> = Arc::from("generation");
    store.append(&terminal, &generation, b"final output", None);

    assert!(!store.release_terminal_output(&terminal, generation.as_ref(), 12));
    let log = store.logs.lock().unwrap().get(&terminal).cloned().unwrap();
    let state = log.state.lock().unwrap();
    assert_eq!(state.tail.iter().copied().collect::<Vec<_>>(), b"final output");
    drop(state);
    let window = store.read_after(&terminal, 0, 1024).unwrap();
    assert_eq!(window.bytes, b"final output");
    assert_eq!((window.start_offset, window.next_offset), (0, 12));
    assert_eq!(store.stream_end(&terminal).unwrap().1, 12);

    store.append(&terminal, &generation, b"late reader chunk", None);
    assert_eq!(
        store.read_after(&terminal, 0, 1024).unwrap().bytes,
        b"final outputlate reader chunk"
    );
    assert_eq!(store.stream_end(&terminal).unwrap().1, 29);
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
    assert!(!store.release_terminal_output(&terminal, old_generation.as_ref(), 10));

    store.append(&terminal, &new_generation, b"new output", None);
    assert_eq!(store.read_after(&terminal, 0, 1024).unwrap().bytes, b"new output");
    assert_eq!(store.stream_end(&terminal).unwrap().0.as_ref(), "new");
}

#[test]
fn an_ended_snapshot_log_reads_the_raw_tail_from_disk() {
    let root = std::env::temp_dir().join(format!(
        "cmux-output-ended-tail-{}-{}",
        std::process::id(),
        crate::workspace_registry::new_uuid_v4()
    ));
    std::fs::create_dir_all(&root).unwrap();
    let store = OutputStore::new(Some(&root));
    let terminal = terminal();
    let generation: Arc<str> = Arc::from("generation");
    let raw = b"raw tail bytes\x00\xff";
    store.append(&terminal, &generation, raw, None);

    assert!(store.release_terminal_output(&terminal, generation.as_ref(), raw.len() as u64));
    let window = store.read_after(&terminal, 0, 1024).unwrap();
    assert_eq!(window.start_offset, 0);
    assert_eq!(window.next_offset, raw.len() as u64);
    assert_eq!(window.bytes, raw);
    assert!(!window.truncated);

    std::fs::remove_dir_all(root).unwrap();
}
