use super::*;

#[test]
fn mark_queue_deduplicates_ids_but_counts_each_mark() {
    let state = TeeState::default();
    state.mark("chat");
    state.mark("chat");
    state.mark("other");

    assert_eq!(state.marks.load(Ordering::Relaxed), 3);
    let mut ids = state.take();
    ids.sort();
    assert_eq!(ids, ["chat", "other"]);
    assert!(state.take().is_empty());
}

#[test]
fn expiry_deadlines_are_replaced_and_expiry_marks_once() {
    let state = TeeState::default();
    let mut expiries = Expiries::default();
    expiries.set("chat", Some(100));
    expiries.set("chat", Some(200));

    expiries.mark_due(&state, 150);
    assert!(state.take().is_empty(), "the replaced deadline must not fire");
    expiries.mark_due(&state, 200);
    assert_eq!(state.take(), vec!["chat".to_owned()]);
    expiries.mark_due(&state, 300);
    assert!(state.take().is_empty(), "an expired deadline is removed after one mark");
}

#[test]
fn removing_a_deadline_prevents_a_late_mark() {
    let state = TeeState::default();
    let mut expiries = Expiries::default();
    expiries.set("chat", Some(100));
    expiries.set("chat", None);
    expiries.mark_due(&state, 1000);
    assert!(state.take().is_empty());
}

#[tokio::test]
async fn one_hundred_thousand_stream_appends_do_not_mark() {
    let hub = memory_hub();
    let mut row = meta("chat");
    row.status = crate::store::SessionStatus::Running;
    let session = hub.insert_test_session(row);
    let state = Arc::new(TeeState::default());
    hub.install_v2_tee(Arc::new(TeeHandle { state: state.clone() }));
    for _ in 0..100_000 {
        hub.append(&session, "in", "agent_message_chunk", serde_json::json!({"delta":"x"}));
    }
    assert_eq!(state.marks.load(Ordering::Relaxed), 0);
    assert!(!state.has_pending());
    hub.append(&session, "mux", "status", serde_json::json!({"status":"running"}));
    assert_eq!(state.take(), ["chat"]);
}

#[tokio::test]
async fn coalesced_marks_read_activity_at_the_drain_after_unmarked_chunks() {
    let v1 = memory_hub();
    let mut row = meta("streaming");
    row.status = crate::store::SessionStatus::Running;
    let session = v1.insert_test_session(row);
    let initial = summary_from_session(&v1, &session).unwrap();
    let index = acpmux_book::index::SummaryIndex::new().apply(1, initial);
    let (hub, writer) = acpmux_core::hub::Hub::new(index);
    let v2 = V2::new(hub, writer);
    let subscription = v2.hub.subscribe(&acpmux_core::wire::Sub::new("test", "list")).unwrap();
    let state = Arc::new(TeeState::default());
    v1.install_v2_tee(Arc::new(TeeHandle { state: state.clone() }));
    let at = crate::store::now_ms() + 10;
    let (_, stored) = v1.append_at(
        &session,
        "mux",
        "status",
        serde_json::json!({"status":"running"}),
        None,
        Some(at),
    );
    assert!(stored);
    assert_eq!(state.marks.load(Ordering::Relaxed), 1);
    for n in 1..=100 {
        let (_, stored) = v1.append_at(
            &session,
            "in",
            "agent_message_chunk",
            serde_json::json!({"delta":"x"}),
            None,
            Some(at + n),
        );
        assert!(stored);
    }
    assert_eq!(state.marks.load(Ordering::Relaxed), 1, "chunks add no marks");
    v1.events.row_changed(&session);
    assert_eq!(state.marks.load(Ordering::Relaxed), 2);
    let mut expiries = Expiries::default();
    drain_marks(&v1, &v2, &state, &mut expiries);
    v2.hub.close();
    v2.take_writer().unwrap().run().await.unwrap();
    let Some(acpmux_core::hub::ListItem::Summary(event)) = subscription.receiver.try_next() else {
        panic!("one summary for both marks");
    };
    assert_eq!(event.summary.last_activity, at + 100);
    assert_eq!(event.summary.last_activity, session.meta().updated_at);
    assert!(event.summary.same_content(&summary_from_session(&v1, &session).unwrap()));
    assert!(subscription.receiver.try_next().is_none());
}

