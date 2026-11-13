use super::*;
use acpmux_book::index::SummaryIndex;
use acpmux_core::life::V2;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

// Mark audit for this fixture:
//
// | change | mark source | why this test uses it |
// |---|---|---|
// | title, status, unread | `edit_test_meta` plus `append`/`attach_count` | the helper is the test seam for v1's `row_changed`; records and seen use production paths |
// | child and fork creation | `insert_test_session`/`session_came` | the helper emits the same creation mark and parent fanout |
// | parent archive edges | `note_rows_reading` then `list_head` | flushes v1's production dependent-row propagation |
// | peer saved | `send_remote` | production peer events intentionally never mark the local tee |
// | purge | `sessions.remove` plus a `purged` row event | avoids unrelated filesystem/audit cleanup while retaining v1's list transition |
//
// Deliberately omitted from equality: `usageStats` is a v1-only usage read and is not a summary
// field. Peer rows are excluded because this tee owns local v1 sessions; the remote assertion
// above verifies that the peer path does not add one.

fn roundtrip_hub() -> Arc<Hub> {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(config, store)
}

fn roundtrip_meta(id: &str) -> crate::store::SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA,
        "id": id,
        "name": id,
        "harness": "fake",
        "cwd": "/tmp",
        "status": "closed",
        "createdAt": 1,
        "updatedAt": crate::store::now_ms(),
    }))
    .unwrap()
}

fn without_usage_stats(mut row: Value) -> Value {
    if let Some(object) = row.as_object_mut() {
        object.remove("usageStats");
    }
    row
}

fn indexed_v1_row(index: &SummaryIndex, id: &str) -> Option<Value> {
    let summary = index.get(id)?;
    let parent = summary.parent.as_ref().and_then(|key| index.get_row(key));
    Some(acpmux_client::v1_row(
        &summary,
        acpmux_client::wire::OriginState::Connected,
        parent.as_deref(),
    ))
}

fn assert_roundtrip(v1: &Hub, index: &SummaryIndex) {
    let sessions = v1.session_handles();
    let expected_ids: HashSet<_> = sessions.iter().map(|session| session.id.clone()).collect();
    let actual_ids: HashSet<_> = index.iter().map(|row| row.chat_id.clone()).collect();
    assert_eq!(actual_ids, expected_ids, "the tee index has the same local sessions as v1");
    assert!(
        index.iter().all(|row| row.origin == "local"),
        "peer rows must not enter the local tee"
    );

    for session in sessions {
        let expected = indexed_v1_row(index, &session.id).expect("the id set check found this row");
        let actual = v1.session_list_summary(&session);
        // usageStats is intentionally a v1-only usage read; all other fields and
        // the bounded text values are compared exactly.
        assert_eq!(
            without_usage_stats(actual),
            without_usage_stats(expected),
            "v1 and v2 rows differ for {}",
            session.id
        );
    }
}

async fn wait_roundtrip(v1: &Hub, v2: &V2) {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let snapshot = v2.hub.snapshot();
            let sessions = v1.session_handles();
            let ids: HashSet<_> = snapshot.iter().map(|row| row.chat_id.clone()).collect();
            let expected: HashSet<_> = sessions.iter().map(|session| session.id.clone()).collect();
            if ids == expected
                && snapshot.iter().all(|row| row.origin == "local")
                && sessions.iter().all(|session| {
                    let Some(expected) = indexed_v1_row(&snapshot, &session.id) else {
                        return false;
                    };
                    without_usage_stats(v1.session_list_summary(session))
                        == without_usage_stats(expected)
                })
            {
                assert_roundtrip(v1, &snapshot);
                break;
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    })
    .await
    .expect("v1 and the v2 tee did not converge");
}

