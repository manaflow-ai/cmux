//! `draft_attachments.rs`: a draft's attachments, in order and in their place in its text, come
//! back after every transition a chat goes through (Leo, 2026-11-22: "there's prob additional
//! lifecycle stuff with making sure they dont get lost sometimes if random state happens").

use super::*;
use crate::config::{Config, StoreMode};

/// The page's inline token for a placed chip (webviews `attachments.ts` `inlineToken`): the id
/// between two U+FFFC marks.
fn token(id: &str) -> String {
    format!("\u{FFFC}{id}\u{FFFC}")
}

/// A draft with a picture placed between two words and a PDF after them.
fn draft_text() -> String {
    format!("look at {} then read {}", token("img-1"), token("pdf-2"))
}

fn chips() -> Vec<Value> {
    vec![
        json!({"id": "img-1", "kind": "image", "inline": true, "name": "shot.png",
               "mimeType": "image/png", "size": 4, "data": "iVBO"}),
        json!({"id": "pdf-2", "kind": "document", "inline": true, "name": "spec.pdf",
               "mimeType": "application/pdf", "size": 3, "data": "JVBE", "pageCount": 2}),
        json!({"id": "paste-3", "kind": "pasted", "name": "Pasted text", "mimeType": "text/plain",
               "size": 5, "text": "hello"}),
    ]
}

fn ids(chips: &[Value]) -> Vec<&str> {
    chips.iter().filter_map(|c| c["id"].as_str()).collect()
}

/// Every chip came back as it was written, in order, contents and all, and each placed one's token
/// is still where it was in the draft's text.
fn assert_in_place(hub: &Hub, session: &Session, kept: &[Value]) {
    assert_eq!(kept, chips().as_slice(), "the chips, in order, with their contents");
    let text = session.meta().composer_draft.unwrap_or_default();
    assert_eq!(text, draft_text(), "the draft's text with its tokens");
    let at = |id: &str| text.find(&token(id)).unwrap_or_else(|| panic!("{id} not placed"));
    assert!(at("img-1") < at("pdf-2"), "the picture before the PDF");
    assert_eq!(&text[..at("img-1")], "look at ");
    let _ = hub;
}

fn meta(id: &str) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "fake",
        "cwd": std::env::temp_dir(), "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap()
}

fn disk_hub(dir: &Path) -> Arc<Hub> {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    Hub::new(cfg.clone(), crate::store::open(&cfg.store, dir).unwrap())
}

fn chat(hub: &Hub, id: &str) -> Arc<Session> {
    let meta = hub.store.load(id).ok().flatten().unwrap_or_else(|| meta(id));
    hub.store.save(&meta).unwrap();
    hub.insert_test_session(meta)
}

async fn keep(hub: &Hub, session: &Arc<Session>) {
    hub.set_composer_draft(session, &draft_text()).unwrap();
    let held = hub.set_draft_attachments(session, chips()).await.unwrap();
    assert_eq!(held, ["img-1", "paste-3", "pdf-2"], "contents held for every chip");
}

/// App or daemon restart: the chips are on disk in the chat's folder, and a new daemon's read
/// of that folder (`draft_attachments`, which holds nothing in memory) brings them back. The
/// text's own restart is `durable_gate_tests.rs` ("the draft after the kill"); the store's
/// journal stays held by this process, so the reopen reads the folder as the next daemon does.
#[tokio::test]
async fn draft_attachments_survive_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let hub = disk_hub(dir.path());
    let s = chat(&hub, "restart");
    keep(&hub, &s).await;
    let folder = hub.store.session_path("restart").unwrap().join(DIR);
    assert!(folder.join(LIST).is_file(), "kept on disk");
    let kept = read(&folder).unwrap();
    assert_in_place(&hub, &s, &kept);
    assert_eq!(hub.draft_attachments(&s).await.unwrap(), kept, "the daemon reads the folder");
}

/// A bundle with a declared contents file missing is rejected instead of silently importing a
/// chip with no bytes. The source can therefore retry the move without losing the attachment.
#[tokio::test]
async fn a_missing_declared_attachment_file_fails_the_read() {
    let dir = tempfile::tempdir().unwrap();
    let hub = disk_hub(dir.path());
    let s = chat(&hub, "missing-file");
    keep(&hub, &s).await;
    let folder = hub.store.session_path("missing-file").unwrap().join(DIR);
    std::fs::remove_file(folder.join(file_name("img-1", "data"))).unwrap();
    let error = read(&folder).unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::NotFound);
    assert!(hub.draft_attachments(&s).await.is_err());
    let bundle = tempfile::tempdir().unwrap();
    assert!(hub.export_draft_attachments(&s, bundle.path()).is_err());

    let imported_bundle = tempfile::tempdir().unwrap();
    write(&imported_bundle.path().join(DIR), &chips()).unwrap();
    std::fs::remove_file(imported_bundle.path().join(DIR).join(file_name("img-1", "data")))
        .unwrap();
    let target_dir = tempfile::tempdir().unwrap();
    let target = disk_hub(target_dir.path());
    let target_session = chat(&target, "target");
    assert!(target.import_draft_attachments(imported_bundle.path(), &target_session.id).is_err());
    assert!(target.draft_attachments(&target_session).await.unwrap().is_empty());
}