#[test]
fn due_work_is_bounded_and_drains_without_new_marks() {
    let state = TeeState::default();
    let mut expiries = Expiries::default();
    for n in 0..1000 {
        expiries.set(&format!("chat-{n}"), Some(100));
    }
    let mut total = 0;
    for _ in 0..4 {
        expiries.mark_due(&state, 100);
        let batch = state.take();
        assert!(batch.len() <= BATCH);
        total += batch.len();
    }
    assert_eq!(total, 1000);
    expiries.mark_due(&state, 100);
    assert!(!state.has_pending());
}

fn memory_hub() -> Arc<Hub> {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(config, store)
}

fn meta(id: &str) -> crate::store::SessionMeta {
    serde_json::from_value(serde_json::json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id,
        "harness": "fake", "cwd": "/tmp", "status": "closed",
        "createdAt": 1, "updatedAt": crate::store::now_ms()
    }))
    .unwrap()
}

async fn next(receiver: &acpmux_core::hub::ListReceiver) -> acpmux_core::hub::ListItem {
    tokio::time::timeout(std::time::Duration::from_secs(5), receiver.recv()).await.unwrap().unwrap()
}

#[tokio::test]
async fn a_held_v1_load_submits_no_removal() {
    use std::future::Future as _;
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let v1 = Hub::new_loading(config, store, crate::mailbox::Mailbox::memory());
    let index = acpmux_book::index::SummaryIndex::new().apply(1, Summary::new("still-loading"));
    let (hub, writer) = acpmux_core::hub::Hub::new(index);
    let v2 = Arc::new(V2::new(hub, writer));
    let (_, task) = start_v2_tee(v1, v2.clone());
    let mut task = Box::pin(task);
    std::future::poll_fn(|cx| {
        assert!(task.as_mut().poll(cx).is_pending());
        std::task::Poll::Ready(())
    })
    .await;
    drop(task);
    // Close drains everything queued before returning. An erroneous early
    // remove would now be visible, with no sleep or scheduler guess.
    v2.hub.close();
    v2.take_writer().unwrap().run().await.unwrap();
    assert_eq!(v2.hub.snapshot().seq(), 1);
    assert!(v2.hub.snapshot().get("still-loading").is_some());
}

#[tokio::test]
async fn a_key_not_loaded_yet_is_not_reported_missing() {
    use acpmux_core::hub::PageProvider as _;
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    store.save(&meta("not-loaded-yet")).unwrap();
    let v1 = Hub::new_loading(config, store, crate::mailbox::Mailbox::memory());
    let provider = V1PageProvider::new(v1.clone());
    let key = RowKey::new("local", "not-loaded-yet");
    assert_eq!(provider.row(&key).unwrap_err().kind(), std::io::ErrorKind::WouldBlock);
    assert!(provider.row(&RowKey::new("peer", "unknown")).unwrap().is_none());
    v1.load_store_async().await;
    assert_eq!(provider.row(&key).unwrap().unwrap().chat_id, "not-loaded-yet");
    assert!(provider.row(&RowKey::new("local", "missing")).unwrap().is_none());
}

