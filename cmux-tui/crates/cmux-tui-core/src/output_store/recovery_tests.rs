use super::*;

#[test]
fn output_recovery_cache_budget_is_shared_and_released_with_the_last_reader() {
    let store = OutputStore::new(None);
    let mut cuts = Vec::new();
    for _ in 0..16 {
        cuts.push(store.make_recovery_cut("x".repeat(4 * 1024 * 1024), 0).unwrap());
    }
    assert!(store.make_recovery_cut("x".into(), 0).is_err());
    let retained_reader = cuts[0].clone();
    cuts.remove(0);
    assert!(store.make_recovery_cut("x".into(), 0).is_err(), "a live reader still owns the bytes");
    drop(retained_reader);
    assert!(store.make_recovery_cut("x".repeat(4 * 1024 * 1024), 0).is_ok());
}

#[test]
fn output_recovery_invalidates_on_each_gap_generation_and_clear_in_all_modes() {
    for mode in [PersistenceMode::Memory, PersistenceMode::Snapshot, PersistenceMode::Full] {
        let store = OutputStore::new(None);
        store.full.set_enabled(mode == PersistenceMode::Full);
        store.tail.store(mode == PersistenceMode::Snapshot, std::sync::atomic::Ordering::Relaxed);
        let terminal = TerminalPublicId::parse("term_00000000000000000000000000000f3a").unwrap();
        let generation = Arc::from("first");
        store.stream_gap(&terminal, &generation);
        let (first, gap, slot, end) = store.recovery_state(&terminal).unwrap();
        assert!(gap);
        assert_eq!(end, 0);
        *slot.lock().unwrap() = Some(store.make_recovery_cut("old history".into(), end).unwrap());
        store.stream_gap(&terminal, &generation);
        let (second, _, slot, _) = store.recovery_state(&terminal).unwrap();
        assert_ne!(first, second);
        assert!(slot.lock().unwrap().is_none());
        assert!(store.check_recovery_epoch(&terminal, &first).is_err());
        store.append(&terminal, &Arc::from("second"), b"new", None);
        let (third, _, _, end) = store.recovery_state(&terminal).unwrap();
        assert_ne!(second, third);
        assert_eq!(end, 3);
        store.history_cleared(&terminal);
        let (fourth, _, slot, _) = store.recovery_state(&terminal).unwrap();
        assert_ne!(third, fourth);
        assert!(slot.lock().unwrap().is_none());
    }
}
