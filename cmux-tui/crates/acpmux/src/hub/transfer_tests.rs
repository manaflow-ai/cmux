use super::*;

/// A durable replacement (`transfer_in.rs`) moved the chat's store aside before its import,
/// which failed: the import leaves no marker, so the move can be tried again on this daemon.
#[tokio::test]
async fn a_failed_durable_replacement_leaves_no_recovery_marker() {
    let dir = std::env::temp_dir().join(format!("acpmux-test-{}", uuid::Uuid::now_v7()));
    let profile = crate::config::HarnessProfile {
        kind: Default::default(),
        argv: vec!["true".into()],
        env: Default::default(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut cfg = crate::config::Config::default();
    cfg.harnesses.insert("cmux-harness".into(), profile);
    cfg.store.mode = crate::config::StoreMode::Local;
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &dir).unwrap());
    let id = uuid::Uuid::now_v7().to_string();
    let meta = json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "durable",
        "harness": "cmux-harness", "cwd": std::env::temp_dir(), "agentSessionId": "agent-0002",
        "status": "idle", "createdAt": 1, "updatedAt": 1,
    });
    let backup = dir.join("sessions").join(format!(".{id}.replacement-backup"));
    std::fs::create_dir_all(&backup).unwrap();
    std::fs::write(backup.join("session.json"), meta.to_string()).unwrap();
    let bundle = dir.join("bundle");
    std::fs::create_dir_all(bundle.join("events")).unwrap();
    std::fs::write(bundle.join("session.json"), meta.to_string()).unwrap();
    std::fs::write(bundle.join("events").join("000001.ndjson"), "not a record\n").unwrap();
    let marker = dir.join("sessions/.agent-0002.durable-transfer-state");
    for attempt in ["first", "retry"] {
        let failed = hub.import_into(&bundle, None, true, None, true, true).await;
        let failed = failed.err().map(|e| e.message);
        assert!(
            failed.as_deref().is_some_and(|m| m.starts_with("import events")),
            "{attempt}: {failed:?}"
        );
        assert!(!marker.exists(), "{attempt} left its recovery marker");
    }
    assert!(backup.join("session.json").exists(), "the moved-aside store is the receive's");
    let _ = std::fs::remove_dir_all(&dir);
}

fn harness_hub(dir: &Path) -> Arc<Hub> {
    let profile = crate::config::HarnessProfile {
        kind: Default::default(),
        argv: vec!["true".into()],
        env: Default::default(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut cfg = crate::config::Config::default();
    cfg.harnesses.insert("cmux-harness".into(), profile);
    cfg.store.mode = crate::config::StoreMode::Local;
    Hub::new(cfg.clone(), crate::store::open(&cfg.store, dir).unwrap())
}

fn harness_meta(id: &str, agent: &str) -> Value {
    json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "durable",
        "harness": "cmux-harness", "cwd": std::env::temp_dir(), "agentSessionId": agent,
        "status": "idle", "createdAt": 1, "updatedAt": 1,
    })
}

/// Review of #25676: a marker write that fails before its rename takes its temporary file
/// with it, so the next write of that marker (a retry's) is not refused as occupied.
#[test]
fn a_failed_marker_write_leaves_no_temporary_file() {
    let dir = std::env::temp_dir().join(format!("acpmux-test-{}", uuid::Uuid::now_v7()));
    let marker = dir.join(".agent-0004.durable-transfer-state");
    // A non-empty directory where the marker goes: the rename fails.
    std::fs::create_dir_all(marker.join("in-the-way")).unwrap();
    let written = write_json_atomic(&marker, &json!({"phase": "staged"}));
    assert!(written.is_err(), "the rename onto a directory went through");
    let tmp = dir.join(".agent-0004.durable-transfer-state.importing");
    assert!(!tmp.exists(), "the failed write left its temporary file");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Review of #25676: a prepared marker that is renamed into place before the directory sync
/// fails is this import's own, so the failed preparation does not leave it.
#[cfg(unix)]
#[tokio::test]
async fn a_prepared_marker_whose_directory_sync_fails_does_not_stay() {
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::temp_dir().join(format!("acpmux-test-{}", uuid::Uuid::now_v7()));
    let hub = harness_hub(&dir);
    let root = dir.join("sessions");
    std::fs::create_dir_all(&root).unwrap();
    let id = uuid::Uuid::now_v7().to_string();
    let meta: SessionMeta = serde_json::from_value(harness_meta(&id, "agent-0005")).unwrap();
    // Write and search but no read: the marker is written and renamed, the sync's open fails.
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o300)).unwrap();
    if std::fs::read_dir(&root).is_ok() {
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o755)).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        eprintln!("skipped: this user reads a directory without its read bit");
        return;
    }
    let prepared = hub.prepare_harness_state(&meta, false);
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(prepared.is_err(), "the directory sync went through");
    let marker = root.join(".agent-0005.durable-transfer-state");
    assert!(!marker.exists(), "the failed preparation left its marker");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Review 105 of #25676: a sweep on this daemon (another import's failed finalize) that read a
