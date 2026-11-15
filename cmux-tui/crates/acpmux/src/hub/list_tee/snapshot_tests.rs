use super::*;
use acpmux_book::index::{SortedSnapshot, SummaryIndex};
use acpmux_core::hub::ListItem;

#[tokio::test]
async fn reconciliation_removes_a_stale_disk_row_after_a_damaged_frame() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("index.snap");
    let mut index = SummaryIndex::new();
    for (id, at) in [("first", 3), ("damaged", 2), ("deleted-while-down", 1)] {
        let mut row = Summary::new(id);
        row.state = "closed".into();
        row.last_activity = at;
        index = index.apply(index.seq() + 1, row);
    }
    SortedSnapshot::write(&path, &index).unwrap();
    let mut bytes = std::fs::read(&path).unwrap();
    let first_length =
        u32::from_le_bytes(bytes.get(4096..4100).unwrap().try_into().unwrap()) as usize + 12;
    // Keep the next boundary sound and damage only the middle payload's CRC.
    *bytes.get_mut(4096 + first_length + 8).unwrap() ^= 1;
    std::fs::write(&path, bytes).unwrap();

    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, root.path()).unwrap();
    let v1 = Hub::new(config, store);
    for id in ["first", "damaged"] {
        let meta = serde_json::from_value(serde_json::json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": id,
            "harness": "fake", "cwd": "/tmp", "status": "closed",
            "createdAt": 1, "updatedAt": crate::store::now_ms()
        }))
        .unwrap();
        v1.insert_test_session(meta);
    }
    let (hub, writer) = acpmux_core::hub::Hub::open(root.path(), 101, || 7).unwrap();
    let receiver =
        hub.subscribe_replay(&acpmux_core::wire::Sub::new("walk", "list"), index.seq()).unwrap();
    let v2 = V2::new(hub, writer);
    // Reconciliation waits for snapshot hydration, which the writer advances.
    let (written, reconciled) = tokio::join!(v2.take_writer().unwrap().run(), async {
        // timeout: Bound this test's hydration wait, then close and drain its writer.
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            reconcile(&v1, &v2, &TeeState::default()),
        )
        .await;
        v2.hub.close();
        result
    });
    written.unwrap();
    reconciled.unwrap();

    let snapshot = v2.hub.snapshot();
    for id in ["first", "damaged"] {
        let session = session_by_id(&v1, id).unwrap();
        assert!(
            snapshot.get(id).unwrap().same_content(&summary_from_session(&v1, &session).unwrap())
        );
    }
    let mut removed = Vec::new();
    while let Some(item) = receiver.try_next() {
        if let ListItem::Gone { origin, chat_id, .. } = item {
            removed.push((origin, chat_id));
        }
    }
    assert_eq!(removed, vec![("local".to_owned(), "deleted-while-down".to_owned())]);
    assert!(snapshot.is_shadowed(&RowKey::new("local", "deleted-while-down")));
}