#[tokio::test]
async fn an_unchanged_second_start_appends_no_record_and_sends_no_op() {
    use std::future::Future as _;
    let v1 = memory_hub();
    v1.insert_test_session(meta("unchanged"));
    let directory = tempfile::tempdir().unwrap();
    let mut previous_bytes = None;
    for boot in [1, 2] {
        let (hub, writer) =
            acpmux_core::hub::Hub::open(directory.path(), boot, || boot as u32).unwrap();
        let v2 = Arc::new(V2::new(hub, writer));
        let subscription = v2.hub.subscribe(&acpmux_core::wire::Sub::new("test", "list")).unwrap();
        let (_, task) = start_v2_tee(v1.clone(), v2.clone());
        let mut task = Box::pin(task);
        // One session fits in the first page/batch; the first suspension is
        // the worker's yield after submitting the complete startup walk.
        std::future::poll_fn(|cx| {
            assert!(task.as_mut().poll(cx).is_pending());
            std::task::Poll::Ready(())
        })
        .await;
        drop(task);
        v2.hub.close();
        v2.take_writer().unwrap().run().await.unwrap();
        let bytes = std::fs::read(directory.path().join("index.log")).unwrap();
        assert_eq!(v2.hub.snapshot().seq(), 1);
        if let Some(previous) = previous_bytes {
            assert_eq!(bytes, previous);
            assert!(subscription.receiver.try_next().is_none());
        } else {
            assert!(matches!(
                subscription.receiver.try_next(),
                Some(acpmux_core::hub::ListItem::Summary(_))
            ));
        }
        previous_bytes = Some(bytes);
    }
}

#[tokio::test]
async fn eleven_thousand_rows_reconcile_with_a_thousand_changes_between_pages() {
    use std::future::Future as _;
    let v1 = memory_hub();
    let mut index = acpmux_book::index::SummaryIndex::new();
    for n in 0..11_000 {
        let id = format!("chat-{n:05}");
        v1.insert_test_session(meta(&id));
        let mut stale = Summary::new(id);
        stale.last_activity = n;
        index = index.apply(n + 1, stale);
    }
    let (hub, writer) = acpmux_core::hub::Hub::new(index);
    let v2 = Arc::new(V2::new(hub, writer));
    let state = Arc::new(TeeState::default());
    v1.install_v2_tee(Arc::new(TeeHandle { state: state.clone() }));
    let mut walk = Box::pin(reconcile(&v1, &v2, &state));
    std::future::poll_fn(|cx| {
        assert!(walk.as_mut().poll(cx).is_pending(), "the walk yields between pages");
        std::task::Poll::Ready(())
    })
    .await;
    for n in 0..1000 {
        // Include keys on both sides of the first page's continuation key.
        let id = format!("chat-{:05}", n * 17 % 11_000);
        let session = session_by_id(&v1, &id).unwrap();
        v1.edit_test_meta(&session, |row| {
            row.title = Some(format!("changed-{n}"));
            row.unread = true;
            row.unread_turns = n + 1;
        });
    }
    let _expiries = walk.await;
    assert_eq!(state.marks.load(Ordering::Relaxed), 1000);
    assert!(!state.has_pending());
    v2.hub.close();
    v2.take_writer().unwrap().run().await.unwrap();
    let index = v2.hub.snapshot();
    assert_eq!(index.len(), 11_000);
    for n in 0..11_000 {
        let id = format!("chat-{n:05}");
        let session = session_by_id(&v1, &id).unwrap();
        let expected = summary_from_session(&v1, &session).unwrap();
        assert!(index.get(&id).unwrap().same_content(&expected), "{id}");
    }
}

