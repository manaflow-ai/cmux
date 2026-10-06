//! Disk behavior of the attachment store: bytes land once by hash in
//! `attachments/`, survive a reopen, partial files never outlive their run,
//! and unreferenced records are swept with their bytes.

use super::super::ConversationStore;
use super::*;
use cmux_conversation::{Op, Participant};

struct TempDir(PathBuf);

impl TempDir {
    fn new(name: &str) -> Self {
        let mut random = [0_u8; 8];
        getrandom::fill(&mut random).unwrap();
        let suffix: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
        let path = std::env::temp_dir().join(format!("cmux-attachments-{name}-{suffix}"));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

const BYTES: &[u8] = b"\x89PNG not pixels";

fn hash(bytes: &[u8]) -> String {
    hex_digest({
        let mut hasher = Sha256::new();
        hasher.update(bytes);
        hasher
    })
}

fn participants() -> Vec<Participant> {
    serde_json::from_value(serde_json::json!([
        {"id":"user_local","kind":"human","display_name":"Me"},
        {"id":"agent_mux","kind":"agent","display_name":"mux","agent_class":"mux"}
    ]))
    .unwrap()
}

fn declaration(bytes: &[u8]) -> UploadDeclaration {
    serde_json::from_value(serde_json::json!({
        "sha256": hash(bytes), "byte_count": bytes.len(), "mime_type": "image/png", "name": "a.png"
    }))
    .unwrap()
}

fn store_with_conversation(directory: &Path) -> (ConversationStore, String) {
    let mut store = ConversationStore::open(Some(directory)).unwrap();
    let created = store.create("create-1", "user_local", "mux", &participants()).unwrap();
    (store, created.summary.id)
}

fn upload(store: &mut ConversationStore, conversation: &str, bytes: &[u8]) -> StoredAttachment {
    let begun = store.attachment_begin(1, "user_local", conversation, &declaration(bytes)).unwrap();
    let id = begun.upload.unwrap();
    store.attachment_chunk(1, &id, Piece::Original, 0, bytes).unwrap();
    store.attachment_commit(1, &id).unwrap()
}

#[test]
fn bytes_are_stored_once_by_hash_and_survive_a_reopen() {
    let directory = TempDir::new("reopen");
    let (mut store, conversation) = store_with_conversation(&directory.0);
    upload(&mut store, &conversation, BYTES);
    let path = directory.0.join(ATTACHMENTS_DIRECTORY).join(hash(BYTES));
    assert_eq!(fs::read(&path).unwrap(), BYTES);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode =
            fs::metadata(directory.0.join(ATTACHMENTS_DIRECTORY)).unwrap().permissions().mode();
        assert_eq!(mode & 0o077, 0, "attachments/ is private");
    }
    drop(store);
    let store = ConversationStore::open(Some(&directory.0)).unwrap();
    let read = store
        .attachment_read("user_local", &conversation, &hash(BYTES), Piece::Original, 0, 1024)
        .unwrap();
    assert_eq!(read.data, BYTES);
    assert!(read.eof);
}

#[test]
fn an_interrupted_upload_leaves_no_partial_bytes_after_a_reopen() {
    let directory = TempDir::new("partial");
    let (mut store, conversation) = store_with_conversation(&directory.0);
    let begun =
        store.attachment_begin(1, "user_local", &conversation, &declaration(BYTES)).unwrap();
    store
        .attachment_chunk(1, begun.upload.as_deref().unwrap(), Piece::Original, 0, &BYTES[..4])
        .unwrap();
    let partial = directory.0.join(ATTACHMENTS_DIRECTORY).join(".partial");
    assert_eq!(fs::read_dir(&partial).unwrap().count(), 1);
    drop(store);
    let _store = ConversationStore::open(Some(&directory.0)).unwrap();
    assert_eq!(fs::read_dir(&partial).unwrap().count(), 0);
    assert!(!directory.0.join(ATTACHMENTS_DIRECTORY).join(hash(BYTES)).exists());
}

#[test]
fn a_closed_connection_ends_its_uploads() {
    let directory = TempDir::new("closed");
    let (mut store, conversation) = store_with_conversation(&directory.0);
    let begun =
        store.attachment_begin(7, "user_local", &conversation, &declaration(BYTES)).unwrap();
    store.attachments_client_closed(7);
    let error = store.attachment_commit(7, begun.upload.as_deref().unwrap()).unwrap_err();
    assert_eq!(error.to_string(), "unknown_upload");
    let partial = directory.0.join(ATTACHMENTS_DIRECTORY).join(".partial");
    assert_eq!(fs::read_dir(&partial).unwrap().count(), 0);
}

#[test]
fn unreferenced_records_are_swept_with_their_bytes_and_referenced_ones_stay() {
    let directory = TempDir::new("sweep");
    let (mut store, conversation) = store_with_conversation(&directory.0);
    let sent = b"\x89PNG sent";
    upload(&mut store, &conversation, BYTES);
    let stored = upload(&mut store, &conversation, sent);
    let part: Part = serde_json::from_value(serde_json::json!({
        "type":"attachment","hash":stored.hash,"name":"b.png","mime_type":"image/png",
        "byte_count":sent.len()
    }))
    .unwrap();
    store
        .apply_op(
            &conversation,
            "c1",
            "user_local",
            &Op::MessageSend { client_msg_id: "c1".into(), parts: vec![part], reply_to: None },
        )
        .unwrap();
    // Both records are older than the grace period.
    store.connection.execute("UPDATE attachment_record SET created_at_ms = 0", []).unwrap();
    store.sweep_unreferenced().unwrap();
    let root = directory.0.join(ATTACHMENTS_DIRECTORY);
    assert!(!root.join(hash(BYTES)).exists(), "the unsent upload is swept");
    assert!(root.join(hash(sent)).exists(), "the sent attachment stays");
    let error = store
        .attachment_read("user_local", &conversation, &hash(BYTES), Piece::Original, 0, 16)
        .unwrap_err();
    assert_eq!(error.to_string(), "unknown_attachment");
}

fn send(store: &mut ConversationStore, conversation: &str, key: &str, bytes: &[u8]) {
    let part: Part = serde_json::from_value(serde_json::json!({
        "type":"attachment","hash":hash(bytes),"name":"x.png","mime_type":"image/png",
        "byte_count":bytes.len()
    }))
    .unwrap();
    store
        .apply_op(
            conversation,
            key,
            "user_local",
            &Op::MessageSend { client_msg_id: key.into(), parts: vec![part], reply_to: None },
        )
        .unwrap();
}

#[test]
fn a_full_store_evicts_the_oldest_unsent_upload_then_refuses_with_storage_full() {
    let directory = TempDir::new("cap");
    let (mut store, conversation) = store_with_conversation(&directory.0);
    store.set_attachment_storage_cap(50);
    let (a, b, c, d) = (&[1_u8; 20][..], &[2_u8; 20][..], &[3_u8; 20][..], &[4_u8; 20][..]);
    upload(&mut store, &conversation, a);
    upload(&mut store, &conversation, b);
    send(&mut store, &conversation, "b", b);
    // 40 of 50 bytes are stored: C needs room, and A (never sent) goes.
    upload(&mut store, &conversation, c);
    let root = directory.0.join(ATTACHMENTS_DIRECTORY);
    assert!(!root.join(hash(a)).exists(), "the oldest unsent upload is evicted");
    assert!(root.join(hash(b)).exists() && root.join(hash(c)).exists());
    send(&mut store, &conversation, "c", c);
    // Everything stored is in a message: nothing may go, so D is refused.
    let error =
        store.attachment_begin(1, "user_local", &conversation, &declaration(d)).unwrap_err();
    assert_eq!(error.to_string(), "storage_full");
    assert_eq!(error.downcast_ref::<AttachmentRejected>().map(|r| r.0), Some("storage_full"));
}

#[test]
fn an_upload_in_flight_counts_against_the_cap() {
    let directory = TempDir::new("inflight");
    let (mut store, conversation) = store_with_conversation(&directory.0);
    store.set_attachment_storage_cap(30);
    let begun =
        store.attachment_begin(1, "user_local", &conversation, &declaration(&[5_u8; 20])).unwrap();
    assert!(begun.upload.is_some());
    let error = store
        .attachment_begin(2, "user_local", &conversation, &declaration(&[6_u8; 20]))
        .unwrap_err();
    assert_eq!(error.to_string(), "storage_full", "20 in flight + 20 > 30");
}

#[test]
fn a_link_preview_image_counts_as_referenced_and_survives_the_sweep() {
    let directory = TempDir::new("link-preview");
    let (mut store, conversation) = store_with_conversation(&directory.0);
    let image = b"\xff\xd8\xff\xe0 link preview";
    let begun = store
        .attachment_begin(
            1,
            "user_local",
            &conversation,
            &serde_json::from_value(serde_json::json!({
                "sha256": hash(image), "byte_count": image.len(), "mime_type": "image/jpeg",
                "name": "link-preview.jpg"
            }))
            .unwrap(),
        )
        .unwrap();
    let id = begun.upload.unwrap();
    store.attachment_chunk(1, &id, Piece::Original, 0, image).unwrap();
    store.attachment_commit(1, &id).unwrap();
    upload(&mut store, &conversation, BYTES);
    let part: Part = serde_json::from_value(serde_json::json!({
        "type":"link_preview","url":"https://example.com","title":"Example",
        "image":{"hash":hash(image),"mime_type":"image/jpeg","byte_count":image.len()}
    }))
    .unwrap();
    store
        .apply_op(
            &conversation,
            "c1",
            "user_local",
            &Op::MessageSend { client_msg_id: "c1".into(), parts: vec![part], reply_to: None },
        )
        .unwrap();
    store.connection.execute("UPDATE attachment_record SET created_at_ms = 0", []).unwrap();
    store.sweep_unreferenced().unwrap();
    let root = directory.0.join(ATTACHMENTS_DIRECTORY);
    assert!(!root.join(hash(BYTES)).exists(), "the unsent upload is swept");
    assert!(root.join(hash(image)).exists(), "the link preview's image stays");
    // The agent, which never uploaded it, may read it once a message references it.
    let read = store
        .attachment_read("agent_mux", &conversation, &hash(image), Piece::Original, 0, 1024)
        .unwrap();
    assert_eq!(read.data, image);
}