#[tokio::test]
async fn v1_session_lifecycle_roundtrips_through_the_v2_list_tee() {
    let v1 = roundtrip_hub();
    let (hub, writer) = acpmux_core::hub::Hub::new(SummaryIndex::new());
    let v2 = Arc::new(V2::new(hub, writer));
    let (handle, task) = start_v2_tee(v1.clone(), v2.clone());
    v1.install_v2_tee(handle);
    let tee = tokio::spawn(task);
    let writer = tokio::spawn(v2.take_writer().unwrap().run());

    let root = v1.insert_test_session(roundtrip_meta("root"));
    wait_roundtrip(&v1, &v2).await;

    // Create and rename a row through the v1 metadata path.
    v1.edit_test_meta(&root, |meta| {
        meta.title = Some("A short title".into());
    });
    wait_roundtrip(&v1, &v2).await;

    // A turn start and end are records plus the status transitions that v1's
    // row reads. The tee coalesces the two marks before it submits one row.
    v1.edit_test_meta(&root, |meta| {
        meta.status = crate::store::SessionStatus::Running;
        meta.last_prompt = Some("prompt".into());
    });
    *root.turn.lock().unwrap() =
        Some(TurnInfo::prompted("fake", "root", "turn-1", "prompt", Control::Local));
    v1.append(&root, "mux", "status", json!({"status": "running"}));
    wait_roundtrip(&v1, &v2).await;
    v1.edit_test_meta(&root, |meta| {
        meta.status = crate::store::SessionStatus::Idle;
        meta.last_prompt = None;
    });
    *root.turn.lock().unwrap() = None;
    v1.append(&root, "mux", "status", json!({"status": "completed"}));
    wait_roundtrip(&v1, &v2).await;

    // Unread is set by v1 and cleared by its real seen/attach path.
    v1.edit_test_meta(&root, |meta| {
        meta.unread = true;
        meta.unread_turns = 2;
    });
    wait_roundtrip(&v1, &v2).await;
    v1.attach_count(&root, 1, true);
    wait_roundtrip(&v1, &v2).await;

    // A lineage child supplies the activity parent used by spawnedBy.
    let mut child_meta = roundtrip_meta("child");
    child_meta.lineage = Some(crate::store::Lineage {
        parent: root.id.clone(),
        root: root.id.clone(),
        depth: 1,
        tool_call_id: None,
    });
    let child = v1.insert_test_session(child_meta);
    wait_roundtrip(&v1, &v2).await;

    // A fork carries its own parentId/forkSeq fields independently of lineage.
    let mut fork_meta = roundtrip_meta("fork");
    fork_meta.parent_id = Some(root.id.clone());
    fork_meta.fork_seq = Some(1);
    let _fork = v1.insert_test_session(fork_meta);
    wait_roundtrip(&v1, &v2).await;

    // Archiving the root changes whether its child is listed under it; both
    // edges are direct metadata row marks, with no synthetic tee-only mark.
    v1.edit_test_meta(&root, |meta| {
        meta.tags.insert(
            "archived".into(),
            crate::store::Tag { value: "true".into(), expires_at: None },
        );
    });
    v1.note_rows_reading(&root);
    let _ = v1.events.list_head();
    wait_roundtrip(&v1, &v2).await;
    v1.edit_test_meta(&root, |meta| {
        meta.tags.remove("archived");
    });
    v1.note_rows_reading(&root);
    let _ = v1.events.list_head();
    wait_roundtrip(&v1, &v2).await;

    // A peer row is announced through the remote event path. It must not be
    // marked or copied into this daemon's local tee index.
    let peer_row = json!({"sessionId": "peer-session", "title": "peer"});
    let _ = v1.events.send_remote(HubEvent {
        session_id: "peer-session".into(),
        record: Arc::new(EventRecord {
            seq: 0,
            at: crate::store::now_ms(),
            dir: "peer".into(),
            kind: "saved".into(),
            msg: Value::Null,
            host_seq: None,
        }),
        remote: Some(RemoteRef { peer: "other-daemon".into(), summary: peer_row }),
        update_line: Default::default(),
        row: Default::default(),
        list_seq: 0,
    });
    wait_roundtrip(&v1, &v2).await;
    assert!(
        v2.hub
            .snapshot()
            .get_row(&acpmux_book::index::RowKey::new("peer", "peer-session"))
            .is_none()
    );

    // Close, then purge through the same row event used by the v1 purge path.
    v1.edit_test_meta(&child, |meta| {
        meta.status = crate::store::SessionStatus::Closed;
    });
    v1.append(&child, "mux", "status", json!({"status": "closed"}));
    wait_roundtrip(&v1, &v2).await;
    let _ = v1.sessions.lock().unwrap().remove("fork");
    let mut purged = super::super::row_log::row_event("fork");
    Arc::make_mut(&mut purged.record).kind = "purged".into();
    let _ = v1.events.send(purged);
    wait_roundtrip(&v1, &v2).await;

    tee.abort();
    let _ = tee.await;
    v2.hub.close();
    writer.await.unwrap().unwrap();
}