#[tokio::test]
async fn startup_reconciles_local_rows_and_marks_purge_and_recreation() {
    use acpmux_core::hub::ListItem;
    let v1 = memory_hub();
    v1.insert_test_session(meta("existing"));
    v1.insert_test_session(meta("new"));
    let mut peer = Summary::new("peer-chat");
    peer.origin = "peer".into();
    let index = acpmux_book::index::SummaryIndex::new()
        .apply(1, Summary::new("existing"))
        .apply(2, Summary::new("gone-while-down"))
        .apply(3, peer);
    let (hub, writer) = acpmux_core::hub::Hub::new(index);
    let v2 = Arc::new(V2::new(hub, writer));
    let subscribed = v2.hub.subscribe(&acpmux_core::wire::Sub::new("test", "list")).unwrap();
    let writer = tokio::spawn(v2.take_writer().unwrap().run());
    let (handle, task) = start_v2_tee(v1.clone(), v2.clone());
    v1.install_v2_tee(handle);
    let tee = tokio::spawn(task);
    let mut summaries = HashSet::new();
    let mut gone = HashSet::new();
    for _ in 0..3 {
        match next(&subscribed.receiver).await {
            ListItem::Summary(event) => {
                summaries.insert(event.summary.chat_id.clone());
            }
            ListItem::Gone { chat_id, .. } => {
                gone.insert(chat_id);
            }
            _ => panic!("a three-row walk must not lag"),
        }
    }
    assert_eq!(summaries, HashSet::from(["existing".to_owned(), "new".to_owned()]));
    assert_eq!(gone, HashSet::from(["gone-while-down".to_owned()]));
    assert!(v2.hub.snapshot().get_row(&RowKey::new("peer", "peer-chat")).is_some());
    let session = v1.sessions.lock().unwrap().remove("existing").unwrap();
    let mut purged = super::super::row_log::row_event("existing");
    Arc::make_mut(&mut purged.record).kind = "purged".into();
    let _ = v1.events.send(purged);
    assert!(
        matches!(next(&subscribed.receiver).await, ListItem::Gone { chat_id, .. } if chat_id == "existing")
    );
    v1.insert_test_session(session.meta());
    assert!(
        matches!(next(&subscribed.receiver).await, ListItem::Summary(event) if event.summary.chat_id == "existing")
    );
    tee.abort();
    let _ = tee.await;
    v2.hub.close();
    writer.await.unwrap().unwrap();
}

#[tokio::test]
async fn attending_a_chat_updates_the_tee_unread_count_through_seen() {
    use acpmux_core::hub::ListItem;
    let v1 = memory_hub();
    let mut row = meta("unread");
    row.unread = true;
    row.unread_turns = 3;
    let session = v1.insert_test_session(row);
    let (hub, writer) = acpmux_core::hub::Hub::new(acpmux_book::index::SummaryIndex::new());
    let v2 = Arc::new(V2::new(hub, writer));
    let subscribed = v2.hub.subscribe(&acpmux_core::wire::Sub::new("test", "list")).unwrap();
    let writer = tokio::spawn(v2.take_writer().unwrap().run());
    let (handle, task) = start_v2_tee(v1.clone(), v2.clone());
    v1.install_v2_tee(handle);
    let tee = tokio::spawn(task);
    let ListItem::Summary(before) = next(&subscribed.receiver).await else {
        panic!("initial unread row");
    };
    assert_eq!(before.summary.unread, 3);
    // This is the real attach/seen path, not an artificial tee mark.
    v1.attach_count(&session, 1, true);
    let ListItem::Summary(after) = next(&subscribed.receiver).await else {
        panic!("seen row");
    };
    assert_eq!(after.summary.unread, 0);
    assert_eq!(v1.session_list_summary(&session)["unread"], false);
    tee.abort();
    let _ = tee.await;
    v2.hub.close();
    writer.await.unwrap().unwrap();
}