#[test]
fn a_missing_carried_contents_file_rejects_the_write_without_changing_the_manifest() {
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path().join(DIR);
    write(&folder, &chips()).unwrap();
    let manifest_before = std::fs::read(folder.join(LIST)).unwrap();
    std::fs::remove_file(folder.join(file_name("img-1", "data"))).unwrap();

    let mut reconnect = chips();
    for chip in &mut reconnect {
        let object = chip.as_object_mut().unwrap();
        object.remove("data");
        object.remove("text");
    }
    let error = write(&folder, &reconnect).unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::NotFound);
    assert_eq!(std::fs::read(folder.join(LIST)).unwrap(), manifest_before);

    // A complete resend recovers the missing file, while removing a chip from the list remains
    // an intentional operation.
    write(&folder, &chips()).unwrap();
    let without_image: Vec<Value> =
        chips().into_iter().filter(|chip| chip["id"] != "img-1").collect();
    write(&folder, &without_image).unwrap();
}

#[test]
fn a_failed_manifest_commit_keeps_the_previous_payloads_readable() {
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path().join(DIR);
    write(&folder, &chips()).unwrap();
    let before = read(&folder).unwrap();
    let tmp = folder.join(LIST).with_extension(format!("tmp-{}", std::process::id()));
    std::fs::create_dir(&tmp).unwrap();

    let mut changed = chips();
    changed[0]["data"] = json!("changed");
    assert!(write(&folder, &changed).is_err(), "the occupied list temp blocks the commit");
    assert_eq!(read(&folder).unwrap(), before, "the old manifest still names old bytes");
    assert_eq!(std::fs::read_to_string(folder.join(file_name("img-1", "data"))).unwrap(), "iVBO");

    std::fs::remove_dir(&tmp).unwrap();
    write(&folder, &changed).unwrap();
    assert_eq!(read(&folder).unwrap(), changed, "the retry commits the staged replacement");
}

#[tokio::test]
async fn a_write_that_reaches_the_folder_after_a_move_starts_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let hub = disk_hub(dir.path());
    let s = chat(&hub, "freeze-race");
    keep(&hub, &s).await;
    let folder = hub.store.session_path("freeze-race").unwrap().join(DIR);
    let lock = turn(&folder);
    let guard = lock.lock().unwrap();
    let mut write = Box::pin(hub.set_draft_attachments(&s, chips()));
    tokio::task::yield_now().await;
    *s.moving.lock().unwrap() = Some("moving-now".into());
    drop(guard);
    assert!(write.await.is_err(), "a queued write cannot cross the move freeze");
    *s.moving.lock().unwrap() = None;
}

#[tokio::test]
async fn an_unwritable_destination_refuses_the_import_and_preserves_the_source() {
    let source_dir = tempfile::tempdir().unwrap();
    let source = disk_hub(source_dir.path());
    let session = chat(&source, "move-refused");
    keep(&source, &session).await;
    let bundle = tempfile::tempdir().unwrap();
    source.export_draft_attachments(&session, bundle.path()).unwrap();

    let target_dir = tempfile::tempdir().unwrap();
    let target = disk_hub(target_dir.path());
    target.store.save(&session.meta()).unwrap();
    let folder = target.store.session_path("move-refused").unwrap().join(DIR);
    std::fs::write(folder, b"not a directory").unwrap();
    assert!(target.import_draft_attachments(bundle.path(), "move-refused").is_err());
    let kept = source.draft_attachments(&session).await.unwrap();
    assert_in_place(&source, &session, &kept);
}

/// Session switch (A, then B, then A again) and a pane move or second client: each chat reads
/// its own chips, untouched by the other's writes.
#[tokio::test]
async fn draft_attachments_survive_a_session_switch() {
    let dir = tempfile::tempdir().unwrap();
    let hub = disk_hub(dir.path());
    let a = chat(&hub, "chat-a");
    let b = chat(&hub, "chat-b");
    keep(&hub, &a).await;
    hub.set_draft_attachments(&b, vec![json!({"id": "other", "kind": "text", "text": "b"})])
        .await
        .unwrap();
    hub.set_draft_attachments(&b, vec![]).await.unwrap();
    let kept = hub.draft_attachments(&a).await.unwrap();
    assert_in_place(&hub, &a, &kept);
    assert!(hub.draft_attachments(&b).await.unwrap().is_empty(), "B forgot its own");
}

