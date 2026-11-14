use super::*;

#[test]
fn a_peer_row_has_exactly_its_keys() {
    for keys in [3, 15, 75] {
        let row = peer_row("p", 7, keys);
        assert_eq!(row.as_object().unwrap().len(), keys);
        assert_eq!(row["sessionId"], "p-00007");
    }
}

#[test]
fn the_small_home_is_the_god_shape_at_its_size() {
    let dir = tempfile::tempdir().unwrap();
    let (home, claude) = (dir.path().join("acpmux"), dir.path().join("claude"));
    let shape = Shape::small();
    let made = write_home(&home, &claude, &dir.path().join("work"), &shape).unwrap();
    assert_eq!(made.others.len(), shape.chats - 1);
    let jsonl = std::fs::read_to_string(&made.god_jsonl).unwrap();
    assert_eq!(jsonl.lines().count(), shape.god_messages);
    // Within 10% of the bytes asked for, the JSONL and the log alike.
    let near = |got: u64| got.abs_diff(shape.god_bytes) * 10 <= shape.god_bytes;
    assert!(near(made.god_jsonl_bytes), "{} of {}", made.god_jsonl_bytes, shape.god_bytes);
    assert!(near(made.god_log_bytes), "{} of {}", made.god_log_bytes, shape.god_bytes);
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, &home).unwrap();
    let metas = store.list().unwrap();
    assert_eq!(metas.len(), shape.chats);
    let god = metas.iter().find(|m| m.id == made.god).unwrap();
    assert_eq!(god.last_seq, shape.god_messages as u64);
}