#[tokio::test]
async fn repeated_slot_waits_mark_only_the_two_edges_without_records() {
    use acpmux_core::hub::ListItem;
    let v1 = memory_hub();
    let mut child = meta("child");
    child.subsession = Some(crate::store::SubsessionLink {
        started_by: "parent".into(),
        short_name: "child".into(),
        depth: 1,
        offered: false,
    });
    let child = v1.insert_test_session(child);
    let (hub, writer) = acpmux_core::hub::Hub::new(acpmux_book::index::SummaryIndex::new());
    let v2 = Arc::new(V2::new(hub, writer));
    let subscribed = v2.hub.subscribe(&acpmux_core::wire::Sub::new("test", "list")).unwrap();
    let writer = tokio::spawn(v2.take_writer().unwrap().run());
    let (handle, task) = start_v2_tee(v1.clone(), v2.clone());
    let marks = handle.state.clone();
    v1.install_v2_tee(handle);
    let tee = tokio::spawn(task);
    assert!(matches!(next(&subscribed.receiver).await, ListItem::Summary(_)));
    let initial = marks.marks.load(Ordering::Relaxed);
    let last_record = child.meta().last_seq;
    let first = v1.mark_waiting_for_slot("parent", &child);
    let second = v1.mark_waiting_for_slot("parent", &child);
    assert_eq!(marks.marks.load(Ordering::Relaxed), initial + 1);
    assert_eq!(v1.session_list_summary(&child).get("waitsForSlot"), Some(&Value::Bool(true)));
    let ListItem::Summary(event) = next(&subscribed.receiver).await else {
        panic!("summary");
    };
    let extra: Value = serde_json::from_str(event.summary.extra.get()).unwrap();
    assert_eq!(extra.get("waitsForSlot"), Some(&Value::Bool(true)));
    drop(first);
    assert_eq!(marks.marks.load(Ordering::Relaxed), initial + 1);
    drop(second);
    assert_eq!(marks.marks.load(Ordering::Relaxed), initial + 2);
    assert!(
        !v1.session_list_summary(&child)
            .get("waitsForSlot")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    );
    let ListItem::Summary(event) = next(&subscribed.receiver).await else {
        panic!("summary");
    };
    let extra: Value = serde_json::from_str(event.summary.extra.get()).unwrap();
    assert!(!extra.get("waitsForSlot").and_then(Value::as_bool).unwrap_or(false));
    assert_eq!(child.meta().last_seq, last_record, "neither edge needed a record");
    assert!(subscribed.receiver.try_next().is_none());
    tee.abort();
    let _ = tee.await;
    v2.hub.close();
    writer.await.unwrap().unwrap();
}

#[tokio::test]
async fn a_queued_family_prompt_marks_once_per_wait_edge() {
    use acpmux_core::hub::ListItem;
    use std::future::Future;
    use std::task::Poll;

    let v1 = memory_hub();
    let mut parent = meta("parent");
    parent.subsession_limits.max_running = Some(1);
    v1.insert_test_session(parent);
    let child_meta = |id| {
        let mut value = meta(id);
        value.status = crate::store::SessionStatus::Idle;
        value.subsession = Some(crate::store::SubsessionLink {
            started_by: "parent".into(),
            short_name: id.into(),
            depth: 1,
            offered: false,
        });
        value
    };
    let running = v1.insert_test_session(child_meta("running"));
    let child = v1.insert_test_session(child_meta("queued"));
    let provenance = json!({"kind": super::super::subsessions::PROVENANCE_KIND});
    let occupied = v1.take_run_slot(&running, Some(&provenance)).unwrap().unwrap();
    let mut initial = acpmux_book::index::SummaryIndex::new();
    for (n, session) in v1.session_handles().iter().enumerate() {
        initial = initial.apply(n as u64 + 1, summary_from_session(&v1, session).unwrap());
    }
    let (hub, writer) = acpmux_core::hub::Hub::new(initial);
    let v2 = Arc::new(V2::new(hub, writer));
    let subscribed = v2.hub.subscribe(&acpmux_core::wire::Sub::new("queued", "list")).unwrap();
    let writer = tokio::spawn(v2.take_writer().unwrap().run());
    let (handle, task) = start_v2_tee(v1.clone(), v2.clone());
    v1.install_v2_tee(handle);
    let tee = tokio::spawn(task);
    let blocks = [json!({"type":"text", "text":"waiting"})];
    let replaced = std::sync::OnceLock::new();
    let slot = super::super::queue::Slot {
        text: "waiting",
        blocks: &blocks,
        display_parts: None,
        client: "tee-test",
        prompt_id: "queued-prompt",
        control: Control::Local,
        cloud_mobile: false,
        trust_gate: false,
        interrupt: false,
        interrupt_turn: None,
        provenance: Some(&provenance),
        agent: None,
        class: None,
        supersede: None,
        full_access_device: None,
        replaced: &replaced,
        no_queue: false,
        admitted: false,
        after_turn: false,
    };
    let mut accepted = |value: Value| assert_eq!(value.get("waitsForSlot"), Some(&json!(true)));
    let mut waiting = Box::pin(v1.queue_slot(&child, slot, &mut accepted));
    // This poll reaches both queue_slot's initial mark and queue_turn's second
    // mark for the same prompt. Neither can obtain the occupied parent slot.
    std::future::poll_fn(|cx| {
        assert!(waiting.as_mut().poll(cx).is_pending());
        Poll::Ready(())
    })
    .await;
    assert!(v1.waits_for_slot(&child.meta()));
    let ListItem::Summary(event) = next(&subscribed.receiver).await else { panic!("summary") };
    assert_eq!(event.summary.chat_id, child.id);
    let extra: Value = serde_json::from_str(event.summary.extra.get()).unwrap();
    assert_eq!(extra.get("waitsForSlot"), Some(&json!(true)));
    assert!(subscribed.receiver.try_next().is_none());
    assert!(v1.remove_queued(&child, "queued-prompt"));
    assert!(
        tokio::time::timeout(std::time::Duration::from_secs(5), waiting).await.unwrap().is_err()
    );
    assert!(!v1.waits_for_slot(&child.meta()));
    let ListItem::Summary(event) = next(&subscribed.receiver).await else { panic!("summary") };
    let extra: Value = serde_json::from_str(event.summary.extra.get()).unwrap();
    assert!(!extra.get("waitsForSlot").and_then(Value::as_bool).unwrap_or(false));
    assert!(subscribed.receiver.try_next().is_none());
    drop(occupied);
    tee.abort();
    let _ = tee.await;
    v2.hub.close();
    writer.await.unwrap().unwrap();
}