/// Reconnect: the page's next write names its chips without their contents (they travelled
/// once); the folder keeps the contents it holds, and a reorder keeps each chip's.
#[tokio::test]
async fn draft_attachments_survive_a_reconnect_write_without_contents() {
    let dir = tempfile::tempdir().unwrap();
    let hub = disk_hub(dir.path());
    let s = chat(&hub, "reconnect");
    keep(&hub, &s).await;
    let named: Vec<Value> = chips()
        .into_iter()
        .map(|mut c| {
            let o = c.as_object_mut().unwrap();
            o.remove("data");
            o.remove("text");
            c
        })
        .collect();
    let held = hub.set_draft_attachments(&s, named).await.unwrap();
    assert_eq!(held, ["img-1", "paste-3", "pdf-2"]);
    let kept = hub.draft_attachments(&s).await.unwrap();
    assert_in_place(&hub, &s, &kept);
}

/// A move to another machine: the bundle carries the chips, the target keeps them, and the
/// source forgets them once the move commits.
#[tokio::test]
async fn draft_attachments_move_with_the_chat() {
    let (from, to, bundle) =
        (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let source = disk_hub(from.path());
    let s = chat(&source, "moved");
    keep(&source, &s).await;
    source.export_draft_attachments(&s, bundle.path()).unwrap();
    let target = disk_hub(to.path());
    let mut m = s.meta();
    m.updated_at += 1;
    target.store.save(&m).unwrap();
    target.import_draft_attachments(bundle.path(), "moved").unwrap();
    let landed = chat(&target, "moved");
    let kept = target.draft_attachments(&landed).await.unwrap();
    assert_in_place(&target, &landed, &kept);
    source.forget_draft_attachments(&s).unwrap();
    assert!(source.draft_attachments(&s).await.unwrap().is_empty(), "the source forgot them");
}

/// A failed write (a bad list) and a write while the chat is moving are refused whole: what was
/// kept stays, for the page to write again.
#[tokio::test]
async fn a_refused_draft_attachments_write_keeps_what_was_kept() {
    let dir = tempfile::tempdir().unwrap();
    let hub = disk_hub(dir.path());
    let s = chat(&hub, "refused");
    keep(&hub, &s).await;
    let bad = json!([{"id": "x"}, {"id": "x"}]);
    assert!(checked(&bad).is_err(), "an id twice");
    assert!(checked(&json!([{"name": "no id"}])).is_err());
    assert!(checked(&json!({"id": "x"})).is_err(), "not a list");
    *s.moving.lock().unwrap() = Some("t1".into());
    assert!(hub.set_draft_attachments(&s, vec![]).await.is_err(), "frozen while moving");
    *s.moving.lock().unwrap() = None;
    let kept = hub.draft_attachments(&s).await.unwrap();
    assert_in_place(&hub, &s, &kept);
}

/// Edit and resend: a chip taken out goes, with its file; the rest keep their order and contents.
#[tokio::test]
async fn removing_one_draft_attachment_keeps_the_others_in_order() {
    let dir = tempfile::tempdir().unwrap();
    let hub = disk_hub(dir.path());
    let s = chat(&hub, "edited");
    keep(&hub, &s).await;
    let rest: Vec<Value> = chips().into_iter().filter(|c| c["id"] != "img-1").collect();
    hub.set_draft_attachments(&s, rest.clone()).await.unwrap();
    let kept = hub.draft_attachments(&s).await.unwrap();
    assert_eq!(kept, rest);
    assert_eq!(ids(&kept), ["pdf-2", "paste-3"]);
    let folder = hub.store.session_path("edited").unwrap().join(DIR);
    assert!(!folder.join(file_name("img-1", "data")).exists(), "its file went");
    hub.set_draft_attachments(&s, vec![]).await.unwrap();
    assert!(!folder.exists(), "none forgets the folder");
}

/// A store with no folders (memory) keeps them for the daemon's life, the same way.
#[tokio::test]
async fn a_memory_store_keeps_draft_attachments_too() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    let s = hub.insert_test_session(meta("memory-chat"));
    keep(&hub, &s).await;
    let kept = hub.draft_attachments(&s).await.unwrap();
    assert_in_place(&hub, &s, &kept);
    hub.set_draft_attachments(&s, vec![]).await.unwrap();
    assert!(hub.draft_attachments(&s).await.unwrap().is_empty());
}