/// failed import's marker finishes with it before that import's own rollback and its retry
/// run, so it never removes the store and marker the retry made.
#[tokio::test]
async fn a_sweep_never_removes_a_retry_made_after_it_read_the_old_marker() {
    let dir = std::env::temp_dir().join(format!("acpmux-test-{}", uuid::Uuid::now_v7()));
    let hub = harness_hub(&dir);
    let root = dir.join("sessions");
    let id = uuid::Uuid::now_v7().to_string();
    let meta: SessionMeta = serde_json::from_value(harness_meta(&id, "agent-0009")).unwrap();
    // The failed import: its store and its prepared marker.
    hub.store.save(&meta).unwrap();
    hub.prepare_harness_state(&meta, false).unwrap();
    let (h, m) = (hub.clone(), meta.clone());
    let retry = std::sync::Mutex::new(Some(move || {
        h.drop_failed_import(&m);
        h.store.save(&m).unwrap();
        h.prepare_harness_state(&m, false).unwrap();
    }));
    let writer = Arc::new(std::sync::Mutex::new(None::<std::thread::JoinHandle<()>>));
    let spawned = writer.clone();
    let hook = super::super::transfer_in::on_sweep_pause(move |agent| {
        if agent != "agent-0009" {
            return;
        }
        let Some(retry) = retry.lock().unwrap().take() else { return };
        let (done, finished) = std::sync::mpsc::channel();
        *spawned.lock().unwrap() = Some(std::thread::spawn(move || {
            retry();
            let _ = done.send(());
        }));
        let _ = finished.recv_timeout(std::time::Duration::from_millis(300));
    });
    hub.recover_staged_replacements();
    // The sweep on this thread read the failed import's marker, and only that one.
    assert_eq!(hook.reached(), ["agent-0009"]);
    drop(hook);
    let handle = writer.lock().unwrap().take();
    handle.expect("the sweep never read the marker").join().unwrap();
    assert!(root.join(&id).join("session.json").exists(), "the sweep removed the retry's store");
    let marker = root.join(".agent-0009.durable-transfer-state");
    assert!(marker.exists(), "the sweep removed the retry's marker");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Review 104 of #25676: a failed staged import whose store stays for recovery keeps no open
/// log writer, so after a recovery on this daemon removes that store, a retry's events land
/// in the new log on disk, not in the removed one.
#[tokio::test]
async fn a_retry_after_a_kept_failed_import_is_recovered_writes_its_log() {
    let dir = std::env::temp_dir().join(format!("acpmux-test-{}", uuid::Uuid::now_v7()));
    let hub = harness_hub(&dir);
    let root = dir.join("sessions");
    let id = uuid::Uuid::now_v7().to_string();
    let meta: SessionMeta = serde_json::from_value(harness_meta(&id, "agent-0008")).unwrap();
    let record = |seq: u64, kind: &str| -> EventRecord {
        serde_json::from_value(json!({"seq": seq, "at": 0, "dir": "mux", "kind": kind, "msg": {}}))
            .unwrap()
    };
    // The failed import wrote its store and some of its events (`copy_bundle_events`).
    hub.store.save(&meta).unwrap();
    hub.store.append(&id, &record(1, "first-attempt")).unwrap();
    let marker = root.join(".agent-0008.durable-transfer-state");
    let staged = json!({
        "agentId": "agent-0008", "outerId": id, "replaceDurable": false, "phase": "staged",
        "transferId": "t-0008", "piFilename": "agent-0008.jsonl",
        "journalDirWasPresent": false, "hadJournal": false, "hadPi": false,
    });
    std::fs::write(&marker, staged.to_string()).unwrap();
    hub.drop_failed_import(&meta);
    // Another import's failed finalize sweeps on this daemon (`import_into`).
    hub.recover_staged_replacements();
    assert!(!marker.exists(), "the sweep left the failed import's marker");
    // The retry.
    hub.store.save(&meta).unwrap();
    hub.store.append(&id, &record(1, "retry")).unwrap();
    let mut kinds = Vec::new();
    let _ = hub.store.scan(&id, 0, &mut |e: EventRecord| {
        kinds.push(e.kind);
        true
    });
    assert_eq!(kinds, ["retry"], "the retry's event is not in its log on disk");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Review 102 of #25676: an import that failed once its durable state was staged is never
/// loaded as a chat, even when its rollback cannot finish. Its marker and store wait for the
/// next start, whose sweep rolls it back as far as it can and loads nothing of it.
#[tokio::test]
async fn a_staged_import_that_failed_is_not_loaded_at_the_next_start() {
    let dir = std::env::temp_dir().join(format!("acpmux-test-{}", uuid::Uuid::now_v7()));
    let hub = harness_hub(&dir);
    let root = dir.join("sessions");
    let id = uuid::Uuid::now_v7().to_string();
    std::fs::create_dir_all(root.join(&id)).unwrap();
    let owner = harness_meta(&id, "agent-0006");
    std::fs::write(root.join(&id).join("session.json"), owner.to_string()).unwrap();
    let journal_dir = root.join("agent-0006");
    // The journal's path is a non-empty directory: its backup cannot be renamed back.
    std::fs::create_dir_all(journal_dir.join("journal.ndjson").join("in-the-way")).unwrap();
    std::fs::write(journal_dir.join("journal.ndjson.transfer-backup"), "before\n").unwrap();
    let marker = root.join(".agent-0006.durable-transfer-state");
    let staged = json!({
        "agentId": "agent-0006", "outerId": id, "replaceDurable": false, "phase": "staged",
        "transferId": "t-0006", "piFilename": "agent-0006.jsonl",
        "journalDirWasPresent": true, "hadJournal": true, "hadPi": false,
    });
    std::fs::write(&marker, staged.to_string()).unwrap();
    let meta: SessionMeta = serde_json::from_value(owner).unwrap();
    hub.drop_failed_import(&meta);
    // The daemon's shutdown seal: the journal's lock passes to the next start.
    hub.seal();
    drop(hub);
    let restarted = harness_hub(&dir);
    let loaded = restarted.sessions.lock().unwrap().contains_key(&id);
    assert!(!loaded, "the failed import loaded as a chat at the next start");
    assert!(!marker.exists(), "the next start left the failed import's marker");
    let _ = std::fs::remove_dir_all(&dir);
}