#[tokio::test]
async fn a_tag_expiry_reaches_the_subscriber_without_another_record() {
    use acpmux_core::hub::ListItem;
    let v1 = memory_hub();
    let child = v1.insert_test_session(meta("expiring"));
    let (hub, writer) = acpmux_core::hub::Hub::new(acpmux_book::index::SummaryIndex::new());
    let v2 = Arc::new(V2::new(hub, writer));
    let subscribed = v2.hub.subscribe(&acpmux_core::wire::Sub::new("test", "list")).unwrap();
    let writer = tokio::spawn(v2.take_writer().unwrap().run());
    let (handle, task) = start_v2_tee(v1.clone(), v2.clone());
    v1.install_v2_tee(handle);
    let tee = tokio::spawn(task);
    let _ = next(&subscribed.receiver).await;
    v1.edit_test_meta(&child, |meta| {
        meta.tags.insert(
            "notifications".into(),
            crate::store::Tag {
                value: "muted".into(),
                expires_at: Some(crate::store::now_ms() + 2_000),
            },
        );
    });
    let ListItem::Summary(before) = next(&subscribed.receiver).await else {
        panic!("summary");
    };
    let extra: Value = serde_json::from_str(before.summary.extra.get()).unwrap();
    assert_eq!(extra.pointer("/tags/notifications").and_then(Value::as_str), Some("muted"));
    let last_record = child.meta().last_seq;
    // No event and no mark after this point. The task's deadline schedule
    // must produce the changed row using the same wall clock as v1 tags.
    let ListItem::Summary(after) = next(&subscribed.receiver).await else {
        panic!("summary");
    };
    let extra: Value = serde_json::from_str(after.summary.extra.get()).unwrap();
    assert!(extra.pointer("/tags/notifications").is_none());
    assert!(v1.session_list_summary(&child).pointer("/tags/notifications").is_none());
    assert_eq!(child.meta().last_seq, last_record);
    tee.abort();
    let _ = tee.await;
    v2.hub.close();
    writer.await.unwrap().unwrap();
}
